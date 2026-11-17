<#
.SYNOPSIS
    Configure Windows crash-dump settings so a dump is written on the next BSOD,
    or verify the current settings without changing them.

.DESCRIPTION
    Applies the recommended CrashControl values from crash-control.json under
    HKLM\SYSTEM\CurrentControlSet\Control\CrashControl and removes any DedicatedDumpFile
    value (dumps go through the page file only). DedicatedDumpFile is never written: an older
    crash-control.json that still lists it is accepted, the entry is ignored and a warning is
    written to stderr. Only with -StageNotMyFault, for an intentional crash run, does it also
    stage NotMyFault. With -VerifyOnly it only reads and reports; nothing is written or
    downloaded, even if -StageNotMyFault is given.

    Runs on the guest VM. Applying requires Administrator. Pagefile sizing belongs to
    golden-image-pre-reboot.ps1 (a fixed C:\pagefile.sys of RAM + 257 MB, sized from the RAM of
    the VM that prepared the image); this script only reports whether the configured page file
    meets that size for the RAM of the VM it runs on. A VM with more RAM than the VM that
    prepared its golden image is therefore reported as not adequate, as is an image prepared by
    an older pre-reboot script (a 4096 MB page file and a DedicatedDumpFile): rebuild such an
    image with the current golden-image scripts.

.PARAMETER DumpType
    Override the recommended dump type with any key of crash-control.json
    .crashDumpTypes. Defaults to .recommended.crashDumpType.

.PARAMETER VerifyOnly
    Report the current settings without changing anything.

.PARAMETER StageNotMyFault
    Apply mode only: make sure C:\Temp\nmf\notmyfaultc64.exe is a trusted NotMyFault copy,
    downloading the Sysinternals archive when the file is missing or untrusted. A copy is trusted
    only when Windows reports a valid Authenticode signature whose signer certificate belongs to
    Microsoft Corporation, the publisher of the Sysinternals tools. An untrusted copy is renamed
    to notmyfaultc64.exe.untrusted (replacing an earlier quarantined copy; it is never run), so it
    cannot satisfy a later presence check; if that rename fails the script exits with code 5.
    Nothing passes this switch implicitly: a caller that requires the binary for an
    intentional crash run must pass it. Without it (watch runs, default apply, -VerifyOnly)
    nothing is downloaded.

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
      "dedicatedDumpFile": null | "<value>",               # live value; present means no match
      "matchesRecommended": true,
      "rebootRequired": false,      # true when CrashDumpEnabled changed or DedicatedDumpFile was removed
      "pageFile": {
        "configured": "<PagingFiles entries joined by '; '>" | null,
        "adequate": true | false,   # a C: entry with initial and maximum >= requiredMB; never null
        "requiredMB": 16641 | null  # RAM + 257 MB; null when RAM cannot be read or is not positive
      }
    }
    On failure: { "ok": false, "error": "...", "script": "configure-dumps.ps1" } with exit
    code 2 (unknown dump type), 3 (not elevated), 4 (CrashControl could not be written,
    including a DedicatedDumpFile value that could not be removed) or 5 (an untrusted NotMyFault
    copy could not be renamed away from C:\Temp\nmf). A missing data file is a
    terminating error. NotMyFault staging problems are reported on stderr and do not change
    stdout.
