<#
.SYNOPSIS
    Download Sysinternals NotMyFault into the guest (driver-based BSOD trigger).

.DESCRIPTION
    Fetches NotMyFault.zip from download.sysinternals.com and extracts it to
    C:\Temp\nmf. NotMyFault ships its own signed myfault.sys, so it can trigger a
    driver-attributed bugcheck WITHOUT the cluster's crashme.sys.

    The caller must provide an independently approved SHA-256 for the archive.
    Accept the EULA as a separate administrative step, then trigger a crash
    asynchronously with: C:\Temp\nmf\notmyfaultc64.exe /crash 0x01
    /crash types: 0x01 High IRQL (kernel) -> 0xD1 DRIVER_IRQL_NOT_LESS_OR_EQUAL,
    0x02 buffer overflow, 0x03 code overwrite, 0x04 stack trash, 0x06 stack overflow,
    0x07 hardcoded bp, 0x08 double free, 0x09 HAL timer watchdog.

    Runs on: the GUEST VM. Requires outbound internet.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [ValidatePattern('^[0-9a-fA-F]{64}$')]
  [string]$Sha256
)
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$dir='C:\Temp\nmf'
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$zip="$dir\NotMyFault.zip"
try {
  Invoke-WebRequest -Uri 'https://download.sysinternals.com/files/NotMyFault.zip' -OutFile $zip -UseBasicParsing -TimeoutSec 60
  $actual = (Get-FileHash -Algorithm SHA256 -Path $zip).Hash
  if ($actual -ne $Sha256.ToUpperInvariant()) { throw "NotMyFault SHA-256 mismatch: expected $Sha256, got $actual" }
  Write-Output ("downloaded {0} bytes" -f (Get-Item $zip).Length)
  Expand-Archive -Path $zip -DestinationPath $dir -Force
  $exe = Get-ChildItem "$dir\notmyfaultc64.exe" -ErrorAction SilentlyContinue
  Write-Output ("notmyfaultc64.exe present: {0}" -f [bool]$exe)
  Get-ChildItem $dir -Filter *.exe | ForEach-Object { Write-Output ("  " + $_.Name) }
} catch {
  Write-Error ("DOWNLOAD-FAILED: " + $_.Exception.Message)
  exit 1
}
