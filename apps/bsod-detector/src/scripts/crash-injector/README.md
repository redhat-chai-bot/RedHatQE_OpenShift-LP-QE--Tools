# Crash Injector Scripts

Scripts that orchestrate intentional BSOD injection for testing the BSOD detector pipeline.

Designed for **deliberate, controlled crash testing** — not production use.

## Script Overview

### `trigger-bsod-intentional.sh`

**Purpose**: Main entry point for end-to-end intentional BSOD pipeline.

**Usage**:
```bash
BSOD_DET__VM__NAME="win2022-vm-hjoshi1" \
BSOD_DET__NAMESPACE="windows-bsod" \
BSOD_DET__CONFIRM_TARGET="win2022-vm-hjoshi1" \
  ./trigger-bsod-intentional.sh 0x01
```

**Arguments**:
- `crash_type` — NotMyFault bugcheck code (explicit, no default)
  - `0x01` EXCEPTION_ACCESS_VIOLATION
  - `0x02` INVALID_KERNEL_HANDLE
  - `0x03` SYSTEM_SERVICE_EXCEPTION
  - `0x09` DRIVER_IRQL_NOT_LESS_OR_EQUAL
  - See `notmyfaultc64.exe /?` for full list

**Environment Variables**:

| Variable | Required | Purpose |
|---|---|---|
| `BSOD_DET__VM__NAME` | **Yes — no default** | Target Windows VM name |
| `BSOD_DET__NAMESPACE` | **Yes — no default** | Kubernetes namespace |
| `BSOD_DET__CONFIRM_TARGET` | **Yes — no default** | **Authorization token.** Must equal `BSOD_DET__VM__NAME` to prevent accidental BSOD injection on wrong VM. Prevents typos/mistakes. |
| `BSOD_DET__EVIDENCE__DIR` | No | Evidence root (default: `/mnt/persistent-bsod-evidence`) |
| `BSOD_DET__SNAPSHOT__CLASS` | No | Storage snapshot class |
| `BSOD_DET__MEMORY__DUMP_PVC` | No | Memory dump PVC name |
| `BSOD_RECOVERY_IMAGE` | No | Digest-pinned guestfs recovery image |
| `BSOD_DET__READY__TIMEOUT` | No | Watcher readiness timeout in seconds (default: 300) |
| `BSOD_DET__PREFLIGHT__TIMEOUT` | No | Currently validated as a positive integer; the preflight invocation uses a fixed 1800-second timeout |

