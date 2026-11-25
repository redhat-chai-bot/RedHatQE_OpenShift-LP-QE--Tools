# Idempotent golden-image OS configuration.
# Replaces golden-image-pre-reboot.ps1 and
# golden-image-post-reboot.ps1 with one script that
# checks each setting, changes only what deviates,
# and reports whether a reboot is still needed.
#
# Usage:
#   .\configure--OS.ps1          # pagefile + crash
#   .\configure--OS.ps1 -extra 1 # + VirtIO drivers
#   .\configure--OS.ps1 -extra 2 # + QEMU Guest Agent
#   .\configure--OS.ps1 -extra 3 # drivers + agent

param([int]$extra = 0x00)

$needReboot = $false
$success    = $true
$note       = ''

# ── helpers ──────────────────────────────────────

function Enable-TLS12 {
    $cur = [Net.ServicePointManager]::SecurityProtocol
    $tls = [Net.SecurityProtocolType]::Tls12
    if (($cur -band $tls) -ne $tls) {
        [Net.ServicePointManager]::SecurityProtocol =
            $cur -bor $tls
    }
}

function Get-PagefileSizeMB ([int64]$memoryBytes) {
    [int64][math]::Round(
        ($memoryBytes + 257MB) / 1MB, 0
    )
}

# Configure a fixed C:\pagefile.sys idempotently.
# Returns $true when a reboot is needed.
function Set-FixedPagefile ([int64]$sizeMB) {
    $changed = $false
    $comp = Get-CimInstance `
        -ClassName Win32_ComputerSystem `
        -ErrorAction Stop
    if ($comp.AutomaticManagedPagefile) {
        Set-CimInstance -InputObject $comp `
            -Property @{
                AutomaticManagedPagefile = $false
            } -ErrorAction Stop
        Write-Host `
            'OK: automatic pagefile management disabled'
        $changed = $true
    }
    $mmKey = 'HKLM:\SYSTEM\CurrentControlSet' +
        '\Control\Session Manager\Memory Management'
    $want = "C:\pagefile.sys ${sizeMB} ${sizeMB}"
    $have = (Get-ItemProperty -Path $mmKey `
        -Name PagingFiles `
        -ErrorAction SilentlyContinue).PagingFiles
    if ($have -is [array]) {
        $have = $have -join ';'
    }
    if ($have -ne $want) {
        Set-ItemProperty -Path $mmKey `
            -Name PagingFiles `
            -Type MultiString `
            -Value @($want) `
            -ErrorAction Stop
        Write-Host (
            "OK: PagingFiles set to '${want}'" +
            ' (RAM + 257 MB), active after reboot'
        )
        $changed = $true
    } else {
        Write-Host 'OK: pagefile already configured'
    }
    $changed
}

# ── HTTPS redirect resolver ─────────────────────
# Needed only when 0x01 or 0x02 bits are set.

function Save-HTTPSdownload (
    [string]$url, [string]$path
) {
    if ($url -notlike 'https://*') {
        throw "not an HTTPS URL: ${url}"
    }
    $request =
        [System.Net.HttpWebRequest]::Create($url)
    $request.AllowAutoRedirect = $false
    $response = $request.GetResponse()
    try {
        if ([int]$response.StatusCode -ne 200) {
            throw (
                'HTTP ' +
                "$([int]$response.StatusCode)" +
                " from ${url}"
            )
        }
        $file = [System.IO.File]::Create($path)
        try {
            $response.GetResponseStream().CopyTo(
                $file
            )
        } finally { $file.Close() }
    } finally { $response.Close() }
}

