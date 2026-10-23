# Host Scripts

Scripts that run on the orchestration host (CI operator machine or laptop).

These scripts manage the full BSOD detection and artifact extraction pipeline orchestrated from outside the Kubernetes cluster.

---

## Files Overview

| File | Purpose |
|------|---------|
| `preflight-rhov.sh` | Fail-closed pre-run validation; generates recovery metadata |
| `watch-crash.sh` | Background BSOD detection & memory capture orchestration |
| `extract--guest-os--crash-info.sh` | Offline NTFS artifact extraction from stopped guest disk |
| `guest-agent.py` | Python CLI for QEMU Guest Agent communication (PowerShell tunnel) |
| `reliability.py` | Artifact validation, decision logic, summary generation |
| `collect-host-signals.sh` | Parse host-side KVM/Hyper-V crash correlation signals |
| `parse-dump-header.sh` | Extract Windows bugcheck code from crash dump headers |
| Archived `extract-evtx.py` | Optional offline EVTX parser at `../../../archieve/src/scripts/host/extract-evtx.py`; not present in the active script tree |

---

## Script Overview

### `trigger-bsod-intentional.sh`

**Purpose**: Main orchestration entry point for intentional BSOD testing. Enforces explicit authorization before any destructive action.

**All steps performed (in order)**:

**Authorization guards (before any action)**
- Crash type argument `$1` must be supplied — no silent default (destructive operation)
- Crash type must be one of `0x01..0x09` (NotMyFault supported codes)
- `BSOD_DET__VM__NAME` and `BSOD_DET__NAMESPACE` must be explicitly set
- `BSOD_DET__CONFIRM_TARGET` must equal `BSOD_DET__VM__NAME` — prevents accidental wrong-VM runs
- Evidence root must be non-empty
- Timeouts must be positive integers

**Initialization**
- Generates unique `runId` = `YYYYMMDDTHHMMSSz-intentional-PID-RANDOM`
- Creates `outDir` = `evidenceRoot/runId` (fails if already exists)
- Creates run-scoped temp dir for guestfish cache (`/tmp/bsod-injector-<runId>.XXXXXX`)
- Exports `LIBGUESTFS_CACHEDIR` and `LIBGUESTFS_TMPDIR` to run-scoped dir
- Registers `Cleanup()` on EXIT (kills watcher, removes scoped temp dir)
- Registers `OnSignal` on INT/TERM (exits with correct signal code)

**Phase 1 — Preflight** (`preflight-rhov.sh`)
- Runs all 10 preflight checks (see preflight-rhov.sh section)
- Exports `BSOD_DET__POD__NAME` and `BSOD_DET__DOMAIN__NAME` from metadata

**Phase 2 — Guest cleanup**
- Removes `C:\Windows\MEMORY.DMP` and `C:\Windows\Minidump\*.dmp` via guest-agent
- Verifies cleanup: `memory=false` and `minidumpCount=0` — Die if stale dumps remain

**Phase 3 — Start watcher** (`watch-crash.sh`, background)
- Starts watcher in background, records `watcherPid`
- Polls `watcher-ready` file until it contains the run ID (max `readyTimeout` seconds)
- Die if watcher exits before publishing readiness

**Phase 4 — Inject BSOD** (`notmyfaultc64.exe`)
- Calls `guest-agent.py exec-crash notmyfaultc64.exe /accepteula /crash <crashType>`
- Waits up to 90s for QGA to confirm crash delivery (disconnect = success)

**Phase 5 — Wait for completion**
- Waits for watcher background process to exit
- Die if `watcherStatus != 0`
- Validates `evidence-summary.json` has `ok=true` and correct `runId`

**Cleanup (EXIT trap)**
- Kills watcher process if still running
- Removes run-scoped temp dir (never touches shared paths)

**Environment Variables**:

| Variable | Required | Purpose |
|---|---|---|
| `BSOD_DET__VM__NAME` | **Yes** | Target VM — no default |
| `BSOD_DET__NAMESPACE` | **Yes** | Namespace — no default |
| `BSOD_DET__CONFIRM_TARGET` | **Yes** | Must equal VM name to authorize crash |
| `BSOD_DET__EVIDENCE__DIR` | No | Evidence root (default: `/mnt/persistent-bsod-evidence`) |
| `BSOD_DET__SNAPSHOT__CLASS` | No | Storage snapshot class |
| `BSOD_DET__MEMORY__DUMP_PVC` | No | Memory dump PVC name |
| `BSOD_DET__READY__TIMEOUT` | No | Watcher readiness timeout (default: 300s) |
| `BSOD_DET__PREFLIGHT__TIMEOUT` | No | Positive-integer validation only; trigger script currently uses a fixed 1800s preflight timeout |
| `BSOD_RECOVERY_IMAGE` | No | Digest-pinned guestfs image |

**Example**:
```bash
BSOD_DET__VM__NAME="win2022-vm-hjoshi1" \
BSOD_DET__NAMESPACE="windows-bsod" \
BSOD_DET__CONFIRM_TARGET="win2022-vm-hjoshi1" \
  ../crash-injector/trigger-bsod-intentional.sh 0x01
```

---

### `watch-crash.sh`

**Purpose**: Background BSOD detection, memory capture, and recovery orchestration.

