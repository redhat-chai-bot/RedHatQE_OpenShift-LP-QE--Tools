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
| `BSOD_DET__RECOVERY__IMAGE` | No | Digest-pinned guestfs recovery image |
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
   ├─ Runs extract--guest-os--crash-info.sh (offline NTFS extraction)
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
| `vm-memory.elf.tar.gz` | ~800 MB–2.3 GB | At BSOD (VM still frozen) | `watch-crash.sh` → `virtctl memory-dump` | **Primary dump artifact.** Full physical RAM snapshot in ELF ET_CORE format, streamed from KubeVirt via HTTP export. Contains full Windows memory: kernel, drivers, user processes, page tables. Developer converts offline with `elf2dmp` for WinDbg/Volatility |
| `domain-bsod.xml` | ~14 KB | At BSOD (VM still frozen) | `watch-crash.sh` → `virsh dumpxml` | libvirt domain XML captured **at crash detection time** (state=crashed/paused). Primary XML artifact for forensics. |
| `domain.xml` | ~14 KB | Pre-BSOD (Phase 2b) | `watch-crash.sh` → `virsh dumpxml` | Pre-crash backup domain XML. Fallback if crash-time capture fails. |
| `launcher-compute.log` | ~100–200 KB | At BSOD (VM still frozen) | `watch-crash.sh` → `oc logs` on virt-launcher pod | Raw KVM/QEMU compute container logs — hypervisor events, device errors, split-lock traps, memory balloon events, KVM internal errors |
| `host-signals.json` | ~1.3 KB | At BSOD (VM still frozen) | `watch-crash.sh` → `collect-host-signals.sh` | Parsed summary of `launcher-compute.log` — split-lock trap count, KVM internal error count, Hyper-V feature states (tlbflush/ipi/vapic/spinlocks/synictimer), risk assessment |
| `guest-fs--crash-info--<partition>.tgz` | varies | After VM stopped | `extract--guest-os--crash-info.sh` | Recursive source-to-destination mapping: raw pagefile.sys bytes stored as MEMORY.DMP plus EVTX files; no conversion, loose outputs or automatic unpacking |
| `stage-errors.jsonl` | 0 B (success) | Throughout | `watch-crash.sh` | Watcher stage failures; extraction does not append entries and inherits stdout/stderr into the watcher log. |
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
  ├─── [Recovery] extract--guest-os--crash-info.sh via guestfs-ntfs pod
  │         → guest-fs--crash-info--<partition>.tgz     (independent readonly guestfish copy-out, then tar)
  │
  ├─── [VM restarted] virtctl start
  │
  └─── [Pipeline end]
            → stage-errors.jsonl         (populated throughout)
            → evidence-summary.json      (final verdict)
            → watcher.log               (written throughout)
```

**Crash dump artifacts (platform-dependent)**:
- `MEMORY.DMP` / `DedicatedDump.sys` — Not extracted by the retained archive-only extractor.
- `Minidump/` — Not created or populated by the retained extractor.
- Offline memory analysis — If KubeVirt capture succeeds, developers may attempt `elf2dmp` conversion of `vm-memory.elf.tar.gz`; neither capture nor conversion is guaranteed.
- `vm-memory-windows.dmp` — elf2dmp conversion disabled (17GB, developer runs offline)
- Volatility outputs — Developer tool, run offline against vm-memory.elf.tar.gz

**Exit Codes**:
- `0` — Pipeline gates returned success; this is not proof of complete extraction. The extractor bypasses its final validator and may return zero for an empty or missing archive
- `1` — Pipeline failed — check `stage-errors.jsonl` then `watcher.log`

**Diagnosing failures**:
```bash
run=/path/to/run
cat $run/stage-errors.jsonl | jq .
cat $run/evidence-summary.json | jq '{ok,stageErrors,missingRequiredArtifactTypes,invalidArtifacts}'
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
| source PVC attached | `watcher.log` | StopVM failed or VMI still running |
| oc cp unexpected EOF | `watcher.log` | Retry — transient network issue |
| missing: memory | `evidence-summary.json` / `watcher.log` | KubeVirt capture or export failed |
| missing: evtx | `evidence-summary.json` | Watcher validator still requires loose EVTX; archive support is deferred |

## Related Scripts

- `../host/preflight-rhov.sh` — VM validation and metadata generation
- `../host/watch-crash.sh` — BSOD detection and memory capture
- `../host/extract--guest-os--crash-info.sh` — Offline NTFS artifact extraction
- `../guest/configure-dumps.ps1` — Windows crash dump configuration
