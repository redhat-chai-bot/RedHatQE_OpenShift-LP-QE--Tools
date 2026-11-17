# Golden-image setup, part 1 of 2. Run as Administrator BEFORE sealing; reboots at the end.
# Afterwards run golden-image-post-reboot.ps1 and seal only if it passes.
# Both VirtIO storage drivers are staged so the image boots on a virtio (viostor),
# scsi (vioscsi) or sata (storahci, inbox) disk bus.

# Fixed pagefile size in MB: physical RAM plus 257 MB, rounded once to a whole MB.
# golden-image-post-reboot.ps1 checks the active pagefile against the same calculation.
function Get-PagefileSizeMB ([int64]$MemoryBytes) {
    [int64][math]::Round(($MemoryBytes + 257MB) / 1MB, 0)
}

# The cached ISO is replaced only when the server reports a newer copy. An unknown remote
# timestamp (failed HEAD request) keeps an existing cache instead of forcing a download.
function Test-ISOdownloadNeeded ($LocalLastWriteUTC, $RemoteLastModifiedUTC) {
    if ($null -eq $LocalLastWriteUTC) { return $true }
    if ($null -eq $RemoteLastModifiedUTC) { return $false }
    $LocalLastWriteUTC -lt $RemoteLastModifiedUTC
}

# Windows Installer success codes: 0, 1641 (restart initiated) and 3010 (restart required);
# pnputil uses 0 and 3010. A missing exit code is not treated as success.
function Test-InstallerSuccess ([Nullable[int]]$ExitCode) {
    $null -ne $ExitCode -and $ExitCode -in 0, 1641, 3010
}

New-Item -ItemType Directory -Force -Path C:\Temp | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$isoURL  = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso'
$isoPath = 'C:\Temp\virtio-win.iso'

$remoteLastModified = $null
try {
    $req = [System.Net.HttpWebRequest]::Create($isoURL)
    $req.Method = 'HEAD'
    $resp = $req.GetResponse()
    try {
        $remoteLastModified = $resp.LastModified.ToUniversalTime()
    } finally {
        $resp.Close()
    }
    Write-Host "Remote ISO Last-Modified (UTC): ${remoteLastModified}"
} catch {
    Write-Host "WARN: cannot read the remote ISO timestamp: $($_.Exception.Message)"
}

$localLastWrite = $null
if (Test-Path $isoPath) { $localLastWrite = (Get-Item $isoPath).LastWriteTimeUtc }
if (Test-ISOdownloadNeeded $localLastWrite $remoteLastModified) {
    # Download to a temporary name first: a failed transfer must neither replace the cache
    # nor leave a partial file that a later run would treat as the latest ISO.
    $isoTmpPath = "${isoPath}.download"
    try {
        Write-Host 'Downloading virtio-win ISO...'
        (New-Object System.Net.WebClient).DownloadFile($isoURL, $isoTmpPath)
        Move-Item -Path $isoTmpPath -Destination $isoPath -Force -ErrorAction Stop
        Write-Host "OK: Downloaded $([math]::Round((Get-Item $isoPath).Length / 1MB, 0)) MB"
    } catch {
        Remove-Item -Path $isoTmpPath -Force -ErrorAction SilentlyContinue
        if ($null -eq $localLastWrite) {
            Write-Error "FAIL: virtio-win ISO download failed and no cached copy exists: $($_.Exception.Message)"
            exit 1
        }
        Write-Host "WARN: virtio-win ISO download failed, using the cached copy: $($_.Exception.Message)"
    }
} else {
    Write-Host "OK: using cached virtio-win ISO (local=${localLastWrite}, remote=$(if ($remoteLastModified) { $remoteLastModified } else { 'unknown' }))"
}

$iso   = Mount-DiskImage -ImagePath $isoPath -PassThru
$drive = ($iso | Get-Volume).DriveLetter
Write-Host "OK: ISO mounted at ${drive}:\"

Write-Host "`n--- Installing QEMU Guest Agent ---"
$msiProcess = Start-Process msiexec.exe -ArgumentList "/i ${drive}:\guest-agent\qemu-ga-x86_64.msi /quiet /norestart" -Wait -PassThru
if (Test-InstallerSuccess $msiProcess.ExitCode) {
    Write-Host "OK: QEMU Guest Agent MSI installed (exit code $($msiProcess.ExitCode))"
} else {
    Write-Host "WARN: QEMU Guest Agent MSI exited with code $($msiProcess.ExitCode); the service check below decides"
}

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
        if (Test-InstallerSuccess $LASTEXITCODE) {
            Write-Host "OK: $($drv.Name) installed from $($inf.FullName)"
        } else {
            Write-Host "WARN: pnputil exited with code ${LASTEXITCODE} for $($inf.FullName) - golden-image-post-reboot.ps1 checks the driver store"
        }
    } else {
        Write-Host "WARN: $($drv.Name) not found in ISO - skip"
    }
}
Write-Host 'NOTE: storahci.sys (SATA) is an inbox Windows driver - no installation needed'

# pvpanic: no guest pvpanic driver is installed here (golden-image-post-reboot.ps1 does not check
# one). The pipeline entry script attempts, best effort and non-fatal, to hot-add the pvpanic
# device to the running VM through the QEMU monitor
# (`virsh qemu-monitor-command --hmp 'device_add pvpanic,id=pvpanic0'`):
# src/scripts/crash-injector/trigger-bsod-intentional.sh, or src/scripts/bsod-pipeline/bsod-runner.sh
# after the pipeline rename. Whether the KubeVirt Panicked event is raised without a guest driver
# has not been verified.

# The ISO stays on disk for the version check if this script is re-run; golden-image-post-reboot.ps1
# removes it once every check has passed.
Dismount-DiskImage -ImagePath $isoPath
Write-Host "OK: ISO unmounted (kept on disk at ${isoPath} until golden-image-post-reboot.ps1 passes)"

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
$pagefileSizeMB = Get-PagefileSizeMB $ramBytes
$pagefilePath = 'C:\pagefile.sys'
Write-Host "OK: pagefile.sys will be created by Windows on next reboot at ${pagefileSizeMB} MB ($([math]::Round($pagefileSizeMB / 1024, 1)) GB)"

# Set pagefile via registry (PagingFiles REG_MULTI_SZ) - avoids CIM type inference issues.
# Format: "<path> <initialMB> <maxMB>"
Set-ItemProperty -Path $mm -Name PagingFiles -Type MultiString -Value @("${pagefilePath} ${pagefileSizeMB} ${pagefileSizeMB}")
Write-Host "OK: pagefile.sys registered via registry (${pagefileSizeMB} MB = RAM + 257MB)"
Write-Host 'OK: Pagefile pre-allocation complete - active after reboot'

Write-Host "`n=== All steps complete. Rebooting in 5 seconds... ==="
Start-Sleep -Seconds 5
Restart-Computer -Force