#>
[CmdletBinding()]
param(
    [string]$DumpType,
    [switch]$VerifyOnly,
    [switch]$StageNotMyFault,
    [string]$DataFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail ([string]$Message, [int]$ExitCode) {
    [ordered]@{ ok = $false; error = $Message; script = 'configure-dumps.ps1' } | ConvertTo-Json
    exit $ExitCode
}

# Diagnostics go to stderr; stdout carries only the JSON result.
function Write-StdErr ([string]$Message) {
    [Console]::Error.WriteLine("configure-dumps.ps1: ${Message}")
}

function Test-IsAdministrator {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Loads crash-control.json; without a path, the repository copy <app>\src\data\crash-control.json.
function Read-CrashControlData ([string]$Path) {
    if (-not $Path) {
        $appDir = Join-Path $PSScriptRoot '..\..\..'
        if (Test-Path $appDir) { $Path = Join-Path (Resolve-Path $appDir) 'src\data\crash-control.json' }
    }
    if (-not $Path) { throw 'No explicit data path is configured for crash-control.json' }
    if (-not (Test-Path $Path)) { throw "Data file not found: ${Path}" }
    Get-Content -Raw -Path $Path | ConvertFrom-Json
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

# The values to write: recommended.values with CrashDumpEnabled taken from the selected dump type.
# DedicatedDumpFile is always left out, so an older crash-control.json that still lists it cannot
# write it back after it was removed.
function Get-DesiredCrashControl ($RecommendedValues, [int]$CrashDumpEnabled) {
    $desired = [ordered]@{}
    foreach ($prop in $RecommendedValues.PSObject.Properties) {
        if ($prop.Name -ne 'DedicatedDumpFile') { $desired[$prop.Name] = $prop.Value }
    }
    $desired['CrashDumpEnabled'] = $CrashDumpEnabled
    $desired
}

# Removes a DedicatedDumpFile value left by an older configuration and returns 'removed', or
# 'absent' without touching the registry. A failed removal throws instead of being ignored.
function Remove-DedicatedDumpFile ([string]$Path) {
    if ($null -eq (Get-RegValue $Path 'DedicatedDumpFile')) { return 'absent' }
    Remove-ItemProperty -Path $Path -Name 'DedicatedDumpFile' -ErrorAction Stop
    'removed'
}

# Downloads the Sysinternals NotMyFault archive, adding TLS 1.2 to the protocols this process
# allows (with the SystemDefault setting the result is TLS 1.2 only).
function Save-NotMyFaultArchive ([string]$Path) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    (New-Object System.Net.WebClient).DownloadFile('https://download.sysinternals.com/files/NotMyFault.zip', $Path)
}

# Returns nothing for a trusted NotMyFault copy, otherwise the reason it is not trusted. Trusted
# means Windows reports a valid Authenticode signature (the file is intact and its certificate
# chain is trusted) and the signer certificate's subject has exactly the relative distinguished
# name O=Microsoft Corporation (commas inside quoted values do not separate names).
function Get-NotMyFaultTrustProblem ([string]$Path) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $signer = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { 'none' }
    if ("$($signature.Status)" -ne 'Valid') { return "signature status $($signature.Status), signer ${signer}" }
    $names = ($signer -split ',(?=(?:[^"]*"[^"]*")*[^"]*$)') -replace '^\s+|\s+$', ''
    if ($names -cnotcontains 'O=Microsoft Corporation') { return "signer is not Microsoft Corporation: ${signer}" }
}

# Stages a trusted NotMyFault for an intentional crash run and returns what happened. It works
# only in apply mode and only when -StageNotMyFault was given. A trusted existing copy is kept;
# an untrusted existing or downloaded copy is renamed to .untrusted so it is never used, and
# 'unsafe: ...' is returned if that rename fails (the caller then stops the script).
# C:\Temp\nmf is a fixed contract shared with the host preflight and pipeline scripts, which
# check that exact path through the guest agent (a per-user $env:TEMP would differ).
function Invoke-NotMyFaultStaging ([bool]$IsVerifyOnly, [bool]$IsStageRequested) {
    $nmfDir = 'C:\Temp\nmf'
    $nmfPath = "${nmfDir}\notmyfaultc64.exe"
    if ($IsVerifyOnly) { return 'skipped: -VerifyOnly is read-only' }
    if (-not $IsStageRequested) { return 'skipped: not requested' }
    $replaced = ''
    try {
        if (Test-Path -LiteralPath $nmfPath) {
            $problem = Get-NotMyFaultTrustProblem $nmfPath
            if (-not $problem) { return 'present' }
            try {
                Move-Item -LiteralPath $nmfPath -Destination "${nmfPath}.untrusted" -Force
            } catch {
                return "unsafe: the untrusted ${nmfPath} could not be renamed (${problem}): $($_.Exception.Message)"
            }
            $replaced = " (an untrusted copy was renamed to ${nmfPath}.untrusted: ${problem})"
        }
        New-Item -ItemType Directory -Force -Path $nmfDir | Out-Null
        $zip = "${nmfDir}\NotMyFault.zip"
        Save-NotMyFaultArchive $zip
        Expand-Archive -Path $zip -DestinationPath $nmfDir -Force
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $nmfPath)) { return "failed: ${nmfPath} missing after extraction${replaced}" }
        $problem = Get-NotMyFaultTrustProblem $nmfPath
        if ($problem) {
            try {
                Move-Item -LiteralPath $nmfPath -Destination "${nmfPath}.untrusted" -Force
            } catch {
                return "unsafe: the untrusted downloaded ${nmfPath} could not be renamed (${problem}): $($_.Exception.Message)"
            }
            return "failed: the downloaded ${nmfPath} is not trusted and was renamed to ${nmfPath}.untrusted: ${problem}"
        }
        Unblock-File -Path $nmfPath -ErrorAction SilentlyContinue
        "staged${replaced}"
    } catch {
        "failed: $($_.Exception.Message)${replaced}"
    }
}

$cfg = Read-CrashControlData $DataFile

