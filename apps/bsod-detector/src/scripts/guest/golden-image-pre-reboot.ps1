# Golden-image setup, part 1 of 2. Run as Administrator BEFORE sealing; reboots at the end.
# Afterwards run golden-image-post-reboot.ps1 and seal only if it passes.
# Both VirtIO storage drivers are staged so the image boots on a virtio (viostor),
# scsi (vioscsi) or sata (storahci, inbox) disk bus.
# The page file is sized from this VM's RAM (RAM + 257 MB). configure-dumps.ps1 checks it against
# the RAM of the VM it runs on, so VMs cloned from this image must not have more RAM than this VM.

# Fixed pagefile size in MB: physical RAM plus 257 MB, rounded once to a whole MB.
# golden-image-post-reboot.ps1 checks the active pagefile against the same calculation.
function Get-PagefileSizeMB ([int64]$MemoryBytes) {
    [int64][math]::Round(($MemoryBytes + 257MB) / 1MB, 0)
}

# True only when the file exists and its SHA-256 equals the pinned digest (case-insensitive).
function Test-ISOhash ([string]$Path, [string]$ExpectedSHA256) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $ExpectedSHA256
}

# Windows Installer success codes: 0, 1641 (restart initiated) and 3010 (restart required);
# pnputil uses 0 and 3010. A missing exit code is not treated as success.
function Test-InstallerSuccess ([Nullable[int]]$ExitCode) {
    $null -ne $ExitCode -and $ExitCode -in 0, 1641, 3010
}

# Replaces any system-managed or other page file configuration with one fixed C:\pagefile.sys.
# Automatic management is turned off through the documented read/write
# Win32_ComputerSystem.AutomaticManagedPagefile property, then PagingFiles is set to exactly
# this entry (other entries are dropped). No page file is deleted here: Windows applies the
# configuration at the next boot.
function Set-FixedPagefile ([int64]$SizeMB) {
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    if ($computer.AutomaticManagedPagefile) {
        Set-CimInstance -InputObject $computer -Property @{ AutomaticManagedPagefile = $false } -ErrorAction Stop
        Write-Host 'OK: automatic pagefile management disabled'
    }
    $entry = 'C:\pagefile.sys {0} {0}' -f $SizeMB
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name PagingFiles -Type MultiString -Value @($entry) -ErrorAction Stop
    Write-Host "OK: PagingFiles set to '${entry}' (RAM + 257 MB), active after reboot"
}

# Adds TLS 1.2 to the protocols this process already allows instead of replacing them.
function Enable-TLS12 {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# Downloads the ISO to the given (temporary) path.
function Save-ISOdownload ([string]$URL, [string]$Path) {
    (New-Object System.Net.WebClient).DownloadFile($URL, $Path)
}

# The memory size is read before any change: an unreadable, missing or non-positive size stops the
# script before the ISO download, installations, registry writes, page file change or reboot.
try {
    $ramBytes = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory -as [int64]
} catch {
    Write-Error "FAIL: cannot read the physical memory size: $($_.Exception.Message)"
    exit 1
}
if (-not ($ramBytes -gt 0)) {
    Write-Error "FAIL: physical memory size is missing or not positive (TotalPhysicalMemory = '${ramBytes}')"
    exit 1
}
$pagefileSizeMB = Get-PagefileSizeMB $ramBytes
Write-Host "OK: physical memory read; the page file will be ${pagefileSizeMB} MB (RAM + 257 MB)"

# C:\Temp is a fixed location on purpose: the ISO cache must survive the reboot and be found by
# golden-image-post-reboot.ps1, which may run under another account (per-user $env:TEMP differs).
New-Item -ItemType Directory -Force -Path 'C:\Temp' | Out-Null
Enable-TLS12
# virtio-win is pinned to the published build 0.1.302-1 (what stable-virtio and latest-virtio
# pointed to on 2026-11-17) and used only when its SHA-256 matches. No detached signature is
# published: the digest is the one recorded for this ISO in the official
# virtio-win-0.1.302-1.noarch.rpm header, and the ISO inside that RPM and the direct download
# hash to the same value. To move to another build, update the version and digest together.
$isoURL    = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302.iso'
$isoSHA256 = '303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d'
$isoPath = 'C:\Temp\virtio-win.iso'

# A cached ISO is reused only if it matches the pinned digest. Otherwise the ISO is downloaded to a
# temporary name, verified and only then moved over the cache; a failed or mismatching download
# stops the script before anything is installed, without falling back to an unverified copy.
if (Test-ISOhash $isoPath $isoSHA256) {
    Write-Host "OK: cached virtio-win ISO matches the pinned SHA-256 ${isoSHA256}"
} else {
    if (Test-Path -LiteralPath $isoPath) {
        Write-Host 'WARN: the cached virtio-win ISO does not match the pinned SHA-256 - replacing it'
    }
    $isoTmpPath = "${isoPath}.download"
    try {
        Write-Host "Downloading ${isoURL} ..."
        Save-ISOdownload $isoURL $isoTmpPath
        if (-not (Test-ISOhash $isoTmpPath $isoSHA256)) { throw "the download does not match the pinned SHA-256 ${isoSHA256}" }
        # A mismatching cache can still be mounted by an interrupted earlier run; detach it first.
        if ((Test-Path -LiteralPath $isoPath) -and (Get-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue).Attached) {
            Dismount-DiskImage -ImagePath $isoPath -ErrorAction Stop | Out-Null
        }
        Move-Item -Path $isoTmpPath -Destination $isoPath -Force -ErrorAction Stop
        Write-Host "OK: downloaded and verified virtio-win 0.1.302 ($([math]::Round((Get-Item $isoPath).Length / 1MB, 0)) MB)"
    } catch {
        Remove-Item -Path $isoTmpPath -Force -ErrorAction SilentlyContinue
        Write-Error "FAIL: no virtio-win ISO matching the pinned SHA-256 is available: $($_.Exception.Message)"
        exit 1
    }
}

# An ISO left mounted by an interrupted run is reused. A failed mount or a missing drive letter
# stops the script before anything is installed.
$drive = $null
try {
    $iso = Get-DiskImage -ImagePath $isoPath -ErrorAction Stop
    if (-not $iso.Attached) { $iso = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop }
    $drive = ($iso | Get-Volume -ErrorAction Stop).DriveLetter
} catch {
    Write-Error "FAIL: cannot mount ${isoPath}: $($_.Exception.Message)"
    exit 1
}
if (-not $drive) {
    Write-Error "FAIL: ${isoPath} is mounted without a drive letter"
    exit 1
}
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
        $inf = Get-ChildItem "${drive}:\" -Recurse -Filter ($drv.Inf -split '\\')[-1] -ErrorAction SilentlyContinue |
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
# src/scripts/crash-injector/trigger-bsod-intentional.sh (a separately proposed pipeline runner may
# take over that step). Whether the KubeVirt Panicked event is raised without a guest driver has
# not been verified.
# Windows boot-recovery settings (boot-status policy, automatic recovery, recovery environment) are
# intentionally left at their Windows defaults: the intended flow does not restart a VM after a
# simulated crash. The current src/scripts/host/watch-crash.sh still starts the VM again unless it
# runs with --no-restart (a watcher change is planned separately); a restarted VM is not verified.

# The ISO stays on disk for re-runs (reused only while its SHA-256 matches); golden-image-post-reboot.ps1
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
    $svc = Get-Service QEMU-GA -ErrorAction SilentlyContinue
}
if (-not $svc -or $svc.Status -ne 'Running') {
    Write-Error "FAIL: QEMU-GA could not be started (Status: $(if ($svc) { $svc.Status } else { 'not installed' })) - abort"
    exit 1
}
Write-Host 'OK: QEMU-GA is Running and set to Automatic'

