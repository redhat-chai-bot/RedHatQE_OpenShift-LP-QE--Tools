# Golden-image setup, part 2 of 2. Run as Administrator AFTER the reboot triggered by
# golden-image-pre-reboot.ps1 and BEFORE sealing. Any FAIL exits 1 (do not seal);
# WARN lines are informational.
$hasFailure = $false

# Also (re)sets the startup type to Automatic.
Write-Host "`n--- Checking QEMU Guest Agent ---"
$svc = Get-Service QEMU-GA -ErrorAction SilentlyContinue
Set-Service qemu-ga -StartupType Automatic -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') {
    Write-Host 'OK: QEMU-GA = Running, StartupType = Automatic'
} else {
    Write-Error "FAIL: QEMU-GA not running (status: $($svc.Status))"
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

# pvpanic check not needed — pipeline uses KubeVirt Panicked event for crash detection,
# not the Windows pvpanic driver. Device is added at runtime by preflight-rhov.sh via QMP.
# Write-Host "`n--- Checking pvpanic driver ---"
# $pvpanicStart = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\pvpanic' -Name Start -ErrorAction SilentlyContinue).Start
# if ("$pvpanicStart" -eq '3') {
#     Write-Host 'OK: pvpanic service key present (Start=3) - driver will load when QEMU presents the device'
# } else {
#     Write-Host "WARN: pvpanic service key missing or incorrect (Start='$pvpanicStart') - pipeline adds device via QMP at runtime (non-fatal)"
# }

# Disabled together with the recovery step in golden-image-pre-reboot.ps1.
#Write-Host "`n--- Checking recovery settings ---"
#$bootStatus  = bcdedit /enum '{default}' | Select-String "bootstatuspolicy"
#$recoveryEna = bcdedit /enum '{default}' | Select-String "recoveryenabled"
#if ($bootStatus -match "IgnoreAllFailures") {
#    Write-Host "OK: bootstatuspolicy = IgnoreAllFailures"
#} else {
#    Write-Error "FAIL: bootstatuspolicy not set to IgnoreAllFailures"; $hasFailure = $true
#}
#if ($recoveryEna -match "No") {
#    Write-Host "OK: recoveryenabled = No"
#} else {
#    Write-Error "FAIL: recoveryenabled not set to No"; $hasFailure = $true
#}

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
    if ("$actual" -eq "$($expected[$name])") {
        Write-Host "OK: $name = $actual"
    } else {
        Write-Error "FAIL: $name = '$actual' (expected '$($expected[$name])')"
        $hasFailure = $true
    }
}
$dedicatedDump = (Get-ItemProperty -Path $cc -Name DedicatedDumpFile -ErrorAction SilentlyContinue).DedicatedDumpFile
if ($dedicatedDump) {
    Write-Error "FAIL: DedicatedDumpFile = '$dedicatedDump' (must be absent - forces StorPort miniport, fails on VirtIO)"
    $hasFailure = $true
} else {
    Write-Host 'OK: DedicatedDumpFile = (not set) - pagefile.sys used via normal I/O'
}

Write-Host "`n--- Checking pagefile management ---"
$computer = Get-CimInstance -ClassName Win32_ComputerSystem
if (-not $computer.AutomaticManagedPagefile) {
    Write-Host 'OK: AutomaticManagedPagefile = false'
} else {
    Write-Error 'FAIL: AutomaticManagedPagefile is still true'
    $hasFailure = $true
}

# Must be active in the running kernel with at least the RAM + 257 MB set before the reboot.
Write-Host "`n--- Checking pagefile.sys ---"
$pf = Get-CimInstance Win32_PageFileUsage | Where-Object { $_.Name -like 'C:\*' }
$expectedMinMB = [math]::Round($computer.TotalPhysicalMemory / 1MB, 0) + 257
if ($pf -and $pf.AllocatedBaseSize -ge $expectedMinMB) {
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
    Write-Error '=== One or more checks FAILED - DO NOT SEAL. Fix issues and re-run Script 1. ==='
    exit 1
}
Write-Host '=== All checks passed - safe to seal the golden image. ===' -ForegroundColor Green
Write-Host '=== Seal the image with: sysprep /generalize /oobe /shutdown /quiet ===' -ForegroundColor Green