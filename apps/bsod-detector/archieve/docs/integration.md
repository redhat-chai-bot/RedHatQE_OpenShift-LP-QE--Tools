# Agentic & CI/CD Integration Guide

How to use bsod-detector programmatically — from an AI agent, a CI/CD pipeline,
or any automation that needs to detect a BSOD on a Windows guest and collect the
post-mortem.

## Design principles

Every script emits **exactly one JSON object to stdout** and exits with a
meaningful code. Diagnostic chatter goes to stderr/information streams, never
stdout. This means any consumer — `jq`, Python, a CI step, an LLM agent — can
`json.loads()` stdout and get structured facts without parsing prose.

**Scripts produce facts; consumers make decisions.** The scripts will never
interpret a crash, decide whether to retry, or post a notification. That logic
belongs in the calling pipeline or agent.

**Implicit detection:** The collector (`collect-guest.ps1`) detects ANY
bug-check code that occurs, not just those pre-registered in
`bugcheck-codes.json`. Unknown codes are still reported; they just lack a
human-readable name.

---

## JSON contracts at a glance

### `collect-guest.ps1`

| Field | Type | Description |
|---|---|---|
| `ok` | bool | `true` if collection completed |
| `collectedAt` | string (ISO 8601) | UTC timestamp |
| `outputDir` | string | Where dumps and artifacts were written (guest path) |
| `system.osBuild` | string | e.g. `"Microsoft Windows Server 2025 Standard Evaluation build 26100"` |
| `system.uptimeSeconds` | int | Seconds since last boot (i.e. since the crash reboot) |
| `system.cpu` | string | Processor name |
| `crash.bugCheckCode` | string \| null | Hex stop code, e.g. `"0x000000D1"` |
| `crash.bugCheckName` | string \| null | Human name from `bugcheck-codes.json`, or null if unknown |
| `crash.parameters` | string[] | The 4 bug-check parameters |
| `crash.faultingModule` | string \| null | Driver name if identifiable (currently requires dump analysis) |
| `crash.dumpFiles` | string[] | Relative paths of collected dumps |
| `crash.crashTime` | string (ISO 8601) \| null | Time of the BugCheck event |
| `events` | object[] | Crash-timeline events (log, eventId, time, message) |
| `suspectDriver` | object \| null | Sigcheck result if faultingModule was resolved |
| `warnings` | string[] | Non-fatal issues (no dumps found, unknown code, etc.) |

**Exit code:** `0` if the script ran to completion. `warnings` is the
machine-readable signal for degraded results (e.g. missing dumps).

### `host-tools/extract-dump.sh` (container, offline recovery)

| Field | Type | Description |
|---|---|---|
| `ok` | bool | `true` if at least one dump was extracted |
| `disk` | string | Path to the disk image that was read |
| `outputDir` | string | Where dumps were written (container-local `/out`) |
| `dumpFiles` | string[] | List of extracted files |
| `warnings` | string[] | Non-fatal issues |

**Exit code:** `0` if dumps found, `1` if none, `2` on bad args.

---

## Integration patterns

### Pattern 1: CI post-mortem step (simplest)

Your CI pipeline runs a Windows VM for testing. If the job sees a BSOD (the VM
rebooted unexpectedly), add a post-mortem step that SSHes in and runs the
collector.

```yaml
# Pseudocode — adapt to your CI system (Jenkins, Tekton, GitHub Actions, etc.)
post-mortem:
  when: always                          # run even if the test step failed
  steps:
    - name: collect-bsod-evidence
      run: |
        ssh Administrator@$GUEST_IP \
          'powershell -File C:\bsod-detector\scripts\collect-guest.ps1 \
                      -OutputDir C:\bsod-out' \
          > collect-guest.json 2>collect-guest.stderr

        # Parse the result
        OK=$(jq -r '.ok' collect-guest.json)
        CODE=$(jq -r '.crash.bugCheckCode // "none"' collect-guest.json)

        if [ "$CODE" != "none" ]; then
          echo "::error::BSOD detected: $CODE ($(jq -r '.crash.bugCheckName' collect-guest.json))"
          # Pull the dump files back for archival
          scp -r Administrator@$GUEST_IP:'C:\bsod-out\*' ./artifacts/
        fi

    - name: upload-artifacts
      if: always
      uses: actions/upload-artifact@v4
      with:
        name: bsod-evidence
        path: |
          collect-guest.json
          artifacts/
```

Key points:
- Run `collect-guest.ps1` **unconditionally** (`when: always`) — you want the
  evidence even when the test step's exit code says "failed."
- Parse `crash.bugCheckCode` to decide whether a BSOD actually happened.
  If it's `null`, the reboot may have been a clean shutdown or power loss, not
  a BSOD.
- Upload `collect-guest.json` + the dump files as pipeline artifacts. The JSON
  is self-contained for triage; the `.dmp` files are for deep analysis with
  `kd`/WinDbg.
