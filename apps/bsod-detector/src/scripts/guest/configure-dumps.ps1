<#
.SYNOPSIS
    Configure Windows crash-dump settings so a dump is written on the next BSOD,
    or verify the current settings without changing them.

.DESCRIPTION
    Applies the recommended CrashControl values from crash-control.json under
    HKLM\SYSTEM\CurrentControlSet\Control\CrashControl and stages NotMyFault for the
    trigger step. With -VerifyOnly it only reports the live values; nothing is changed.

    Runs on the guest VM. Applying requires Administrator. Pagefile sizing belongs to
    golden-image-pre-reboot.ps1; this script only reports it.

.PARAMETER DumpType
    Override the recommended dump type with any key of crash-control.json
    .crashDumpTypes. Defaults to .recommended.crashDumpType.

.PARAMETER VerifyOnly
    Report the current settings without changing anything.

.PARAMETER DataFile
    Path to crash-control.json. Required when the script is staged outside its
    repository layout (for example through qemu-guest-agent).

.OUTPUTS
    One JSON object on stdout:
    {
      "ok": true,
      "action": "applied" | "verified",
      "requestedDumpType": "automatic",
      "applied": { "CrashDumpEnabled": 7, ... } | null,   # null with -VerifyOnly
      "current": { "CrashDumpEnabled": 7, ... },           # live registry values
      "matchesRecommended": true,
      "rebootRequired": false,                             # true when CrashDumpEnabled was changed
      "pageFile": { "configured": "<PagingFiles entries joined by '; '>" | null, "adequate": true | false }
    }
    On failure: { "ok": false, "error": "...", "script": "configure-dumps.ps1" } with exit
    code 2 (unknown dump type) or 3 (not elevated). A missing data file is a terminating
    error.
#>
[CmdletBinding()]
param(
    [string]$DumpType,
    [switch]$VerifyOnly,
    [string]$DataFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail ([string]$Message, [int]$ExitCode) {
    [ordered]@{ ok = $false; error = $Message; script = 'configure-dumps.ps1' } | ConvertTo-Json
    exit $ExitCode
}

# Returns nothing when the key or value is absent. The property check keeps StrictMode from
# throwing if Get-ItemProperty returns an object without that property.
function Get-RegValue ([string]$Path, [string]$Name) {
    $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($item -and ($item.PSObject.Properties.Name -contains $Name)) { $item.$Name }
}

# Get-ItemProperty returns REG_EXPAND_SZ data expanded, so expand both sides before comparing.
function Test-ValueMatch ($Actual, $Expected) {
    if ($null -eq $Actual -or $null -eq $Expected) { return $false }
    [Environment]::ExpandEnvironmentVariables($Actual.ToString()) -eq [Environment]::ExpandEnvironmentVariables($Expected.ToString())
}

# Default to the repository copy: <app>\src\data\crash-control.json.
if (-not $DataFile) {
    $appDir = Join-Path $PSScriptRoot '..\..\..'
    if (Test-Path $appDir) { $DataFile = Join-Path (Resolve-Path $appDir) 'src\data\crash-control.json' }
}
if (-not $DataFile) { throw 'No explicit data path is configured for crash-control.json' }
if (-not (Test-Path $DataFile)) { throw "Data file not found: $DataFile" }
$cfg = Get-Content -Raw -Path $DataFile | ConvertFrom-Json

$type = if ($DumpType) { $DumpType } else { $cfg.recommended.crashDumpType }
$typeNames = $cfg.crashDumpTypes.PSObject.Properties.Name
if ($typeNames -notcontains $type) { Fail "Unknown dump type '$type'. Valid: $($typeNames -join ', ')." 2 }
$crashDumpEnabled = [int]$cfg.crashDumpTypes.$type.CrashDumpEnabled

# Recommended values, with CrashDumpEnabled taken from the selected dump type.
$regPath = $cfg.registryPath
$desired = [ordered]@{}
foreach ($prop in $cfg.recommended.values.PSObject.Properties) { $desired[$prop.Name] = $prop.Value }
$desired['CrashDumpEnabled'] = $crashDumpEnabled

$action = 'verified'
$applied = $null
$isRebootRequired = $false
if (-not $VerifyOnly) {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Fail 'configure-dumps.ps1 must run elevated (Administrator) to write CrashControl.' 3
    }
    $isRebootRequired = -not (Test-ValueMatch (Get-RegValue $regPath 'CrashDumpEnabled') $crashDumpEnabled)

    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    # Drop any existing DedicatedDumpFile; the loop below writes it back only if the data
    # file recommends it (the golden image requires it absent, see virtio-win issue #1629).
    Remove-ItemProperty -Path $regPath -Name 'DedicatedDumpFile' -ErrorAction SilentlyContinue
    # Strings are REG_EXPAND_SZ (expanded when read); numbers are DWORD.
    foreach ($name in $desired.Keys) {
        $value = $desired[$name]
        if ($value -is [string]) {
            New-ItemProperty -Path $regPath -Name $name -Value $value -PropertyType ExpandString -Force | Out-Null
        } else {
            New-ItemProperty -Path $regPath -Name $name -Value ([int]$value) -PropertyType DWord -Force | Out-Null
        }
    }
    $action = 'applied'
    $applied = $desired

    # The trigger step needs NotMyFault (preflight checks this path). Best effort: on any
    # failure the binary stays missing and preflight reports it.
    $nmfDir = 'C:\Temp\nmf'
    $nmfPath = "$nmfDir\notmyfaultc64.exe"
    if (-not (Test-Path $nmfPath)) {
        try {
            New-Item -ItemType Directory -Force -Path $nmfDir | Out-Null
            $zip = "$nmfDir\NotMyFault.zip"
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            (New-Object System.Net.WebClient).DownloadFile('https://download.sysinternals.com/files/NotMyFault.zip', $zip)
            Expand-Archive -Path $zip -DestinationPath $nmfDir -Force
            Remove-Item $zip -Force
            Unblock-File -Path $nmfPath -ErrorAction SilentlyContinue
        } catch {
            # Non-fatal by design; see above.
        }
    }
}

$current = [ordered]@{}
$isMatch = $true
foreach ($name in $desired.Keys) {
    $current[$name] = Get-RegValue $regPath $name
    if (-not (Test-ValueMatch $current[$name] $desired[$name])) { $isMatch = $false }
}

# Adequate = the last entry ("<path> <initialMB> <maxMB>") with both sizes has a non-zero
# maximum; system-managed or missing pagefiles are not adequate.
$pfRaw = Get-RegValue $cfg.pageFile.path $cfg.pageFile.value
$pfEntries = @(if ($pfRaw) { $pfRaw })
$maxMb = $null
foreach ($entry in $pfEntries) {
    $sizes = @(($entry -split '\s+') -match '^\d+$')
    if ($sizes.Count -ge 2) { $maxMb = [int]$sizes[1] }
}
$pfConfigured = if ($pfEntries.Count) { $pfEntries -join '; ' } else { $null }
$isPfAdequate = ($null -ne $maxMb) -and ($maxMb -gt 0)

[ordered]@{
    ok                 = $true
    action             = $action
    requestedDumpType  = $type
    applied            = $applied
    current            = $current
    matchesRecommended = $isMatch
    rebootRequired     = $isRebootRequired
    pageFile           = [ordered]@{ configured = $pfConfigured; adequate = $isPfAdequate }
} | ConvertTo-Json -Depth 12