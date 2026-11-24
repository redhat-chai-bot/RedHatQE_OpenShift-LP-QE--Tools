#Requires -RunAsAdministrator

$result = @{
    ok              = $false
    testsigning     = $false
    serviceCreated  = $false
    driverStarted   = $false
    deviceAccessible = $false
}

$enumOutput = bcdedit /enum '{current}'
if ($LASTEXITCODE -ne 0) {
    $result | ConvertTo-Json -Compress
    exit 1
}
$testsigningAlready = $null -ne ($enumOutput | Select-String 'testsigning\s+Yes')
if (-not $testsigningAlready) {
    bcdedit /set testsigning on | Out-Null
    $result.testsigning = $true
    Write-Warning "Test-signing was just enabled. A REBOOT is required before the driver will load."
    $result | ConvertTo-Json -Compress
    exit 0
} else {
    $result.testsigning = $true
}

Copy-Item -Force ".\crashme.sys" "C:\Windows\System32\drivers\crashme.sys"
Copy-Item -Force ".\crashme-ctl.exe" "C:\Tools\crashme-ctl.exe"

$existingService = Get-Service -Name CrashMe -ErrorAction SilentlyContinue
if ($existingService) {
    sc.exe stop CrashMe 2>$null | Out-Null
    sc.exe delete CrashMe | Out-Null
    Start-Sleep -Seconds 1
}

$scCreate = sc.exe create CrashMe type= kernel binPath= "C:\Windows\System32\drivers\crashme.sys"
$result.serviceCreated = ($LASTEXITCODE -eq 0)

$scStart = sc.exe start CrashMe
$result.driverStarted = ($LASTEXITCODE -eq 0)

if ($result.driverStarted) {
    try {
        $h = [System.IO.File]::Open("\\.\CrashMe", [System.IO.FileMode]::Open,
              [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $h.Close()
        $result.deviceAccessible = $true
    } catch {
        $result.deviceAccessible = $false
    }
}

$result.ok = $result.serviceCreated -and $result.driverStarted -and $result.deviceAccessible
$result | ConvertTo-Json -Compress