**Responsibilities**:
- Poll VM via QGA ping every 5s; detect BSOD when pings exceed miss threshold
- After the QGA miss threshold, use libvirt `domstate`, VMI phase, launcher-pod presence, and a current KubeVirt `Panicked` event as capture evidence. These signals identify an unresponsive guest but do not independently prove a Windows bug-check.
- Capture full physical memory via `virtctl memory-dump get` → writes ELF dump to PVC
- Download ELF dump via `virtctl vmexport download --format gzip` (no port-forward, no token in logs)
- Clean up stale VirtualMachineExports on same PVC before creating new one
- Capture VNC screenshot, domain XML, host signals
- Monitor dump write progress (virsh domstats)
- Stop VM using `virtctl stop`
- Call `extract--guest-os--crash-info.sh` for offline NTFS extraction
- Restart VM after recovery
- Generate `evidence-summary.json`

**Memory dump flow**:
```
virtctl memory-dump get → KubeVirt freezes VM → writes RAM to PVC (ELF ET_CORE, ~1.5GB compressed)
Create VirtualMachineExport on PVC
virtctl vmexport download --format gzip --port-forward --insecure → vm-memory.elf.tar.gz
Delete VirtualMachineExport
virtctl memory-dump remove
```

**Why virtctl vmexport download** (replaced port-forward + curl):
- No token exposed in logs — virtctl resolves auth internally
- virtctl manages its own port-forward — no connection drops on large files
- Simpler — 1 command replaces 30+ lines of retry loop + pfPid management

**Developer tools (commented out — run offline)**:
- `elf2dmp` conversion → `vm-memory-windows.dmp` (17GB — run offline against vm-memory.elf.tar.gz)
- Volatility3 analysis (windows.info, crashinfo, driverscan, dumpfiles)

**Primary artifact**: `vm-memory.elf.tar.gz` (~1.5GB compressed from 16GB RAM) — KubeVirt captures directly from QEMU, works regardless of Windows/pagefile state.

**Output**:
```
bsod-screenshot.png          (VNC screenshot at crash)
vm-memory.elf.tar.gz         (primary memory artifact ~1.5GB compressed)
domain.xml                   (libvirt domain configuration at crash)
host-signals.json            (host diagnostics)
launcher-compute.log         (KVM launcher logs)
parse-dump-header.json       (bugcheck code stub — elf2dmp disabled)
watcher.log                  (full execution trace)
stage-errors.jsonl           (per-stage error tracking)
evidence-summary.json        (final pipeline verdict)
```

---

### `preflight-rhov.sh`

**Purpose**: Fail-closed pre-run validation. Every check is a hard `Die` — no partial arming allowed.

**All checks performed (in order)**:

**1. Input validation**
- `--ns`, `--vm`, `--out`, `--metadata`, `--run-id` all required
- `runId` must match DNS label pattern `^[a-zA-Z0-9][a-zA-Z0-9._-]{5,80}$`
- `ns`, `vm`, `snapClass`, `memoryPvc` must be valid Kubernetes DNS labels
- Recovery image must be digest-pinned (`@sha256:[64 hex chars]`)
- Evidence volume kind must be `pvc`, `network`, or `csi` (hostPath/emptyDir forbidden)
- Evidence storage ID must be stable (alphanumeric + safe chars)
- Snapshot class, memory dump PVC both required
- `BSOD_DET__COMMAND__TIMEOUT` must be a positive integer

**2. Helper scripts present**
- All pipeline helpers must exist and be readable: `guest-agent.py`, `reliability.py`, `extract--guest-os--crash-info.sh`, `collect-host-signals.sh`, `parse-dump-header.sh`
- Guest config inputs must exist: `configure-dumps.ps1`, `crash-control.json`

**3. Evidence mount validation**
- Evidence root must be an existing non-symlink directory
- Filesystem must not be ephemeral (`overlay`, `tmpfs`, `ramfs`, `rootfs` all forbidden)
- Network kind requires a network filesystem (`nfs`, `cifs`, `ceph`, etc.)
- Evidence PVC must be `Bound` and `Filesystem` mode
- Run output dir must be a unique direct child of evidence root (not nested)
- Run output basename must equal the run ID
- Run output dir must be empty (no stale artifacts)

**4. VM and VMI state**
- VM `runStrategy` must be `Manual` (not `Always` — would auto-restart after BSOD)
- Exactly one running `virt-launcher` pod must exist for the VM
- Guest PVC must be `Block` mode with storage class and size (required for snapshot recovery)
- Memory dump PVC must be `Bound`, `Filesystem` mode, and different from the guest PVC
- Snapshot class driver must match the guest PVC provisioner

**5. Recovery image capability probe**
- Creates a temporary pod from the recovery image
- Runs `bash -c 'guestfish --version'` to verify the image has the `bash+guestfish-v1` contract
- Pod must complete with `Succeeded` — die if `Failed` or timeout

**6. QGA liveness**
- QGA ping via `guest-agent.py ping` — 5 retries × 3s sleep
- Die if all retries fail (VM not ready for crash injection)

**7. Guest crash dump configuration**
- Upload `configure-dumps.ps1` + `crash-control.json` to VM via guest-agent
- Run `configure-dumps.ps1 -DataFile crash-control.json`
- Die if output fails any of:
  - `ok == true` — script ran successfully
  - `matchesRecommended == true` — all registry values match expected
  - `current.AutoReboot == 0` — VM will stay frozen after BSOD
  - `pageFile.adequate == true` — DedicatedDumpFile or pagefile is adequate
  - `rebootRequired == false` — no pending reboot needed; if true, do `virtctl stop && virtctl start`

**8. Guest path verification**
- `C:\Windows` exists
- `C:\Windows\Minidump` exists
- If `--require-trigger`: `C:\Temp\nmf\notmyfaultc64.exe` exists (NotMyFault binary)

