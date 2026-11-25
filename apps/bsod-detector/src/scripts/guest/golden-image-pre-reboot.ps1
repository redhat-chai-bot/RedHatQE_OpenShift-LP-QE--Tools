# Golden-image setup, part 1 of 2. Run as Administrator BEFORE sealing; reboots at the end.
# Afterwards run golden-image-post-reboot.ps1 and seal only if it passes.
# Both VirtIO storage drivers are staged so the image boots on a virtio (viostor),
# scsi (vioscsi) or sata (storahci, inbox) disk bus.
# The page file is sized from this VM's RAM (RAM + 257 MB) and keeps that fixed size in VMs cloned
# from this image, so those VMs must not have more RAM than this VM: a page file smaller than a VM's
# RAM + 257 MB may be too small for its crash dump.

# Undefined variables, missing properties and unhandled errors stop the script. FAIL lines are
# written with -ErrorAction Continue so that every diagnostic is shown before the explicit exit 1.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Fixed pagefile size in MB: physical RAM plus 257 MB, rounded once to a whole MB.
# golden-image-post-reboot.ps1 checks the active pagefile against the same calculation.
function Get-PagefileSizeMB ([int64]$memoryBytes) {
    [int64][math]::Round(($memoryBytes + 257MB) / 1MB, 0)
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
# status other than 200 throws instead of being followed, so the download cannot leave HTTPS. The
# file, the response stream and the response are always disposed; a failure while disposing is
# raised only when nothing failed before it, so it never hides a download or copy failure.
function Save-HTTPSdownload ([string]$url, [string]$path) {
    if ($url -notlike 'https://*') { throw "not an HTTPS URL: ${url}" }
    $request = [System.Net.HttpWebRequest]::Create($url)
    $request.AllowAutoRedirect = $false
    $requestError = $null
    try {
        $response = $request.GetResponse()
    } catch [System.Net.WebException] {
        $requestError = $_
    }
    if ($requestError) {
        # An error status arrives as an exception that carries the response. The response is released first;
        # a failure to release it is ignored, so the request error itself is what is reported.
        $webException = $requestError.Exception
        while ($webException -and $webException -isnot [System.Net.WebException]) { $webException = $webException.InnerException }
        if ($webException -and $webException.Response) {
            try { ([System.IDisposable]$webException.Response).Dispose() } catch { }
        }
        throw $requestError
    }
    $stream = $null
    $file = $null
    $hasFailed = $false
    try {
        if ([int]$response.StatusCode -ne 200) { throw "HTTP $([int]$response.StatusCode) from ${url}" }
        $stream = $response.GetResponseStream()
        $file = [System.IO.File]::Create($path)
        $stream.CopyTo($file)
    } catch {
        $hasFailed = $true
        throw
    } finally {
        $disposeError = $null
        foreach ($resource in @($file, $stream, $response)) {
            if ($null -ne $resource) {
                try { ([System.IDisposable]$resource).Dispose() } catch { if ($null -eq $disposeError) { $disposeError = $_ } }
            }
        }
        if (-not $hasFailed -and $null -ne $disposeError) { throw $disposeError }
    }
}

# Turns an HTTP(S) redirect location into the HTTPS URL on the same official host, or nothing when
# it points elsewhere. Official download aliases may redirect to plain http://, which is never
# requested: the location is parsed as a URI and only its path and query are reused over HTTPS.
# A relative location, another scheme or host, user information, a non-default port or a fragment
# is refused.
function Get-HTTPSredirectTarget ([string]$location, [string]$officialHost) {
    $uri = $location -as [uri]
    if (-not $uri -or -not $uri.IsAbsoluteUri -or $uri.Scheme -notin 'http', 'https' -or $uri.Host -ne $officialHost -or
        $uri.UserInfo -or -not $uri.IsDefaultPort -or $uri.Fragment) { return }
    "https://${officialHost}$($uri.PathAndQuery)"
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

# The administrator's TEMP directory, where this run creates its own directory for the ISO.
function Get-TempDirectory {
    $env:TEMP
}

# Unmounts the ISO this run downloaded and removes it and the directory this run created for it.
# Only that file and that directory are removed: a directory that still holds anything else is
# reported and left in place. Returns a message when something is left, or nothing when all is gone.
function Remove-ISOworkspace ([string]$dirPath, [string]$isoPath) {
    try {
        if ($isoPath -and (Test-Path -LiteralPath $isoPath)) {
            $image = Get-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue
            if ($image -and $image.Attached) { Dismount-DiskImage -ImagePath $isoPath -ErrorAction Stop | Out-Null }
            Remove-Item -LiteralPath $isoPath -Force -ErrorAction Stop
        }
        if (Get-ChildItem -LiteralPath $dirPath -Force -ErrorAction Stop) { return "${dirPath} is not empty and was left in place" }
        Remove-Item -LiteralPath $dirPath -Force -ErrorAction Stop
    } catch {
        return "cannot unmount and remove the virtio-win ISO in ${dirPath}: $($_.Exception.Message)"
    }
    if (Test-Path -LiteralPath $dirPath) { return "${dirPath} still exists after its removal" }
}

# Removes the exact dedicated dump file an older preparation created, only when CrashControl names
# no dedicated dump file and the path is a plain file (not a directory, link or other reparse
# point). Returns 'absent', 'removed', or why the file is still there.
function Remove-LegacyDedicatedDump ([string]$path, [string]$configuredTarget) {
    if (-not (Test-Path -LiteralPath $path)) { return 'absent' }
    if ($configuredTarget) { return "CrashControl still names DedicatedDumpFile '${configuredTarget}'" }
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.PSIsContainer -or "$($item.Attributes)" -like '*ReparsePoint*') { return 'it is not a plain file' }
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $path) { return 'it could not be removed (it may stay locked until the next reboot)' }
    'removed'
}

