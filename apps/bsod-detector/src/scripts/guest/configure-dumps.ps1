<#
.SYNOPSIS
    Configure Windows crash-dump settings so a dump is written on the next BSOD,
    or verify the current settings without changing them.

.DESCRIPTION
    Reads the recommended CrashControl settings from data/crash-control.json and
    applies them under HKLM\SYSTEM\CurrentControlSet\Control\CrashControl. With
    -VerifyOnly it reports the live settings and whether they match the
    recommendation, changing nothing.

    Runs on: the GUEST VM. Requires Administrator (registry write). A reboot is
    required for some dump-type changes to take effect.

    Prerequisite step: without this, a BSOD may leave no dump to analyze.

.PARAMETER DumpType
    Override the recommended dump type. One of the keys in
    crash-control.json .crashDumpTypes (none|complete|kernel|small|automatic).
    Defaults to the file's recommended.crashDumpType.

.PARAMETER VerifyOnly
    Report current settings without modifying the registry.

.PARAMETER DataFile
    Explicit path to crash-control.json. Required when the script is staged
    outside its repository layout (for example through qemu-guest-agent).

.OUTPUTS
    A single JSON object to stdout:
    {
      "ok": true,
      "action": "applied" | "verified",
      "requestedDumpType": "kernel",
      "applied":  { "CrashDumpEnabled": 2, ... },   # present when action=applied
      "current":  { "CrashDumpEnabled": 2, ... },   # live registry values
      "matchesRecommended": true,
      "rebootRequired": false,
      "pageFile": { "configured": "?system-managed?", "adequate": true|null }
    }
#>
# Define this as an advanced function with support for -Verbose and -Debug flags
[CmdletBinding()]
param(
    # Optional override for the dump type (none|complete|kernel|small|automatic)
    [string]$DumpType,
    # If set, only report current settings without modifying registry
    [switch]$VerifyOnly,
    # Optional explicit path to crash-control.json data file
    [string]$DataFile
)

# --- standalone helpers (no Common.ps1 dependency) ---
# Enable strict mode to catch undefined variables and other common mistakes
Set-StrictMode -Version Latest
# Stop execution immediately on any error (no error handling needed)
$ErrorActionPreference = 'Stop'

# Use provided DataFile or auto-discover it from repo structure
$script:DataFile = $DataFile
# If no explicit path was given, look for crash-control.json in the repo
if (-not $script:DataFile) {
    # Navigate from script location up three levels to reach project root (..\..\..)
    $repoCandidate = Join-Path $PSScriptRoot '..\..\..'
    # Check if the repository structure exists
    if (Test-Path $repoCandidate) {
        # Construct full path to crash-control.json and resolve it to absolute path
        $script:DataFile = Join-Path (Resolve-Path $repoCandidate) 'src\data\crash-control.json'
    }
}

# Load JSON configuration file and return as PowerShell object
function Get-BsodData {
    param([Parameter(Mandatory)][string]$Name)
    # Map requested file name to the configured data file path
    $p = if ($Name -eq 'crash-control.json') { $script:DataFile } else { $null }
    # Error if no path is configured for this file name
    if (-not $p) { throw "No explicit data path is configured for $Name" }
    # Error if the data file doesn't exist
    if (-not (Test-Path $p)) { throw "Data file not found: $p" }
    # Read file contents and parse as JSON, return the object
    Get-Content -Raw -Path $p | ConvertFrom-Json
}
# Convert PowerShell object to formatted JSON and output to stdout
function Write-JsonResult {
    param([Parameter(Mandatory)]$Object)
    # Convert object to JSON with deep nesting support (up to 12 levels)
    $Object | ConvertTo-Json -Depth 12
}

# Output structured error JSON and exit with error code
function Fail {
    param([Parameter(Mandatory)][string]$Message, [int]$ExitCode = 1)
    # Create error result object with ok=false flag and error message
    Write-JsonResult ([ordered]@{ ok = $false; error = $Message; script = 'configure-dumps.ps1' })
    # Exit script with error code (1 by default, 3 for admin check failures)
    exit $ExitCode
}