**9. Pre-crash dump inventory**
- Records all existing dump files (`MEMORY.DMP`, `Minidump\*.dmp`) with path/size/mtime
- Stored in `recovery-metadata.json` as `preCrashInventory` for post-crash comparison

**10. Generate recovery-metadata.json**
Writes all collected VM/storage/config data needed by downstream scripts.

**Environment Variables**:

| Variable | Purpose |
|---|---|
| `BSOD_DET__MEMORY__DUMP_PVC` | Memory dump PVC name |
| `BSOD_DET__SNAPSHOT__CLASS` | Storage snapshot class |
| `BSOD_DET__COMMAND__TIMEOUT` | Command timeout (default: 30s) |
| `BSOD_DET__PREFLIGHT__TIMEOUT` | Positive-integer validation only; trigger script currently uses a fixed 1800s preflight timeout |

**Output**: `recovery-metadata.json` — VM name, namespace, pod, domain, PVC names, storage class, storage size, volume mode, recovery image digest, armed epoch, pre-crash dump inventory, evidence mount details

---

### `extract--guest-os--crash-info.sh`

**Purpose**: Offline NTFS artifact extraction from stopped VM disk.

**Usage**: `extract--guest-os--crash-info.sh --metadata PRE_STOP_METADATA.json`.
Optionally export `BSOD_DET__GUEST_FS__CTR_IMG` before running the extractor, watcher or container. The extractor uses the value directly; unset or empty uses `quay.io/konveyor/oadp-vmfr-access:latest`. The legacy image environment variable is not consulted.
Run it as an executable, as the watcher and container entrypoint do; it is not a sourceable shell library.
The output directory comes only from metadata `.outputDir`; there is no extractor `--out` option.
The extractor preserves the provided path spelling and accepts existing directory aliases and arbitrary directory names.
Metadata `.runId` is retained in the extraction summary, independently of the output directory name.
Stale-output scanning follows a command-line directory alias, not symlinks encountered below it.
The extractor needs only `runId`, `outputDir`, `namespace`, `vm` and `guestPvc` metadata fields.
It preserves and validates a watcher-produced dump-parser result, or writes the existing no-dump stub; on-disk dump extraction remains disabled.
It rejects stale extraction artifacts, but does not revalidate evidence-mount identity or preflight-only storage/image fields.
Preflight's persistent-storage validation is unchanged; extraction no longer checks whether that mount changed afterwards.
Container `MODE=recover` takes the same metadata-only arguments; watcher/preflight and archived `MODE=extract` retain their own `--out` options.
Extraction inherits stdout/stderr (captured in `watcher.log` when called by the watcher); it creates no `extraction.log` or stage-error entries. Summary generation still reads an existing watcher-owned `stage-errors.jsonl`, without creating or modifying it.
Cleanup takes a required nonempty pod-name argument, uses native `oc delete --ignore-not-found` with its default wait behavior, then `oc wait --for=delete --timeout=60s`. Successful extraction calls `Cleanup "${helperPod}"` directly before summary generation and again through `trap 'Cleanup "${helperPod}"' EXIT`; there is no ownership flag or custom INT/TERM trap. The supplied `${1:?}` rejects an empty helper name on early EXIT before any cleanup API call; it can replace an earlier status (malformed VM JSON changes from 5 to 1). A main cleanup failure stops summary generation and remains a failure even when EXIT cleanup retries successfully. Native cleanup errors can replace an earlier exit status, and custom signal-status guarantees no longer apply.

**Responsibilities**:
- Validate output path and preflight metadata integrity
- Require the metadata target VM's printable status to be **Stopped**, using a direct process substitution; no VMI absence or namespace-wide PVC scan is performed. Empty/malformed responses and non-Stopped statuses block extraction, but valid Stopped JSON followed by an API failure can pass because the producer exit status is not propagated. This point-in-time status check is not an exclusive PVC lock.
- Create a `guest-fs--ntfs--<epoch>-<pid>` helper using `BSOD_DET__GUEST_FS__CTR_IMG` directly, defaulting unset or empty to `quay.io/konveyor/oadp-vmfr-access:latest` (no legacy environment fallback), with `force_kvm`: request/limit one `devices.kubevirt.io/kvm` device. The initial budget requests 512Mi memory and 500m CPU, with limits of 2Gi memory and 2000m CPU; adequacy has not been measured. The supplied Pod template has no node selector or fsGroup; it uses `/bin/bash -c` with `args: [exec tail -f /dev/null]`, the `vm-disk` read-only PVC and `guest-fs--tmp`/`guest-fs--home` emptyDirs. A quoted static YAML template passes through `oc create --dry-run=client -o json --save-config`, then `jq --arg` injects only pod name, namespace, container name, image and PVC. The container name and image are blank in the template; nested jq updates set the name from `helperPodCtr` (normally `libguestfs`) and image together. The client accepts blank container-name/image/PVC placeholders and fills the blank namespace from local context; marshalling overwrites it. The original YAML has no annotations. Client `--save-config` generates a last-applied annotation; grouped jq updates preserve it unchanged in the raw apply input, including its template placeholders. This is not a claim about server-side final annotations; no `yq` is required. Rendering the same inputs yields the same payload, not whole-script idempotence.
- Recovery tests require the real `oc` client on `PATH` for offline YAML-to-JSON generation; API operations and apply remain mocked. Generation/marshalling failures stop subsequent helper execution under `pipefail`; apply is a concurrent pipeline stage, not a transactional producer-status gate.
- Wait once for the helper's Ready condition with native `oc wait --timeout=180s`, discarding stdout; no extractor `--request-timeout` or added process deadline is used. A failed wait stops before helper execution and triggers cleanup. Cleanup retains its supplied 60-second deletion wait.
- Discover filesystems once through `FindNTFS "${helperPod}" "${helperPodCtr}"`, whose required arguments select the pod/container independently of the caller's variables. Its process-substitution status remains unchecked: failed/empty discovery can reach placeholder artifacts and a failed summary; partial valid producer output can still trigger extraction despite the producer failure.
- Probe each NTFS partition with readonly `guestfish -ra /dev/vda ... mount-ro ... ls /Windows`; failed probes continue to the next partition. `set-program virt-sh` sets an informative name, not a different executable.
- Copy System.evtx and Application.evtx independently with helper-side Bash `mkdir -p` and readonly guestfish `copy-out`; a failed file does not prevent attempting the other. Each copy starts a separate guestfish session. The required `exec -a` replaces Bash, so the supplied final `true` is not reached after a successful exec.
- Test `/tmp/bsod--guest-files--<epoch>/` inside the helper, then stream helper `tar zc` to runner `guest-fs--crash-info.tgz` and stop scanning partitions. The temporary name has no PID suffix. Directory existence does not prove any file copied: both failed copies can leave an empty archive. Tar failure can leave partial archive bytes on the runner; no transactional cleanup is claimed.
- Archive-only output intentionally has no loose EVTX files or implicit unpacking. Validator changes are deferred: the unchanged `rhov-snapshot-recovery` and watcher `natural-rhov` summaries require loose EVTX, so even a valid archive currently causes missing `evtx` and exit 1. Checksum inclusion does not validate archive members.
- Generate `checksums.sha256` manifest (log files excluded — still being written at manifest time)
- Write `extraction-summary.json` via `reliability.py write-summary`

