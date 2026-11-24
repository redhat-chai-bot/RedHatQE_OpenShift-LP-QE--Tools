<#
.SYNOPSIS
    Delete existing crash dumps so a test captures only the new one.

.DESCRIPTION
    Removes the guest's minidumps and full dump, then confirms both are gone. Run
    this BEFORE triggering a BSOD so the resulting evidence package contains exactly
    the dump from this run (this mirrors the lead's guidance to clear minidumps
    before the test rather than diffing a baseline). Honors the VM's configured
    dump paths (CrashControl DumpFile / MinidumpDir) instead of assuming C:\Windows,
    falling back to the OS defaults.

    Runs on: the GUEST VM. Requires elevation.
#>
# Standalone helpers (no Common.ps1 dependency).
$ErrorActionPreference = 'SilentlyContinue'

function Get-DumpPaths {
    <# .SYNOPSIS Resolve where this Windows guest writes crash dumps. #>
    $ccPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
    $cc = Get-ItemProperty -Path $ccPath -ErrorAction SilentlyContinue
    function Read-CcValue { param([string]$Name)
        if ($cc -and ($cc.PSObject.Properties.Name -contains $Name)) {
            $v = $cc.$Name
            if ($v -is [string] -and $v.Trim()) { return [Environment]::ExpandEnvironmentVariables($v) }
        }
        return $null
    }
    $dumpFile = Read-CcValue 'DumpFile'
    if (-not $dumpFile) { $dumpFile = Join-Path $env:SystemRoot 'MEMORY.DMP' }
    $miniDir = Read-CcValue 'MinidumpDir'
    if (-not $miniDir) { $miniDir = Join-Path $env:SystemRoot 'Minidump' }
    [pscustomobject]@{
        DumpFile          = $dumpFile
        MinidumpDir       = $miniDir
        DedicatedDumpFile = Read-CcValue 'DedicatedDumpFile'
    }
}

$paths   = Get-DumpPaths
$miniDir = $paths.MinidumpDir
Remove-Item (Join-Path $miniDir '*.dmp') -Force -ErrorAction SilentlyContinue
foreach ($full in @($paths.DumpFile, $paths.DedicatedDumpFile)) {
    if ($full) { Remove-Item $full -Force -ErrorAction SilentlyContinue }
}
$md=@(Get-ChildItem (Join-Path $miniDir '*.dmp') -EA SilentlyContinue).Count
Write-Output ("minidumps after clear: {0}" -f $md)
Write-Output ("MEMORY.DMP after clear: {0}" -f (Test-Path $paths.DumpFile))
