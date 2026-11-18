<#
.SYNOPSIS
    Validate the guest's crash-dump settings against crash-control.json without changing them.

.DESCRIPTION
    Read-only check run before arming a crash test. It compares the desired CrashControl values in
    crash-control.json (value, registry type and key path) with the live registry, checks that
    values the frozen-VM flow requires to be absent (DedicatedDumpFile) are absent, and reports
    whether the configured page file meets the size the golden image sets (RAM + 257 MB). It
    never writes the registry, CIM or page file, never repairs anything and never reboots:
    golden-image-pre-reboot.ps1 configures these settings and golden-image-post-reboot.ps1
    verifies them before the image is sealed.

    Runs on the guest VM. Only with -StageNotMyFault (intentional crash runs) does it also stage
    the current NotMyFault release; it never runs NotMyFault, crashes or reboots the guest.

.PARAMETER DumpType
    Validate against another key of crash-control.json .crashDumpTypes instead of
    .recommended.crashDumpType.

.PARAMETER StageNotMyFault
    Download the current NotMyFault archive afresh (an earlier copy is removed first and never
    reused), require a valid Authenticode signature from Microsoft Corporation on
    notmyfaultc64.exe, and stage it as C:\Temp\nmf\notmyfaultc64.exe. The JSON reports the source
    URL, the resolved HTTPS source, the SHA-256 of the archive and of the executable, the file
    version and the signer. No hash is published for NotMyFault: the SHA-256 values are an audit
    record of what was downloaded, not a publisher attestation (the signature is). Without this
    switch nothing is downloaded or staged.

.PARAMETER DataFile
    Path to crash-control.json. Required when the script is staged outside its repository
    layout (for example through qemu-guest-agent).

.OUTPUTS
    One JSON object on stdout:
    {
      "ok": true,
      "action": "validated",
      "script": "validate-crash-settings.ps1",
      "requestedDumpType": "automatic",
      "registryPath": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl",
      "desired": { "CrashDumpEnabled": 7, ... },
      "current": { "CrashDumpEnabled": 7, ... },      # live values; null when missing
      "mismatches": [ { "name": "...", "issue": "missing|wrong type|wrong value|must be absent|key missing",
                        "expected": ..., "actual": ..., "expectedType": "DWord", "actualType": "String" } ],
      "matchesRecommended": true,                     # no mismatches
      "pageFile": { "configured": "...", "adequate": true, "requiredMB": 16641 },
      "notMyFault": { "status": "not requested" } | { "status": "staged", "source": "...", "resolvedSource": "...",
                      "archiveSHA256": "...", "sha256": "...", "version": "...", "signer": "...", "stagedPath": "..." }
    }
    On failure: { "ok": false, "error": "...", "script": "validate-crash-settings.ps1" } with exit code
    2 (unknown dump type) or 4 (NotMyFault could not be staged; the full result above is emitted with
    ok = false and the error, so settings mismatches stay visible; the host preflight then stops).
    A missing data file is a terminating error. A settings mismatch is reported in the JSON, not
    through the exit code.
