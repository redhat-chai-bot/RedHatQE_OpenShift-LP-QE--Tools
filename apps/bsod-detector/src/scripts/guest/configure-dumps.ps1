<#
.SYNOPSIS
    Configure Windows crash-dump settings so a dump is written on the next BSOD,
    or verify the current settings without changing them.

.DESCRIPTION
    Applies the recommended CrashControl values from crash-control.json under
    HKLM\SYSTEM\CurrentControlSet\Control\CrashControl, removes any DedicatedDumpFile
    value (dumps go through the page file only) and stages NotMyFault for the trigger
    step. With -VerifyOnly it only reads and reports; nothing is written or downloaded.

    Runs on the guest VM. Applying requires Administrator. Pagefile sizing belongs to
    golden-image-pre-reboot.ps1 (a fixed C:\pagefile.sys of RAM + 257 MB); this script
    only reports whether the configured page file meets that size.

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
      "rebootRequired": false,      # true when CrashDumpEnabled changed or DedicatedDumpFile was removed
      "pageFile": {
        "configured": "<PagingFiles entries joined by '; '>" | null,
        "adequate": true | false,   # a C: entry with initial and maximum >= requiredMB; never null
        "requiredMB": 16641 | null  # RAM + 257 MB; null when RAM cannot be read
      }
    }
    On failure: { "ok": false, "error": "...", "script": "configure-dumps.ps1" } with exit
    code 2 (unknown dump type) or 3 (not elevated). A missing data file is a terminating
    error. NotMyFault staging problems are reported on stderr and do not change stdout.
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

# Fixed pagefile size in MB: physical RAM plus 257 MB, rounded once to a whole MB. Identical to
# the calculation in golden-image-pre-reboot.ps1 (which configures it) and
# golden-image-post-reboot.ps1 (which verifies the active page file).
function Get-PagefileSizeMB ([int64]$MemoryBytes) {
    [int64][math]::Round(($MemoryBytes + 257MB) / 1MB, 0)
}

# Adequate = a PagingFiles entry on C: ("C:\<file> <initialMB> <maxMB>") whose initial and maximum
# sizes are both at least the required size: a dump is written into the space allocated at boot.
# System-managed entries (no sizes, or 0 0), other drives, missing entries and an unknown RAM size
# are not adequate.
function Test-PageFileAdequate ([string[]]$Entries, $RequiredMB) {
    if ($null -eq $RequiredMB) { return $false }
    foreach ($entry in $Entries) {
        $sizes = @(($entry -split '\s+') -match '^\d+$')
        if ($entry -like 'C:\*' -and $sizes.Count -ge 2 -and [int64]$sizes[0] -ge $RequiredMB -and [int64]$sizes[1] -ge $RequiredMB) {
            return $true
        }
    }
    $false
}

# CrashDumpEnabled and DedicatedDumpFile both take effect only after a reboot.
function Test-RebootRequired ($CurrentCrashDumpEnabled, [int]$DesiredCrashDumpEnabled, [bool]$HadDedicatedDumpFile) {
    $HadDedicatedDumpFile -or "${CurrentCrashDumpEnabled}" -ne "${DesiredCrashDumpEnabled}"
}

# Default to the repository copy: <app>\src\data\crash-control.json.
if (-not $DataFile) {
    $appDir = Join-Path $PSScriptRoot '..\..\..'
    if (Test-Path $appDir) { $DataFile = Join-Path (Resolve-Path $appDir) 'src\data\crash-control.json' }
}
if (-not $DataFile) { throw 'No explicit data path is configured for crash-control.json' }
if (-not (Test-Path $DataFile)) { throw "Data file not found: ${DataFile}" }
$cfg = Get-Content -Raw -Path $DataFile | ConvertFrom-Json

$type = if ($DumpType) { $DumpType } else { $cfg.recommended.crashDumpType }
$typeNames = $cfg.crashDumpTypes.PSObject.Properties.Name
if ($typeNames -notcontains $type) { Fail "Unknown dump type '${type}'. Valid: $($typeNames -join ', ')." 2 }
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
    $hadDedicatedDumpFile = $null -ne (Get-RegValue $regPath 'DedicatedDumpFile')
    $isRebootRequired = Test-RebootRequired (Get-RegValue $regPath 'CrashDumpEnabled') $crashDumpEnabled $hadDedicatedDumpFile

    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    # Dumps go through the page file only: remove a DedicatedDumpFile left by an older
    # configuration (the golden image requires it absent, see virtio-win issue #1629).
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

    # The trigger step needs NotMyFault. C:\Temp\nmf is a fixed contract shared with the host
    # preflight and pipeline scripts, which check that exact path through the guest agent; a
    # per-user $env:TEMP would differ between the SYSTEM account used here and other accounts.
    # Staging stays best effort, but a failure is reported on stderr (stdout carries the JSON).
    $nmfDir = 'C:\Temp\nmf'
    $nmfPath = "${nmfDir}\notmyfaultc64.exe"
    if (-not (Test-Path $nmfPath)) {
        try {
            New-Item -ItemType Directory -Force -Path $nmfDir | Out-Null
            $zip = "${nmfDir}\NotMyFault.zip"
            # Add TLS 1.2 to the protocols this process already allows instead of replacing them.
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            (New-Object System.Net.WebClient).DownloadFile('https://download.sysinternals.com/files/NotMyFault.zip', $zip)
            Expand-Archive -Path $zip -DestinationPath $nmfDir -Force
            Remove-Item $zip -Force
            Unblock-File -Path $nmfPath -ErrorAction SilentlyContinue
        } catch {
            [Console]::Error.WriteLine("configure-dumps.ps1: WARN: NotMyFault staging to ${nmfPath} failed: $($_.Exception.Message)")
        }
    }
}

$current = [ordered]@{}
$isMatch = $true
foreach ($name in $desired.Keys) {
    $current[$name] = Get-RegValue $regPath $name
    if (-not (Test-ValueMatch $current[$name] $desired[$name])) { $isMatch = $false }
}

$pfRaw = Get-RegValue $cfg.pageFile.path $cfg.pageFile.value
$pfEntries = @(if ($pfRaw) { $pfRaw })
$pfConfigured = if ($pfEntries.Count) { $pfEntries -join '; ' } else { $null }
$requiredMB = $null
try {
    $requiredMB = Get-PagefileSizeMB (Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory
} catch {
    [Console]::Error.WriteLine("configure-dumps.ps1: WARN: cannot read physical memory size: $($_.Exception.Message)")
}
$isPfAdequate = Test-PageFileAdequate $pfEntries $requiredMB

[ordered]@{
    ok                 = $true
    action             = $action
    requestedDumpType  = $type
    applied            = $applied
    current            = $current
    matchesRecommended = $isMatch
    rebootRequired     = $isRebootRequired
    pageFile           = [ordered]@{ configured = $pfConfigured; adequate = $isPfAdequate; requiredMB = $requiredMB }
} | ConvertTo-Json -Depth 12
