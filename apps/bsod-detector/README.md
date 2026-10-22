# BSOD Detector

Detect, capture, and analyze Blue Screen of Death (BSOD) events on Windows VMs running under KubeVirt / OpenShift Virtualization (RHOV).

---

## What the Pipeline Does

1. **Preflight** — validates cluster state, VM configuration, QGA liveness, and crash dump registry settings before arming
2. **Detects** BSOD by polling QEMU Guest Agent; corroborates via `virsh domstate` and pvpanic events
3. **Captures** full physical memory via `virtctl memory-dump` → `vm-memory.elf.tar.gz` (primary artifact)
4. **Extracts** offline forensics from the stopped VM disk via guestfish NTFS mount:
   - Windows EventLogs (`System.evtx`, `Application.evtx`)
   - VNC screenshot of the blue screen
   - Domain XML captured at crash moment
   - `MEMORY.DMP` streamed from `DedicatedDump.sys`
   - All files in `C:\Windows\Minidump\`
5. **Validates** all artifacts and generates `evidence-summary.json` with `ok: true/false`

---

## Quick Start

```bash
export BSOD_DET__VM__NAME=<your-vm-name>
export BSOD_DET__NAMESPACE=<your-namespace>
export BSOD_DET__CONFIRM_TARGET=<your-vm-name>
export BSOD_DET__RECOVERY__IMAGE="quay.io/konveyor/oadp-vmfr-access:latest@sha256:<digest>"

# Get current digest:
# skopeo inspect docker://quay.io/konveyor/oadp-vmfr-access:latest | jq -r '.Digest'

bash src/scripts/crash-injector/trigger-bsod-intentional.sh 0x01
```

Check result:
```bash
run=$(ls -t /mnt/persistent-bsod-evidence/ | head -1)
jq '{ok, stageErrors, missingRequiredArtifactTypes}' \
  /mnt/persistent-bsod-evidence/$run/evidence-summary.json
```

---

## Architecture

```
trigger-bsod-intentional.sh
  │
  ├── Phase 1a: Pre-cleanup — delete stale DVs/PVCs from previous failed runs
  ├── Phase 1b: Validate notmyfaultc64.exe binary exists on host
  ├── Phase 2:  preflight-rhov.sh
  │               ├── Auto-create memory-dump PVC if missing
  │               ├── Auto-create evidence PVC if missing
  │               ├── QGA ping (5 retries)
  │               ├── Crash dump registry validation (rebootRequired=false)
  │               └── Write recovery-metadata.json
  ├── Phase 2b: Add pvpanic device via QMP + pre-capture domain.xml + vmi-spec.json
  ├── Phase 2c: Upload notmyfaultc64.exe to VM via QGA
  ├── Phase 3:  Guest cleanup — remove stale MEMORY.DMP and Minidump files
  ├── Phase 4:  watch-crash.sh (background)
  │               ├── Poll QGA every 5s → BSOD detected
  │               ├── Capture domain-bsod.xml at crash moment (always overwrites)
  │               ├── CaptureMemory → vm-memory.elf.tar.gz (progress-monitored)
  │               ├── CaptureScreenshot, CaptureHostSignals
  │               ├── WaitDumpMonitor (disk write quiescence)
  │               ├── StopVM
  │               ├── extract-crash-info.sh (offline NTFS extraction)
  │               └── RestartVM → evidence-summary.json
  ├── Phase 5:  Wait for watcher readiness
  ├── Phase 6:  Inject BSOD via notmyfaultc64.exe /crash <type>
  └── Phase 7:  Delete memory-dump and evidence PVCs (auto-recreated on next run)