**Optional offline tool (archived)**:
- `extract-evtx.py` can parse extracted `.evtx` files into crash-detection JSON; it is not called by the active pipeline and requires `python-evtx`.
- Inline python-evtx parser → `EventLogs/System.json`, `Application.json`

**Output structure**:
```
guest-fs--crash-info.tgz  (archive members: Windows/System32/winevt/Logs/*.evtx)
parse-dump-header.json   (stub — on-disk dumps blocked on KVM)
events.json              (stub — optional parser is archived, not in the active script tree)
checksums.sha256         (manifest of evidence files)
extraction-summary.json  (artifact inventory and validation)
```

**Why no EventLogs/ symlink**: `.evtx` files are directly accessible under `guestFS_<partition>/Windows/System32/winevt/Logs/`. The archived parser is at `../../../archieve/src/scripts/host/extract-evtx.py`; its lookup files are maintained in `../../../src/data`.

**Platform limitations (KVM + VirtIO Balloon)**:
- `pagefile.sys` cannot be reliably created — Windows Server 2022 lazy pagefile allocation + balloon driver
- `MEMORY.DMP` (on-disk): Not produced — `AutoReboot=0` prevents the boot that copies DedicatedDump.sys → MEMORY.DMP
- `Minidump`: Not produced — requires pagefile which cannot be created
- Intended primary memory artifact is `vm-memory.elf.tar.gz` from KubeVirt; capture depends on successful dump, PVC, export, and download stages.

**Environment Variables**:

| Variable | Purpose |
|---|---|
| `BSOD_DET__COMMAND__TIMEOUT` | Command timeout (default: 30s) |
| `BSOD_DET__EXTRACT_EVTX__BIN` | Legacy override referenced only by the commented parser hook; the active pipeline does not use it |
| `BSOD_DET__DATA__DIR` | Legacy override referenced only by the commented parser hook; active pipeline does not use it |
| `BSOD_DET__GUEST_FS__CTR_IMG` | Guestfs helper image; unset or empty defaults to `quay.io/konveyor/oadp-vmfr-access:latest`, with no legacy environment fallback |

---

### `guest-agent.py`

**Purpose**: Tunnel PowerShell commands into Windows VM via qemu-guest-agent.

**How it works**:
```
guest-agent.py <cmd>
  → oc exec virt-launcher-pod
    → virsh qemu-agent-command <domain> '<QMP JSON>'
      → qemu-guest-agent (Windows)
        → PowerShell / program execution
```

**Environment Variables** (re-read at resolve time, not just import time):

| Variable | Purpose |
|---|---|
| `BSOD_DET__VM__NAME` | Target VM name |
| `BSOD_DET__NAMESPACE` | Kubernetes namespace |
| `BSOD_DET__POD__NAME` | Virt-launcher pod (auto-resolved if unset) |
| `BSOD_DET__DOMAIN__NAME` | Libvirt domain name (auto-derived as `<ns>_<vm>`) |

**Subcommands**:
- `ping` — QGA liveness check
- `exec <program> [args]` — run and wait for output
- `exec-crash <program> [args]` — run crash command (handles disconnect as success)
- `psfile <local.ps1> [--companion ...] [-- args]` — upload and run PowerShell script
- `put <local> <guestpath>` — upload file
- `get <guestpath> <local>` — download file

---

### `collect-host-signals.sh`

**Purpose**: Parse host-side KVM/Hyper-V crash-correlation signals from pre-captured files.

**Called by**: `watch-crash.sh` → `CaptureHostSignals()` with `--log-file launcher-compute.log --domain-xml domain.xml`