# CrashDumpEnabled=7 is the Automatic memory dump. DedicatedDumpFile must be absent
# (golden-image policy, see virtio-win issue #1629). A failed write stops the script before the
# page file change and the reboot; an absent DedicatedDumpFile value is left alone.
Write-Host "`n--- Setting crash dump registry ---"
$cc = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
try {
    Set-ItemProperty -Path $cc -Name CrashDumpEnabled     -Value 7                         -Type DWord        -ErrorAction Stop
    Set-ItemProperty -Path $cc -Name AutoReboot           -Value 0                         -Type DWord        -ErrorAction Stop
    Set-ItemProperty -Path $cc -Name AlwaysKeepMemoryDump -Value 1                         -Type DWord        -ErrorAction Stop
    Set-ItemProperty -Path $cc -Name Overwrite            -Value 1                         -Type DWord        -ErrorAction Stop
    Set-ItemProperty -Path $cc -Name LogEvent             -Value 1                         -Type DWord        -ErrorAction Stop
    Set-ItemProperty -Path $cc -Name DumpFile             -Value '%SystemRoot%\MEMORY.DMP' -Type ExpandString -ErrorAction Stop
    Set-ItemProperty -Path $cc -Name MinidumpDir          -Value '%SystemRoot%\Minidump'   -Type ExpandString -ErrorAction Stop
    if (Get-ItemProperty -Path $cc -Name DedicatedDumpFile -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $cc -Name DedicatedDumpFile -ErrorAction Stop
    }
} catch {
    Write-Error "FAIL: crash dump registry write failed: $($_.Exception.Message)"
    exit 1
}
Write-Host 'OK: Crash dump registry set (CrashDumpEnabled=7, no DedicatedDumpFile)'
# A dedicated dump file from an older preparation is no longer used. It is not deleted here;
# golden-image-post-reboot.ps1 refuses to seal while it exists.
if (Test-Path -LiteralPath 'C:\DedicatedDump.sys') {
    Write-Host 'WARN: C:\DedicatedDump.sys from an older preparation is no longer used - delete it before sealing'
}

# Fixed-size C:\pagefile.sys of RAM + 257 MB (computed above) with automatic management off,
# active after the reboot; golden-image-post-reboot.ps1 checks this size.
Write-Host "`n--- Configuring pagefile.sys ---"
try {
    Set-FixedPagefile $pagefileSizeMB
} catch {
    Write-Error "FAIL: pagefile configuration failed: $($_.Exception.Message)"
    exit 1
}

Write-Host "`n=== All steps complete. Rebooting in 5 seconds... ==="
Start-Sleep -Seconds 5
Restart-Computer -Force
