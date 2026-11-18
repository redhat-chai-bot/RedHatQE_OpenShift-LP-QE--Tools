# Golden-image setup, part 1 of 2. Run as Administrator BEFORE sealing; reboots at the end.
# Afterwards run golden-image-post-reboot.ps1 and seal only if it passes.
# Both VirtIO storage drivers are staged so the image boots on a virtio (viostor),
# scsi (vioscsi) or sata (storahci, inbox) disk bus.

# The ISO is downloaded again only when the remote copy is newer than the local one.
New-Item -ItemType Directory -Force -Path C:\Temp | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$isoUrl  = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso'
$isoPath = 'C:\Temp\virtio-win.iso'

$req = [System.Net.HttpWebRequest]::Create($isoUrl)
$req.Method = 'HEAD'
$resp = $req.GetResponse()
$remoteLastModified = $resp.LastModified
$resp.Close()
Write-Host "Remote ISO Last-Modified: $remoteLastModified"

$isDownloadNeeded = $true
if (Test-Path $isoPath) {
    $localLastModified = (Get-Item $isoPath).LastWriteTimeUtc
    if ($localLastModified -ge $remoteLastModified.ToUniversalTime()) {
        Write-Host "OK: virtio-win ISO already latest (local=$localLastModified >= remote=$($remoteLastModified.ToUniversalTime())) - skipping download"
        $isDownloadNeeded = $false
    } else {
        Write-Host "ISO outdated (local=$localLastModified, remote=$($remoteLastModified.ToUniversalTime())) - re-downloading"
    }
}
if ($isDownloadNeeded) {
    Write-Host 'Downloading virtio-win ISO...'
    (New-Object System.Net.WebClient).DownloadFile($isoUrl, $isoPath)
    Write-Host "OK: Downloaded $([math]::Round((Get-Item $isoPath).Length / 1MB, 0)) MB"
}

$iso   = Mount-DiskImage -ImagePath $isoPath -PassThru
$drive = ($iso | Get-Volume).DriveLetter
Write-Host "OK: ISO mounted at ${drive}:\"

Write-Host "`n--- Installing QEMU Guest Agent ---"
Start-Process msiexec.exe -ArgumentList "/i ${drive}:\guest-agent\qemu-ga-x86_64.msi /quiet /norestart" -Wait
Write-Host 'OK: QEMU Guest Agent MSI installed'

# A driver missing from its expected path is searched for recursively; still missing is a warning.
Write-Host "`n--- Installing VirtIO storage drivers ---"
$storageDrivers = @(
    @{ Name = 'viostor (VirtIO block)'; Inf = 'viostor\w11\amd64\viostor.inf' },
    @{ Name = 'vioscsi (VirtIO SCSI)';  Inf = 'vioscsi\w11\amd64\vioscsi.inf' }
)
foreach ($drv in $storageDrivers) {
    $inf = Get-Item "${drive}:\$($drv.Inf)" -ErrorAction SilentlyContinue
    if (-not $inf) {
        Write-Host "WARN: $($drv.Name) inf not found at ${drive}:\$($drv.Inf) - trying recursive search"
        $inf = Get-ChildItem "${drive}:\" -Recurse -Filter $drv.Inf.Split('\')[-1] -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -like '*amd64*' } | Select-Object -First 1
    }
    if ($inf) {
        pnputil /add-driver $inf.FullName /install | Out-Null
        Write-Host "OK: $($drv.Name) installed from $($inf.FullName)"
    } else {
        Write-Host "WARN: $($drv.Name) not found in ISO - skip"
    }
}
Write-Host 'NOTE: storahci.sys (SATA) is an inbox Windows driver - no installation needed'

# pvpanic driver install not needed — pipeline uses KubeVirt Panicked event for crash detection,
# not the Windows pvpanic driver. Device is added at runtime by preflight-rhov.sh via QMP.
# Write-Host "`n--- Installing pvpanic driver ---"
# $pvpanicInf = Get-ChildItem "${drive}:\pvpanic" -Recurse -Filter 'pvpanic.inf' -ErrorAction SilentlyContinue |
#     Where-Object { $_.FullName -like '*amd64*' } | Select-Object -First 1
# if ($pvpanicInf) {
#     pnputil /add-driver $pvpanicInf.FullName /install | Out-Null
#     Write-Host "OK: pvpanic driver added to store from $($pvpanicInf.FullName)"
#     $pvpanicReg = 'HKLM:\SYSTEM\CurrentControlSet\Services\pvpanic'
#     New-Item -Path $pvpanicReg -Force | Out-Null
#     Set-ItemProperty -Path $pvpanicReg -Name Start -Value 3 -Type DWord
#     Set-ItemProperty -Path $pvpanicReg -Name Type  -Value 1 -Type DWord
#     Write-Host 'OK: pvpanic service key set (Start=3 demand-load, Type=1 kernel driver)'
# } else {
#     Write-Host 'WARN: pvpanic.inf not found in ISO - pipeline will add pvpanic device via QMP at runtime'
# }