**Responsibilities**:
- Scan `launcher-compute.log` for Intel split-lock `#AC` trap patterns defined in `host-signals.json`
- Extract Hyper-V enlightenment feature states from `domain.xml` (tlbflush, ipi, vapic, spinlocks, synictimer)
- Detect if split-lock mitigation is applied (tlbflush + ipi both off)
- Generate crash-correlation assessment

**Operates fully offline** — reads pre-captured files, never connects to the node or pod directly (important for OpenShift/KubeVirt where kernel log and domain live in different pods).

**Output** (`host-signals.json`):
```json
{
  "ok": true,
  "vm": "windows-bsod_win2022-vm-hjoshi1",
  "kernelSignals": [{"id": "split-lock-trap", "count": 0, "relatedBugCheck": "0x00020001", "matches": []}],
  "splitLockDetected": false,
  "hyperv": {"features": [{"name": "tlbflush", "state": "absent", "risk": "high", "present": false}, ...], "mitigationApplied": false},
  "assessment": ["No split-lock #AC traps found in the examined kernel-log window."]
}
```

**Data source**: `src/data/host-signals.json` — defines signal patterns and Hyper-V feature list.

---

### `parse-dump-header.sh`

**Purpose**: Extract Windows bugcheck code from a `.dmp` file header.

**Output**:
```json
{
  "ok": true,
  "totalDumps": 1,
  "dumps": [{
    "file": "vm-memory-windows.dmp",
    "bugCheckCode": "0x00000161",
    "bugCheckName": "LIVE_SYSTEM_DUMP",
    "parameters": ["0x0", "0x0", "0x0", "0x0"],
    "valid": true
  }]
}
```

**Note**: When elf2dmp is disabled (default), `parse-dump-header.json` is written as a stub with `ok=true` and no dumps — the bugcheck code from the ELF dump is not extracted at pipeline time. Developer runs elf2dmp offline and re-runs parse-dump-header.sh.

---

### `reliability.py`

**Purpose**: Artifact validation, evidence integrity, and summary generation.

**Commands**:
- `decision` — crash capture decision from QGA misses + domstate + pvpanic
- `progress-step` — advance dump write progress state machine
- `validate-artifact` — check individual file format (screenshot/memory/dump/evtx/json)
- `write-summary` — generate extraction-summary.json or evidence-summary.json
- `map-disk` — map libvirt disk target to VMI PVC

**Required artifact types per mode**:

| Mode | Required types |
|---|---|
| `intentional-rhov` | screenshot, memory, log, json |
| `natural-rhov` | screenshot, memory, evtx, log, json, checksums |
| `rhov-snapshot-recovery` | memory, evtx, log, json, checksums |

**Note**: `dump` (MEMORY.DMP/Minidump) is **not required** — blocked on KVM (pagefile unavailable).

**Manifest validation rules**:
- Log files (`.log`, `.xml`) — exempt from manifest (still being written at manifest time)
- `checksums.sha256` — exempt from manifest (cannot be in its own manifest)
- Summary files (`extraction-summary.json`, `evidence-summary.json`) — excluded from scan (generated after manifest)
- All other classified artifacts — must have manifest entry and matching hash

---

### Archived `extract-evtx.py`

**Purpose**: Parse Windows `.evtx` EventLog files to JSON with crash detection. This utility is archived at `../../../archieve/src/scripts/host/extract-evtx.py`; it is not called by the active pipeline.

**Crash detection tiers**:
1. `System/1001` BugCheck — classic BSOD with bugcheck code
2. `Application/1001` LiveKernelEvent — kernel event
3. `System/6008` dirty shutdown

**Usage (offline)**:
```bash
run_dir=/path/to/run
python3 apps/bsod-detector/archieve/src/scripts/host/extract-evtx.py \
  --data-dir apps/bsod-detector/src/data \
  "$run_dir"/guestFS_*/Windows/System32/winevt/Logs/*.evtx
```

Requires: `pip install python-evtx`

---

## Execution Flow (Intentional Crash)

```
trigger-bsod-intentional.sh
  ├─ preflight-rhov.sh
  │    ├─ QGA ping (5 retries)
  │    ├─ configure-dumps.ps1 → verify rebootRequired=false
  │    └─ write recovery-metadata.json
  │
  ├─ Clear and verify stale guest dumps
  ├─ watch-crash.sh (background)
  │    ├─ Poll QGA every 5s
  │    ├─ Capture decision after QGA miss threshold plus domain/VMI/pod evidence, or current KubeVirt Panicked event
  │    ├─ CaptureScreenshot, CaptureMemory (→ vm-memory.elf.tar.gz)
  │    ├─ CaptureHostSignals
  │    ├─ WaitDumpMonitor (non-fatal on timeout)
  │    ├─ StopVM
  │    ├─ extract--guest-os--crash-info.sh
  │    │    ├─ Require target VM printableStatus Stopped
  │    │    ├─ Create guestfs-ntfs pod
  │    │    ├─ Detect Windows partition dynamically
  │    │    ├─ Batch guestfish download (single QEMU session)
  │    │    ├─ oc cp to host
  │    │    └─ write extraction-summary.json
  │    ├─ RestartVM
  │    └─ write evidence-summary.json
  │
  └─ Inject BSOD via guest-agent.py exec-crash notmyfaultc64.exe /crash <type> after watcher readiness
```

## Environment Variable Convention

All variables follow Red Hat Chaos Team naming: `BSOD_DET__[<COMPONENT>__]<NAME>`

- Prefix: `BSOD_DET`
- Component separator: `__` (double underscore)
- Multi-word within component: `_` (single underscore)

---

## Function Reference