- `warnings` being non-empty means the collection was degraded (e.g. no dump
  file was written because the page file is too small). Surface these in the
  CI output.

### Pattern 2: deliberate crash testing (full loop)

When you are *testing* that crash detection works — e.g. validating that your
monitoring catches BSODs — use the full trigger + collect loop with the CrashMe
driver.

```bash
# From the host, sweep all 19 defined codes:
export LIBVIRT_DEFAULT_URI=qemu:///system
./src/scripts/crash-injector/sweep-crashme.sh

# Or drive a single code manually:
# 1. Revert to known-good state
virsh snapshot-revert bsod-test crashme-installed
virsh start bsod-test

# 2. Wait for SSH
until ssh $SSHOPTS Administrator@$IP 'echo up' 2>/dev/null; do sleep 8; done

# 3. Trigger (example: BAD_POOL_HEADER 0x19)
ssh $SSHOPTS Administrator@$IP 'C:\Tools\crashme-ctl.exe 0x19 0x3 0x0 0x0 0x0'
# SSH drops here — the machine just crashed. This is expected.

# 4. Wait for auto-reboot
sleep 30
until ssh $SSHOPTS Administrator@$IP 'echo up' 2>/dev/null; do sleep 10; done

# 5. Collect
ssh $SSHOPTS Administrator@$IP \
    'powershell -File C:\bsod-detector\scripts\collect-guest.ps1' \
    > result.json

# 6. Validate
EXPECTED="0x00000019"
ACTUAL=$(jq -r '.crash.bugCheckCode' result.json)
if [ "$ACTUAL" = "$EXPECTED" ]; then
    echo "PASS: got $ACTUAL as expected"
else
    echo "FAIL: expected $EXPECTED, got $ACTUAL"
    exit 1
fi

# 7. Revert for next test
virsh snapshot-revert bsod-test crashme-installed
```

### Pattern 3: offline recovery (guest won't boot)

When the VM is frozen or won't come back after a crash, use the containerized
host-side extractor. The VM must be **shut off** (or force-killed).

```bash
virsh destroy bsod-test                   # force power-off
mkdir -p output/offline

host-tools/run.sh \
    --disk /var/lib/libvirt/images/bsod-test.qcow2 \
    --out "$(pwd)/output/offline" \
    > extract-result.json

jq '.dumpFiles' extract-result.json       # list of recovered dump files
# -> ["Minidump/082026-10046-01.dmp"]
```

### Pattern 4: agent-driven triage

An AI agent can consume the JSON output directly. The contracts are designed
for this: every field is typed, every factual claim is a discrete JSON value,
and interpretation is left to the consumer.

```
Agent prompt:
  "You have the JSON output from collect-guest.ps1. The crash produced
   bug-check code {crash.bugCheckCode} ({crash.bugCheckName}) with parameters
   {crash.parameters}. The event timeline is in {events}. The guest is
   {system.osBuild}.

   1. Look up the bug-check code in the Windows documentation.
   2. Identify the most likely root cause from the parameters and timeline.
   3. If a faulting module is identified, check whether it is a known
      problematic driver version.
   4. Recommend next steps."
```

The agent never needs to parse event logs, read registry keys, or handle dump
files — the scripts already did that and produced structured facts.

---

## Safety model

The CrashMe driver requires Administrator and an explicit IOCTL call to fire.
The `sweep-crashme.sh` orchestrator is the explicit opt-in for a test cycle;
it reverts the VM to a known snapshot before each trigger.

For CI use, the trigger is gated by:
1. The driver must be installed and loaded (deliberate guest prep step).
2. `crashme-ctl.exe` must be invoked with a valid code and 4 parameters.
3. The VM is always reverted to a known snapshot, so accidental triggers have
   no persistent effect.

---

## Exit codes