$type = if ($DumpType) { $DumpType } else { $cfg.recommended.crashDumpType }
$typeNames = $cfg.crashDumpTypes.PSObject.Properties.Name
if ($typeNames -notcontains $type) { Fail "Unknown dump type '${type}'. Valid: $($typeNames -join ', ')." 2 }
$crashDumpEnabled = [int]$cfg.crashDumpTypes.$type.CrashDumpEnabled

$regPath = $cfg.registryPath
$desired = Get-DesiredCrashControl $cfg.recommended.values $crashDumpEnabled
if ($cfg.recommended.values.PSObject.Properties.Name -contains 'DedicatedDumpFile') {
    Write-StdErr 'WARN: crash-control.json still recommends DedicatedDumpFile; it is ignored (dumps use the page file only)'
}

$action = 'verified'
$applied = $null
$isRebootRequired = $false
if (-not $VerifyOnly) {
    if (-not (Test-IsAdministrator)) {
        Fail 'configure-dumps.ps1 must run elevated (Administrator) to write CrashControl.' 3
    }
    $hadDedicatedDumpFile = $null -ne (Get-RegValue $regPath 'DedicatedDumpFile')
    $isRebootRequired = Test-RebootRequired (Get-RegValue $regPath 'CrashDumpEnabled') $crashDumpEnabled $hadDedicatedDumpFile

    try {
        if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
        # Dumps go through the page file only: remove a DedicatedDumpFile left by an older
        # configuration (the golden image requires it absent, see virtio-win issue #1629).
        $null = Remove-DedicatedDumpFile $regPath
        # Strings are REG_EXPAND_SZ (expanded when read); numbers are DWORD.
        foreach ($name in $desired.Keys) {
            $value = $desired[$name]
            if ($value -is [string]) {
                New-ItemProperty -Path $regPath -Name $name -Value $value -PropertyType ExpandString -Force | Out-Null
            } else {
                New-ItemProperty -Path $regPath -Name $name -Value ([int]$value) -PropertyType DWord -Force | Out-Null
            }
        }
    } catch {
        Fail "cannot write CrashControl at ${regPath}: $($_.Exception.Message)" 4
    }
    $action = 'applied'
    $applied = $desired
}

# Staging problems are reported on stderr (stdout carries the JSON); a caller that requires the
# binary then finds it missing. An untrusted copy that could not be renamed away stops the script.
$nmfStatus = Invoke-NotMyFaultStaging ([bool]$VerifyOnly) ([bool]$StageNotMyFault)
if ($nmfStatus -like 'unsafe*') { Fail "NotMyFault staging: ${nmfStatus}" 5 }
if ($nmfStatus -like 'failed*' -or $nmfStatus -like '*untrusted*') {
    Write-StdErr "WARN: NotMyFault staging to C:\Temp\nmf: ${nmfStatus}"
}

$current = [ordered]@{}
$isMatch = $true
foreach ($name in $desired.Keys) {
    $current[$name] = Get-RegValue $regPath $name
    if (-not (Test-ValueMatch $current[$name] $desired[$name])) { $isMatch = $false }
}
# A DedicatedDumpFile value that is still present (for example under -VerifyOnly) does not match
# the page-file-only recommendation.
$currentDedicatedDumpFile = Get-RegValue $regPath 'DedicatedDumpFile'
if ($null -ne $currentDedicatedDumpFile) { $isMatch = $false }

$pfRaw = Get-RegValue $cfg.pageFile.path $cfg.pageFile.value
$pfEntries = @(if ($pfRaw) { $pfRaw })
$pfConfigured = if ($pfEntries.Count) { $pfEntries -join '; ' } else { $null }
# An unreadable, missing or non-positive memory size leaves requiredMB null (not adequate).
$requiredMB = $null
try {
    $ramBytes = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
    if ($ramBytes -gt 0) {
        $requiredMB = Get-PagefileSizeMB $ramBytes
    } else {
        Write-StdErr "WARN: physical memory size is missing or not positive (TotalPhysicalMemory = '${ramBytes}')"
    }
} catch {
    Write-StdErr "WARN: cannot read physical memory size: $($_.Exception.Message)"
}
$isPfAdequate = Test-PageFileAdequate $pfEntries $requiredMB

[ordered]@{
    ok                 = $true
    action             = $action
    requestedDumpType  = $type
    applied            = $applied
    current            = $current
    dedicatedDumpFile  = $currentDedicatedDumpFile
    matchesRecommended = $isMatch
    rebootRequired     = $isRebootRequired
    pageFile           = [ordered]@{ configured = $pfConfigured; adequate = $isPfAdequate; requiredMB = $requiredMB }
} | ConvertTo-Json -Depth 12