### preflight-rhov.sh

**Purpose**: Fail-closed pre-run validation. Every check is a hard `Die` — no partial arming allowed.

#### Helper Functions

| Function | Purpose |
|----------|---------|
| `Die()` | Print fatal error to stderr and exit with code 1 |
| `RequireCommand()` | Check if command exists in PATH; die if missing |
| `ValidName()` | Validate Kubernetes DNS label format (alphanum, hyphens, lowercase) |
| `RunTimed()` | Execute command with timeout; TERM after N seconds, KILL after 5 more |
| `Oc()` | Wrapper around kubectl/oc with automatic command and request timeouts |
| `Cleanup()` | Exit trap: delete temporary probe pod, clean temp directory |
| `OnSignal()` | Signal trap: exit with proper signal code on INT/TERM |

#### Validation Sections

1. **Input validation** (lines 107–147): DNS labels, run ID format, recovery image digest-pinning
2. **Helper scripts present** (lines 149–151): Verify all pipeline helpers exist (guest-agent.py, reliability.py, etc.)
3. **Evidence mount validation** (lines 153–198): Filesystem type, durability proof, run directory uniqueness
4. **VM and VMI state** (lines 162–172): runStrategy=Manual, VMI phase=Running, PVC modes
5. **Recovery image capability probe** (lines 169–172): Temporary pod validates bash + guestfish contract
6. **QGA liveness** (lines 174–176): Ping guest via QEMU Guest Agent (5 retries)
7. **Guest crash dump configuration** (lines 178–186): Upload configure-dumps.ps1, verify settings effective (not pending reboot)
8. **Guest path verification** (lines 188–191): Verify C:\Windows, C:\Windows\Minidump exist; NotMyFault binary if required
9. **Pre-crash dump inventory** (lines 193–195): Record baseline dumps for post-crash comparison
10. **Generate recovery-metadata.json** (lines 197–210): Write all validated state for downstream scripts

#### Output

- `recovery-metadata.json`: JSON file with VM/cluster identifiers, storage config, recovery image digest, pre-crash dump inventory

---

### watch-crash.sh

**Purpose**: Background BSOD detection, memory capture, and recovery orchestration.

#### Helper Functions

| Function | Purpose |
|----------|---------|
| `CleanupGuestfishCache()` | Remove leftover cache files (file.0x*) from libguestfs operations |
| `Die()` | Print fatal error and exit with code 1 |
| `RunTimed()` | Execute with timeout; TERM then KILL after 5s |
| `Oc()` | Wrapper around kubectl/oc with timeouts |
| `Log()` | Print timestamped message to stdout and pipeline log file |
| `RecordError()` | Append error to stage-errors.jsonl JSONL file and log |
| `Cleanup()` | EXIT trap: kill background processes, remove temp dirs, cleanup cache |
| `OnSignal()` | Signal trap: record interruption, exit with signal code |
| `PingOk()` | Check guest liveness via QGA ping (returns exit code 0/1) |
| `DomainState()` | Query libvirt domain state (running, crashed, paused, etc.) |
| `WriteSummary()` | Generate evidence-summary.json via reliability.py |
| `CaptureScreenshot()` | Capture BSOD screenshot via virtctl VNC (60s delay for VNC responsiveness) |
| `CaptureMemory()` | Orchestrate full memory dump: KubeVirt request → export → download via virtctl vmexport |
| `CaptureHostSignals()` | Capture domain XML, launcher logs, run host-signal parser |
| `ProgressSample()` | Poll disk write progress via virsh domstats; update state machine |
| `MonitorDumpProgress()` | Background loop: poll dump progress every N seconds until complete or timeout |
| `StartDumpMonitor()` | Validate baseline (must not be complete), start background monitor |
| `WaitDumpMonitor()` | Wait for background progress monitor to complete |
| `StopVM()` | Stop VM via virtctl stop, poll until phase=Succeeded/Failed |
| `RestartVM()` | Restart VM via virtctl start (unless --no-restart flag) |
| `Recover()` | Invoke extract--guest-os--crash-info.sh for offline NTFS extraction |
| `CrashResponse()` | Main orchestration: screenshot → memory → host signals → dump monitor → stop → recover → restart → summary |

#### Memory Dump Flow (CaptureMemory)

```
1. virtctl memory-dump get → KubeVirt freezes VM → writes ELF to PVC
2. Poll vm.status.memoryDumpRequest.phase until Completed
3. Clean up stale VirtualMachineExports on this PVC
4. Create new VirtualMachineExport (HTTP stream)
5. Poll until export.status.phase=Ready
6. virtctl vmexport download --format gzip → vm-memory.elf.tar.gz
7. Validate ELF structure
8. Delete VirtualMachineExport
9. virtctl memory-dump remove (cleanup association)
```

#### Main Watcher Loop (lines 421–449)

1. **Preflight check** (line 422): Ensure guest still responsive before arming
2. **Arm pvpanic event watcher** (lines 423–428): Background kubectl watch for "Panicked" events
3. **Signal readiness** (line 427): Write runId to --ready-file if specified
4. **Detection loop** (lines 430–446):
   - Ping guest every 5 seconds
   - On 2+ consecutive failures → collect corroborating evidence (pvpanic, VMI phase, pod status)
   - reliability.py decision returns "capture" or "continue"
   - If capture → invoke CrashResponse

#### Output Artifacts

