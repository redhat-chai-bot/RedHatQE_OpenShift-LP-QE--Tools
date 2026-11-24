<#
.SYNOPSIS
    Validate the RtlSetProcessIsCritical P/Invoke path WITHOUT crashing.

.DESCRIPTION
    When a BSOD trigger is a silent no-op you need to know whether the failure is in
    the API path (privilege / P/Invoke) or in the termination step. This calls the
    same ntdll routines trigger-bsod.ps1 uses, reports their NTSTATUS return codes,
    then immediately clears the critical flag so the process exits cleanly (NO crash).

    Expected healthy output when run as SYSTEM:
        whoami: nt authority\system
        RtlAdjustPrivilege rc=0x00000000 prevEnabled=True
        RtlSetProcessIsCritical(true)  rc=0x00000000 oldWasCritical=False
        RtlSetProcessIsCritical(false) rc=0x00000000 oldWasCritical=True

    Runs on: the GUEST VM.
#>
$ErrorActionPreference='Stop'
Write-Output ("whoami: " + (whoami))
try {
$sig = @'
using System;
using System.Runtime.InteropServices;
public static class Crit {
    [DllImport("ntdll.dll", SetLastError=true)]
    public static extern int RtlAdjustPrivilege(int Privilege, bool Enable, bool CurrentThread, out bool Enabled);
    [DllImport("ntdll.dll", SetLastError=true)]
    public static extern int RtlSetProcessIsCritical(bool bNew, out bool pbOld, bool bNeedScb);
}
'@
Add-Type -TypeDefinition $sig
Write-Output "Add-Type: OK"
$en=$false
$r1=[Crit]::RtlAdjustPrivilege(20,$true,$false,[ref]$en)
Write-Output ("RtlAdjustPrivilege rc=0x{0:X8} prevEnabled={1}" -f $r1,$en)
$old=$false
$r2=[Crit]::RtlSetProcessIsCritical($true,[ref]$old,$false)
Write-Output ("RtlSetProcessIsCritical(true) rc=0x{0:X8} oldWasCritical={1}" -f $r2,$old)
# Immediately clear it so we do NOT crash during diagnosis.
$old2=$false
$r3=[Crit]::RtlSetProcessIsCritical($false,[ref]$old2,$false)
Write-Output ("RtlSetProcessIsCritical(false) rc=0x{0:X8} oldWasCritical={1}" -f $r3,$old2)
Write-Output "DIAG DONE (process left NON-critical; no crash)"
} catch {
Write-Output ("EXCEPTION: " + $_.Exception.Message)
}