# The ISO stays on disk for the version check on the next run.
Dismount-DiskImage -ImagePath $isoPath
Write-Host "OK: ISO unmounted (kept on disk at $isoPath for future version checks)"

Write-Host "`n--- Verifying QEMU Guest Agent ---"
$svc = Get-Service QEMU-GA -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Error 'FAIL: QEMU-GA service not installed - abort'
    exit 1
}
Set-Service QEMU-GA -StartupType Automatic
if ($svc.Status -ne 'Running') {
    Write-Host 'QEMU-GA is stopped - starting...'
    Start-Service QEMU-GA -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    $svc.Refresh()
}
if ($svc.Status -ne 'Running') {
    Write-Error "FAIL: QEMU-GA could not be started (Status: $($svc.Status)) - abort"
    exit 1
}
Write-Host 'OK: QEMU-GA is Running and set to Automatic'

# Disabled: keep Windows out of automatic recovery (WinRE) after a BSOD. Re-enable together
# with the matching check in golden-image-post-reboot.ps1.
#bcdedit /set '{default}' bootstatuspolicy IgnoreAllFailures
#bcdedit /set '{default}' recoveryenabled No
#bcdedit /set '{bootmgr}' displaybootmenu No
#reagentc /disable

# CrashDumpEnabled=7 is the Automatic memory dump. DedicatedDumpFile must be absent
# (golden-image policy, see virtio-win issue #1629).
Write-Host "`n--- Setting crash dump registry ---"
$cc = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
Set-ItemProperty -Path $cc -Name CrashDumpEnabled     -Value 7                         -Type DWord
Set-ItemProperty -Path $cc -Name AutoReboot           -Value 0                         -Type DWord
Set-ItemProperty -Path $cc -Name AlwaysKeepMemoryDump -Value 1                         -Type DWord
Set-ItemProperty -Path $cc -Name Overwrite            -Value 1                         -Type DWord
Set-ItemProperty -Path $cc -Name LogEvent             -Value 1                         -Type DWord
Set-ItemProperty -Path $cc -Name DumpFile             -Value '%SystemRoot%\MEMORY.DMP' -Type ExpandString
Set-ItemProperty -Path $cc -Name MinidumpDir          -Value '%SystemRoot%\Minidump'   -Type ExpandString
Remove-ItemProperty -Path $cc -Name DedicatedDumpFile -ErrorAction SilentlyContinue
Write-Host 'OK: Crash dump registry set (CrashDumpEnabled=7, no DedicatedDumpFile)'

# Fixed-size C:\pagefile.sys of RAM + 257 MB with automatic management off, active after
# the reboot; golden-image-post-reboot.ps1 checks this size.
Write-Host "`n--- Pre-allocating pagefile.sys ---"
$mm = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
Set-ItemProperty -Path $mm -Name AutomaticManagedPagefile -Value 0 -Type DWord

$ramBytes = (Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory
$pagefileSizeBytes = $ramBytes + 257MB
$pagefileSizeMB = [math]::Round($pagefileSizeBytes / 1MB, 0)
$pagefilePath = 'C:\pagefile.sys'
Write-Host "OK: pagefile.sys will be created by Windows on next reboot at ${pagefileSizeMB} MB ($([math]::Round($pagefileSizeBytes / 1GB, 1)) GB)"

# Set pagefile via registry (PagingFiles REG_MULTI_SZ) — avoids CIM type inference issues.
# Format: "<path> <initialMB> <maxMB>"
Set-ItemProperty -Path $mm -Name PagingFiles -Type MultiString -Value @("$pagefilePath $pagefileSizeMB $pagefileSizeMB")
Write-Host "OK: pagefile.sys registered via registry (${pagefileSizeMB} MB = RAM + 257MB)"
Write-Host 'OK: Pagefile pre-allocation complete - active after reboot'

Write-Host "`n=== All steps complete. Rebooting in 5 seconds... ==="
Start-Sleep -Seconds 5
Restart-Computer -Force