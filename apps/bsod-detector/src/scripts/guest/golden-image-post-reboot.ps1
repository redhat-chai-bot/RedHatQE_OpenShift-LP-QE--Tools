# Golden-image setup, part 2 of 2. Run as Administrator AFTER the reboot triggered by
# golden-image-pre-reboot.ps1 and BEFORE sealing. Any FAIL exits 1 (do not seal);
# WARN lines are informational. When every check passes, the ISO cache files left by
# golden-image-pre-reboot.ps1 are removed so they are not sealed into the image.

# Fixed pagefile size in MB: physical RAM plus 257 MB, rounded once to a whole MB. This must
# match the size golden-image-pre-reboot.ps1 configures, so the check below can pass exactly.
function Get-PagefileSizeMB ([int64]$memoryBytes) {
    [int64][math]::Round(($memoryBytes + 257MB) / 1MB, 0)
}

# Removes the given cache files and outputs one message per file that could not be removed.
# A missing file is already clean. A mounted ISO is left in place and reported, and any
# removal error (for example a file in use) is reported instead of being ignored.
function Remove-SetupCacheFile ([string[]]$pathArr) {
    $failures = @()
    foreach ($path in $pathArr) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        if ($path -like '*.iso') {
            $image = Get-DiskImage -ImagePath $path -ErrorAction SilentlyContinue
            if ($image -and $image.Attached) {
                $failures += "${path} is still mounted"
                continue
            }
        }
        try {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            Write-Host "OK: removed ${path}"
        } catch {
            $failures += "${path} could not be removed: $($_.Exception.Message)"
        }
    }
    $failures
}

# Returns a stored artifact record (JSON), or nothing when it is missing or unreadable.
function Read-ArtifactRecord ([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    try { Get-Content -Raw -LiteralPath $path | ConvertFrom-Json } catch { return }
}

# FAIL lines use Write-Error. Keep the default preference so a caller's Stop preference cannot end
# the script at the first FAIL and skip the remaining checks.
$ErrorActionPreference = 'Continue'
$hasFailure = $false

# Also (re)sets the startup type to Automatic.
Write-Host "`n--- Checking QEMU Guest Agent ---"
$svc = Get-Service QEMU-GA -ErrorAction SilentlyContinue
Set-Service qemu-ga -StartupType Automatic -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') {
    Write-Host 'OK: QEMU-GA = Running, StartupType = Automatic'
} else {
    Write-Error "FAIL: QEMU-GA not running (status: $(if ($svc) { $svc.Status } else { 'not installed' }))"
    $hasFailure = $true
}

# Each storage driver activates only for its disk bus, so a missing one is a warning.
Write-Host "`n--- Checking VirtIO storage drivers ---"
$oemDrivers = Get-WindowsDriver -Online
if ($oemDrivers | Where-Object { $_.OriginalFileName -like '*viostor*' }) {
    Write-Host 'OK: viostor.sys in driver store (activates with bus: virtio)'
} else {
    Write-Host 'WARN: viostor.sys not in driver store - VM with bus: virtio may not boot (non-fatal if using SATA/SCSI)'
}
if ($oemDrivers | Where-Object { $_.OriginalFileName -like '*vioscsi*' }) {
    Write-Host 'OK: vioscsi.sys in driver store (activates with bus: scsi)'
} else {
    Write-Host 'WARN: vioscsi.sys not in driver store - VM with bus: scsi may not boot (non-fatal if using VirtIO/SATA)'
}
if (Test-Path 'C:\Windows\System32\drivers\storahci.sys') {
    Write-Host 'OK: storahci.sys present (inbox driver, activates with bus: sata - crash dump supported natively)'
} else {
    Write-Host 'WARN: storahci.sys not found - unexpected (inbox driver should always be present)'
}

# pvpanic: this script does not check a guest pvpanic driver (golden-image-pre-reboot.ps1 does
# not install one). The pipeline entry script attempts, best effort and non-fatal, to hot-add the
# pvpanic device to the running VM through the QEMU monitor
# (`virsh qemu-monitor-command --hmp 'device_add pvpanic,id=pvpanic0'`):
# src/scripts/crash-injector/trigger-bsod-intentional.sh (a separately proposed pipeline runner may
# take over that step). Whether the KubeVirt Panicked event is raised without a guest driver has
# not been verified.

# The DWORD values golden-image-pre-reboot.ps1 writes; DedicatedDumpFile must be absent.
Write-Host "`n--- Checking crash dump registry ---"
$cc = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
$expected = [ordered]@{
    CrashDumpEnabled     = 7
    AutoReboot           = 0
    AlwaysKeepMemoryDump = 1
    Overwrite            = 1
    LogEvent             = 1
}
foreach ($name in $expected.Keys) {
    $actual = (Get-ItemProperty -Path $cc -Name $name -ErrorAction SilentlyContinue).$name
    if ("${actual}" -eq "$($expected[$name])") {
        Write-Host "OK: ${name} = ${actual}"
    } else {
        Write-Error "FAIL: ${name} = '${actual}' (expected '$($expected[$name])')"
        $hasFailure = $true
    }
}
$dedicatedDump = (Get-ItemProperty -Path $cc -Name DedicatedDumpFile -ErrorAction SilentlyContinue).DedicatedDumpFile
if ($dedicatedDump) {
    Write-Error "FAIL: DedicatedDumpFile = '${dedicatedDump}' (must be absent - forces StorPort miniport, fails on VirtIO)"
    $hasFailure = $true
} else {
    Write-Host 'OK: DedicatedDumpFile = (not set) - pagefile.sys used via normal I/O'
}
# A dedicated dump file left by an older preparation is unused but would be sealed into the image.
# It is not deleted automatically: remove it manually once DedicatedDumpFile is unset and the VM has
# rebooted (Windows can hold the file open until then), then re-run this script.
if (Test-Path -LiteralPath 'C:\DedicatedDump.sys') {
    Write-Error 'FAIL: C:\DedicatedDump.sys from an older preparation still exists - delete it manually once DedicatedDumpFile is unset and the VM has rebooted, then re-run this script'
    $hasFailure = $true
}