# The memory size is read before any change: an unreadable, missing or non-positive size stops the
# script before the ISO download, installations, registry writes, page file change or reboot.
try {
    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
} catch {
    Write-Error "FAIL: cannot read the physical memory size: $($_.Exception.Message)" -ErrorAction Continue
    exit 1
}
$ramBytes = if ($computerSystem) { $computerSystem.TotalPhysicalMemory -as [int64] } else { $null }
if (-not ($ramBytes -gt 0)) {
    Write-Error "FAIL: physical memory size is missing or not positive (TotalPhysicalMemory = '${ramBytes}')" -ErrorAction Continue
    exit 1
}
$pagefileSizeMB = Get-PagefileSizeMB $ramBytes
Write-Host "OK: physical memory read; the page file will be ${pagefileSizeMB} MB (RAM + 257 MB)"

Enable-TLS12
# virtio-win: the current official release behind the latest-virtio alias, with no hardcoded
# version or digest. The alias is resolved hop by hop over HTTPS on fedorapeople.org (it
# redirects to plain http://, which is never requested). No checksum or signature is published
# for the ISO. It is downloaded into a new directory this run creates under the administrator's
# TEMP directory and removed again before the reboot, so nothing of it is left for
# golden-image-post-reboot.ps1 or the sealed image.
$isoAliasURL = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso'
try {
    $isoURL = Resolve-OfficialHTTPS $isoAliasURL 'fedorapeople.org'
} catch {
    Write-Error "FAIL: cannot resolve the latest virtio-win ISO over HTTPS: $($_.Exception.Message)" -ErrorAction Continue
    exit 1
}
$isoVersion = if ($isoURL -match '/virtio-win-([0-9][0-9.]*)\.iso$') { $Matches[1] } else { $null }
Write-Host "Latest virtio-win ISO: ${isoURL} (version $(if ($isoVersion) { $isoVersion } else { 'not in the file name' }))"

# The ISO directory is new and belongs to this run: its name is unique, and New-Item without -Force
# refuses a path that already exists. A TEMP that is unset or not an existing directory, or a
# failed creation, stops the script here, before the download, with nothing created or removed.
$isoFailure = $null
$isoCleanupProblem = $null
try {
    $tempDir = Get-TempDirectory
    if (-not $tempDir -or -not (Test-Path -LiteralPath $tempDir -PathType Container)) { throw "TEMP ('${tempDir}') is not an existing directory" }
    $isoDir = Join-Path $tempDir "bsod-virtio-win-$((New-Guid).Guid)"
    $isoPath = Join-Path $isoDir 'virtio-win.iso'
    New-Item -ItemType Directory -Path $isoDir -ErrorAction Stop | Out-Null
} catch {
    Write-Error "FAIL: $($_.Exception.Message)" -ErrorAction Continue
    exit 1
}