function Get-HTTPSredirectTarget (
    [string]$location, [string]$officialHost
) {
    if ($location -notlike `
        "http*://${officialHost}/*") {
        return
    }
    $location -replace '^http://', 'https://'
}

function Get-HTTPSresponseHead ([string]$url) {
    $request =
        [System.Net.HttpWebRequest]::Create($url)
    $request.Method = 'HEAD'
    $request.AllowAutoRedirect = $false
    try {
        $response = $request.GetResponse()
    } catch [System.Net.WebException] {
        if (-not $_.Exception.Response) { throw }
        $response = $_.Exception.Response
    }
    try {
        [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            Location   =
                $response.Headers['Location']
        }
    } finally { $response.Close() }
}

function Resolve-OfficialHTTPS (
    [string]$url, [string]$officialHost
) {
    if ($url -notlike `
        "https://${officialHost}/*") {
        throw (
            "not an HTTPS URL on" +
            " ${officialHost}: ${url}"
        )
    }
    foreach ($hop in 1..5) {
        $head = Get-HTTPSresponseHead $url
        if ($head.StatusCode -eq 200) {
            return $url
        }
        if ($head.StatusCode -lt 300 -or
            $head.StatusCode -ge 400) {
            throw (
                "HTTP $($head.StatusCode)" +
                " from ${url}"
            )
        }
        $next = Get-HTTPSredirectTarget `
            $head.Location $officialHost
        if (-not $next) {
            throw (
                "redirect from ${url} leaves" +
                " ${officialHost}:" +
                " $($head.Location)"
            )
        }
        $url = $next
    }
    throw "too many redirects from ${url}"
}

# Download an ISO by URL to ${env:TEMP}, mount it,
# and return the drive letter. Caller must call
# Dismount-ISO when finished.
function Mount-ISO ([string]$url) {
    Enable-TLS12
    $officialHost = 'fedorapeople.org'
    $resolved = Resolve-OfficialHTTPS `
        $url $officialHost
    $isoPath = Join-Path `
        ${env:TEMP} 'virtio-win.iso'
    Write-Host "Downloading ${resolved} ..."
    Save-HTTPSdownload $resolved $isoPath
    Write-Host 'OK: virtio-win ISO downloaded'
    $img = Mount-DiskImage `
        -ImagePath $isoPath `
        -PassThru -ErrorAction Stop
    $letter = (
        $img | Get-Volume -ErrorAction Stop
    ).DriveLetter
    if (-not $letter) {
        throw (
            "${isoPath} is mounted" +
            ' without a drive letter'
        )
    }
    Write-Host "OK: ISO mounted at ${letter}:\"
    $letter
}

# Dismount and delete the ISO from ${env:TEMP}.
function Dismount-ISO {
    $isoPath = Join-Path `
        ${env:TEMP} 'virtio-win.iso'
    if (-not (Test-Path `
        -LiteralPath $isoPath)) { return }
    $img = Get-DiskImage `
        -ImagePath $isoPath `
        -ErrorAction SilentlyContinue
    if ($img -and $img.Attached) {
        Dismount-DiskImage `
            -ImagePath $isoPath `
            -ErrorAction SilentlyContinue |
            Out-Null
    }
    Remove-Item `
        -LiteralPath $isoPath `
        -Force -ErrorAction SilentlyContinue
}

# ── main logic ───────────────────────────────────

try {

# -- read physical memory --------------------------
try {
    $ramBytes = (
        Get-CimInstance `
            -ClassName Win32_ComputerSystem `
            -ErrorAction Stop
    ).TotalPhysicalMemory -as [int64]
} catch {
    throw (
        'cannot read physical memory:' +
        " $($_.Exception.Message)"
    )
}
if (-not ($ramBytes -gt 0)) {
    throw (
        'physical memory size is missing or' +
        " not positive ('${ramBytes}')"
    )
}
$pagefileSizeMB = Get-PagefileSizeMB $ramBytes
Write-Host (
    'OK: physical memory read; pagefile will' +
    " be ${pagefileSizeMB} MB (RAM + 257 MB)"
)

# -- VirtIO drivers (bit 0x01) ---------------------
$wantDrivers = ($extra -band 0x01) -ne 0
$wantAgent   = ($extra -band 0x02) -ne 0
$isoNeeded   = $wantDrivers -or $wantAgent

if ($isoNeeded) {
    $isoURL = 'https://fedorapeople.org' +
        '/groups/virt/virtio-win' +
        '/direct-downloads/latest-virtio' +
        '/virtio-win.iso'
    $drive = $null
    try {
        $drive = Mount-ISO $isoURL

        if ($wantDrivers) {
            Write-Host (
                "`n--- Installing VirtIO" +
                ' storage drivers ---'
            )
            $drivers = @(
                @{
                    Name = 'viostor (VirtIO block)'
                    Inf  = 'viostor\w11\amd64' +
                           '\viostor.inf'
                }
                @{
                    Name = 'vioscsi (VirtIO SCSI)'
                    Inf  = 'vioscsi\w11\amd64' +
                           '\vioscsi.inf'
                }
            )
            foreach ($drv in $drivers) {
                $inf = Get-Item `
                    "${drive}:\$($drv.Inf)" `
                    -ErrorAction SilentlyContinue
                if (-not $inf) {
                    $filter = (
                        $drv.Inf -split '\\'
                    )[-1]
                    $inf = Get-ChildItem `
                        "${drive}:\" -Recurse `
                        -Filter $filter `
                        -ErrorAction `
                            SilentlyContinue |
                        Where-Object {
                            $_.FullName `
                                -like '*amd64*'
                        } |
                        Select-Object -First 1
                }
                if ($inf) {
                    pnputil /add-driver `
                        $inf.FullName /install |
                        Out-Null
                    if ($LASTEXITCODE -in `
                        0, 1641, 3010) {
                        Write-Host (
                            "OK: $($drv.Name)" +
                            ' installed from' +
                            " $($inf.FullName)"
                        )
                    } else {
                        Write-Host (
                            'WARN: pnputil' +
                            " exit ${LASTEXITCODE}" +
                            " for $($drv.Name)"
                        )
                    }
                } else {
                    Write-Host (
                        "WARN: $($drv.Name)" +
                        ' not found in ISO'
                    )
                }
            }
        }

        if ($wantAgent) {
            Write-Host (
                "`n--- Installing QEMU" +
                ' Guest Agent ---'
            )
            $msiPath = "${drive}:\guest-agent" +
                '\qemu-ga-x86_64.msi'
            $proc = Start-Process msiexec.exe `
                -ArgumentList (
                    "/i ${msiPath}" +
                    ' /quiet /norestart'
                ) `
                -Wait -PassThru
            if ($null -ne $proc.ExitCode -and
                $proc.ExitCode -in `
                    0, 1641, 3010) {
                Write-Host (
                    'OK: QEMU Guest Agent' +
                    ' MSI installed (exit' +
                    " $($proc.ExitCode))"
                )
            } else {
                Write-Host (
                    'WARN: QEMU Guest Agent' +
                    ' MSI exit code' +
                    " $($proc.ExitCode)"
                )
            }
        }
    } finally {
        Dismount-ISO
    }
}

# -- QEMU Guest Agent check (when 0x02) -----------
if ($wantAgent) {
    Write-Host "`n--- Verifying QEMU Guest Agent ---"
    $svc = Get-Service QEMU-GA `
        -ErrorAction SilentlyContinue
    if (-not $svc) {
        throw 'QEMU-GA service not installed'
    }
    Set-Service QEMU-GA -StartupType Automatic
    if ($svc.Status -ne 'Running') {
        Start-Service QEMU-GA `
            -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        $svc = Get-Service QEMU-GA `
            -ErrorAction SilentlyContinue
    }
    if (-not $svc -or
        $svc.Status -ne 'Running') {
        throw (
            'QEMU-GA could not be started' +
            ' (Status:' +
            " $(if ($svc) {
                $svc.Status
            } else { 'missing' }))"
        )
    }
    Write-Host (
        'OK: QEMU-GA is Running and' +
        ' set to Automatic'
    )
}

# -- crash dump registry --------------------------
Write-Host "`n--- Configuring crash dump registry ---"
$cc = 'HKLM:\SYSTEM\CurrentControlSet' +
    '\Control\CrashControl'
$crashSettings = @{
    CrashDumpEnabled     = @(7, 'DWord')
    AutoReboot           = @(0, 'DWord')
    AlwaysKeepMemoryDump = @(1, 'DWord')
    Overwrite            = @(1, 'DWord')
    LogEvent             = @(1, 'DWord')
    DumpFile             = @(
        '%SystemRoot%\MEMORY.DMP',
        'ExpandString'
    )
}
$crashChanged = $false
foreach ($name in $crashSettings.Keys) {
    $want = $crashSettings[$name][0]
    $type = $crashSettings[$name][1]
    $have = (Get-ItemProperty -Path $cc `
        -Name $name `
        -ErrorAction SilentlyContinue).$name
    $match = if ($type -eq 'ExpandString') {
        $ec = [Environment]
        $ex = $ec::ExpandEnvironmentVariables(
            $want
        )
        "$have" -eq "$ex" -or
            "$have" -eq "$want"
    } else {
        $have -eq $want
    }
    if (-not $match) {
        Set-ItemProperty -Path $cc `
            -Name $name `
            -Value $want `
            -Type $type `
            -ErrorAction Stop
        Write-Host "OK: ${name} set to ${want}"
        $crashChanged = $true
    } else {
        Write-Host "OK: ${name} = ${want}"
    }
}
# Remove DedicatedDumpFile registry value
$hasDedicated = Get-ItemProperty `
    -Path $cc `
    -Name DedicatedDumpFile `
    -ErrorAction SilentlyContinue
if ($hasDedicated) {
    Remove-ItemProperty -Path $cc `
        -Name DedicatedDumpFile `
        -ErrorAction Stop
    Write-Host 'OK: removed DedicatedDumpFile key'
    $crashChanged = $true
}
if ($crashChanged) {
    $needReboot = $true
    Write-Host (
        'OK: crash dump registry updated' +
        ' (reboot needed)'
    )
} else {
    Write-Host 'OK: crash dump registry correct'
}

# -- remove legacy DedicatedDump.sys ---------------
$legacyDumpPath = 'C:\DedicatedDump.sys'
if (Test-Path -LiteralPath $legacyDumpPath) {
    $item = Get-Item `
        -LiteralPath $legacyDumpPath `
        -Force -ErrorAction SilentlyContinue
    if ($item -and
        -not $item.PSIsContainer -and
        "$($item.Attributes)" `
            -notlike '*ReparsePoint*') {
        try {
            Remove-Item `
                -LiteralPath $legacyDumpPath `
                -Force -ErrorAction Stop
            Write-Host (
                "OK: removed ${legacyDumpPath}"
            )
        } catch {
            Write-Host (
                "WARN: ${legacyDumpPath}" +
                ' could not be removed' +
                ' (may be locked until reboot)'
            )
            $needReboot = $true
        }
    }
}

# -- pagefile --------------------------------------
Write-Host "`n--- Configuring pagefile.sys ---"
try {
    $pfChanged = Set-FixedPagefile $pagefileSizeMB
    if ($pfChanged) { $needReboot = $true }
} catch {
    throw (
        'pagefile configuration failed:' +
        " $($_.Exception.Message)"
    )
}

# -- check active pagefile after reboot ------------
if (-not $needReboot) {
    $activePf = Get-CimInstance `
        Win32_PageFileUsage `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'C:\*' }
    if ($activePf -and
        $activePf.AllocatedBaseSize -gt 0) {
        Write-Host (
            'OK: pagefile.sys active' +
            " ($($activePf.AllocatedBaseSize) MB)"
        )
    } else {
        Write-Host (
            'WARN: pagefile.sys not active;' +
            ' reboot needed'
        )
        $needReboot = $true
    }
}

# -- build note ------------------------------------
if ($needReboot) {
    $note = 'Reboot and re-run to verify'
} else {
    $note = 'All settings verified; ready to seal'
}

} catch {
    $success = $false
    $note    = $_.Exception.Message
    Write-Error "FAIL: ${note}"
} finally {
    $result = @{
        success    = $success
        needReboot = $needReboot
        note       = $note
    } | ConvertTo-Json -Compress
    Write-Host $result
}

if (-not $success) { exit 1 }
