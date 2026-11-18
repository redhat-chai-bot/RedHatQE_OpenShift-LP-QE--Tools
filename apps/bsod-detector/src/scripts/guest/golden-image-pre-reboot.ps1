# Golden-image setup, part 1 of 2. Run as Administrator BEFORE sealing; reboots at the end.
# Afterwards run golden-image-post-reboot.ps1 and seal only if it passes.
# Both VirtIO storage drivers are staged so the image boots on a virtio (viostor),
# scsi (vioscsi) or sata (storahci, inbox) disk bus.
# The page file is sized from this VM's RAM (RAM + 257 MB). validate-crash-settings.ps1 checks it
# against the RAM of the VM it runs on, so VMs cloned from this image must not have more RAM than this VM.

# Fixed pagefile size in MB: physical RAM plus 257 MB, rounded once to a whole MB.
# golden-image-post-reboot.ps1 checks the active pagefile against the same calculation.
function Get-PagefileSizeMB ([int64]$memoryBytes) {
    [int64][math]::Round(($memoryBytes + 257MB) / 1MB, 0)
}

# True only when the file exists and its SHA-256 equals the expected digest (case-insensitive).
function Test-ISOhash ([string]$path, [string]$expectedSHA256) {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $expectedSHA256
}

# Windows Installer success codes: 0, 1641 (restart initiated) and 3010 (restart required);
# pnputil uses 0 and 3010. A missing exit code is not treated as success.
function Test-InstallerSuccess ([Nullable[int]]$exitCode) {
    $null -ne $exitCode -and $exitCode -in 0, 1641, 3010
}

# Replaces any system-managed or other page file configuration with one fixed C:\pagefile.sys.
# Automatic management is turned off through the documented read/write
# Win32_ComputerSystem.AutomaticManagedPagefile property, then PagingFiles is set to exactly
# this entry (other entries are dropped). No page file is deleted here: Windows applies the
# configuration at the next boot.
function Set-FixedPagefile ([int64]$sizeMB) {
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    if ($computer.AutomaticManagedPagefile) {
        Set-CimInstance -InputObject $computer -Property @{ AutomaticManagedPagefile = $false } -ErrorAction Stop
        Write-Host 'OK: automatic pagefile management disabled'
    }
    $entry = 'C:\pagefile.sys {0} {0}' -f $sizeMB
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name PagingFiles -Type MultiString -Value @($entry) -ErrorAction Stop
    Write-Host "OK: PagingFiles set to '${entry}' (RAM + 257 MB), active after reboot"
}