**Execution Flow**:
```
1. Validate BSOD_DET__VM__NAME and BSOD_DET__NAMESPACE are set (no defaults)
2. Create run directory: /mnt/persistent-bsod-evidence/{TIMESTAMP}-intentional-{PID}-{RANDOM}/
3. Run preflight-rhov.sh
   ├─ QGA ping (5 retries)
   ├─ configure-dumps.ps1 on guest → validate rebootRequired=false
   └─ Write recovery-metadata.json
4. Clean stale guest dumps (`MEMORY.DMP`, `Minidump/*.dmp`) and verify they are absent
5. Start `watch-crash.sh` in the background and wait for its run-ID readiness marker
6. Inject BSOD via guest-agent.py exec-crash notmyfaultc64.exe /crash <type>
7. watch-crash.sh detects BSOD:
   ├─ Captures vm-memory.elf.tar.gz via virtctl memory-dump
   ├─ Captures screenshot, domain.xml, host-signals.json
   ├─ Stops VM (virtctl stop)
   ├─ Runs extract--guest-os--crach-info.sh (offline NTFS extraction)
   ├─ Restarts VM (virtctl start)
   └─ Writes evidence-summary.json
8. Return exit code (0=success, 1=failure)
```

**Evidence Directory — All Files Explained**

By default, files are placed under `/mnt/persistent-bsod-evidence/{TIMESTAMP}-intentional-{PID}-{RANDOM}/`; `BSOD_DET__EVIDENCE__DIR` can select another validated persistent evidence mount.
The table below shows what each file is, who writes it, and at which pipeline phase.

| File | Size (typical) | Phase | Written by | What it contains |
|---|---|---|---|---|
| `watcher-ready` | 42 B | Pre-BSOD | `watch-crash.sh` | Run ID marker — written when watcher is armed and watching |
| `recovery-metadata.json` | ~1.3 KB | Pre-BSOD | `preflight-rhov.sh` | VM name, namespace, PVC names, storage class, snapshot class, recovery image digest, armed epoch, pre-crash dump inventory |
| `bsod-screenshot.png` | ~37 KB | At BSOD (VM still frozen) | `watch-crash.sh` → `virtctl vnc` | VNC screenshot of the Windows blue screen at crash moment |
| `vm-memory.elf.tar.gz` | ~800 MB–1.4 GB | At BSOD (VM still frozen) | `watch-crash.sh` → `virtctl memory-dump` | **Primary dump artifact.** Full physical RAM snapshot in ELF ET_CORE format, streamed from KubeVirt via HTTP export. Contains full Windows memory: kernel, drivers, user processes, page tables. Developer converts offline with `elf2dmp` for WinDbg/Volatility |
| `domain.xml` | ~14 KB | At BSOD (VM still frozen) | `watch-crash.sh` → `virsh dumpxml` inside virt-launcher pod | Complete libvirt XML domain definition at crash time — CPU topology, memory, all attached disks, network interfaces, QEMU devices. Richer than `oc get vmi -o yaml` as it reflects actual QEMU runtime state |
| `launcher-compute.log` | ~100–200 KB | At BSOD (VM still frozen) | `watch-crash.sh` → `oc logs` on virt-launcher pod | Raw KVM/QEMU compute container logs — hypervisor events, device errors, split-lock traps, memory balloon events, KVM internal errors |
| `host-signals.json` | ~1.3 KB | At BSOD (VM still frozen) | `watch-crash.sh` → `collect-host-signals.sh` | Parsed summary of `launcher-compute.log` — split-lock trap count, KVM internal error count, Hyper-V feature states (tlbflush/ipi/vapic/spinlocks/synictimer), risk assessment |
| `parse-dump-header.json` | ~146 B | After VM stopped | `extract--guest-os--crach-info.sh` | Bugcheck code + parameters extracted from dump header. **Stub** when elf2dmp is disabled (no on-disk MEMORY.DMP on KVM). Run `parse-dump-header.sh` offline against elf2dmp output |
| `guestFS_sda3/Windows/System32/winevt/Logs/System.evtx` | ~8–9 MB | After VM stopped | `extract--guest-os--crach-info.sh` → guestfs-ntfs pod → `guestfish` | Windows System EventLog extracted offline from NTFS partition. Contains crash event 1001 (BugCheck), dirty shutdown 6008, kernel events. `sda3` is dynamic — detected as whichever NTFS partition contains `C:\` |
| `guestFS_sda3/Windows/System32/winevt/Logs/Application.evtx` | ~6 MB | After VM stopped | `extract--guest-os--crach-info.sh` → guestfs-ntfs pod → `guestfish` | Windows Application EventLog extracted offline from NTFS partition. Contains Application/1001 LiveKernelEvent and app-level crash records |
| `events.json` | ~162 B | After VM stopped | `extract--guest-os--crach-info.sh` | **Stub.** The EVTX parser is archived at `apps/bsod-detector/archieve/src/scripts/host/extract-evtx.py`; its lookup data is maintained in active `apps/bsod-detector/src/data`. |
| `checksums.sha256` | ~900 B | After VM stopped | `extract--guest-os--crach-info.sh` | SHA-256 hashes of all evidence files (except log files and summary files generated after this point). Used by reliability.py to detect tampering |
| `extraction.log` | ~3–5 KB | After VM stopped | `extract--guest-os--crach-info.sh` | Step-by-step guestfish extraction trace — partition discovery, guestfish commands, oc cp transfers, file sizes |
| `extraction-summary.json` | ~3 KB | After VM stopped | `reliability.py write-summary` | Artifact inventory from recovery phase — lists every file with type, format, size, sha256, valid flag. Reports missing types or invalid artifacts |
| `stage-errors.jsonl` | 0 B (success) | Throughout | `watch-crash.sh` + `extract--guest-os--crach-info.sh` | One JSON line per stage failure — stage name, error message, timestamp. Empty on clean run |
| `evidence-summary.json` | ~3 KB | End of pipeline | `watch-crash.sh` → `reliability.py write-summary` | Final pipeline verdict — `ok: true/false`, consolidated stage errors, missing required artifact types, invalid artifacts |
| `watcher.log` | ~100–120 KB | Throughout | `watch-crash.sh` | Full timestamped execution trace of the entire pipeline — QGA pings, BSOD detection, memory capture, stop VM, recovery, restart |

**Timing diagram**:
```
Pipeline start
  │
  ├─── [Pre-BSOD] preflight-rhov.sh runs
  │         → recovery-metadata.json written
  │         → watcher-ready written when armed
  │
  ├─── [BSOD injected] notmyfaultc64.exe /crash 0x01
  │
  ├─── [Capture decision] QGA miss threshold plus corroborating domain/VMI/pod evidence, or current KubeVirt Panicked event
  │         → bsod-screenshot.png        (virtctl VNC screenshot, ~seconds)
  │         → vm-memory.elf.tar.gz       (virtctl memory-dump, ~5–10 min)
  │         → domain.xml                 (virsh dumpxml, ~seconds)
  │         → launcher-compute.log       (oc logs, ~seconds)
  │         → host-signals.json          (parsed from launcher-compute.log)
  │
  ├─── [VM stopped] virtctl stop
  │
  ├─── [Recovery] extract--guest-os--crach-info.sh via guestfs-ntfs pod
  │         → guestFS_sda3/...System.evtx      (guestfish + oc cp, ~30s)
  │         → guestFS_sda3/...Application.evtx  (same session, ~30s)
  │         → parse-dump-header.json     (stub)
  │         → events.json               (stub)
  │         → checksums.sha256
  │         → extraction.log
  │         → extraction-summary.json
  │
  ├─── [VM restarted] virtctl start
  │
  └─── [Pipeline end]
            → stage-errors.jsonl         (populated throughout)
            → evidence-summary.json      (final verdict)
            → watcher.log               (written throughout)
```

**What is NOT captured (platform limitations)**:
- `MEMORY.DMP` — `AutoReboot=0` prevents the reboot that copies DedicatedDump.sys → MEMORY.DMP
- `Minidump/` — Requires pagefile.sys which Windows Server 2022 on KVM does not create
- `vm-memory-windows.dmp` — elf2dmp conversion disabled (17GB, developer runs offline)
- Volatility outputs — Developer tool, run offline against vm-memory.elf.tar.gz

**Exit Codes**:
- `0` — All required artifacts captured and validated
- `1` — Pipeline failed — check `stage-errors.jsonl` then `watcher.log`

**Diagnosing failures**:
```bash
run=/path/to/run
cat $run/stage-errors.jsonl | jq .
cat $run/evidence-summary.json | jq '{ok,stageErrors,missingRequiredArtifactTypes,invalidArtifacts}'
cat $run/extraction-summary.json | jq '{ok,stageErrors,missingRequiredArtifactTypes,invalidArtifacts}'
```

## Prerequisites

Before running the pipeline:

1. **VM Running**: `oc get vmi win2022-vm-hjoshi1 -n windows-bsod` shows `Running`
2. **QGA healthy**: `python3 guest-agent.py ping` returns `{}`
3. **Crash dump configured** (golden image settings — requires one prior reboot):
   - `CrashDumpEnabled=7` (Automatic)
   - `AutoReboot=0`
   - `DedicatedDumpFile=C:\DedicatedDump.sys` (15.9GB pre-allocated)
4. **Evidence mount**: `/mnt/persistent-bsod-evidence` writable and persistent
5. **NotMyFault binary**: `C:\Temp\nmf\notmyfaultc64.exe` on the VM
6. **Recovery image**: Digest-pinned `quay.io/konveyor/oadp-vmfr-access@sha256:...` pullable

**If preflight fails with rebootRequired=true**:
```bash
virtctl stop win2022-vm-hjoshi1 -n windows-bsod
virtctl start win2022-vm-hjoshi1 -n windows-bsod
# Wait for VM Ready, then re-run
```

## Troubleshooting

| Error | Where to look | Likely cause |
|---|---|---|
| QGA ping failed | `watcher.log` | VM frozen from previous BSOD — restart with virtctl |
| rebootRequired=true | preflight output | CrashDumpEnabled changed — do virtctl stop/start |
| source PVC attached | `extraction.log` | StopVM failed or VMI still running |
| oc cp unexpected EOF | `extraction.log` | Retry — transient network issue |
| missing: memory | `extraction-summary.json` | vm-memory.elf.tar.gz missing — virtctl dump failed |
| missing: evtx | `extraction-summary.json` | No System.evtx on any NTFS partition |

## Related Scripts

- `../host/preflight-rhov.sh` — VM validation and metadata generation
- `../host/watch-crash.sh` — BSOD detection and memory capture
- `../host/extract--guest-os--crach-info.sh` — Offline NTFS artifact extraction
- `../guest/configure-dumps.ps1` — Windows crash dump configuration
