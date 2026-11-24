<#
.SYNOPSIS
    Driver-free BSOD trigger: bugcheck 0x000000EF CRITICAL_PROCESS_DIED.

.DESCRIPTION
    Marks THIS process critical via ntdll RtlSetProcessIsCritical (after enabling
    SeDebugPrivilege with RtlAdjustPrivilege), then hard-terminates itself with
    kernel32 TerminateProcess on the current-process pseudo-handle (-1). Any
    termination of a process flagged critical makes the kernel bugcheck with
    CRITICAL_PROCESS_DIED (0xEF) -- no third-party driver required.

    Runs on: the GUEST VM. Requires elevation (guest-agent guest-exec runs as
    SYSTEM, which satisfies this). The process that goes critical is the one that
    dies, so it MUST run synchronously -- fire it via guest-agent.py with wait=False
    (the guest crashes mid-call) or over a synchronous SSH session.

    Cluster gotcha: the .NET Process.GetCurrentProcess().Kill() variant that worked
    locally did NOT reliably produce a catchable blue screen through guest-exec;
    the kernel32 TerminateProcess((IntPtr)-1) path used here is the reliable one.

.NOTES
    Verify the P/Invoke path first with diag-critical-api.ps1 if a trigger is a no-op.
#>
$sig = @'
using System;
using System.Runtime.InteropServices;
public static class Crit {
    [DllImport("ntdll.dll", SetLastError=true)]
    public static extern int RtlAdjustPrivilege(int Privilege, bool Enable, bool CurrentThread, out bool Enabled);
    [DllImport("ntdll.dll", SetLastError=true)]
    public static extern int RtlSetProcessIsCritical(bool bNew, out bool pbOld, bool bNeedScb);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);
}
'@
Add-Type -TypeDefinition $sig
$en=$false; $old=$false
# 20 = SeDebugPrivilege
[Crit]::RtlAdjustPrivilege(20,$true,$false,[ref]$en) | Out-Null
[Crit]::RtlSetProcessIsCritical($true,[ref]$old,$false) | Out-Null
# -1 = GetCurrentProcess() pseudo-handle; terminating a critical process bugchecks the box.
[Crit]::TerminateProcess([IntPtr](-1), 1) | Out-Null