# Adds TLS 1.2 to the protocols this process already allows instead of replacing them.
function Enable-TLS12 {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# Downloads an already resolved HTTPS URL to a file without following redirects: a redirect or any
# status other than 200 throws instead of being followed, so the download cannot leave HTTPS.
function Save-HTTPSdownload ([string]$url, [string]$path) {
    if ($url -notlike 'https://*') { throw "not an HTTPS URL: ${url}" }
    $request = [System.Net.HttpWebRequest]::Create($url)
    $request.AllowAutoRedirect = $false
    $response = $request.GetResponse()
    try {
        if ([int]$response.StatusCode -ne 200) { throw "HTTP $([int]$response.StatusCode) from ${url}" }
        $file = [System.IO.File]::Create($path)
        try { $response.GetResponseStream().CopyTo($file) } finally { $file.Close() }
    } finally {
        $response.Close()
    }
}

# Turns an HTTP(S) redirect location into the HTTPS URL on the same official host, or nothing when
# it points elsewhere. Official download aliases may redirect to plain http://; only the host and
# path are taken from such a location, and the request is always made over HTTPS.
function Get-HTTPSredirectTarget ([string]$location, [string]$officialHost) {
    if ($location -notmatch '^https?://([^/?#]+)(/[^#]*)$') { return }
    if ($Matches[1] -ne $officialHost) { return }
    "https://$($Matches[1])$($Matches[2])"
}

# Returns the status code and Location header of one HTTPS HEAD request without following redirects.
function Get-HTTPSresponseHead ([string]$url) {
    $request = [System.Net.HttpWebRequest]::Create($url)
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
function Resolve-OfficialHTTPS ([string]$url, [string]$officialHost) {
    if ($url -notlike "https://${officialHost}/*") { throw "not an HTTPS URL on ${officialHost}: ${url}" }
    foreach ($hop in 1..5) {
        $head = Get-HTTPSresponseHead $url
        if ($head.StatusCode -eq 200) { return $url }
        if ($head.StatusCode -lt 300 -or $head.StatusCode -ge 400) { throw "HTTP $($head.StatusCode) from ${url}" }
        $next = Get-HTTPSredirectTarget $head.Location $officialHost
        if (-not $next) { throw "redirect from ${url} leaves ${officialHost}: $($head.Location)" }
        $url = $next
    }
    throw "too many redirects from ${url}"
}

# Returns a stored artifact record (JSON), or nothing when it is missing or unreadable.
function Read-ArtifactRecord ([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    try { Get-Content -Raw -LiteralPath $path | ConvertFrom-Json } catch { return }
}

# Stores an artifact record as JSON, adding the UTC time it was recorded.
function Write-ArtifactRecord ([string]$path, $record) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) -ErrorAction Stop | Out-Null
    $record['recordedUTC'] = [DateTime]::UtcNow.ToString('o')
    $record | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding ASCII -ErrorAction Stop
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
# virtio-win: the current official release behind the latest-virtio alias, with no hardcoded
# version or digest. The alias is resolved hop by hop over HTTPS on fedorapeople.org (it
# redirects to plain http://, which is never requested). No checksum or signature is published
# for the ISO, so its SHA-256 is calculated from the downloaded file and recorded, with the
# source, resolved source and version, in an audit record that stays in the image after
# golden-image-post-reboot.ps1 removes the ISO cache. The record is not a publisher attestation.
$isoAliasURL   = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso'
$isoPath = 'C:\Temp\virtio-win.iso'
$isoRecordPath = 'C:\ProgramData\bsod-detector\virtio-win-iso.json'
try {
    $isoURL = Resolve-OfficialHTTPS $isoAliasURL 'fedorapeople.org'
} catch {
    Write-Error "FAIL: cannot resolve the latest virtio-win ISO over HTTPS: $($_.Exception.Message)"
    exit 1
}
$isoVersion = if ($isoURL -match '/virtio-win-([0-9][0-9.]*)\.iso$') { $Matches[1] } else { $null }
Write-Host "Latest virtio-win ISO: ${isoURL} (version $(if ($isoVersion) { $isoVersion } else { 'not in the file name' }))"

# A cached ISO is reused only when it is that same latest release and still matches the SHA-256
# recorded when it was downloaded; otherwise the latest ISO is downloaded to a temporary name and
# only then moved over the cache. A failed download stops the script before anything is installed.
$isoRecord = Read-ArtifactRecord $isoRecordPath
if ($isoRecord -and $isoRecord.resolvedSource -eq $isoURL -and (Test-ISOhash $isoPath $isoRecord.sha256)) {
    Write-Host "OK: cached virtio-win ISO is the latest release and matches its recorded SHA-256 $($isoRecord.sha256)"
} else {
    $isoTmpPath = "${isoPath}.download"
    try {
        # The old record no longer describes the cache once a new download starts.
        if (Test-Path -LiteralPath $isoRecordPath) { Remove-Item -LiteralPath $isoRecordPath -Force -ErrorAction Stop }
        Write-Host "Downloading ${isoURL} ..."
        Save-HTTPSdownload $isoURL $isoTmpPath
        $isoSHA256 = (Get-FileHash -LiteralPath $isoTmpPath -Algorithm SHA256 -ErrorAction Stop).Hash
        # An older cache can still be mounted by an interrupted earlier run; detach it first.
        if ((Test-Path -LiteralPath $isoPath) -and (Get-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue).Attached) {
            Dismount-DiskImage -ImagePath $isoPath -ErrorAction Stop | Out-Null
        }
        Move-Item -Path $isoTmpPath -Destination $isoPath -Force -ErrorAction Stop
        Write-ArtifactRecord $isoRecordPath ([ordered]@{
            schema = 1; artifact = 'virtio-win.iso'; source = $isoAliasURL; resolvedSource = $isoURL; version = $isoVersion
            sha256 = $isoSHA256; sizeBytes = (Get-Item $isoPath).Length
            verification = 'No checksum or signature is published for this ISO; sha256 was calculated from the downloaded file (audit record, not publisher verification).'
        })
        Write-Host "OK: downloaded virtio-win ${isoVersion}; SHA-256 ${isoSHA256} recorded in ${isoRecordPath}"
    } catch {
        Remove-Item -Path $isoTmpPath -Force -ErrorAction SilentlyContinue
        Write-Error "FAIL: the latest virtio-win ISO could not be downloaded and recorded: $($_.Exception.Message)"
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

# The ISO stays on disk for re-runs (reused only while it is the latest release and matches its
# recorded SHA-256); golden-image-post-reboot.ps1 removes it once every check has passed.
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