# golden-image-pre-reboot.ps1 records the virtio-win ISO it installed from (source, resolved HTTPS
# source, version, SHA-256 calculated at download) in this file. The record stays in the image when
# the ISO cache is removed below; its SHA-256 is an audit record, not a publisher attestation.
Write-Host "`n--- Checking the virtio-win ISO record ---"
$isoRecordPath = 'C:\ProgramData\bsod-detector\virtio-win-iso.json'
$isoRecord = Read-ArtifactRecord $isoRecordPath
if ($isoRecord -and "$($isoRecord.sha256)" -match '^[0-9A-Fa-f]{64}$' -and "$($isoRecord.resolvedSource)" -like 'https://*') {
    Write-Host "OK: virtio-win $($isoRecord.version) from $($isoRecord.resolvedSource), SHA-256 $($isoRecord.sha256) (kept in ${isoRecordPath})"
} else {
    Write-Error "FAIL: ${isoRecordPath} is missing or incomplete - re-run golden-image-pre-reboot.ps1"
    $hasFailure = $true
}

# Both pagefile checks need the memory size: a failed query or a missing or non-positive
# size fails verification instead of being read as 'automatic management off' or as a
# 257 MB minimum.
Write-Host "`n--- Checking pagefile management ---"
$computer = $null
try {
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
} catch {
    Write-Error "FAIL: Win32_ComputerSystem query failed: $($_.Exception.Message)"
}
$hasMemorySize = $computer -and $computer.TotalPhysicalMemory -gt 0
if (-not $hasMemorySize) {
    Write-Error "FAIL: physical memory size is missing or not positive (TotalPhysicalMemory = '$($computer.TotalPhysicalMemory)')"
    $hasFailure = $true
} elseif (-not $computer.AutomaticManagedPagefile) {
    Write-Host 'OK: AutomaticManagedPagefile = false'
} else {
    Write-Error 'FAIL: AutomaticManagedPagefile is still true'
    $hasFailure = $true
}

# Must be active in the running kernel with at least the size (RAM + 257 MB) that
# golden-image-pre-reboot.ps1 set before the reboot.
Write-Host "`n--- Checking pagefile.sys ---"
$pf = Get-CimInstance Win32_PageFileUsage | Where-Object { $_.Name -like 'C:\*' }
$expectedMinMB = Get-PagefileSizeMB $computer.TotalPhysicalMemory
if (-not $hasMemorySize) {
    Write-Error 'FAIL: pagefile.sys size not verified - the physical memory size is unknown'
    $hasFailure = $true
} elseif ($pf -and $pf.AllocatedBaseSize -ge $expectedMinMB) {
    Write-Host "OK: pagefile.sys active - AllocatedBaseSize=$($pf.AllocatedBaseSize) MB (>= RAM+257MB=${expectedMinMB} MB), CurrentUsage=$($pf.CurrentUsage) MB"
} elseif ($pf -and $pf.AllocatedBaseSize -gt 0) {
    Write-Error "FAIL: pagefile.sys active but too small - AllocatedBaseSize=$($pf.AllocatedBaseSize) MB (expected >= ${expectedMinMB} MB = RAM+257MB)"
    $hasFailure = $true
} else {
    Write-Error 'FAIL: pagefile.sys not active in running kernel - crash dump will not be written on BSOD'
    $hasFailure = $true
}

Write-Host ''
if ($hasFailure) {
    Write-Error '=== One or more checks FAILED - DO NOT SEAL. Fix the issues (re-run golden-image-pre-reboot.ps1 if needed), then re-run this script. ==='
    exit 1
}

# Only after every check passed: golden-image-pre-reboot.ps1 keeps its ISO download (and, after an
# interrupted transfer, a partial .download file) for re-runs, but neither belongs in the image.
Write-Host "`n--- Removing stale setup files ---"
$cleanupFailures = @(Remove-SetupCacheFile @('C:\Temp\virtio-win.iso', 'C:\Temp\virtio-win.iso.download'))
if ($cleanupFailures.Count) {
    foreach ($failure in $cleanupFailures) { Write-Error "FAIL: ${failure}" }
    Write-Error '=== Stale setup files remain - DO NOT SEAL. Unmount or close them, remove them and re-run this script. ==='
    exit 1
}
Write-Host 'OK: virtio-win ISO cache files removed or already absent'

Write-Host ''
Write-Host '=== All checks passed - safe to seal the golden image. ===' -ForegroundColor Green
Write-Host '=== Seal the image with: C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /quiet ===' -ForegroundColor Green