#>
[CmdletBinding()]
param(
    [string]$DumpType,
    [switch]$StageNotMyFault,
    [string]$DataFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Emits failure JSON and exits. Given a validation result, emits that result with ok = false and the
# error added, so a NotMyFault staging failure still reports the settings mismatches and page file.
function Fail ([string]$Message, [int]$ExitCode, $Result) {
    if ($null -eq $Result) { $Result = [ordered]@{ ok = $false; error = $Message; script = 'validate-crash-settings.ps1' } }
    $Result['ok'] = $false
    $Result['error'] = $Message
    $Result | ConvertTo-Json -Depth 12
    exit $ExitCode
}

# Diagnostics go to stderr; stdout carries only the JSON result.
function Write-StdErr ([string]$Message) {
    [Console]::Error.WriteLine("validate-crash-settings.ps1: ${Message}")
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

# The registry type of a value (DWord, ExpandString, String, ...), or nothing when it is absent.
function Get-RegValueKind ([string]$Path, [string]$Name) {
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($key -and ($key.GetValueNames() -contains $Name)) { "$($key.GetValueKind($Name))" }
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

# The values to compare: recommended.values with CrashDumpEnabled taken from the selected dump
# type. DedicatedDumpFile is never a desired value (dumps go through the page file only), even if
# an older crash-control.json still lists it.
function Get-DesiredCrashControl ($RecommendedValues, [int]$CrashDumpEnabled) {
    $desired = [ordered]@{}
    foreach ($prop in $RecommendedValues.PSObject.Properties) {
        if ($prop.Name -ne 'DedicatedDumpFile') { $desired[$prop.Name] = $prop.Value }
    }
    $desired['CrashDumpEnabled'] = $CrashDumpEnabled
    $desired
}

# Values that must not exist: recommended.absentValues from the data file, and always
# DedicatedDumpFile.
function Get-RequiredAbsence ($Recommended) {
    $names = @('DedicatedDumpFile')
    if ($Recommended.PSObject.Properties.Name -contains 'absentValues') {
        foreach ($name in $Recommended.absentValues) { if ($names -notcontains $name) { $names += $name } }
    }
    $names
}

# The fixed registry type golden-image-pre-reboot.ps1 writes: strings as REG_EXPAND_SZ, numbers as DWORD.
function Get-ExpectedValueKind ($Value) {
    if ($Value -is [string]) { 'ExpandString' } else { 'DWord' }
}

# Turns an HTTP(S) redirect location into the HTTPS URL on the same official host, or nothing when
# it points elsewhere. Official download aliases may redirect to plain http://; only the host and
# path are taken from such a location, and the request is always made over HTTPS.
function Get-HTTPSredirectTarget ([string]$Location, [string]$OfficialHost) {
    if ($Location -notmatch '^https?://([^/?#]+)(/[^#]*)$') { return }
    if ($Matches[1] -ne $OfficialHost) { return }
    "https://$($Matches[1])$($Matches[2])"
}

# Returns the status code and Location header of one HTTPS HEAD request without following redirects.
function Get-HTTPSresponseHead ([string]$URL) {
    $request = [System.Net.HttpWebRequest]::Create($URL)
    $request.Method = 'HEAD'
    $request.AllowAutoRedirect = $false
    try {
        $response = $request.GetResponse()
    } catch [System.Net.WebException] {
        if (-not $_.Exception.Response) { throw }
        $response = $_.Exception.Response
    }
    try {
        [pscustomobject]@{ StatusCode = [int]$response.StatusCode; Location = $response.Headers['Location'] }
    } finally {
        $response.Close()
    }
}

# Follows an official download alias hop by hop (at most five) and returns the final HTTPS URL on
# the same host; a redirect to another host, a non-HTTPS start or an error status throws.
function Resolve-OfficialHTTPS ([string]$URL, [string]$OfficialHost) {
    if ($URL -notlike "https://${OfficialHost}/*") { throw "not an HTTPS URL on ${OfficialHost}: ${URL}" }
    foreach ($hop in 1..5) {
        $head = Get-HTTPSresponseHead $URL
        if ($head.StatusCode -eq 200) { return $URL }
        if ($head.StatusCode -lt 300 -or $head.StatusCode -ge 400) { throw "HTTP $($head.StatusCode) from ${URL}" }
        $next = Get-HTTPSredirectTarget $head.Location $OfficialHost
        if (-not $next) { throw "redirect from ${URL} leaves ${OfficialHost}: $($head.Location)" }
        $URL = $next
    }
    throw "too many redirects from ${URL}"
}

# Adds TLS 1.2 to the protocols this process already allows instead of replacing them.
function Enable-TLS12 {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# Downloads an already resolved HTTPS URL to a file without following redirects: a redirect or any
# status other than 200 throws instead of being followed, so the download cannot leave HTTPS.
function Save-HTTPSdownload ([string]$URL, [string]$Path) {
    if ($URL -notlike 'https://*') { throw "not an HTTPS URL: ${URL}" }
    $request = [System.Net.HttpWebRequest]::Create($URL)
    $request.AllowAutoRedirect = $false
    $response = $request.GetResponse()
    try {
        if ([int]$response.StatusCode -ne 200) { throw "HTTP $([int]$response.StatusCode) from ${URL}" }
        $file = [System.IO.File]::Create($Path)
        try { $response.GetResponseStream().CopyTo($file) } finally { $file.Close() }
    } finally {
        $response.Close()
    }
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

# Stages the current NotMyFault release for an intentional crash run and returns its record.
# Any earlier copy at the staging path is removed first and never reused, so the trigger can only
# find the copy downloaded and verified now. An untrusted download is deleted, never staged.
# C:\Temp\nmf is a fixed contract shared with the host preflight and trigger scripts, which check
# that exact path through the guest agent (a per-user $env:TEMP would differ).
function Invoke-NotMyFaultStaging ([string]$Source) {
    $nmfDir = 'C:\Temp\nmf'
    $nmfPath = "${nmfDir}\notmyfaultc64.exe"
    $zip = "${nmfDir}\NotMyFault.zip"
    $extractDir = "${nmfDir}\extract"
    $record = [ordered]@{
        status = 'failed'; source = $Source; resolvedSource = $null; archiveSHA256 = $null
        sha256 = $null; version = $null; signer = $null; stagedPath = $nmfPath; problem = $null
    }
    try {
        foreach ($stale in @($nmfPath, $zip, $extractDir)) {
            if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Recurse -Force -ErrorAction Stop }
        }
        New-Item -ItemType Directory -Force -Path $nmfDir | Out-Null
        Enable-TLS12
        $record.resolvedSource = Resolve-OfficialHTTPS $Source 'download.sysinternals.com'
        Save-HTTPSdownload $record.resolvedSource $zip
        $record.archiveSHA256 = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        Expand-Archive -Path $zip -DestinationPath $extractDir -Force
        $candidate = "${extractDir}\notmyfaultc64.exe"
        if (-not (Test-Path -LiteralPath $candidate)) {
            $record.problem = 'notmyfaultc64.exe is missing from the downloaded archive'
        } else {
            $record.problem = Get-NotMyFaultTrustProblem $candidate
            if (-not $record.problem) {
                $record.sha256 = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
                $record.version = (Get-Item -LiteralPath $candidate).VersionInfo.FileVersion
                $record.signer = (Get-AuthenticodeSignature -LiteralPath $candidate).SignerCertificate.Subject
                Move-Item -LiteralPath $candidate -Destination $nmfPath -Force
                Unblock-File -Path $nmfPath -ErrorAction SilentlyContinue
                $record.status = 'staged'
            }
        }
    } catch {
        $record.problem = $_.Exception.Message
    }
    foreach ($leftover in @($zip, $extractDir)) {
        if (Test-Path -LiteralPath $leftover) { Remove-Item -LiteralPath $leftover -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $record
}

$cfg = Read-CrashControlData $DataFile

$type = if ($DumpType) { $DumpType } else { $cfg.recommended.crashDumpType }
$typeNames = $cfg.crashDumpTypes.PSObject.Properties.Name
if ($typeNames -notcontains $type) { Fail "Unknown dump type '${type}'. Valid: $($typeNames -join ', ')." 2 }
$crashDumpEnabled = [int]$cfg.crashDumpTypes.$type.CrashDumpEnabled

$regPath = $cfg.registryPath
$desired = Get-DesiredCrashControl $cfg.recommended.values $crashDumpEnabled
if ($cfg.recommended.values.PSObject.Properties.Name -contains 'DedicatedDumpFile') {
    Write-StdErr 'WARN: crash-control.json still recommends DedicatedDumpFile; it is validated as must-be-absent instead'
}
$absentNames = Get-RequiredAbsence $cfg.recommended

# Compare every desired value (presence, registry type, value) and every required absence.
$current = [ordered]@{}
$mismatches = @()
if (-not (Test-Path $regPath)) {
    $mismatches += [ordered]@{ name = $regPath; issue = 'key missing'; expected = 'present'; actual = $null; expectedType = $null; actualType = $null }
}
foreach ($name in $desired.Keys) {
    $expected = $desired[$name]
    $actual = Get-RegValue $regPath $name
    $actualType = Get-RegValueKind $regPath $name
    $expectedType = Get-ExpectedValueKind $expected
    $current[$name] = $actual
    $issue = if ($null -eq $actual) { 'missing' }
        elseif ($actualType -ne $expectedType) { 'wrong type' }
        elseif (-not (Test-ValueMatch $actual $expected)) { 'wrong value' }
    if ($issue) {
        $mismatches += [ordered]@{ name = $name; issue = $issue; expected = $expected; actual = $actual; expectedType = $expectedType; actualType = $actualType }
    }
}
foreach ($name in $absentNames) {
    $actual = Get-RegValue $regPath $name
    $current[$name] = $actual
    if ($null -ne $actual) {
        $mismatches += [ordered]@{ name = $name; issue = 'must be absent'; expected = $null; actual = $actual; expectedType = $null; actualType = (Get-RegValueKind $regPath $name) }
    }
}

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

# Intentional runs only: stage the current NotMyFault; a failed staging stops the run.
$notMyFault = [ordered]@{ status = 'not requested' }
if ($StageNotMyFault) {
    $notMyFault = Invoke-NotMyFaultStaging 'https://download.sysinternals.com/files/NotMyFault.zip'
}

$result = [ordered]@{
    ok                 = $true
    action             = 'validated'
    script             = 'validate-crash-settings.ps1'
    requestedDumpType  = $type
    registryPath       = $regPath
    desired            = $desired
    current            = $current
    mismatches         = $mismatches
    matchesRecommended = ($mismatches.Count -eq 0)
    pageFile           = [ordered]@{ configured = $pfConfigured; adequate = $isPfAdequate; requiredMB = $requiredMB }
    notMyFault         = $notMyFault
}
if ($StageNotMyFault -and $notMyFault.status -ne 'staged') { Fail "NotMyFault could not be staged: $($notMyFault.problem)" 4 $result }
$result | ConvertTo-Json -Depth 12
