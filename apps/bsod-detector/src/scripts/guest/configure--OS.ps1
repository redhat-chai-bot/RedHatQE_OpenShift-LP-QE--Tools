# Setting Windows PageFile and BSOD Crash Policy.
#
# Usage:
#   .\configure--OS.ps1 -task TASK
#   TASK    Extra task (bit map):
#       0x01:   Install VirtIO Storage Drivers.
#       0x02:   Install QEMU Guest Agent.

param([int]$task = 0x00)

$success     =  $true
$needReboot  =  $false
$note        =  ''

### Helper Functions

function Enable-TLS12 {
    $tls = [Net.SecurityProtocolType]::Tls12
    $cur = [Net.ServicePointManager]::SecurityProtocol
    if (($cur -band $tls) -ne $tls) {
        [Net.ServicePointManager]::SecurityProtocol = $cur -bor $tls
    }
}

function Get-PageFileSizeMB ([int64]$memoryBytes) {
    [int64][math]::Round((($memoryBytes + 257MB) / 1MB), 0)
}

# Configure a fixed `${env:SystemDrive}\pagefile.sys`.
# Returns `$true` when a reboot is needed.
function Set-FixedPagefile ([int64]$sizeMB) {
    $changed = $false
    $comp = Get-CimInstance `
        -ClassName Win32_ComputerSystem `
        -ErrorAction Stop
    if ($comp.AutomaticManagedPagefile) {
        Set-CimInstance `
            -InputObject $comp `
            -Property @{AutomaticManagedPagefile = $false} `
            -ErrorAction Stop
        Write-Host 'OK: Automatic PageFile management disabled.'
        $changed = $true
    }
    $mmKey = (
        'HKLM:\SYSTEM\CurrentControlSet' +
        '\Control\Session Manager\Memory Management'
    )
    $want = "${env:SystemDrive}\pagefile.sys ${sizeMB} ${sizeMB}"
    $have = (
        Get-ItemProperty `
            -Path $mmKey `
            -Name PagingFiles `
            -ErrorAction SilentlyContinue
    ).PagingFiles
    if ($have -is [array]) {$have = $have -join ';'}
    if ($have -ne $want) {
        Set-ItemProperty `
            -Path $mmKey `
            -Name PagingFiles `
            -Type MultiString `
            -Value @($want) `
            -ErrorAction Stop
        Write-Host (
            "OK: PagingFile is set to '${want}' (RAM + 257 MiB), " +
            'active after reboot.'
        )
        $changed = $true
    } else {
        Write-Host (
            "OK: PagingFile is already set to '${want}' (RAM + 257 MiB)."
        )
    }
    $changed
}

function Save-HTTPSdl ([string]$url, [string]$path) {
    if ($url -notlike 'https://*') {throw "not an HTTPS URL: ${url}"}
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.AllowAutoRedirect = $false
    $rsp = $req.GetResponse()
    try {
        if ([int]$rsp.StatusCode -ne 200) {
            throw ("HTTP $([int]$rsp.StatusCode) from ``${url}``.")
        }
        $file = [System.IO.File]::Create($path)
        try {
            $rsp.GetResponseStream().CopyTo($file)
        } finally {$file.Close()}
    } finally {$rsp.Close()}
}

function Get-HTTPSrspHead ([string]$url) {
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Method = 'HEAD'
    $req.AllowAutoRedirect = $false
    try {
        $rsp = $req.GetResponse()
    } catch [System.Net.WebException] {
        if (-not $_.Exception.Response) {throw}
        $rsp = $_.Exception.Response
    }
    try {
        [pscustomobject]@{
            StatusCode   =  [int]$rsp.StatusCode
            Location     =  $rsp.Headers['Location']
        }
    } finally {$rsp.Close()}
}

function Resolve-HSTS ([string]$url) {
    foreach ($hop in 1..5) {
        $url = $url -replace '^http://', 'https://'
        $head = Get-HTTPSrspHead $url
        if ($head.StatusCode -eq 200) {return $url}
        if (($head.StatusCode -lt 300) -or ($head.StatusCode -ge 400)) {
            throw "HTTP $($head.StatusCode) from ``${url}``."
        }
        $url = $head.Location
        if (-not $url) {throw 'Redirect with no Location header.'}
    }
    throw "Too many redirects from ``${url}``."
}

# Download an ISO by URL to ${env:TEMP}, mount it.
# Return the Drive Letter of the mounted ISO.
function Mount-ISO ([string]$url) {
    Enable-TLS12
    $resolved = Resolve-HSTS $url
    $isoPath = (
        Join-Path `
            -Path ${env:TEMP} `
            -ChildPath 'virtio-win.iso'
    )
    Write-Host "Downloading ``${resolved}`` ..."
    Save-HTTPSdl $resolved $isoPath
    Write-Host 'OK: The ``virtio-win`` ISO is downloaded.'
    $img = (
        Mount-DiskImage `
            -ImagePath $isoPath `
            -PassThru `
            -ErrorAction Stop
    )
    $letter = ($img | Get-Volume -ErrorAction Stop).DriveLetter
    if (-not $letter) {
        throw ("The ``${isoPath}`` is mounted without a Drive Letter.")
    }
    Write-Host "OK: ISO mounted at ${letter}:\"
    $letter
}