```
bsod-screenshot.png           BSOD screenshot at crash
vm-memory.elf.tar.gz          Primary memory artifact (~1.5GB compressed)
domain.xml                    Libvirt domain config at crash
host-signals.json             Host KVM diagnostics
launcher-compute.log          virt-launcher pod logs
parse-dump-header.json        Bugcheck code (elf2dmp disabled by default)
watcher.log                   Full execution trace
stage-errors.jsonl            Per-stage error tracking
evidence-summary.json         Final pipeline verdict
```

---

### extract--guest-os--crash-info.sh

**Purpose**: Offline NTFS artifact extraction from stopped VM disk via guestfs-ntfs pod.

#### Helper Functions

| Function | Purpose |
|----------|---------|
| `Die()` | Print fatal error and exit with code 1 |
| `RunTimed()` | Execute with timeout |
| `Oc()` | Wrapper around kubectl/oc |
| `CleanupGuestfishCache()` | Remove leftover cache files from libguestfs |
| `Cleanup()` | EXIT trap: delete guestfs-ntfs pod, cleanup cache |
| `WaitJsonPath()` | Poll Kubernetes resource until jsonpath expression matches |
| `DiscoverNTFSPartitions()` | Use guestfish list-filesystems to detect NTFS partitions on guest disk |
| `ExtractNTFSFile()` | Extract single file via guestfish (partition + Windows path) → oc cp to host |
| `ExtractNTFSFilesParallel()` | Parallel extraction with controlled concurrency (max 3 simultaneous) |

#### Extraction Flow

1. **Validate metadata** (lines 36–62): Ensure output path matches preflight, evidence mount unchanged
2. **Check target VM status**: Require metadata target VM printableStatus Stopped. Preflight supplies the target-to-guest-PVC association; extraction checks neither VMI absence nor namespace-wide PVC consumers. Direct process substitution does not propagate the API producer's exit status; a partial valid Stopped response can pass even when that producer fails.
3. **Create guestfs-ntfs pod** (lines 299–327): Deploy pod with block device attachment, verify guestfish ready
4. **Discover NTFS partitions** (lines 340–344): Query guest disk for all NTFS partitions
5. **Archive guest files**:
   - Readonly Windows-directory probe per NTFS partition
   - Independent helper-side mkdir/copy-out sessions for each EVTX
   - Helper-side directory test and tar stream to guest-fs--crash-info.tgz; no loose EVTX copies
   - Existing validators still require loose EVTX and fail until separately adapted
6. **Parse dump headers** (lines 453–465): Run parse-dump-header.sh on MEMORY.DMP or Minidump dir
7. **Generate checksums manifest** (lines 530–540): SHA256 of all artifacts (excludes logs, temp files)
8. **Generate extraction-summary.json** (lines 543–545): Validate artifacts via reliability.py

#### Output Structure

```
guest-fs--crash-info.tgz        (Windows/System32/winevt/Logs/*.evtx members)
parse-dump-header.json        (Dump metadata, or stub if no on-disk dump)
events.json                   (stub — archived parser is optional and not called by the active pipeline)
checksums.sha256              (Manifest of all evidence files)
extraction-summary.json       (Artifact inventory & validation)
```

---

### guest-agent.py

**Purpose**: Tunnel PowerShell commands into Windows VM via QEMU Guest Agent.

#### Key Functions

| Function | Purpose |
|----------|---------|
| `_oc()` | Execute OpenShift CLI command, return stdout or empty string |
| `_resolve_pod()` | Find virt-launcher pod for a given VM in namespace |
| `resolve_target()` | Auto-detect and populate NS, VM, POD, DOM from cluster; re-reads environment variables |
| `agent()` | Send QEMU agent command via virsh; return response payload JSON |
| `guest_exec()` | Execute program in guest; optionally wait for completion |
| `guest_exec_crash()` | Execute crash program; handle disconnect as success |
| `guest_put()` | Upload local file to guest (512KB chunks via base64) |
| `guest_get()` | Download guest file (1MB chunks, seek-based retries); auto-compress large files |
| `_print_exec_result()` | Output guest command results (stdout, stderr); return exit code |
| `_psfile_args()` | Parse companion file uploads and PowerShell arguments |
| `main()` | Parse CLI commands and dispatch to above functions |

#### Subcommands

| Command | Purpose |
|---------|---------|
| `ping` | QGA liveness check |
| `exec <prog> [args]` | Run and wait for output |
| `exec-crash <prog> [args]` | Run crash command (disconnect = success) |
| `psfile <script.ps1> [--companion LOCAL GUEST -- args]` | Upload + run PowerShell script |
| `put <local> <guestpath>` | Upload file |
| `get <guestpath> <local>` | Download file |

#### Environment Variables

- `BSOD_DET__VM__NAME`: Target VM name
- `BSOD_DET__NAMESPACE`: Kubernetes namespace
- `BSOD_DET__POD__NAME`: Virt-launcher pod (auto-resolved)
- `BSOD_DET__DOMAIN__NAME`: Libvirt domain (derived as `<ns>_<vm>` if unset)

#### Communication Path

```
guest-agent.py <cmd>
  → oc exec virt-launcher-pod
    → virsh qemu-agent-command <domain> '<QMP JSON>'
      → qemu-guest-agent (Windows)
        → PowerShell / program execution
```

---

### reliability.py

**Purpose**: Artifact validation, evidence integrity, and summary generation.

#### Key Functions

