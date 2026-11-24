# Development Notes

Key decisions, trade-offs, and lessons learned during development of the
bsod-detector tool. Written for anyone asking "why did you do it this way?"

## Why a custom kernel driver instead of NotMyFault?

Microsoft's NotMyFault (from Sysinternals) is the standard tool for triggering
BSODs on demand. We started with it and switched to a custom KeBugCheckEx driver
for three reasons:

1. **NotMyFault's 32-bit binary silently fails on 64-bit Windows.** The download
   includes `notmyfault.exe` (32-bit) and `notmyfaultc64.exe` (64-bit console).
   The 32-bit version prints usage text on a 64-bit OS without any error. This
   cost debugging time before we identified the issue.

2. **`/accepteula` and `/crash` cannot be combined.** NotMyFault's EULA prompt
   blocks execution on first run. Adding `/accepteula` should suppress it, but
   combining `/accepteula /crash N` in a single invocation fails silently
   (the crash type argument is misinterpreted). You must accept the EULA in a
   separate invocation first.

3. **Remote UAC blocks `-Verb RunAs`.** NotMyFault requires elevation. Over SSH,
   `Start-Process notmyfaultc64.exe -Verb RunAs` pops a UAC dialog on the remote
   desktop that never completes in an unattended session. Running directly as
   Administrator over SSH avoids this, but NotMyFault still needs the two-step
   EULA workaround.

The custom `crashme.sys` driver calls `KeBugCheckEx` directly with caller-specified
parameters. No EULA, no UAC prompt, no 32/64 confusion, and we control exactly
which bug-check code and parameters are used.

## Why SSH over WinRM?

Both are available on the test guest. We chose SSH because:

- **Quoting is solved.** PowerShell over SSH with `-EncodedCommand` (base64 UTF-16LE)
  eliminates all quoting issues. WinRM's SOAP XML encoding corrupts certain
  characters and has payload size limits.
- **Connection lifecycle is predictable.** When the guest crashes, the SSH connection
  drops cleanly (TCP RST or timeout). WinRM sessions can hang indefinitely on a
  half-open connection after a BSOD.
- **OpenSSH is built into Windows Server 2019+.** No additional agent or firewall
  rules needed beyond enabling the `sshd` service.
- **Key auth works.** The `administrators_authorized_keys` file provides
  password-free access without storing credentials in scripts.

The `guest-ssh.sh` wrapper auto-detects the guest IP from libvirt, handles both
short inline commands (EncodedCommand) and long scripts (scp + invoke), and sets
`ServerAliveInterval` to detect a dead connection within 15 seconds.

## Why Driver Verifier matters

Driver Verifier is a Windows kernel feature that adds runtime checks around driver
operations (pool allocations, IRQL tracking, I/O verification). It is enabled in
our test VM for all drivers.

This changes observed crash behavior: a KeBugCheckEx call with code `0x0A`
(IRQL_NOT_LESS_OR_EQUAL) may be intercepted and reported as `0xD1`
(DRIVER_IRQL_NOT_LESS_OR_EQUAL) because Verifier catches the violation at a
different point in the call stack.

The `src/data/trigger-methods.json` file records codes **as observed** with
Verifier enabled and marks each entry `"verified": true`. If Verifier is disabled,
the observed codes will differ; re-run `src/scripts/crash-injector/sweep-crashme.sh` to re-baseline.

## Snapshot-based testing methodology

The test loop is deliberately simple and stateless:

```
revert to known-good snapshot
  → start VM
    → wait for SSH
      → trigger BSOD (KeBugCheckEx via crashme-ctl.exe)
        → wait for auto-reboot
          → collect evidence (collect-guest.ps1)
            → pull artifacts to host
              → revert (reset for next iteration)
```

Each iteration starts from identical state. This eliminates:
- Accumulated crash artifacts from prior runs
- Registry corruption from repeated crashes
- Driver state drift from Verifier interactions

The `crashme-installed` snapshot includes the CrashMe driver loaded and ready.
The `clean-baseline` snapshot is the same but without the driver (for non-crash
testing).

## Offline dump extraction as fallback

Some crash types leave the VM unbootable (boot loops, stuck at recovery screen).
When SSH is unreachable after a crash:

1. Force-kill the VM (`virsh destroy`)
2. Mount the guest disk offline using libguestfs (containerized in `host-tools/`)
3. Extract `C:\Windows\MEMORY.DMP` and `C:\Windows\Minidump\*.dmp`

This recovers the raw dump files but loses event logs, system context, and the
structured report that `collect-guest.ps1` provides. It exists as a last resort
for the cases where the guest never comes back.

## Implicit detection vs. pre-registered codes

The tool detects ANY bug-check code, not just the 19 we trigger in testing.
Detection relies on the WER System/1001 event that Windows always writes after
a BugCheck reboot. The `bugcheck-codes.json` lookup table provides human-readable
names for known codes, but unknown codes still appear in the report with
`bugCheckName: null`.

This means the tool works as a post-mortem detector for product test failures
without needing to predict which codes might appear.

## Cross-compilation (mingw64)

The test driver and control utility are cross-compiled on Linux using mingw64:

```bash
x86_64-w64-mingw32-gcc -o crashme-ctl.exe crashme-ctl.c
x86_64-w64-mingw32-gcc -shared -o crashme.sys crashme.c \
    -nostdlib -lntoskrnl -Wl,--entry,DriverEntry
```

This keeps the build reproducible on the Linux CI host without needing a Windows
build environment. The resulting PE binaries are verified in bats tests
(`test-build.bats`) by checking for the MZ/PE headers.

## JSON-first output contract

Every script produces exactly one JSON object on stdout. Diagnostics go to stderr
(or xtrace via `BASH_XTRACEFD`). This enables:

- Direct consumption by `jq` in pipelines
- Parsing by AI agents without text extraction
- Structured artifact storage in CI systems
- Composability (one script's output feeds another's input)

Scripts that emit JSON redirect xtrace output to `/dev/null` via
`exec {BASH_XTRACEFD}>/dev/null` before `set -x`. This prevents trace lines from
corrupting the JSON stream while keeping the `set -euxo pipefail` convention
intact.