```

---

## Evidence Artifacts

Every pipeline run produces a timestamped directory under `/mnt/persistent-bsod-evidence/`:

| File | Size | Phase | Description |
|---|---|---|---|
| `recovery-metadata.json` | ~1.2 KB | Pre-BSOD | VM name, namespace, PVC names, storage class, recovery image digest, armed epoch |
| `watcher-ready` | 42 B | Pre-BSOD | Arming marker — written when watcher begins polling |
| `vmi-spec.json` | ~13 KB | Pre-BSOD | KubeVirt VMI spec via `oc get vmi -o json` — available even when virt-launcher pod is Failed |
| `domain.xml` | ~13 KB | Pre-BSOD | Pre-crash domain XML backup captured before injection |
| `bsod-screenshot.png` | ~16 KB | At BSOD | VNC screenshot of the Windows blue screen |
| `vm-memory.elf.tar.gz` | 1.5–2.5 GB | At BSOD | **Primary dump artifact.** Full physical RAM in ELF ET_CORE format via KubeVirt. Always works — captured at hypervisor level, independent of Windows pagefile state |
| `domain-bsod.xml` | ~13 KB | At BSOD | Libvirt domain XML captured at crash detection time (state=crashed/paused) |
| `launcher-compute.log` | 100–400 KB | At BSOD | Raw QEMU/KVM compute container logs |
| `host-signals.json` | ~1.3 KB | At BSOD | Parsed KVM signals — split-lock traps, KVM errors, Hyper-V feature states |
| `guestFS_sda3/.../System.evtx` | ~2 MB | After stop | Windows System EventLog — contains crash Event 1001 (BugCheck code + parameters) |
| `guestFS_sda3/.../Application.evtx` | ~2–3 MB | After stop | Windows Application EventLog |
| `guestFS_sda3/domain-guestfs.xml` | ~13 KB | After stop | Copy of domain-bsod.xml placed alongside extracted files for forensic comparison |
| `MEMORY.DMP` | 0–7.9 GB | After stop | Extracted from `DedicatedDump.sys` via guestfish stdout streaming. Zero-filled on KVM/VirtIO — `StorPortGetUncachedExtension` fails in crash dump miniport mode ([virtio-win #1629](https://github.com/virtio-win/kvm-guest-drivers-windows/issues/1629)) |
| `Minidump/` | varies | After stop | All files from `C:\Windows\Minidump\`. Zero-filled on KVM/VirtIO for the same reason |
| `parse-dump-header.json` | ~300 B | After stop | Bugcheck code when MEMORY.DMP has valid content; stub with `vm-memory.elf.tar.gz` usage note when zero-filled |
| `events.json` | ~160 B | After stop | Stub — run `extract-evtx.py` offline against `guestFS_*/.../*.evtx` |
| `checksums.sha256` | ~1 KB | After stop | SHA-256 manifest of all evidence files |
| `extraction.log` | 3–10 KB | After stop | Guestfish extraction trace |
| `extraction-summary.json` | ~3 KB | After stop | Recovery phase artifact inventory with validation |
| `stage-errors.jsonl` | 0 B (success) | Throughout | One JSON line per stage failure. Empty on clean run |
| `evidence-summary.json` | ~3 KB | End | Final pipeline verdict — `ok: true/false`, artifact inventory, stage errors |
| `watcher.log` | 500 KB–1 MB | Throughout | Full timestamped execution trace |

**Partition name** (`sda3`) is detected dynamically every run — never hardcoded.

---

## Platform Constraints — MEMORY.DMP and Minidump

Windows crash dump miniport mode calls `StorPortGetUncachedExtension` to allocate DMA buffers. On KVM/VirtIO this call returns `SP_RETURN_ERROR` — no bytes are written to `DedicatedDump.sys`. This affects all VirtIO storage drivers on this platform ([virtio-win issue #1629](https://github.com/virtio-win/kvm-guest-drivers-windows/issues/1629)).

`MEMORY.DMP` and `Minidump/` are always extracted and present in the evidence directory, but contain zeros. They do **not** cause `ok=false` — `dump` is not a required artifact type.

**Primary artifact:** `vm-memory.elf.tar.gz` (hypervisor-level ELF dump) is always captured and provides equivalent forensic data. Convert offline with `elf2dmp` for WinDbg/Volatility.

---

## Offline Analysis (Developer Tools)

These are **not called by the pipeline** — run manually on captured artifacts. The EVTX parser is archived; it is not shipped in the active script tree.

```bash
# Convert ELF → Windows DMP for WinDbg / Volatility
tar -xzf vm-memory.elf.tar.gz
elf2dmp [inner-elf-file] memory-windows.dmp

# Volatility3 analysis
vol -f memory-windows.dmp windows.info.Info
vol -f memory-windows.dmp windows.crashinfo.CrashInfo
vol -f memory-windows.dmp windows.driverscan.DriverScan

# Parse Windows EventLogs → JSON (crash detection)
pip install python-evtx
run_dir=/path/to/run
python3 apps/bsod-detector/archieve/src/scripts/host/extract-evtx.py \
  --data-dir apps/bsod-detector/src/data \
  "$run_dir"/guestFS_*/Windows/System32/winevt/Logs/*.evtx
```

---

## Golden Image Setup

Run these scripts inside the VM **before sealing the image**. One reboot required.

```powershell
# Step 1: Pre-reboot setup (run as Administrator — auto-reboots at end)
# Installs: QGA, viostor, vioscsi, pvpanic drivers from virtio-win ISO
# Configures: recovery disable, crash dump registry,
#             DedicatedDump.sys (RAM + 1MB), pagefile.sys (4GB)
.\src\scripts\guest\golden-image-pre-reboot.ps1

# Step 2: Post-reboot verification (run as Administrator)
# Verifies 9 checks — all must pass before sealing
.\src\scripts\guest\golden-image-post-reboot.ps1
```

**Download note:** Use `.NET WebClient` to download the virtio-win ISO — `curl.exe` and BITS both fail in the VM context:
```powershell
$wc = New-Object System.Net.WebClient
$wc.DownloadFile("https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso", "C:\Temp\virtio-win.iso")
```

**Driver compatibility:** All three storage drivers (viostor, vioscsi, storahci) are installed in the image. Windows PnP activates only the one matching the hardware presented at boot — installing all three has no impact on VM operations.

---

## Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `BSOD_DET__VM__NAME` | **Yes** | — | Target VM name — no default |
| `BSOD_DET__NAMESPACE` | **Yes** | — | Kubernetes namespace — no default |
| `BSOD_DET__CONFIRM_TARGET` | **Yes** | — | Must equal `BSOD_DET__VM__NAME` — authorization guard against wrong-VM crashes |
| `BSOD_DET__EVIDENCE__DIR` | No | `/mnt/persistent-bsod-evidence` | Evidence storage root |
| `BSOD_DET__RECOVERY__IMAGE` | No | — | Digest-pinned guestfs recovery image (`image@sha256:...`) |
| `BSOD_DET__SNAPSHOT__CLASS` | No | `ocs-storagecluster-rbdplugin-snapclass` | Storage snapshot class |
| `BSOD_DET__MEMORY__DUMP_PVC` | No | `<vm>-memdump` | Memory dump PVC name (auto-created if missing) |
| `BSOD_DET__EVIDENCE__STORAGE_SIZE` | No | `200Gi` | Evidence PVC size when auto-created |
| `BSOD_DET__COMMAND__TIMEOUT` | No | `30` | oc command timeout in seconds |
| `BSOD_DET__READY__TIMEOUT` | No | `300` | Watcher readiness timeout in seconds |
| `BSOD_DET__PREFLIGHT__TIMEOUT` | No | `300` | Preflight timeout in seconds |
| `BSOD_DET__GUESTFS__NTFS_IMAGE` | No | `quay.io/konveyor/oadp-vmfr-access:latest` | guestfs-ntfs pod image override |

---

## Diagnosing Failures

```bash
run=/mnt/persistent-bsod-evidence/<run-id>

# Final verdict
jq '{ok, stageErrors, missingRequiredArtifactTypes, invalidArtifacts}' $run/evidence-summary.json

# Stage-by-stage errors
cat $run/stage-errors.jsonl | jq .

# Extraction phase
jq '{ok, stageErrors, missingRequiredArtifactTypes}' $run/extraction-summary.json
tail -30 $run/extraction.log

# Full timeline
grep -E "ERROR|WARN" $run/watcher.log
```

| Symptom | Likely cause | Fix |
|---|---|---|
| `rebootRequired=true` in preflight | Crash dump settings changed — reboot pending | `virtctl stop <vm> -n <ns> && virtctl start <vm> -n <ns>` |
| `recovery-image capability probe timed out` | Recovery image digest is stale (image updated in registry) | Get new digest: `skopeo inspect docker://quay.io/konveyor/oadp-vmfr-access:latest \| jq -r '.Digest'` |
| `QGA ping failed after 5 retries` | QEMU-GA not running in VM | Start QEMU-GA service: `Start-Service QEMU-GA` |
| `vm-memory.elf.tar.gz` missing | virtctl vmexport download stalled or failed | Check `watcher.log`; pipeline has 5-min stall detection |
| `MEMORY.DMP` zero-filled | KVM/VirtIO StorPort crash dump limitation (expected) | Use `vm-memory.elf.tar.gz` + `elf2dmp` for analysis |
| `download stalled (no writes for 5 min)` | Network/cluster I/O issue during transfer | Re-run pipeline |
| Evidence PVC missing | First run on fresh cluster | Auto-created by preflight — no action needed |
| `CloneSourceInUse` on DV creation | Source PVC attached to running VM | Stop the source VM temporarily to allow CSI clone to proceed |

---

## Directory Structure

```
apps/bsod-detector/
├── README.md
└── src/
    ├── data/
    │   ├── crash-control.json              # CrashControl registry source of truth
    │   ├── bugcheck-codes.json             # Windows bugcheck code database
    │   └── event-sources.json              # EventLog source definitions
    └── scripts/
        ├── crash-injector/
        │   ├── README.md
        │   ├── trigger-bsod-intentional.sh # Pipeline entry point
        │   └── notmyfaultc64.exe           # BSOD injection binary
        ├── host/
        │   ├── README.md
        │   ├── watch-crash.sh              # BSOD detection + memory capture
        │   ├── preflight-rhov.sh           # Pre-run validation
        │   ├── extract-crash-info.sh       # Offline NTFS extraction
        │   ├── guest-agent.py              # QGA PowerShell tunnel
        │   ├── parse-dump-header.sh        # Bugcheck code extraction
        │   ├── reliability.py              # Artifact validation + summary
        │   ├── extract-evtx.py             # EventLog → JSON (developer tool)
        │   └── collect-host-signals.sh     # KVM/Hyper-V signal parser
        └── guest/
            ├── README.md
            ├── configure-dumps.ps1         # Windows crash dump config (runtime)
            ├── clear-dumps.ps1             # Pre-test cleanup
            ├── golden-image-pre-reboot.ps1 # Golden image setup (run before reboot)
            └── golden-image-post-reboot.ps1# Golden image verification (run after reboot)
```
