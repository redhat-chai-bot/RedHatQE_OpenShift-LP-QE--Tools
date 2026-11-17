# Host Scripts

Scripts that run on the orchestration host (CI operator machine or laptop).

Current extraction contract: `extract--guest-os--crash-info.sh --metadata METADATA.json` reads the shared output directory from metadata and streams `guest-fs--crash-info--<partition>.tgz`, recursively mapping raw pagefile.sys bytes to MEMORY.DMP and retaining EVTX source paths. It does not convert or validate dump bytes, retain loose EVTX or generate JSON/checksums. Its final reliability summary call remains commented out, and EXIT cleanup runs once. A successful exit does not establish archive completeness; the watcher summary validator remains separate.

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
- Calls `guest-agent.py exec-crash 'C:\Temp\nmf\notmyfaultc64.exe' /accepteula /crash <crashType>`
- Waits up to `BSOD_TRIGGER_CONFIRM_TIMEOUT` seconds (default 45) for QGA to confirm crash delivery (disconnect = success);
  the caller's outer `timeout 90` bounds the whole call, including the launch and the final status poll

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
| `BSOD_DET__PREFLIGHT__TIMEOUT` | No | Preflight timeout (default: 300s) |
| `BSOD_DET__RECOVERY__IMAGE` | No | Digest-pinned guestfs image |

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

**Primary artifact**: `vm-memory.elf.tar.gz` (~1.5GB compressed from 16GB RAM) — KubeVirt captures independently of guest pagefile state, but API, storage, export or download failures can prevent capture.

