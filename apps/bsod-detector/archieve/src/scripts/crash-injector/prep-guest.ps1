<#
.SYNOPSIS
    One-time prep of the golden BSOD test guest: crash-dump config, page file,
    and CrashMe test driver staging.

.DESCRIPTION
    Runs INSIDE the guest (elevated). Makes the VM test-ready so the
    clean-baseline snapshot starts from a known-good state:
      1. Applies the kernel-dump CrashControl settings (matches the project's
         data/crash-control.json recommendation).
      2. Ensures a system-managed page file on C: (the 1.9 GB fixed default is
         too small to guarantee a dump on 8 GB RAM).
      3. Stages the CrashMe test driver (crashme.sys + crashme-ctl.exe) into
         C:\Tools and installs the driver service.

    Idempotent: safe to re-run. Emits one JSON object to stdout describing the
    resulting state (the script contract).

    NOTE: the CrashControl values here MUST stay in sync with
    data/crash-control.json (kernel dump = CrashDumpEnabled 2). That file is the
    source of truth; this script hard-applies the same values because it runs in
    the guest with no access to the repo.

.PARAMETER ToolsDir
    Where to stage the CrashMe driver. Default C:\Tools.

.PARAMETER SkipDriver
    Skip the driver installation (config/page-file only).

.OUTPUTS
    { "ok": true, "crashControl": {...}, "pageFile": {...},
      "driver": { "dir": "...", "installed": true }, "rebootRecommended": bool,
      "warnings": [ ... ] }
#>
[CmdletBinding()]
param(
    [string]$ToolsDir = 'C:\Tools',
    [switch]$SkipDriver
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$warnings = @()
$rebootRecommended = $false

# --- 1. Crash-dump config (kernel dump; mirror of data/crash-control.json) ---
$cc = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
$desired = @{
    CrashDumpEnabled     = 2                       # kernel dump
    AlwaysKeepMemoryDump = 1
    Overwrite            = 1
    LogEvent             = 1
    AutoReboot           = 0
}
foreach ($k in $desired.Keys) {
    $cur = (Get-ItemProperty -Path $cc -Name $k -ErrorAction SilentlyContinue).$k
    if ($cur -ne $desired[$k]) {
        Set-ItemProperty -Path $cc -Name $k -Value $desired[$k] -Type DWord
        $rebootRecommended = $true
    }
}
# Pin the dump-file paths (REG_EXPAND_SZ) so a dump always lands where the
# collectors look, matching data/crash-control.json's recommended values.
$desiredPaths = @{
    DumpFile    = '%SystemRoot%\MEMORY.DMP'
    MinidumpDir = '%SystemRoot%\Minidump'
}
foreach ($k in $desiredPaths.Keys) {
    $cur = (Get-ItemProperty -Path $cc -Name $k -ErrorAction SilentlyContinue).$k
    if ($cur -ne [Environment]::ExpandEnvironmentVariables($desiredPaths[$k])) {
        New-ItemProperty -Path $cc -Name $k -Value $desiredPaths[$k] -PropertyType ExpandString -Force | Out-Null
        $rebootRecommended = $true
    }
}
$crashControl = Get-ItemProperty -Path $cc |
    Select-Object CrashDumpEnabled, AlwaysKeepMemoryDump, Overwrite, LogEvent, AutoReboot, DumpFile, MinidumpDir

# --- 2. Page file: switch to system-managed so a kernel dump always fits -----
$csItem = Get-CimInstance Win32_ComputerSystem
if (-not $csItem.AutomaticManagedPagefile) {
    try {
        $cs = Get-WmiObject Win32_ComputerSystem -EnableAllPrivileges
        $cs.AutomaticManagedPagefile = $true
        [void]$cs.Put()
        $rebootRecommended = $true
    } catch {
        $warnings += "Could not enable system-managed page file: $($_.Exception.Message)"
    }
}
$pageFile = Get-CimInstance Win32_PageFileUsage |
    Select-Object Name, AllocatedBaseSize

# --- 3. Stage CrashMe driver and control program -----------------------------
$driverInstalled = $false
if (-not $SkipDriver) {
    New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null

    $sysFile = Join-Path $ToolsDir 'crashme.sys'
    $ctlFile = Join-Path $ToolsDir 'crashme-ctl.exe'

    $driverInstalled = (Get-Service -Name 'CrashMe' -ErrorAction SilentlyContinue) -ne $null

    if (-not $driverInstalled) {
        if (-not (Test-Path $sysFile)) {
            $warnings += "crashme.sys not found in $ToolsDir; copy it from test-driver/ before running this script"
        } elseif (-not (Test-Path $ctlFile)) {
            $warnings += "crashme-ctl.exe not found in $ToolsDir; copy it from test-driver/ before running this script"
        } else {
            sc.exe create CrashMe type= kernel binPath= $sysFile start= demand | Out-Null
            sc.exe start CrashMe | Out-Null
            $driverInstalled = (Get-Service -Name 'CrashMe' -ErrorAction SilentlyContinue).Status -eq 'Running'
            if (-not $driverInstalled) {
                $warnings += "CrashMe driver service created but failed to start"
            }
        }
    }
}

[ordered]@{
    ok                = $true
    crashControl      = $crashControl
    pageFile          = $pageFile
    driver            = [ordered]@{ dir = $ToolsDir; installed = $driverInstalled; skipped = [bool]$SkipDriver }
    rebootRecommended = $rebootRecommended
    warnings          = $warnings
} | ConvertTo-Json -Depth 6