# Dismount and delete the ISO from ${env:TEMP}.
function Dismount-ISO {
    $isoPath = (
        Join-Path `
        -Path ${env:TEMP} `
        -ChildPath 'virtio-win.iso'
    )
    if (-not (Test-Path -LiteralPath $isoPath)) {return}
    $img = (
        Get-DiskImage `
            -ImagePath $isoPath `
            -ErrorAction SilentlyContinue
    )
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

### Main Logic

try {
    # Read Physical Memory.
    try {
        $ramBytes = (
            Get-CimInstance `
                -ClassName Win32_ComputerSystem `
                -ErrorAction Stop
        ).TotalPhysicalMemory -as [int64]
    } catch {
        throw ("Cannot read physical memory: $($_.Exception.Message)")
    }
    if (-not ($ramBytes -gt 0)) {
        throw (
            "Physical memory size is missing or not positive ('${ramBytes}')."
        )
    }
    $pfSzMB = Get-PageFileSizeMB $ramBytes
    Write-Host (
        'OK: Physical memory read and PageFile will be ' +
        "${pfSzMB} MiB (RAM + 257)."
    )

    # Get Extra Tasks.
    $wantDrivers =  ($task -band 0x01) -ne 0
    $wantAgent   =  ($task -band 0x02) -ne 0
    $isoNeeded   =  $wantDrivers -or $wantAgent

    # Setting Windows PageFile and BSOD Crash Policy.
    Write-Host "`n--- Configuring Crash Dump Registry ---"
    $cc = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
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
        $have = (
            Get-ItemProperty -Path $cc `
                -Name $name `
                -ErrorAction SilentlyContinue
        ).$name
        $match = if ($type -eq 'ExpandString') {
            ($have -eq $want) -or
                ($have -eq [Environment]::ExpandEnvironmentVariables($want))
        } else {
            $have -eq $want
        }
        if ($match) {
            Write-Host "OK: ${name} == ${want}"
        } else {
            Set-ItemProperty -Path $cc `
                -Name $name `
                -Value $want `
                -Type $type `
                -ErrorAction Stop
            Write-Host "OK: ${name} := ${want}"
            $crashChanged = $true
        }
    }

    # Remove `DedicatedDumpFile` and its `.sys` artifact.
    $dumpFile = 'C:\DedicatedDump.sys'
    if (Test-Path -LiteralPath $dumpFile) {
        try {
            Remove-Item `
                -LiteralPath $dumpFile `
                -Force `
                -ErrorAction Stop
            Write-Host ("OK: Removed ``${dumpFile}``.")
        } catch {
            Write-Host (
                "WARN: The ``${dumpFile}`` could not be removed " +
                '(may be locked until reboot).'
            )
            $needReboot = $true
        }
    }
    if (
        Get-ItemProperty `
            -Path $cc `
            -Name DedicatedDumpFile `
            -ErrorAction SilentlyContinue
    ) {
        Remove-ItemProperty `
            -Path $cc `
            -Name DedicatedDumpFile `
            -ErrorAction Stop
        Write-Host 'OK: Removed `DedicatedDumpFile` Registry Key.'
        $crashChanged = $true
    }
    if ($crashChanged) { $needReboot = $true }

    # PageFile.
    Write-Host "`n--- Configuring ``pagefile.sys`` ---"
    try {
        if (Set-FixedPagefile $pfSzMB) {$needReboot = $true}
    } catch {
        throw "PageFile configuration failed: $($_.Exception.Message)"
    }

    # Check active PageFile.
    if (-not $needReboot) {
        $actPF = (
            Get-CimInstance `
                -ClassName Win32_PageFileUsage `
                -ErrorAction SilentlyContinue |
            Where-Object -FilterScript {$_.Name -like "${env:SystemDrive}\*"}
        )
        if (
            $actPF -and
            ($actPF.AllocatedBaseSize -gt 0)
        ) {
            Write-Host (
                'OK: The ``pagefile.sys`` is active ' +
                "($($actPF.AllocatedBaseSize) MiB)."
            )
        } else {
            Write-Host (
                'WARN: pagefile.sys not active;' +
                ' reboot needed'
            )
            $needReboot = $true
        }
    }

    if ($isoNeeded) {
        $isoURL = (
            'https://fedorapeople.org/groups/virt/virtio-win/' +
            'direct-downloads/latest-virtio/virtio-win.iso'
        )
        $isoDrv = $null
        try {
            $isoDrv = Mount-ISO $isoURL

            if ($wantDrivers) {
                Write-Host "`n--- Installing VirtIO Storage Drivers ---"
                $drivers = @(
                    @{
                        Name = 'viostor (VirtIO block)'
                        Inf  = 'viostor\w11\amd64\viostor.inf'
                    },
                    @{
                        Name = 'vioscsi (VirtIO SCSI)'
                        Inf  = 'vioscsi\w11\amd64\vioscsi.inf'
                    }
                )
                foreach ($drv in $drivers) {
                    $inf = (
                        Get-Item `
                            -Path "${isoDrv}:\$($drv.Inf)" `
                            -ErrorAction SilentlyContinue
                    )
                    if (-not $inf) {
                        $inf = Get-ChildItem `
                            "${isoDrv}:\" -Recurse `
                            -Filter ($drv.Inf -split '\\')[-1] `
                            -ErrorAction `
                                SilentlyContinue |
                            Where-Object {
                                $_.FullName `
                                    -like '*amd64*'
                            } |
                            Select-Object -First 1
                    }
                    if ($inf) {
                        pnputil /add-driver $inf.FullName /install |
                        Out-Null
                        if ($LASTEXITCODE -in @(0, 1641, 3010)) {
                            Write-Host (
                                "OK: The ``$($drv.Name)`` is installed from " +
                                "$($inf.FullName)"
                            )
                        } else {
                            Write-Host (
                                'WARN: The ``pnputil`` exit status is ' +
                                "${LASTEXITCODE} for ``$($drv.Name)``."
                            )
                        }
                    } else {
                        Write-Host (
                            "WARN: The ``$($drv.Name)`` is not found in ISO."
                        )
                    }
                }
            }

            if ($wantAgent) {
                Write-Host "`n--- Installing QEMU Guest Agent ---"
                $msiPath = "${isoDrv}:\guest-agent\qemu-ga-x86_64.msi"
                $proc = (
                    Start-Process msiexec.exe `
                        -ArgumentList @(
                            "/i `"${msiPath}`" /quiet /norestart"
                        ) `
                        -Wait -PassThru
                )
                if (
                    ($proc.ExitCode -ne $null) -and
                    ($proc.ExitCode -in @(0, 1641, 3010))
                ) {
                    Write-Host (
                        'OK: QEMU Guest Agent MSI installed (exit status ' +
                        "$($proc.ExitCode))"
                    )
                } else {
                    Write-Host (
                        'WARN: QEMU Guest Agent MSI exit status: ' +
                        "$($proc.ExitCode)"
                    )
                }
            }
        } finally {
            Dismount-ISO
        }
    }

    # QEMU Guest Agent check.
    if ($wantAgent) {
        Write-Host "`n--- Verifying QEMU Guest Agent ---"
        $svc = Get-Service -Name 'QEMU-GA' -ErrorAction SilentlyContinue
        if (-not $svc) {throw 'The `QEMU-GA` service not installed'}
        Set-Service -Name QEMU-GA -StartupType Automatic
        if ($svc.Status -ne 'Running') {
            Start-Service -Name 'QEMU-GA' -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            $svc.Refresh()
        }
        if ($svc.Status -eq 'Running') {
            Write-Host 'OK: Service `QEMU-GA` is Running and set to Automatic.'
        } else {Write-Host (
            "WARN: Service ``QEMU-GA`` status is ``$($svc.Status)`` after " +
            'start attempt.'
        )}
    }

    if ($needReboot) {
        $note = 'Reboot and re-run to verify.'
    } else {
        $note = 'All settings verified.'
    }
} catch {
    $success     =  $false
    $note        =  $_.Exception.Message
    Write-Error "FAIL: ${note}"
} finally {
    Write-Host (@{
        success      =  $success
        needReboot   =  $needReboot
        note         =  $note
    } | ConvertTo-Json -Compress)
}

if (-not $success) {exit 1}
