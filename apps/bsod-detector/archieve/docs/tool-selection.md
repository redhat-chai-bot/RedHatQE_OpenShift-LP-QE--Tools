# Tool Selection

Which tools we use to trigger and capture BSOD events, and why.

## Trigger: KeBugCheckEx test driver

The CrashMe driver (`src/scripts/crash-injector/test-driver/crashme.sys`) calls `KeBugCheckEx` directly
with a caller-specified stop code and 4 parameters. This gives full control over
which bug-check code is produced, without depending on third-party tools or
complex fault injection paths.

- Cross-compiled on the host with `mingw64-gcc` (no WDK dependency).
- Loaded as a kernel service via `sc.exe create CrashMe type= kernel`.
- Triggered from user mode by `crashme-ctl.exe <code> <p1> <p2> <p3> <p4>`.
- The code-to-parameters mapping lives in
  [`data/trigger-methods.json`](../src/data/trigger-methods.json).

The primary justification for the custom driver over Sysinternals NotMyFault is
**arbitrary bug-check code control** — NotMyFault cannot produce most of the 19
stop codes the test suite exercises. See
[`crashme-vs-notmyfault.md`](crashme-vs-notmyfault.md) for the full tradeoff
comparison.

## What to gather, by perspective

### From inside the guest (the detector's normal home; runs after reboot)

- Bug-check code + parameters and faulting module, parsed from the minidump /
  `MEMORY.DMP`.
- Crash dump files: `C:\Windows\Minidump\*.dmp` and `%SystemRoot%\MEMORY.DMP`.
- System/Application event log entries bracketing the crash,
  especially source `BugCheck` (Event ID 1001) and `EventLog` (6008, dirty
  shutdown).
- System context: OS build, uptime, CPU, driver inventory, signature of the
  suspect driver.
- **Prerequisite:** the dump type must be configured *before* a crash
  (registry `CrashControl` -> complete/kernel/automatic/minidump) with an
  adequate page file, or there is nothing to capture. See
  [`data/crash-control.json`](../src/data/crash-control.json).

### From the host / hypervisor (a crashed guest may be frozen or rebooting)

- **External crash detection** — the host observes a guest hang/reset before
  the guest OS itself recovers.
- **Mount the guest qcow2 from the host** (via libguestfs / `host-tools/`) to
  pull `MEMORY.DMP` even when the guest will not boot. Most robust recovery route.
- **Host kernel-log + VM-config signals** (via `src/scripts/collect-host-signals.sh`) —
  some root causes never appear in the guest dump. For example, HYPERVISOR_ERROR
  (0x20001) can be caused by Intel split-lock `#AC` traps during a Hyper-V
  enlightened TLB-flush hypercall; the only evidence is the host kernel log
  (`x86/split lock detection: #AC ...`) correlated with the guest's Hyper-V
  `tlbflush`/`ipi` enlightenments in the libvirt domain XML. Patterns and
  feature list live in [`data/host-signals.json`](../src/data/host-signals.json).

### Deep dump analysis (symbolized)

- Header parsing (`parse-dump-header.sh`) gives the stop code + parameters
  without a debugger. Bucket / faulting-image attribution requires symbols.
- `scripts/analyze-dump.ps1` wraps `cdb !analyze -v` to produce the
  `FAILURE_BUCKET_ID`, `IMAGE_NAME`, and call stack (e.g.
  `0x7a_c0000185_DUMP_VIOSTOR` -> viostor.sys as an I/O-completion attribution,
  `PAGE_HASH_ERRORS_0x1a_3f` for page-hash corruption).
  `collect-guest.ps1 -Symbolize` runs it inline.

## Design implications

Maps onto the project convention "scripts produce facts; the agent decides":

1. **Source-of-truth data** in `data/`:
   - `bugcheck-codes.json` — stop code -> name / description (shared by parser
     and any reporting step).
   - `trigger-methods.json` — KeBugCheckEx code -> parameters
     (shared by sweep script and reporting).
   - `crash-control.json` — dump-type registry settings the configure step
     applies and the collector verifies.
   - `event-sources.json` — event log sources/IDs relevant to crashes.
2. **One-job scripts** with JSON stdout (under `scripts/`):
   - `configure-dumps.ps1` (guest) — apply `CrashControl`, verify page file.
   - `collect-guest.ps1` (guest) — dumps + event logs + context.
   - `collect-from-host.ps1` (host) — detect crash, mount disk, pull dump.

No table (bug-check codes, trigger methods, event sources) is duplicated across
scripts; every script reads it from `data/`.