# Check if the current PowerShell process is running with Administrator privileges
function Test-IsAdministrator {
    # Get the current Windows user identity
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    # Create a principal object from the identity to check roles
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    # Return true if this process has Administrator role
    $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Load crash dump configuration from JSON file
$cfg = Get-BsodData 'crash-control.json'

# STEP 1: Resolve and validate the requested dump type
# Use provided DumpType parameter, or fall back to the recommended type from config
$type = if ($DumpType) { $DumpType } else { $cfg.recommended.crashDumpType }
# Get all valid dump type names from the config (none, complete, kernel, small, automatic)
$typeNames = $cfg.crashDumpTypes.PSObject.Properties.Name
# Error if the requested type is not recognized
if ($typeNames -notcontains $type) {
    Fail "Unknown dump type '$type'. Valid: $($typeNames -join ', ')." 2
}
# Extract the CrashDumpEnabled registry value for the selected dump type
$typeEnabledValue = [int]$cfg.crashDumpTypes.$type.CrashDumpEnabled

# STEP 2: Build the desired registry value set for CrashControl registry path
# Get the registry path where CrashControl settings are stored
$regPath = $cfg.registryPath
# Create an ordered dictionary to hold all desired registry values
$desired = [ordered]@{}
# Copy all recommended values from the config file to our desired set
foreach ($p in $cfg.recommended.values.PSObject.Properties) { $desired[$p.Name] = $p.Value }
# Override CrashDumpEnabled with the value corresponding to the selected dump type
$desired['CrashDumpEnabled'] = $typeEnabledValue

# --- Registry access helpers ---------------------------------------------------------------

# Read a single registry value from the specified path
function Get-RegValue {
    param([string]$Path, [string]$Name)
    # Try to read the registry value (silently fail if it doesn't exist)
    $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    # Return the value if the property exists, otherwise return null
    if ($item -and ($item.PSObject.Properties.Name -contains $Name)) { return $item.$Name }
    return $null
}

# Expand environment variables in a string value
function Expand-IfString {
    param($Value)
    # Check if value is a string (paths often contain %SystemRoot%)
    if ($Value -is [string]) { return [Environment]::ExpandEnvironmentVariables($Value) }
    # Return non-string values as-is (e.g., integers)
    return $Value
}

# Compare two registry values for equality, handling environment variable expansion
# (registry stores %SystemRoot%\... as REG_EXPAND_SZ, but Get-ItemProperty returns it expanded)
function Values-Match {
    param($A, $B)
    # If either value is null, they don't match
    if ($null -eq $A -or $null -eq $B) { return $false }
    # Expand environment variables in both values, convert to strings, then compare
    (Expand-IfString $A).ToString() -eq (Expand-IfString $B).ToString()
}

# Read all current registry values that we care about
function Read-Current {
    # Create an ordered dictionary to hold current values
    $c = [ordered]@{}
    # Loop through each desired registry key and read its current value
    foreach ($k in $desired.Keys) { $c[$k] = Get-RegValue -Path $regPath -Name $k }
    # Return the dictionary of current values
    return $c
}

# STEP 3: Snapshot the live registry values before making any changes
$currentBefore = Read-Current

# STEP 4: Apply the recommended settings to the registry (unless -VerifyOnly was specified)
# Initialize variables: assume we're just verifying unless we actually apply changes
$action         = 'verified'
$applied        = $null
$rebootRequired = $false
# Only proceed with registry modifications if -VerifyOnly was NOT specified
if (-not $VerifyOnly) {
    # Check that we have Administrator privileges to write to HKLM registry
    if (-not (Test-IsAdministrator)) {
        Fail 'configure-dumps.ps1 must run elevated (Administrator) to write CrashControl.' 3
    }
    # Create the registry path if it doesn't exist yet
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }

    # Pre-create DedicatedDumpFile with size = RAM + 1MB (guarantees space for any dump type)
    # This avoids depending on pagefile which may not be configured or may be disabled
    if ($desired.Contains('DedicatedDumpFile') -and $desired['DedicatedDumpFile']) {
        # Expand environment variables in the file path (e.g., %SystemRoot% → C:\Windows)
        $dedicatedPath = [Environment]::ExpandEnvironmentVariables($desired['DedicatedDumpFile'])
        # Only create if the file doesn't already exist
        if (-not (Test-Path $dedicatedPath)) {
            # Get the total physical RAM on the system
            $ramBytes = $null
            try { $ramBytes = [int64](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory } catch { }
            # Use RAM+1MB if known, otherwise default to 16GB
            $sizeBytes = if ($ramBytes) { $ramBytes + 1MB } else { 17179869184 }
            # Create the file using fsutil (raw API, faster than PowerShell)
            & fsutil file createnew $dedicatedPath $sizeBytes | Out-Null
        }
    }

    # NOTE: Pagefile configuration is NOT touched here (it's a golden image concern).
    # VirtIO Balloon driver on KVM blocks pagefile.sys creation, so AutomaticManagedPagefile
    # must be false before image sealing. DedicatedDumpFile handles dump staging without pagefile.

    # Write each desired registry value to the CrashControl registry path
    foreach ($k in $desired.Keys) {
        $v = $desired[$k]
        # String values (like paths) go in as REG_EXPAND_SZ so env vars expand at read time
        if ($v -is [string]) {
            New-ItemProperty -Path $regPath -Name $k -Value $v -PropertyType ExpandString -Force | Out-Null
        } else {
            # Numeric values go in as DWord (32-bit integer)
            New-ItemProperty -Path $regPath -Name $k -Value ([int]$v) -PropertyType DWord -Force | Out-Null
        }
    }

    # Track that we successfully applied the settings
    $action  = 'applied'
    $applied = $desired

    # Determine if a reboot is required: CrashDumpEnabled changes require reboot to take effect
    # Use cumulative logic (preserve any prior reboot requirement flags)
    # Do not overwrite — only set to true if it wasn't already true
    $rebootRequired = $rebootRequired -or (-not (Values-Match $currentBefore['CrashDumpEnabled'] $typeEnabledValue))
}

# STEP 5: Re-read the live registry values (after applying changes, or unchanged if -VerifyOnly)
$current = Read-Current

# STEP 6: Check if the current live config matches what we intended to set
# Start by assuming everything matches, then break if we find any mismatch
$matchesRecommended = $true
foreach ($k in $desired.Keys) {
    # Compare each registry value; if any doesn't match, flag it and exit the loop
    if (-not (Values-Match $current[$k] $desired[$k])) { $matchesRecommended = $false; break }
}

# STEP 7: Assess page file adequacy for the selected dump type
# Read page file configuration from the registry
$mmPath    = $cfg.pageFile.path
# The registry value name that holds pagefile entries (REG_MULTI_SZ multi-value)
$pfName    = $cfg.pageFile.value
# Read the raw page file entries from the registry
$pfRaw     = Get-RegValue -Path $mmPath -Name $pfName
# Convert to array (handles both single entry and multiple entries)
$pfEntries = @()
if ($pfRaw) { $pfEntries = @($pfRaw) }
# Format the page file entries for output (either list them or null if none configured)
$pfConfigured = if ($pfEntries.Count) { ($pfEntries -join '; ') } else { $null }
# Check if a dedicated dump file was configured
$dedicated    = Get-RegValue -Path $regPath -Name 'DedicatedDumpFile'

# Get total system RAM for comparison
$ramBytes = $null
try { $ramBytes = [int64](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory } catch { }

# Evaluate whether the page file configuration is adequate
$pfAdequate = $null
if ($dedicated) {
    # If DedicatedDumpFile is set, it handles dump staging independently of pagefile
    $pfAdequate = $true
} elseif ($pfEntries.Count -eq 0) {
    # No page file AND no dedicated dump file = nowhere to store the dump (bad)
    $pfAdequate = $false
} elseif ($type -eq 'complete') {
    # Complete dump requires page file size >= RAM + 1MB on the system volume
    # Note: we can only verify this if the page file size is fixed; system-managed is unknown
    $maxMb = $null
    # Parse page file entries (format: "C: 2048 4096" = drive: min-size max-size)
    foreach ($e in $pfEntries) {
        # Split entry by whitespace, keep only numeric values
        $nums = @(($e -split '\s+') | Where-Object { $_ -match '^\d+$' })
        # The max size is the second number (if present)
        if ($nums.Count -ge 2) { $maxMb = [int]$nums[1] }
    }
    # Only report adequate/inadequate if we know both RAM and max page file size
    if ($null -ne $ramBytes -and $null -ne $maxMb -and $maxMb -gt 0) {
        # Check if max page file size >= (RAM + 1MB)
        $pfAdequate = (([int64]$maxMb * 1MB) -ge ($ramBytes + 1MB))
    } else {
        # Can't determine adequacy (system-managed pagefile or unknown RAM)
        $pfAdequate = $null
    }
} else {
    # For kernel, automatic, or small dumps, any existing page file on the system drive suffices
    $pfAdequate = $true
}

# STEP 8: Emit the final JSON result to stdout
# This single result object contains all information about what was done and the current state
Write-JsonResult ([ordered]@{
    # Overall success flag (true here; failures would have exited earlier via Fail)
    ok                 = $true
    # What action was taken: 'applied' or 'verified' (depends on -VerifyOnly)
    action             = $action
    # Which dump type was requested/used
    requestedDumpType  = $type
    # Registry values that were applied (null if -VerifyOnly, otherwise the set)
    applied            = $applied
    # Current live registry values (what we read back after apply/verify)
    current            = $current
    # Whether live config matches the recommended values for this dump type
    matchesRecommended = $matchesRecommended
    # Whether a reboot is needed for changes to take effect
    rebootRequired     = $rebootRequired
    # Pagefile status: what's configured and whether it's adequate for the dump type
    pageFile           = [ordered]@{ configured = $pfConfigured; adequate = $pfAdequate }
})