| Function | Purpose |
|----------|---------|
| `emit()` | Print JSON to stdout and exit with code |
| `crash_decision()` | Decide "capture" vs "observe" vs "fail" from QGA misses + domstate + pvpanic |
| `parse_domstats()` | Extract disk write bytes for target device from virsh domstats output |
| `domstats()` | Parse domstats from stdin; emit write bytes |
| `initial_progress_state()` | Create empty progress state machine for a disk device |
| `advance_progress()` | State machine: track write progress, detect quiescence, complete on idle |
| `progress_step()` | Load state, parse domstats from stdin, advance, save state, emit result |
| `progress_sequence()` | Validate progress across multiple domstats samples |
| `_validate_png()` | Verify PNG signature, chunk CRCs, IHDR, IEND structure |
| `_validate_ppm()` | Verify PPM (P3/P6) format header and dimensions |
| `_validate_elf()` | Validate ELF header, program header table extents, trailing zeros |
| `_validate_dump()` | Validate PAGEDU64 (Windows kernel dump) or MDMP (minidump) format |
| `_validate_evtx()` | Check EVTX magic header (ElfFile\x00) |
| `artifact_type()` | Classify and validate file format (screenshot/memory/dump/evtx/json) |
| `sha256_file()` | Compute SHA256 hash of a file |
| `validate_artifact()` | Validate single artifact file; emit format + hash |
| `classify()` | Classify file by name (screenshot, memory, evtx, json, log, checksums) |
| `write_summary()` | Load/validate manifest, scan artifacts, check required types, emit evidence-summary.json |
| `map_disk()` | Map libvirt disk target to VMI PVC by parsing domain XML + VMI spec |

#### Artifact Validation Modes

| Mode | Required artifact types |
|------|------------------------|
| `natural-rhov` | screenshot, memory, evtx, log, json, checksums |
| `intentional-rhov` | screenshot, memory, log, json |
| `rhov-snapshot-recovery` | memory, evtx, log, json, checksums |

#### Commands

- `decision`: Crash capture decision from evidence
- `progress-step`: Advance dump write progress state machine
- `validate-artifact`: Validate individual file format
- `write-summary`: Generate evidence-summary.json
- `map-disk`: Map libvirt disk to VMI PVC

---

### collect-host-signals.sh

**Purpose**: Parse host-side KVM/Hyper-V crash-correlation signals from pre-captured files.

#### Helper Functions

| Function | Purpose |
|----------|---------|
| `warn()` | Print diagnostic message to stderr |
| `die()` | Print fatal error and exit with code 2 |
| `have()` | Return 0 if command exists on PATH |

#### Signal Analysis

1. **Kernel log retrieval** (lines 88–111):
   - Priority: `--log-file` (file) > `--dmesg` flag > `journalctl -k` (live)
2. **Scan kernel log** (lines 113–156):
   - Extract patterns defined in host-signals.json
   - Parse KVM thread, trap address, address space
   - Flag split-lock #AC traps
3. **Extract Hyper-V enlightenments** (lines 158–203):
   - Parse domain XML for feature elements (tlbflush, ipi, vapic, etc.)
   - Detect if mitigation applied (tlbflush + ipi both off)
4. **Generate assessment** (lines 206–227):
   - Correlate split-lock traps with Hyper-V config
   - Identify HYPERVISOR_ERROR (0x20001) signature

#### Output

```json
{
  "ok": true,
  "vm": "...",
  "collectedAt": "...",
  "kernelSignals": [...],
  "splitLockDetected": true|false,
  "hyperv": { "features": [...], "mitigationApplied": true|false },
  "assessment": ["..."],
  "warnings": ["..."]
}
```

---

### parse-dump-header.sh

**Purpose**: Extract Windows bugcheck code from crash dump file headers.

#### Helper Functions

| Function | Purpose |
|----------|---------|
| `Die()` | Print error and exit with code 2 |
| `ReadU32Le()` | Read little-endian uint32 at offset via Python binary read |
| `ReadU64Le()` | Read little-endian uint64 at offset via Python binary read |

#### Processing (lines 101–156)

1. **Verify PAGEDU64 signature** (lines 106–113): Check 8-byte magic header
2. **Extract header fields** (lines 115–120):
   - BugCheckCode (uint32 @ offset 0x38)
   - Parameters 1-4 (uint64 each @ 0x40, 0x48, 0x50, 0x58)
3. **Resolve to bugcheck name** (lines 122–129): Lookup in bugcheck-codes.json
4. **Emit JSON result** (lines 152–154):
   - List of processed dumps with codes, names, parameters
   - Warnings for missing codes or signature issues

#### Output

```json
{
  "ok": true,
  "totalDumps": 1,
  "dumps": [{
    "file": "...",
    "bugCheckCode": "0x...",
    "bugCheckName": "...",
    "parameters": ["0x...", ...],
    "valid": true
  }],
  "warnings": ["..."]
}
```

---

### Archived extract-evtx.py

**Purpose**: Parse Windows `.evtx` EventLog files to JSON with crash detection. The utility is archived at `apps/bsod-detector/archieve/src/scripts/host/extract-evtx.py`, not present in the active script tree.

#### Crash Detection Tiers

1. `System/1001` BugCheck — classic BSOD with bugcheck code
2. `Application/1001` LiveKernelEvent — kernel event
3. `System/6008` dirty shutdown

#### Usage (Offline)

```bash
run_dir=/path/to/run
python3 apps/bsod-detector/archieve/src/scripts/host/extract-evtx.py \
  --data-dir apps/bsod-detector/src/data \
  "$run_dir"/guestFS_*/Windows/System32/winevt/Logs/*.evtx
```

**Requires**: `pip install python-evtx`

**Note**: This is a developer tool archived for offline use. The pipeline writes `events.json` as a stub; developers run this manually against extracted `.evtx` files.