**Output**:
```
bsod-screenshot.png          (VNC screenshot at crash)
vm-memory.elf.tar.gz         (primary memory artifact ~1.5GB compressed)
domain-bsod.xml              (libvirt domain XML captured at crash moment — state=crashed/paused)
domain.xml                   (pre-crash backup captured in Phase 2b)
host-signals.json            (host diagnostics)
launcher-compute.log         (KVM launcher logs)
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
- Snapshot class required; memory dump PVC is **auto-created if missing**
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
- **Memory dump PVC auto-creation**: If the named memory-dump PVC doesn't exist, preflight creates it with:
  - Size: **same as guest disk PVC** (dynamically detected)
  - Storage class: **same as guest disk PVC** (dynamically detected)
  - Access mode: `ReadWriteOnce`, `Filesystem` mode
  - Waits up to 120 seconds for the new PVC to bind before continuing
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

**Usage**: `extract--guest-os--crash-info.sh --metadata METADATA.json`.
Optionally export `BSOD_DET__GUEST_FS__CTR_IMG` before running the extractor, watcher or container. The extractor
passes the value directly to `virtctl guestfs --image`; unset or empty uses the pinned default
`quay.io/kubevirt/libguestfs-tools:20261112_5c3989e66e`.
The legacy image environment variable is not consulted.
Run it as an executable, as the watcher and container entrypoint do; it is not a sourceable shell library.
The output directory comes only from metadata `.outputDir`; there is no extractor `--out` option.
The extractor preserves the provided path spelling and accepts existing directory aliases and arbitrary directory names.
Metadata `.runId` is read independently of the output directory name. Existing extraction artifacts do not trigger a stale-output rejection.
The extractor needs only `runId`, `outputDir`, `namespace`, `vm` and `guestPvc` metadata fields.
JSON/parser/checksum generation is removed. Existing outputs are not parsed, validated or rewritten; the parser placeholder comment does not perform conversion.
It does not revalidate evidence-mount identity or preflight-only storage/image fields.
Preflight's persistent-storage validation is unchanged; extraction no longer checks whether that mount changed afterwards.
Container `MODE=recover` takes the same metadata-only arguments; watcher/preflight and archived `MODE=extract` retain their own `--out` options.
Extraction inherits stdout/stderr (captured in `watcher.log` when called by the watcher); it creates no `extraction.log` or stage-error entries. The final summary invocation is commented out pending the Python refactor; pre-existing summary and stage-error files are not revalidated or modified.
`trap 'Cleanup "$?" "${guestfsPid}" "${guestfsStdIn}" "${hlprPod}"' EXIT` is the only cleanup; no custom INT/TERM trap
is added. The virtctl PID and stdin descriptor start as 0, so failures before virtctl starts make no kill, wait or
delete calls. Cleanup deletes `hlprPod` with one blocking `oc delete --ignore-not-found --timeout=60s --wait=true` only
if this run's virtctl was still running when cleanup began; liveness is not proof that the same-name Pod is this run's
helper, and an exited virtctl has already requested deletion of any Pod it created. Cleanup always closes the owned
stdin descriptor and reaps virtctl. After a clean exit it reaps before deleting (virtctl attaches to the Running Pod
and exits on EOF); after a failure it deletes first, which also ends a virtctl wait on a Pending Pod. The exit status
is the delete failure, else the virtctl failure, else the original status. A terminating signal keeps its status
because Bash re-raises it after the trap. The trap sees the status of the last completed command (usually 0); when it
is 0, cleanup takes the clean-exit order and the reap lasts until virtctl exits (on EOF once attached, or after
upstream's 500s Pending limit).

**Responsibilities**:
- Validate output path and preflight metadata integrity
- Require the metadata target VM's printable status to be **Stopped**, using a direct process substitution; no VMI absence or namespace-wide PVC scan is performed. Empty/malformed responses and non-Stopped statuses block extraction, but valid Stopped JSON followed by an API failure can pass because the producer exit status is not propagated. This point-in-time status check is not an exclusive PVC lock.
- Reject a pre-existing `libguestfs-tools-<pvc>` Pod with one `oc get` before starting virtctl; it is never adopted or
  deleted.
- Run `virtctl -n <ns> guestfs --vm <vm> --image <image> <pvc>` as a Bash coprocess. Its PID is saved at once, its
  stdin write end moves to a descriptor owned by the extractor and its stdout goes to stderr. Upstream virtctl
  creates `libguestfs-tools-<pvc>` with container `libguestfs` and the block PVC at `/dev/vda`, waits up to 500s for
  Running, then attaches a TTY. Stdin EOF ends the attach, after which virtctl deletes the Pod without waiting.
- Wait natively on the named Pod: `oc wait --for=create --timeout=60s`, then `--for=condition=Ready --timeout=180s`
  (stdout discarded). `--for=create` needs an oc client built on kubectl 1.31 or later (OpenShift 4.18+). A virtctl
  exit before Pod creation is noticed only after the 60s create timeout, and a later one only when a wait or
  liveness check fails; cleanup then reports virtctl's failure status. virtctl must still run after the Ready wait
  and after extraction.
- Upstream exposes no Pod UID, so a same-name Pod created by someone else between the pre-check and virtctl's create
  cannot be told apart from this run's helper. A same-name Pod that does not use the PVC makes virtctl's own create
  fail, and upstream's deferred delete then removes it; the extractor cannot prevent that.
- Discover filesystems once through `FindNTFS "${hlprPod}" "${helperPodCtr}"`, whose required arguments select the
  pod/container independently of the caller's variables. Its process-substitution status remains unchecked:
  failed/empty discovery can reach placeholder artifacts and return zero without the deferred summary gate; partial
  valid producer output can still trigger extraction despite the producer failure.
- Probe each NTFS partition with readonly `guestfish -ra /dev/vda ... mount-ro ... ls /Windows`; failed probes continue to the next partition. `set-program virt-sh` sets an informative name, not a different executable.
- Iterate `fileArr` original keys, default empty mappings to the source path, normalize file/directory trailing slashes and anchor each final destination under the helper temporary directory. Recursively `copy-out` to the destination parent inside a subshell retaining `exec -a virt-sh`; then rename the source basename with native `mv -T` when necessary. A failed copy stops that helper Bash before rename and the outer loop continues independently. Each copy starts a separate guestfish session; the parent helper Bash survives the subshell exec to rename and reach its final `true`.
- Test `/tmp/bsod--guest-files--<epoch>/` inside the helper, then stream helper `tar zc` to runner `guest-fs--crash-info--<partition>.tgz` and stop scanning partitions. The temporary name has no PID suffix. Directory existence does not prove any file copied: all failed copies can leave an empty archive. Tar failure can leave partial archive bytes on the runner; no transactional cleanup is claimed.
- Archive-only output has no loose EVTX or implicit unpacking. The extractor final validator is commented out, so missing/empty archives can return zero. The separate watcher `natural-rhov` validator still requires loose EVTX and can fail on a valid archive. The extractor no longer generates JSON or checksums.
- Do not invoke the commented final `reliability.py write-summary` call or write a fresh `extraction-summary.json`

**Optional offline tool (archived)**:
- `extract-evtx.py` can parse extracted `.evtx` files into crash-detection JSON; it is not called by the active pipeline and requires `python-evtx`.
- Inline python-evtx parser → `EventLogs/System.json`, `Application.json`

**Output structure**:
```
guest-fs--crash-info--<partition>.tgz  (archive members: Windows/System32/winevt/Logs/*.evtx)
```

**Offline analysis**: EVTX files are archive members, not loose `guestFS_*` outputs. Unpack manually into a separate directory before using the archived parser. Raw pagefile.sys bytes may be archived as MEMORY.DMP; this is not conversion or validation of a Windows dump. DedicatedDump.sys and Minidump/ are not requested; no platform-specific dump availability or verdict is promised here. KubeVirt memory capture is a separate fallible watcher operation.

**Environment Variables**:

| Variable | Purpose |
|---|---|
| `BSOD_DET__COMMAND__TIMEOUT` | Command timeout (default: 30s) |
| `BSOD_DET__EXTRACT_EVTX__BIN` | Legacy override referenced only by the commented parser hook; the active pipeline does not use it |
| `BSOD_DET__DATA__DIR` | Legacy override referenced only by the commented parser hook; active pipeline does not use it |
| `BSOD_DET__GUEST_FS__CTR_IMG` | `virtctl guestfs` image; unset or empty uses the pinned tag, no legacy fallback |

---

### `guest-agent.py`

**Purpose**: Run commands in the Windows guest through the qemu-guest-agent (QGA), without SSH or guest credentials.

**How it works**: a KubeVirt VM is not reachable over SSH without extra network configuration, but `virsh` inside the VM's
virt-launcher Pod talks to the QGA. Each agent call is one `oc exec`, and `guest-exec` programs run in the guest as
`nt authority\system` (fully elevated):
```
oc --request-timeout=<t>s exec -n <namespace> <virt-launcher-pod> -- \
    virsh qemu-agent-command --timeout <t> <domain> '<QMP JSON>'
  → qemu-guest-agent (Windows)
    → PowerShell / program execution
```

**Usage** (running `guest-agent.py` without arguments prints a short usage summary and exits 2):
```
guest-agent.py ping
guest-agent.py exec <program> [args...]
guest-agent.py exec-crash <program> [args...]
guest-agent.py put <localPath> <guestPath>
guest-agent.py psfile <local.ps1> [<psArgs...>]
guest-agent.py psfile <local.ps1> [--companion <localPath> <guestPath>]... [-- <psArgs...>]
```

| Subcommand | Behavior and agent timeouts |
|---|---|
| `ping` | `guest-ping` (10s); prints the agent reply (`{}`) |
| `exec` | `guest-exec` (300s), then a `guest-exec-status` poll (300s) every 3s for up to 600s. Status-poll errors are retried until 10s or less of the window remain; a failed launch or exhausted retries exit 1. Relays the program's stdout/stderr and exits with its exit code |
| `exec-crash` | `guest-exec` (20s) must return a PID, then a status poll (5s) every second for `BSOD_TRIGGER_CONFIRM_TIMEOUT` seconds (default 45). An agent error after the launch is the expected crash signal: it prints `{"disconnected": true, "message": "...", "pid": <pid>}` and exits 0. A failed launch exits 1 and is never reported as a disconnect; a program that exits first is relayed like `exec`; one still running at the end of the window exits 124 |
| `put` | `guest-file-open` (300s), one `guest-file-write` (600s) per 64 KiB chunk (about 85 KiB of base64, which keeps each `oc exec` argument within the argument-size limit), `guest-file-close` (300s, also after a failed write). Logs progress every 50 MiB and prints `wrote <bytes> bytes -> <guestPath>` |
| `psfile` | Uploads the script to `C:\Windows\Temp\<file name>` (`/` and `\` separators both work), then each companion to its explicit guest path, then runs `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <script> [args]` like `exec` (600s window). Script arguments follow the script directly; after `--companion` entries, `--` starts them |

**Target resolution** (once per invocation; nothing is shared between runs):
1. Values set in the environment take precedence.
2. A `<namespace>_<vm>` domain name supplies a missing namespace or VM name (Kubernetes names never contain `_`).
3. A still-missing VM name is discovered with `oc get vmi` (in the namespace when known, otherwise `-A`); exactly one
   VirtualMachineInstance must be in scope.
4. The namespace must be known by then. The domain defaults to `<namespace>_<vm>`, and the Pod to the first Pod in the
   namespace whose name starts with `virt-launcher-<vm>-` (`oc get pod -o name`).

Discovery reads use `oc --request-timeout=20s` (25s local limit), and any failed read (missing client, expired login,
timeout) counts as empty output. Target problems therefore print an actionable `guest-agent: <message>` error (with
several VirtualMachineInstances in scope, the candidates follow on indented lines), for example
`guest-agent: no VirtualMachineInstance found; set BSOD_DET__VM__NAME (and BSOD_DET__NAMESPACE)`, and exit 1 before any
agent call.

**Environment Variables** (read once per invocation):

| Variable | Purpose |
|---|---|
| `BSOD_DET__VM__NAME` | Target VM name (the only VMI in scope is used if unset) |
| `BSOD_DET__NAMESPACE` | Kubernetes namespace |
| `BSOD_DET__POD__NAME` | Virt-launcher pod (auto-resolved if unset) |
| `BSOD_DET__DOMAIN__NAME` | Libvirt domain name (auto-derived as `<ns>_<vm>`) |
| `BSOD_TRIGGER_CONFIRM_TIMEOUT` | `exec-crash` confirmation window in seconds (default 45); predates the `BSOD_DET__` naming convention |

**Exit Status**:

| Status | Meaning |
|---|---|
| guest code | `exec`, `exec-crash` and `psfile` exit with the low 8 bits of the guest exit code, which the script does not remap: `0xC0000005` exits 5, a multiple of 256 such as `0x100` exits 0 (success), and a code can coincide with a status below |
| 0 | `ping`/`put` succeeded, or `exec-crash` observed the expected agent loss |
| 1 | Target error, agent error, or another unhandled error (unreadable local file, non-integer `BSOD_TRIGGER_CONFIRM_TIMEOUT`, `exec`/`psfile` status-poll errors until the end of the window); unhandled errors print a traceback |
| 2 | Usage error: no or unknown subcommand, missing program or script, missing `put` local or guest path, malformed `--companion` list |
| 124 | The guest program did not exit within its wait window |
| 125 | The guest reported an exit without an exit code |

**Examples** (the forms used by `trigger-bsod-intentional.sh` and `preflight-rhov.sh`, which wrap every call in `timeout`):
```bash
export BSOD_DET__NAMESPACE=windows-bsod BSOD_DET__VM__NAME=win2022
guest-agent.py ping
guest-agent.py put notmyfaultc64.exe 'C:\Temp\nmf\notmyfaultc64.exe'
guest-agent.py exec powershell.exe -NoProfile -Command \
  "(Get-Item 'C:\Temp\nmf\notmyfaultc64.exe' -ErrorAction SilentlyContinue)?.Length"
guest-agent.py psfile configure-dumps.ps1 --companion crash-control.json 'C:\Windows\Temp\crash-control.json' -- \
  -DataFile 'C:\Windows\Temp\crash-control.json'
guest-agent.py exec-crash 'C:\Temp\nmf\notmyfaultc64.exe' /accepteula /crash <crashType>
```

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

**Note**: The current extractor does not call this parser or write parse-dump-header.json. Developers may run the parser separately against an independently obtained compatible dump; raw pagefile bytes renamed MEMORY.DMP are not a converted dump.

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

**Note**: `dump` is not a required type in these modes. The current extractor does not extract dumps; this policy is not a platform-availability guarantee.

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
archive=/path/to/guest-fs--crash-info--PARTITION.tgz
mkdir -p "$run_dir/offline-guest-files"
tar -xzf "$archive" -C "$run_dir/offline-guest-files"
python3 apps/bsod-detector/archieve/src/scripts/host/extract-evtx.py \
  --data-dir apps/bsod-detector/src/data \
  "$run_dir"/offline-guest-files/Windows/System32/winevt/Logs/*.evtx
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
  │    │    ├─ Independent readonly guestfish copy-out per file
  │    │    ├─ Stream mapped guest-fs--crash-info--<partition>.tgz
  │    │    └─ EXIT cleanup once (no final summary invocation)
  │    ├─ RestartVM
  │    └─ write evidence-summary.json
  │
  └─ Inject BSOD via guest-agent.py exec-crash C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash <type> after watcher readiness
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
domain-bsod.xml               Libvirt domain XML captured at crash moment (state=crashed/paused)
domain.xml                    Pre-crash backup from Phase 2b
host-signals.json             Host KVM diagnostics
launcher-compute.log          virt-launcher pod logs
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
| `FindNTFS()` | Read filesystem discovery from the required helper pod/container |
| `Cleanup()` | EXIT-only: close virtctl stdin, reap it, delete `hlprPod` if virtctl ran when cleanup began |

#### Extraction Flow

1. Read the five required metadata fields and create the shared output directory.
2. Require target VM printableStatus Stopped; process-substitution producer status is not propagated.
3. Reject a pre-existing helper, start the `virtctl guestfs` coprocess, then wait for its Pod to exist and be Ready.
4. Probe each NTFS partition, independently copy requested EVTX files in the helper, then stream `guest-fs--crash-info--<partition>.tgz`.
5. Leave only `# Python Code to parse MEMORY.DMP` as a placeholder; no parser, JSON or checksum generation is performed.
6. Skip the commented final summary validator; run EXIT cleanup once. Native errors remain visible, but zero is not extraction-completeness proof.

Output, when its stage succeeds: `guest-fs--crash-info--<partition>.tgz`. It may include raw pagefile.sys bytes named MEMORY.DMP; this rename is not conversion or validation as a Windows dump. No JSON/parser/checksum files, fresh extraction summary, loose EVTX or extraction log are produced. Existing watcher outputs are left unchanged.

---

### guest-agent.py

**Purpose**: Tunnel PowerShell commands into Windows VM via QEMU Guest Agent. Usage, timeouts, target resolution and exit
statuses are described in the [script overview](#guest-agentpy) above.

#### Key Functions

| Function | Purpose |
|----------|---------|
| `TargetError` | Raised when the guest target cannot be identified unambiguously |
| `GuestTarget` | Immutable resolved namespace, VM, virt-launcher Pod and libvirt domain |
| `RunOC()` | Execute a bounded OpenShift CLI read, return stdout or empty string |
| `FindLauncherPod()` | Find virt-launcher pod for a given VM in namespace |
| `Log()` | Write one diagnostic line to STDERR |
| `ExitedResult()` | Decode an exited guest-exec-status reply into exit code, stdout and stderr |
| `GuestAgent.FromEnvironment()` | Create a client from the `BSOD_DET__*` target variables |
| `GuestAgent.ResolveTarget()` | Resolve namespace, VM, Pod and domain once; cache the `GuestTarget` on that instance |
| `GuestAgent.SendCommand()` | Send QEMU agent command via virsh; return the decoded `return` payload |
| `GuestAgent.LaunchProgram()` | Start a guest program with captured output; return its PID |
| `GuestAgent.GetExecStatus()` | Return the raw guest-exec-status reply for a PID |
| `GuestAgent.GuestExec()` | Execute program in guest and wait for completion |
| `GuestAgent.GuestExecCrash()` | Execute crash program; handle disconnect as success |
| `GuestAgent.GuestPut()` | Upload local file to guest (64 KiB chunks via base64) |
| `PrintExecResult()` | Output guest command results (stdout, stderr); return exit code |
| `ParsePSfileArgs()` | Parse companion file uploads and PowerShell arguments |
| `Main()` | Parse CLI commands and dispatch to above functions |

#### Design Notes

- **Target state**: `Main()` builds one `GuestAgent` per invocation from the environment. The resolved `GuestTarget` is
  cached on that instance only, and only after a complete resolution, so a failed resolution is retried; the module holds
  no mutable state.
- **Error types**: `TargetError` (configuration) deliberately does not derive from `RuntimeError`. `RuntimeError` means an
  agent or transport failure: `GuestExec()` retries it during status polling (a failed launch is not retried and exits 1)
  and `GuestExecCrash()` treats it, after a confirmed launch, as the crash signal. Keeping the types separate makes this
  explicit; the target is resolved before any polling starts. `Main()` turns `TargetError` into exit 1.
- **Discovery reads**: `RunOC()` folds every `oc` failure into empty output, so discovery reports one actionable
  `TargetError` instead of a client traceback.
- **Timeouts**: `SendCommand()` passes its timeout to both `oc --request-timeout` and `virsh --timeout`; the local subprocess
  limit is 5s longer, so virsh reports its own timeout first.
- **Output decoding**: `ExitedResult()` decodes the base64 `out-data`/`err-data` and replaces undecodable bytes, so a crash
  tool's partial output is still reported.

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
archive=/path/to/guest-fs--crash-info--PARTITION.tgz
mkdir -p "$run_dir/offline-guest-files"
tar -xzf "$archive" -C "$run_dir/offline-guest-files"
python3 apps/bsod-detector/archieve/src/scripts/host/extract-evtx.py \
  --data-dir apps/bsod-detector/src/data \
  "$run_dir"/offline-guest-files/Windows/System32/winevt/Logs/*.evtx
```

**Requires**: `pip install python-evtx`

**Note**: This is a developer tool archived for offline use. The extractor no longer writes `events.json`; developers run this manually against extracted `.evtx` files.