| Script | Code | Meaning |
|---|---|---|
| `collect-guest.ps1` | 0 | Collection completed (check `warnings` for quality) |
| | 1 | Fatal error (couldn't run at all) |
| `extract-dump.sh` | 0 | At least one dump extracted |
| | 1 | No dumps found |
| | 2 | Bad arguments |
| `sweep-crashme.sh` | 0 | All codes passed |
| | 1 | One or more codes failed |

---

## Decision tree: which collection path?

```
Crash detected (guest agent dead / domain crashed)?
  └─ collect-offline.sh --vm <name> --out <dir>
       1. Capture raw memory backup (guest-memory.elf)
       2. Stop the VM (virsh destroy / virtctl stop --force)
       3. Extract dumps + .evtx offline (guestfs)
       4. Parse dump headers + event logs
       5. Collect host-side signals
       6. Assemble evidence-summary.json
```

The offline path is always preferred. It extracts crash dumps, event logs,
and system context without needing guest-side scripts, SSH, or a reboot.

---

## Environment requirements

### Guest prerequisites (one-time setup)

These are set by `src/scripts/crash-injector/prep-guest.ps1` and baked into the `clean-baseline` snapshot:

| Setting | Value | Why |
|---|---|---|
| `CrashDumpEnabled` | 2 (kernel) | Write a kernel dump on BSOD |
| `AlwaysKeepMemoryDump` | 1 | Don't delete the dump on low disk |
| `AutoReboot` | 0 | Stay at crash screen so MEMORY.DMP is fully written; host extracts offline |
| `LogEvent` | 1 | Log the BugCheck event (System/1001) |
| Page file | System-managed; complete dumps require >= RAM + 257 MB | Kernel dumps need a page file on the system volume; complete dumps need one at least as large as physical RAM |
| OpenSSH | Enabled, key auth | Remote access for automation |
| CrashMe driver | `C:\Tools\crashme.sys` + `crashme-ctl.exe` | KeBugCheckEx trigger |

### Host prerequisites (for the offline path)

- **podman** with the unified `quay.io/redhatqe/bsod-detector:latest` image.
  Build through the scoped Makefile with repository-root context and immutable
  inputs:

  ```bash
  make -C image/container/bsod-detector build \
    BASE_IMAGE='<fedora-image@sha256:digest>' \
    OCP_CLIENT_URL='<url>' OCP_CLIENT_SHA256='<sha256>' \
    VIRTCTL_URL='<url>' VIRTCTL_SHA256='<sha256>'
  ```
- The guest disk must be **readable** by the invoking user and the VM **shut off**.

**Guest script deployment:** In the offline-first flow, no guest-side scripts
need to be staged. Evidence (dumps, event logs) is extracted from the guest
disk after the VM is stopped. Only the CrashMe driver needs to be pre-installed
for deliberate crash testing (see `crash-injector/prep-guest.ps1`).

---

## Artifact management

All output goes under the git-ignored `output/` directory. In CI, upload the
directory as a pipeline artifact. Key files:

| File | Contains |
|---|---|
| `collect-guest.json` | Full structured report (the primary artifact) |
| `Minidump/*.dmp` | Small memory dumps (one per crash, ~256 KB each) |
| `MEMORY.DMP` | Kernel dump (`CrashDumpEnabled=2`, kernel pages only) or complete dump (`CrashDumpEnabled=1`, all physical RAM + 257 MB page file required) |

The JSON report is self-contained for triage. The `.dmp` files are for deep
analysis with WinDbg / `kd -z <file> -c "!analyze -v"`.

**Never commit dumps to git** — they contain kernel memory and may include
secrets, credentials, or PII.

---

## Validated crash types

All 19 bug-check codes in
[`data/trigger-methods.json`](../src/data/trigger-methods.json) have been verified
end-to-end on Windows Server 2025 (build 26100) with Driver Verifier enabled.
All use the KeBugCheckEx test driver (`src/scripts/crash-injector/test-driver/crashme.sys`) invoked via
`src/scripts/crash-injector/sweep-crashme.sh`.

| Code | Name |
|---|---|
| `0x0000000A` | IRQL_NOT_LESS_OR_EQUAL (observed as 0xD1 / DRIVER_IRQL_NOT_LESS_OR_EQUAL with Driver Verifier enabled) |
| `0x00000019` | BAD_POOL_HEADER |
| `0x0000001A` | MEMORY_MANAGEMENT |
| `0x0000001E` | KMODE_EXCEPTION_NOT_HANDLED |
| `0x0000003D` | INTERRUPT_EXCEPTION_NOT_HANDLED |
| `0x0000007A` | KERNEL_DATA_INPAGE_ERROR |
| `0x0000007B` | INACCESSIBLE_BOOT_DEVICE |
| `0x0000007E` | SYSTEM_THREAD_EXCEPTION_NOT_HANDLED |
| `0x00000080` | NMI_HARDWARE_FAILURE |
| `0x0000009F` | DRIVER_POWER_STATE_FAILURE |
| `0x000000C1` | SPECIAL_POOL_DETECTED_MEMORY_CORRUPTION |
| `0x000000C2` | BAD_POOL_CALLER |
| `0x000000F7` | DRIVER_OVERRAN_STACK_BUFFER |
| `0x00000109` | CRITICAL_STRUCTURE_CORRUPTION |
| `0x00000124` | WHEA_UNCORRECTABLE_ERROR |
| `0x00000133` | DPC_WATCHDOG_VIOLATION |
| `0x00000135` | REGISTRY_FILTER_DRIVER_EXCEPTION |
| `0x00000154` | UNEXPECTED_STORE_EXCEPTION |
| `0x00020001` | HYPERVISOR_ERROR |

If your guest has a different Driver Verifier configuration, the codes may
differ; re-run the verification sweep to re-baseline.