# Every step that needs the ISO runs inside this try block, which starts right after this run
# created its directory. The finally block always unmounts the ISO and removes that directory (and
# nothing that existed before); a failure in the steps or in that cleanup stops the script here,
# before any registry write or reboot.
try {
    Write-Host "Downloading ${isoURL} to ${isoPath} ..."
    try { Save-HTTPSdownload $isoURL $isoPath } catch { throw "the latest virtio-win ISO could not be downloaded: $($_.Exception.Message)" }
    Write-Host 'OK: virtio-win ISO downloaded'
    try {
        $iso = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
        $volume = $iso | Get-Volume -ErrorAction Stop
        $drive = if ($volume) { $volume.DriveLetter } else { $null }
    } catch {
        throw "cannot mount ${isoPath}: $($_.Exception.Message)"
    }
    if (-not $drive) { throw "${isoPath} is mounted without a drive letter" }
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
            # pnputil reports through its exit code. Windows PowerShell 5.1 hosts that capture native stderr
            # (ISE, remoting) turn its stderr lines into errors, so it runs with the Continue preference.
            & { $ErrorActionPreference = 'Continue'; pnputil /add-driver $inf.FullName /install | Out-Null }
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
} catch {
    # An error without a message still counts as a failure.
    $isoFailure = if ($_.Exception.Message) { $_.Exception.Message } else { $_.Exception.GetType().FullName }
} finally {
    $isoCleanupProblem = Remove-ISOworkspace $isoDir $isoPath
}
if ($isoFailure) { Write-Error "FAIL: ${isoFailure}" -ErrorAction Continue }
if ($isoCleanupProblem) { Write-Error "FAIL: ${isoCleanupProblem}" -ErrorAction Continue }
if ($isoFailure -or $isoCleanupProblem) {
    exit 1
}
Write-Host "OK: ISO unmounted and ${isoDir} removed"

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

Write-Host "`n--- Verifying QEMU Guest Agent ---"
$svc = Get-Service QEMU-GA -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Error 'FAIL: QEMU-GA service not installed - abort' -ErrorAction Continue
    exit 1
}
# A startup type that cannot be set stops the script here, before the registry writes and the reboot.
try {
    Set-Service QEMU-GA -StartupType Automatic -ErrorAction Stop
} catch {
    Write-Error "FAIL: cannot set QEMU-GA to start automatically: $($_.Exception.Message) - abort" -ErrorAction Continue
    exit 1
}
if ($svc.Status -ne 'Running') {
    Write-Host 'QEMU-GA is stopped - starting...'
    Start-Service QEMU-GA -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    $svc = Get-Service QEMU-GA -ErrorAction SilentlyContinue
}
if (-not $svc -or $svc.Status -ne 'Running') {
    Write-Error "FAIL: QEMU-GA could not be started (Status: $(if ($svc) { $svc.Status } else { 'not installed' })) - abort" -ErrorAction Continue
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
    # The whole key is read so that an absent value and a key that cannot be read are told apart.
    if ((Get-ItemProperty -Path $cc -ErrorAction Stop).PSObject.Properties['DedicatedDumpFile']) {
        Remove-ItemProperty -Path $cc -Name DedicatedDumpFile -ErrorAction Stop
    }
} catch {
    Write-Error "FAIL: crash dump registry write failed: $($_.Exception.Message)" -ErrorAction Continue
    exit 1
}
Write-Host 'OK: Crash dump registry set (CrashDumpEnabled=7, no DedicatedDumpFile)'
# The dedicated dump file older preparations created at this fixed path is no longer used once
# DedicatedDumpFile is unset. Only that exact file is removed (see Remove-LegacyDedicatedDump);
# Windows can keep it locked until the reboot, and golden-image-post-reboot.ps1 then removes it or
# refuses to seal. If CrashControl cannot be read, the file is left in place: it might still be the
# configured dump file.
$legacyDumpPath = 'C:\DedicatedDump.sys'
$dumpValue = $null
try {
    $dumpValue = (Get-ItemProperty -Path $cc -ErrorAction Stop).PSObject.Properties['DedicatedDumpFile']
    $canReadCrashControl = $true
} catch {
    $canReadCrashControl = $false
}
$legacyDumpResult = if ($canReadCrashControl) {
    Remove-LegacyDedicatedDump $legacyDumpPath $(if ($dumpValue) { $dumpValue.Value } else { $null })
} else {
    'CrashControl could not be read to confirm that no dedicated dump file is configured'
}
if ($legacyDumpResult -eq 'removed') {
    Write-Host "OK: removed ${legacyDumpPath} from an older preparation"
} elseif ($legacyDumpResult -ne 'absent') {
    Write-Host "WARN: ${legacyDumpPath} from an older preparation was not removed: ${legacyDumpResult} - golden-image-post-reboot.ps1 checks it after the reboot"
}

# Fixed-size C:\pagefile.sys of RAM + 257 MB (computed above) with automatic management off,
# active after the reboot; golden-image-post-reboot.ps1 checks this size.
Write-Host "`n--- Configuring pagefile.sys ---"
try {
    Set-FixedPagefile $pagefileSizeMB
} catch {
    Write-Error "FAIL: pagefile configuration failed: $($_.Exception.Message)" -ErrorAction Continue
    exit 1
}

Write-Host "`n=== All steps complete. Rebooting now... ==="
Restart-Computer -Force
