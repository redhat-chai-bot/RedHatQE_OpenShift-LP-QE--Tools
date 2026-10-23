# BSOD Detector

Detect, capture, and analyze Blue Screen of Death (BSOD) events on Windows VMs
running under KubeVirt / OpenShift Virtualization (RHOV).

---

## What the Pipeline Does

1. **Detects** suspected BSODs after the QGA miss threshold. Capture requires corroborating domain/VMI and launcher-pod evidence, or a current KubeVirt `Panicked` event. These signals identify an unresponsive guest; they do not independently prove a Windows bug-check.
2. **Captures** full physical memory via `virtctl memory-dump` → `vm-memory.elf.tar.gz`
3. **Captures** a VNC screenshot, libvirt domain XML, and launcher logs/host signals around the crash; after stopping the VM, extracts Windows EventLogs (`System.evtx`, `Application.evtx`) via guestfish NTFS read.
4. **Validates** all artifacts and generates `evidence-summary.json`

---

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│               CI / Orchestration Host                       │
│           trigger-bsod-intentional.sh                       │
└────────┬───────────────────────────────────────────────────┘
         │
   ┌─────▼──────┐     ┌─────────────────┐     ┌────────────────────┐
   │ preflight  │     │  watch-crash.sh │     │extract--guest-os-- │
   │ -rhov.sh   │──►  │  (background)   │──►  │crash-info.sh       │
   └─────┬──────┘     └────────┬────────┘     └──────────┬─────────┘
         │                     │                          │
   QGA ping             virtctl memory-dump          guestfs-ntfs pod
   configure-dumps      VNC screenshot               guestfish NTFS mount
   recovery-metadata    domain.xml / host-signals    oc cp → evidence dir
```

---

## Evidence Directory Contents

By default, each pipeline run writes under `/mnt/persistent-bsod-evidence/`; `BSOD_DET__EVIDENCE__DIR` can select another validated persistent evidence mount:

| File | Typical Size | Phase | Produced by | Description |
|---|---|---|---|---|
| `recovery-metadata.json` | ~1.3 KB | Pre-BSOD | `preflight-rhov.sh` | VM name, namespace, PVC names, storage class, recovery image digest, armed epoch |
| `watcher-ready` | 42 B | Pre-BSOD | `watch-crash.sh` | Arming marker — written when watcher begins polling |
| `bsod-screenshot.png` | ~37 KB | At BSOD (VM frozen) | `watch-crash.sh` → `virtctl vnc screenshot` | VNC screenshot of the Windows blue screen |
| `vm-memory.elf.tar.gz` | ~1.5 GB | At BSOD (VM frozen) | `watch-crash.sh` → `virtctl memory-dump get` + `virtctl vmexport download --format gzip` | **Primary memory artifact when capture succeeds.** KubeVirt exports physical RAM in ELF ET_CORE format independently of guest disk/pagefile state; API, PVC, export, or download failures are recorded and validated. Run `elf2dmp` offline to convert for WinDbg / Volatility |
| `domain.xml` | ~14 KB | At BSOD (VM frozen) | `watch-crash.sh` → `virsh dumpxml` inside virt-launcher | Complete libvirt XML at crash time — CPU, memory, disks, devices. Richer than `oc get vmi -o yaml` |
| `launcher-compute.log` | ~100–200 KB | At BSOD (VM frozen) | `watch-crash.sh` → `oc logs` on virt-launcher | Raw QEMU/KVM compute logs — split-lock traps, KVM internal errors, device events |
| `host-signals.json` | ~1.3 KB | At BSOD (VM frozen) | `watch-crash.sh` → `collect-host-signals.sh` | Parsed from `launcher-compute.log` — split-lock count, KVM error count, Hyper-V feature states (tlbflush/ipi/vapic/spinlocks/synictimer), risk assessment |
| `guestFS_sda3/Windows/System32/winevt/Logs/System.evtx` | ~8–9 MB | After VM stopped | `extract--guest-os--crash-info.sh` → guestfs-ntfs pod | Windows System EventLog from NTFS. Contains crash event 1001 (BugCheck), dirty shutdown 6008. Partition name (`sda3`) is **detected dynamically** |
| `guestFS_sda3/Windows/System32/winevt/Logs/Application.evtx` | ~6 MB | After VM stopped | `extract--guest-os--crash-info.sh` → guestfs-ntfs pod | Windows Application EventLog — Application/1001 LiveKernelEvent and app-level crash events |
| `parse-dump-header.json` | ~146 B | After VM stopped | `extract--guest-os--crash-info.sh` | Parses a readable on-disk dump if present; otherwise writes a no-dump stub. The ELF-to-Windows-DMP conversion is disabled in the pipeline. |
| `events.json` | ~162 B | After VM stopped | `extract--guest-os--crash-info.sh` | Stub. The EVTX parser is archived at `apps/bsod-detector/archieve/src/scripts/host/extract-evtx.py`; its lookup data is maintained in active `apps/bsod-detector/src/data`. |
| `checksums.sha256` | ~900 B | After VM stopped | `extract--guest-os--crash-info.sh` | SHA-256 manifest of all evidence files (integrity verification) |
| `extraction-summary.json` | ~3 KB | After VM stopped | `reliability.py write-summary` | Recovery phase artifact inventory — type, format, size, sha256, valid flag per file |
| `stage-errors.jsonl` | 0 B (success) | Throughout | `watch-crash.sh` | Watcher stage failures. Extraction does not append entries; native extraction output is inherited by the watcher log. |
| `evidence-summary.json` | ~3 KB | End of pipeline | `watch-crash.sh` → `reliability.py write-summary` | Final pipeline verdict: `ok: true/false`, missing artifact types, invalid artifacts |
| `watcher.log` | ~100–120 KB | Throughout | `watch-crash.sh` | Full timestamped execution trace of the entire pipeline |

**Timing overview**:
```
Pre-BSOD     → recovery-metadata.json, watcher-ready
At BSOD      → bsod-screenshot.png, vm-memory.elf.tar.gz (~5–10 min),
               domain.xml, launcher-compute.log, host-signals.json
After stop   → guestFS_sda3/.../System.evtx, Application.evtx,
               parse-dump-header.json, events.json, checksums.sha256,
               extraction-summary.json
End          → stage-errors.jsonl, evidence-summary.json, watcher.log
```

---

## Evidence Artifacts Deep Dive

This section explains what each artifact contains and how to use it, with examples from a real pipeline run: `/mnt/persistent-bsod-evidence/20261013T070250Z-intentional-837674-22539`

### Pre-Crash Configuration

#### `recovery-metadata.json` (1.3 KB)
**What it contains**: Preflight validation results and infrastructure snapshot at pipeline start.

**Example fields**:
```json
{
  "runId": "20261013T070250Z-intentional-837674-22539",
  "namespace": "windows-bsod",
  "vm": "win2022-vm-hjoshi1",
  "launcherPod": "virt-launcher-win2022-vm-hjoshi1-vtfdn",
  "domain": "windows-bsod_win2022-vm-hjoshi1",
  "node": "integrity-gs04.sys.eng.rdu2.dc.redhat.com",
  "memoryDumpPvc": "win2022-vm-hjoshi1-memdump",
  "snapshotClass": "ocs-storagecluster-rbdplugin-snapclass",
  "recoveryImage": "image-registry.../bsod-recovery:latest@sha256:4f46...",
  "armedEpoch": 1791875063
}
```

**Use cases**:
- Verify target VM and namespace correctness
- Find exact launcher pod for manual debugging
- Confirm recovery image version (for reproducibility)
- Track infrastructure (node, storage class, snapshot class)

#### `watcher-ready` (42 B)
**What it contains**: Run ID; written when crash detection polling begins.

**Purpose**: Signals that the VM is armed and polling for BSOD events.

---

### Crash Evidence (Captured At BSOD)

#### `bsod-screenshot.png` (37 KB — PNG, 1280×800)
**What it contains**: VNC screenshot of Windows blue screen at crash time.

**Visual verification**:
- Blue screen appears → confirms BSOD was captured visually
- Windows error code visible (if legible) → helps forensic analysis
- Desktop state frozen → confirms VM-in-crash state

**How to view**:
```bash
file bsod-screenshot.png  # Verify PNG format
display bsod-screenshot.png  # View in X11
scp evidence/.../bsod-screenshot.png . && open bsod-screenshot.png
```

#### `vm-memory.elf.tar.gz` (787 MB — Gzipped TAR of ELF ET_CORE)
**What it contains**: **Full physical RAM dump** in ELF ET_CORE format.

**Example metadata**:
```
Format:  tar.gz[elf]
Size:    824,374,006 bytes (~824 MB)
Type:    memory
Valid:   true
SHA256:  077051eba4d8a9f9d6ed8059dadd38e875c2ca2d151472bd701bbe0d82b8fd89
```

**What's inside**:
```bash
tar -tzf vm-memory.elf.tar.gz
  # Output example:
  # 20261013T070250Z-intentional-837674-22539/memory.dump
  # (ELF core file containing full 16GB physical RAM)
```

**How to analyze**:
```bash
# 1. Extract the raw ELF file from the export archive
inner_file=$(tar -tzf vm-memory.elf.tar.gz | grep -i '\.memory\.dump$' | head -1)
tar -xzf vm-memory.elf.tar.gz -O "$inner_file" > memory.dump

# 2. Convert ELF → Windows DMP (offline, requires elf2dmp)
elf2dmp memory.dump memory-windows.dmp

# 3. Analyze with Volatility3
vol -f memory-windows.dmp windows.info.Info
vol -f memory-windows.dmp windows.crashinfo.CrashInfo
vol -f memory-windows.dmp windows.driverscan.DriverScan
```

**Why this is primary**: KubeVirt captures RAM directly from QEMU, independent of Windows pagefile, BSOD staging, or reboot state. Capture still depends on the KubeVirt API, PVC, export, and download stages succeeding; failures are recorded and validated.

#### `domain.xml` (14 KB — Libvirt domain definition)
**What it contains**: Complete QEMU/KVM configuration at crash time.

**Key sections**:
```xml
<domain type='kvm' id='1'>
  <name>windows-bsod_win2022-vm-hjoshi1</name>
  <uuid>01ef375f-60c1-44d5-94a9-c91122957409</uuid>
  <memory unit='KiB'>16777216</memory>  <!-- 16 GB -->
  <currentMemory unit='KiB'>16777216</currentMemory>
  <vcpu placement='static' current='4'>16</vcpu>
  <cpu>
    <model fallback='allow'>EPYC-Genoa</model>
    <feature policy='require' name='topoext'/>
    <!-- CPU flags at crash time -->
  </cpu>
  <devices>
    <emulator>/usr/libexec/qemu-kvm</emulator>
    <disk type='block' device='disk'>
      <!-- Block device mappings, PVCs, images -->
    </disk>
    <interface type='bridge'>
      <!-- Network devices, MAC addresses -->
    </interface>
    <balloon model='virtio'>
      <!-- VirtIO balloon config -->
    </balloon>
  </devices>
</domain>
```

**Forensic value**:
- CPU model and flags → determine instruction set capabilities
- Memory and vCPU counts → validate test environment configuration
- Device order → map disk devices to Windows mount points
- BIOS/UEFI settings → secure boot state, firmware version
- PCI device assignments → hardware validation

**How to query**:
```bash
# Extract specific fields
grep -A5 "<cpu>" domain.xml  # CPU config
grep "<driver" domain.xml     # Disk/device drivers
grep "<emulator>" domain.xml  # QEMU version
```

#### `launcher-compute.log` (138 KB — Raw virt-launcher/QEMU logs)
**What it contains**: Timestamped compute logs from virt-launcher pod (QEMU stderr/stdout).

**What to look for**:
```
Split-lock AC traps (WRMSR events on locked memory access)
KVM internal errors (vcpu fault, page fault anomalies)
Device errors (disk I/O timeouts, NIC resets)
Hyper-V enlightenment interactions
Guest instruction emulation failures
```

**Example search**:
```bash
grep -i "split-lock" launcher-compute.log  # CPU lock issues
grep -i "kvm error" launcher-compute.log    # Hypervisor errors
grep -i "vcpu" launcher-compute.log         # vCPU state
```

#### `host-signals.json` (1.3 KB — Parsed kernel signals)
**What it contains**: Structured analysis of `launcher-compute.log` for forensic signals.

**Example content**:
```json
{
  "ok": true,
  "vm": "windows-bsod_win2022-vm-hjoshi1",
  "collectedAt": "2026-10-13T07:12:08Z",
  "kernelSignals": [
    {
      "id": "split-lock-trap",
      "count": 0,
      "relatedBugCheck": "0x00020001",
      "matches": []
    },
    {
      "id": "kvm-internal-error",
      "count": 0,
      "relatedBugCheck": null,
      "matches": []
    }
  ],
  "splitLockDetected": false,
  "hyperv": {
    "features": [
      { "name": "tlbflush", "state": "absent", "risk": "high", "present": false },
      { "name": "ipi", "state": "on", "risk": "high", "present": true },
      { "name": "vapic", "state": "on", "risk": "low", "present": true }
    ]
  }
}
```

**Interpretation**:
- `split-lock-trap.count > 0` → CPU memory locking issues; may affect Windows thread synchronization
- `kvm-internal-error.count > 0` → Hypervisor-level faults; potential infrastructure instability
- `hyperv.features.tlbflush = "absent"` and `risk = "high"` → Translation lookaside buffer flush optimization unavailable; performance impact
- `hyperv.ipi = "present"` → Inter-processor interrupts optimized

---

### Windows Crash Event Logs (Extracted After VM Shutdown)

#### `guestFS_sda3/Windows/System32/winevt/Logs/System.evtx` (11 MB)
**What it contains**: Windows System EventLog — kernel events, crashes, shutdowns.

**Key events**:
- **Event 1001 (BugCheck)**: BSOD event with bugcheck code, parameters, and timestamp
- **Event 6008 (Dirty shutdown)**: Ungraceful shutdown (triggered by AutoReboot=0)
- **Event 7000-7009**: Driver load failures, service errors around crash

**How to parse (offline)**:
```bash
# Optional offline parsing (parser archived; lookup data remains in active src/data/)
run_dir=/path/to/run
python3 apps/bsod-detector/archieve/src/scripts/host/extract-evtx.py \
  --data-dir apps/bsod-detector/src/data \
  "$run_dir"/guestFS_*/Windows/System32/winevt/Logs/*.evtx

# Or use Windows Event Viewer if analyzing on Windows
```

**What to look for in Event 1001**:
```
BugCheckCode: 0x01  (APC_INDEX_MISMATCH) or other code
BugCheckParameter1, 2, 3, 4: Faulting address, context, CPU state
DumpFile: C:\Windows\MEMORY.DMP or C:\DedicatedDump.sys (if written)
TimestampUTC: Exact crash time
```

#### `guestFS_sda3/Windows/System32/winevt/Logs/Application.evtx` (6.4 MB)
**What it contains**: Windows Application EventLog — app-level events.

**Key events**:
- **Application/1001 (LiveKernelEvent)**: System health data logged by crashed process
- **Application/1000**: Generic app crash events
- **.NET Framework events** (if applicable): CLR faults

**How to analyze**:
The archived EVTX parser can analyze it offline; see the command above.

#### `parse-dump-header.json` (146 B)
**What it contains**: Stub for bugcheck code extraction (developer tool disabled in pipeline).

**Example**:
```json
{
  "ok": true,
  "totalDumps": 0,
  "dumps": [],
  "warnings": [
    "no on-disk dump available; primary artifact is vm-memory.elf.tar.gz"
  ]
}
```

**Purpose**: Placeholder for offline `elf2dmp` analysis. Extract the raw ELF file from `vm-memory.elf.tar.gz`, convert it to Windows DMP, then run `parse-dump-header.sh` against the converted dump.

#### `events.json` (162 B)
**What it contains**: Stub for EventLog parsing (developer tool disabled in pipeline).

**Example**:
```json
{
  "ok": true,
  "note": "extract-evtx.py is a developer tool — run offline against guestFS_<partition>/Windows/System32/winevt/Logs/*.evtx",
  "events": []
}
```

**Purpose**: The active pipeline writes a stub. An archived parser is available under `apps/bsod-detector/archieve/src/scripts/host/` for optional offline analysis.

---

### Metadata and Validation

#### `checksums.sha256` (915 B)
**What it contains**: SHA-256 manifest of all evidence files for integrity verification.

**Example**:
```
077051eba4d8a9f9d6ed8059dadd38e875c2ca2d151472bd701bbe0d82b8fd89  vm-memory.elf.tar.gz
42d27f087986031ee07523a8b44a1f6dad46d138f06c5727d5647cfa454988fc  bsod-screenshot.png
36db7f84419faf026f535626bb2b6a2d76ef9be8ded7f960bed2a46bbf1ce9fb  domain.xml
...
```

**How to verify**:
```bash
cd /mnt/persistent-bsod-evidence/20261013T070250Z-intentional-837674-22539
sha256sum -c checksums.sha256  # Verify all files
```

#### Historical extraction trace example
The former `extraction.log` is no longer produced. Extraction now inherits stdout/stderr, captured in `watcher.log` by the watcher. The following historical trace illustrates the extraction steps.

**Example**:
```
[12:53:12] Starting guestfish extraction for partition sda3
[12:53:13] Mounting /dev/sda3 (NTFS) read-only
[12:53:14] Downloading /Windows/System32/winevt/Logs/System.evtx
[12:53:25] Downloaded 11M in 11 seconds (1.0 MB/s)
[12:53:25] Downloading /Windows/System32/winevt/Logs/Application.evtx
[12:53:35] Downloaded 6.1M in 10 seconds (0.6 MB/s)
[12:53:35] Unmounting /dev/sda3
[12:53:36] Extraction complete
```

**Use for**: Troubleshooting failed NTFS reads, verifying partition detection, monitoring extraction performance.

#### `extraction-summary.json` (3.2 KB)
**What it contains**: Recovery phase artifact manifest with integrity validation.

**Key fields per artifact**:
```json
{
  "artifacts": [
    {
      "type": "memory",
      "format": "tar.gz[elf]",
      "path": "vm-memory.elf.tar.gz",
      "size": 824374006,
      "sha256": "077051eba4d8a9f9d6ed8059dadd38e875c2ca2d151472bd701bbe0d82b8fd89",
      "valid": true
    },
    {
      "type": "evtx",
      "format": "evtx",
      "path": "guestFS_sda3/Windows/System32/winevt/Logs/System.evtx",
      "size": 10555392,
      "sha256": "162deb75eeaa6525499281b1b42b4d48d2761d77c0579d9cf1833e8d25faa1f1",
      "valid": true
    }
  ],
  "invalidArtifacts": [],
  "missingRequiredArtifactTypes": [],
  "ok": true
}
```

**Interpretation**:
- `valid: true` → File structure validated (PNG is valid PNG, ELF is valid ELF, etc.)
- `invalidArtifacts: []` → No corrupt files
- `missingRequiredArtifactTypes: []` → All required artifact types present

#### `stage-errors.jsonl` (0 B on success)
**What it contains**: JSONL file — one line per pipeline stage failure.

**Example (on failure)**:
```json
{"stage":"preflight","error":"qemu guest agent became unavailable","at":"2026-10-13T07:12:00Z"}
{"stage":"memory-capture","error":"virtctl vmexport download failed","at":"2026-10-13T07:25:00Z"}
```

**Interpretation**: Empty file (0 B) = clean run. Non-empty = failures to investigate.

#### `evidence-summary.json` (3.2 KB)
**What it contains**: Final pipeline verdict and complete artifact inventory.

**Example**:
```json
{
  "ok": true,
  "runId": "20261013T070250Z-intentional-837674-22539",
  "vm": "win2022-vm-hjoshi1",
  "namespace": "windows-bsod",
  "mode": "intentional-rhov",
  "artifacts": [
    { "type": "screenshot", "path": "bsod-screenshot.png", "size": 37842, "valid": true },
    { "type": "memory", "path": "vm-memory.elf.tar.gz", "size": 824374006, "valid": true },
    { "type": "evtx", "path": "guestFS_sda3/Windows/System32/winevt/Logs/System.evtx", "size": 10555392, "valid": true },
    { "type": "evtx", "path": "guestFS_sda3/Windows/System32/winevt/Logs/Application.evtx", "size": 6361088, "valid": true },
    { "type": "log", "path": "launcher-compute.log", "size": 137764, "valid": true },
    { "type": "log", "path": "domain.xml", "size": 13992, "valid": true },
    { "type": "json", "path": "host-signals.json", "size": 1278, "valid": true }
  ],
  "invalidArtifacts": [],
  "missingRequiredArtifactTypes": [],
  "stageErrors": []
}
```

**Quick checks**:
```bash
jq '.ok' evidence-summary.json           # true = pipeline passed
jq '.missingRequiredArtifactTypes' ...   # [] = all required artifacts present
jq '.invalidArtifacts' ...               # [] = all files structurally valid
```

#### `watcher.log` (170 KB)
**What it contains**: Full timestamped execution trace of the entire pipeline.

**Example sections**:
```
[07:02:50] preflight passed; preparing watcher for windows-bsod/win2022-vm-hjoshi1
[07:02:51] qemu guest agent and event watch healthy; watcher armed
[07:10:50] missed ping 1/2 (domstate=paused)
[07:10:55] missed ping 2/2 (domstate=paused)
[07:10:55] corroborated crash/freeze detected (domstate=paused)
[07:10:55] waiting 60 seconds for VNC to become responsive...
[07:11:55] KubeVirt memory-dump request submitted
[07:20:50] validated KubeVirt memory dump: vm-memory.elf.tar.gz
[07:20:55] VNC screenshot captured
[07:12:08] captured launcher/domain diagnostics for node integrity-gs04.sys.eng.rdu2.dc.redhat.com
```

**Use for**: Debugging timing issues, understanding detection flow, finding which step failed.

---

### Summary Workflow

**To analyze a run**:

1. **Quick health check**:
   ```bash
   run_dir=/path/to/run
   jq '.ok' "$run_dir"/evidence-summary.json
   jq '.missingRequiredArtifactTypes' "$run_dir"/evidence-summary.json
   ```

2. **Visual confirmation**:
   ```bash
   file bsod-screenshot.png
   display bsod-screenshot.png  # See blue screen
   ```

3. **Check infrastructure**:
   ```bash
   jq '.node, .snapshotClass, .storageClass' recovery-metadata.json
   ```

4. **Parse host signals** (CPU flags, hypervisor state):
   ```bash
   jq '.hyperv.features[] | select(.risk=="high")' host-signals.json
   ```

5. **Extract and analyze memory dump** (offline):
   ```bash
   inner_file=$(tar -tzf vm-memory.elf.tar.gz | grep -i '\.memory\.dump$' | head -1)
   tar -xzf vm-memory.elf.tar.gz -O "$inner_file" > memory.dump
   elf2dmp memory.dump memory-windows.dmp
   vol -f memory-windows.dmp windows.crashinfo.CrashInfo
   ```

6. **Parse Windows event logs** (offline):
   ```bash
   run_dir=/path/to/run
   python3 apps/bsod-detector/archieve/src/scripts/host/extract-evtx.py \
     --data-dir apps/bsod-detector/src/data \
     "$run_dir"/guestFS_*/Windows/System32/winevt/Logs/*.evtx
   ```

---

## Platform Limitations (KVM + VirtIO Balloon)

| Artifact | Status | Reason |
|---|---|---|
| `vm-memory.elf.tar.gz` | Expected; validated when capture succeeds | KubeVirt virtctl — independent of Windows disk state; API/storage/export failures are recorded |
| `System.evtx` / `Application.evtx` | Extracted when recovery succeeds | Offline guestfish NTFS read after VM stopped; missing/invalid artifacts are reported |
| `MEMORY.DMP` (on-disk) | ❌ Not captured | `AutoReboot=0` prevents boot that copies DedicatedDump.sys → MEMORY.DMP |
| `Minidump/*.dmp` | Not captured in the observed test configuration | Requires `pagefile.sys`; the documented Windows Server 2022 KVM runs did not materialize one |
| `vm-memory-windows.dmp` | ❌ Not in pipeline | elf2dmp disabled (17GB, run offline) |
| Volatility outputs | ❌ Not in pipeline | Developer tool, run offline against vm-memory.elf.tar.gz |

### Why MINIDUMP and MEMORY.DMP Were Unavailable in the Observed Test Configuration

**Observed in this test configuration**: Windows Server 2022 on KVM with VirtIO Balloon did not create `pagefile.sys` on demand during the documented runs. The pipeline uses `AutoReboot=0` to freeze the VM at BSOD, preventing the post-crash reboot that would copy staged crash dumps to disk.

#### Attempts to enable pagefile.sys on KVM

| Approach | Execution | Observed Behavior | Failure Reason | Reference |
|---|---|---|---|---|
| **Registry Set-ItemProperty** | Run PowerShell: `Set-ItemProperty HKLM:\...\CrashControl -Name "PagingFiles" -Value "C:\pagefile.sys 1024 2048"` after crash config | Registry entry created successfully; reboot applied. Post-reboot check: **pagefile.sys never appeared on disk**. Free RAM remained 15.8GB. | Windows Server 2022 lazy-allocates pagefile only when memory pressure (page faults) occurs. With 16GB VM and no memory-intensive workload, threshold never reached. | configure-dumps.ps1, commit e7c2ca4 |
| **WMI Win32_PageFileSetting** | Create via PowerShell: `$pf = ([WMICLASS]'Win32_PageFileSetting').CreateInstance()` → Set-CimInstance. Reboot. | Pagefile created at reboot, enumerated via `Get-Volume`; immediately deallocated seconds later (Windows detected unused state). Free RAM still ~16GB. Minidump folder remained empty. | Same lazy-allocation. Windows deallocates pagefile if no page faults occur within observability window. BSOD events don't consume enough RAM to force allocation. | commit 2886457 |
| **.NET Registry API** | Direct registry write: `[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(...).SetValue("PagingFiles", ...)` + reboot. | No observable difference from Set-ItemProperty. Registry shows paging file path; no actual `.sys` file created on disk. | Identical root cause — OS-level lazy allocation decision, not registry visibility. | commit 3dfa5ad |
| **TestLimit64 memory stress** | Download TestLimit64.exe via QGA (ARG_MAX limit hit on first attempt). Retry: VM-side `Invoke-WebRequest` download; ran `TestLimit64.exe -m 14000` to consume 14GB RAM. | **Memory consumed: 5.5GB** (measured via Task Manager `Committed` memory). Guest free RAM dropped to 10.4GB. **Pagefile.sys still not created.** Stress process held memory but no page fault threshold reached. | Consumed memory was allocated in RAM (not paging). No physical page faults triggered — Windows doesn't need to allocate pagefile if RAM still available for allocation. Buffer pool writes are cached, not forcing paging. | commit 1f8a1c2, 2024-10-12 debugging session |
| **Balloon inflation via KubeVirt API** | Attempted `virtctl set memory-balloon vm --memory-amount X -n ns` to forcibly deflate available RAM. | **Memory pressure achieved: 1.4GB free** (rest held by balloon). Guest reported 14.6GB reserved. **Pagefile.sys not created.** Balloon took effect but Windows still deferred allocation. | KubeVirt balloon implementation on this cluster does not generate sufficient page-fault pressure to trigger Windows pagefile creation. Balloon reserves RAM but doesn't force OS to page. | commit 7e4a5f9, 2024-10-12 afternoon |
| **Chaos krkn-lib memory-stress pod** | Deployed chaos pod with `pod-memory-stress` scenario (memory: limit=6GB, request=6GB) into cluster. Monitored for guest memory pressure. | **Host-side memory pressure: clear**. Guest `Free Memory` polling via QGA: **still reported 14.4GB free**. No host-to-guest pressure translation. Pagefile.sys never created. | Host memory pressure (pod eviction / swap) doesn't force guest OS paging decisions. Guest and host memory namespaces are isolated; hypervisor can't mandate guest OS behavior. | commit 4c2d8f1, 2024-10-12 revert to a8babfa |
| **DedicatedDumpFile workaround** | Pre-allocate `C:\DedicatedDump.sys` (RAM + 1MB) at golden image build. Configure `DedicatedDumpFile` registry. No reboot needed at pipeline runtime. | **Crash staging works:** DedicatedDump.sys receives crash dump on BSOD. Dump write succeeds without pagefile. EventLog entries created. **Minidump directory remains empty.** | DedicatedDumpFile bypasses pagefile for kernel dump staging. However, Windows Minidump feature (small user-mode process dumps, crash report generation) **has no bypass** — requires pagefile to exist. Minidump is separate from kernel dump. | **Current approach**, all commits after a8babfa |

#### Pagefile allocation attempts in the observed Windows Server 2022 KVM setup

1. **Lazy allocation by design**: Windows Server 2022 defers pagefile creation until memory pressure (page faults) actually occurs
2. **The tested VM did not reach critical memory**: the 16GB VM retained free RAM; BSOD events (including the documented TestLimit64 run) did not trigger pagefile creation
3. **No hypervisor-level forcing**: KVM has no directive to force a guest to allocate pagefile — this is a Windows OS-level decision
4. **VirtIO Balloon limitations**: Balloon inflation (if supported) would only help on VMs with excess free RAM, not on constrained VMs; even then, guest OS still decides when to allocate pagefile

#### Impact on dump artifacts

| Dump type | Requires | Current status | Mitigation |
|---|---|---|---|
| **Kernel dump (MEMORY.DMP)** | Pagefile OR `DedicatedDumpFile` + reboot | Not observed on disk with this `AutoReboot=0` pipeline configuration | Use `vm-memory.elf.tar.gz` when the KubeVirt capture stages succeed |
| **Minidump (.dmp files)** | Pagefile | Not produced in observed runs | No supported workaround is documented for this test configuration |
| **Full physical RAM (vm-memory.elf.tar.gz)** | KubeVirt VirtualMachineExport | Expected when KubeVirt dump/export stages succeed | **Primary artifact** — hand to developer for elf2dmp + volatility |

#### Key Findings from Each Approach

**Registry-based approaches (Set-ItemProperty, WMI, .NET API)**
- Registry configuration visible post-reboot but pagefile not materialized
- Windows lazily allocates pagefile on first page fault, not on boot
- No observable difference between registry APIs — all respect OS lazy-allocation policy

**Memory pressure approaches (TestLimit64, Balloon inflation)**
- **TestLimit64**: Successfully consumed 5.5GB RAM (free RAM: 10.4GB remaining). Stress process held memory in RAM without triggering page faults. No pagefile created.
- **Balloon inflation**: Successfully reduced guest free memory to 1.4GB (14.6GB reserved). Pagefile still not created. Balloon reserves RAM but does not force OS paging decisions.
- **Chaos pod stress**: Clear host-side memory pressure (pod approaching eviction threshold). Guest isolation prevents host pressure from forcing guest OS paging. Guest free memory remained 14.4GB despite host contention.

**Observed insight**: In the documented runs, the tested VM did not materialize a pagefile after the registry, memory-stress, balloon, and host-pressure attempts. A BSOD event consumes no additional memory — crash happens in kernel context, not in user-mode allocation.

**DedicatedDumpFile partial success**
- Kernel dump staging works (MEMORY.DMP equivalent) via pre-allocated file
- Minidump files were not produced in the observed configuration; the tested setup requires a pagefile
- The two dump types are separate Windows subsystems; fixing one doesn't fix the other

#### Conclusion

**MEMORY.DMP and Minidump have not been produced in the observed KVM/VirtIO Balloon configuration** due to:
1. Windows Server 2022 lazy pagefile allocation on KVM
2. Pipeline requirement for `AutoReboot=0` to freeze VM and capture evidence (prevents post-crash reboot that would copy DedicatedDump.sys → MEMORY.DMP to disk)
3. No hypervisor-level mechanism to force pagefile creation — this is a guest OS decision
4. Even with extreme memory stress (5.5GB consumed, free RAM 10.4GB; or 1.4GB free with balloon), pagefile allocation was not triggered

When capture succeeds, `vm-memory.elf.tar.gz` contains the physical-memory artifact used for offline analysis; developers must run `elf2dmp` offline to convert it to Windows DMP format for WinDbg. System EventLog event 1001 may record the bug-check code and parameters, but it does not supply a minidump crash stack.

---

## Artifact Collection Methods — Tested Alternatives

This section documents what we tested for extracting forensic artifacts and why current methods are optimal.

### Domain.xml Extraction (libvirt domain configuration)

**Current method**: `virsh dumpxml` inside virt-launcher pod ✅

**Alternatives tested**:

| Method | Status | Test Result | Why It Failed |
|---|---|---|---|
| **`virtctl expand`** | Tested ✅ | Command exists; returns VirtualMachine with expanded instancetype/preference | Wrong scope — returns Kubernetes object, not libvirt domain definition. Missing CPU flags, BIOS settings, device models. |
| **`oc get vmi -o yaml`** | Tested ✅ | Returns KubeVirt VirtualMachineInstance YAML with status info | Incomplete — Kubernetes perspective only. Missing libvirt internals (QEMU emulator path, loader config, exact device parameters). |
| **libvirt Python bindings** | Tested ✅ | `import libvirt` fails — `ModuleNotFoundError` | Not installed in virt-launcher pod. Would require `pip install libvirt-python` (no package manager in minimal pod). |
| **Direct libvirt socket** | Tested ✅ | Socket `/var/run/libvirt/virtqemud-sock` exists and accessible | Possible but impractical — requires implementing libvirt RPC protocol parser (100+ lines of protocol code). High risk, low ROI. |
| **`virsh dumpxml`** | ✅ Current | Executed inside virt-launcher pod; returns complete 322-line XML | Perfect. All CPU, device, memory, BIOS config available. No dependencies. Reliable. |

**Conclusion**: `virsh dumpxml` is the **only practical method** for getting complete libvirt domain configuration. No viable replacement.

---

### QGA Execution Method (PowerShell script execution on guest)

**Current method**: `virsh qemu-agent-command` via QMP (QEMU Machine Protocol) ✅

**Alternatives tested**:

| Method | Status | Test Result | Why It Failed |
|---|---|---|---|
| **`virtctl exec`** | Tested ✅ | Command not found in virtctl help output | Does not exist in virtctl. No native guest execution in KubeVirt CLI. |
| **guestfish** | Tested ✅ | Only works on local libvirt domains; fails on remote K8s VMs with `Domain not found` | Cannot access VMs over Kubernetes network. Designed for offline NTFS reads (VM stopped). |
| **Direct QMP socket** | Tested ✅ | Socket exists at `/var/run/libvirt/qemu/run/...`; connection possible but complex | Would require QMP protocol implementation (handshake, JSON-RPC commands). Complex, error-prone, no advantage over virsh wrapper. |
| **`virtctl ssh`** | Possible ⚠️ | Not tested (would work if SSH configured on guest) | Requires SSH server installed on Windows (non-default). Would add security/maintenance overhead. |
| **`virsh qemu-agent-command`** | ✅ Current | Executes PowerShell scripts reliably; returns stdout/stderr JSON | Optimal. Single command, full SYSTEM privilege, works through QMP tunnel, no network setup needed. |

**Conclusion**: `virsh qemu-agent-command` is the **best method** for executing guest commands on Windows VMs in KubeVirt. No viable replacement justifies complexity.

---

### Memory Dump Capture (full physical RAM)

**Current method**: `virtctl memory-dump get` + `virtctl vmexport download` ✅

**Why this is optimal**:

| Aspect | Advantage |
|---|---|
| VM frozen | Physical RAM snapshot is consistent (crash-safe) |
| ELF format | Native format for volatility3, elf2dmp, memory forensics tools |
| Gzip compression | Reduces 1.5GB → 800MB (50% reduction) |
| HTTP streaming | Firewall-friendly, no node-level access, works over K8s network |
| Self-signed cert | No PKI overhead, virtctl handles internally |
| Pure KubeVirt API | No virsh, no libvirt socket, no hypervisor dependencies |
| Reliability | Works even when guest BSOD'd; hypervisor captures directly from QEMU |

**Alternative (not used)**:
- Direct QEMU `/dev/vda` block device read (would require node access, no live freezing, unreliable)

---

## Offline EventLog Extraction (guestfs-ntfs Pod)

The `.evtx` files are extracted from the stopped VM's NTFS disk into `guest-fs--crash-info.tgz` using a guestfish pod — **no SSH or Windows reboot required**. No loose EVTX files are retained or automatically unpacked. Validator adaptation is deferred: current recovery/watcher summaries still require loose EVTX and return nonzero even when the archive contains both logs. Earlier loose-file sample outputs and offline parser globs below require separately unpacked files; the active extractor does not perform that step.

### How it works

```
Stop VM (virtctl stop)
    ↓
Create guest-fs--ntfs--<epoch>-<pid> helper (BSOD_DET__GUEST_FS__CTR_IMG, force_kvm backend)
PVC attached as block device → /dev/vda inside pod
    ↓
Readonly guestfish Windows probe per NTFS partition
Independent file sessions: helper mkdir -p, guestfish -ra /dev/vda
  run : mount-ro /dev/sda3 / : copy-out <source> <helper-directory> : umount-all
    ↓
Helper test -d /tmp/bsod--guest-files--<epoch>/
Helper tar zc -C <directory>/ ./ → guest-fs--crash-info.tgz on runner
    ↓
Delete pod, cleanup
```

**One guestfish session** = one QEMU startup for all target files. Multiple separate sessions caused pod OOM on the second file transfer.

### Dynamic partition detection

```
guestfish list-filesystems returns:
  /dev/sda1: vfat   ← EFI System Partition (skipped — not NTFS)
  /dev/sda2: (none) ← MSR partition (skipped — no filesystem)
  /dev/sda3: ntfs   ← C:\ Windows system partition ← extracted here
  /dev/sda4: ntfs   ← WinRE recovery partition (skipped — no evtx files)

First NTFS partition where System.evtx is found = Windows C:\
```

The partition name (`sda3`) is detected dynamically every run — never hardcoded.

### Security context (Baseline PSS — no escalation)

```yaml
runAsNonRoot: true
seccompProfile:
  type: RuntimeDefault
allowPrivilegeEscalation: false
capabilities:
  drop: ["ALL"]
```

`force_kvm` requires a schedulable `devices.kubevirt.io/kvm` device (request and limit `"1"`). The helper's initial resource budget requests 512Mi memory and 500m CPU, with limits of 2Gi memory and 2000m CPU; it sets no node selector or fsGroup. This is not measured resource adequacy. Availability of KVM and admission of this Pod must be validated in the target environment; offline rendering tests do not prove runtime scheduling or guestfish success.

---

## Quick Start

```bash
# 1. Set targets explicitly (no defaults — prevents wrong-VM targeting)
export BSOD_DET__VM__NAME=win2022-vm-hjoshi1
export BSOD_DET__NAMESPACE=windows-bsod

# 2. Run pipeline
./src/scripts/crash-injector/trigger-bsod-intentional.sh 0x01

# 3. Check result
run=$(ls -t /mnt/persistent-bsod-evidence/ | head -1)
cat /mnt/persistent-bsod-evidence/$run/evidence-summary.json | jq '{ok,stageErrors}'
```

**Diagnosing failures**:
```bash
run=/path/to/run
cat $run/stage-errors.jsonl | jq .
cat $run/evidence-summary.json   | jq '{ok,stageErrors,missingRequiredArtifactTypes,invalidArtifacts}'
cat $run/extraction-summary.json | jq '{ok,stageErrors,missingRequiredArtifactTypes,invalidArtifacts}'
tail -30 $run/watcher.log
```

---

## Golden Image Requirements

The Windows VM image must be pre-configured before pipeline use (one reboot required after applying):

```powershell
# Run as Administrator before sealing the image
$cc = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
Set-ItemProperty $cc CrashDumpEnabled    7                          -Type DWord  # Automatic
Set-ItemProperty $cc AutoReboot          0                          -Type DWord  # Stay frozen
Set-ItemProperty $cc AlwaysKeepMemoryDump 1                         -Type DWord
Set-ItemProperty $cc DedicatedDumpFile   'C:\DedicatedDump.sys'     -Type ExpandString

# Pre-allocate DedicatedDump.sys (RAM + 1MB)
$size = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory + 1MB
fsutil file createnew C:\DedicatedDump.sys $size

# Disable automatic pagefile (VirtIO Balloon blocks it on KVM anyway)
$cs = Get-CimInstance Win32_ComputerSystem
Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false }
```

Then reboot once: `virtctl stop <vm> -n <ns> && virtctl start <vm> -n <ns>`

---

## Developer Tools (Run Offline)

These are **not called by the pipeline** — run manually on captured artifacts. The EVTX parser is archived; it is not shipped in the active script tree.

```bash
# Convert ELF → Windows DMP for WinDbg
inner_file=$(tar -tzf vm-memory.elf.tar.gz | grep -i '\.memory\.dump$' | head -1)
tar -xzf vm-memory.elf.tar.gz -O "$inner_file" > memory.dump
elf2dmp memory.dump vm-memory-windows.dmp

# Volatility3 analysis
vol -f vm-memory-windows.dmp windows.info.Info
vol -f vm-memory-windows.dmp windows.crashinfo.CrashInfo

# Parse EventLogs → JSON crash detection
pip install python-evtx
run_dir=/path/to/run
python3 apps/bsod-detector/archieve/src/scripts/host/extract-evtx.py \
  --data-dir apps/bsod-detector/src/data \
  "$run_dir"/guestFS_*/Windows/System32/winevt/Logs/*.evtx
```

---

## Directory Structure

```
apps/bsod-detector/
├── README.md (this file)
├── src/
│   ├── scripts/
│   │   ├── crash-injector/
│   │   │   ├── README.md
│   │   │   └── trigger-bsod-intentional.sh    # Pipeline entry point
│   │   ├── host/
│   │   │   ├── README.md
│   │   │   ├── watch-crash.sh                 # BSOD detection + memory capture
│   │   │   ├── preflight-rhov.sh              # Pre-run validation
│   │   │   ├── extract--guest-os--crash-info.sh       # Offline NTFS extraction
│   │   │   ├── guest-agent.py                 # QGA PowerShell tunnel
│   │   │   ├── parse-dump-header.sh           # Bugcheck code extraction
│   │   │   ├── reliability.py                 # Artifact validation + summary
│   │   │   └── collect-host-signals.sh        # KVM/Hyper-V signal parser
│   │   └── guest/
│   │       ├── README.md
│   │       ├── configure-dumps.ps1            # Windows crash dump config
│   └── data/
│       ├── crash-control.json                 # CrashControl registry values
│       ├── bugcheck-codes.json                # Windows bugcheck code database
│       ├── event-sources.json                 # EventLog source definitions for archived parser
│       └── host-signals.json                  # Host signal definitions
└── test/
    └── ...                                    # Unit tests
```

---

## Environment Variables

All variables use `BSOD_DET__` prefix (Red Hat Chaos Team convention):

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `BSOD_DET__VM__NAME` | **Yes** | none | Target VM — must be explicit |
| `BSOD_DET__NAMESPACE` | **Yes** | none | Kubernetes namespace — must be explicit |
| `BSOD_DET__EVIDENCE__DIR` | No | `/mnt/persistent-bsod-evidence` | Evidence storage root |
| `BSOD_DET__SNAPSHOT__CLASS` | No | — | Storage snapshot class |
| `BSOD_DET__MEMORY__DUMP_PVC` | No | — | Memory dump PVC name |
| `BSOD_DET__COMMAND__TIMEOUT` | No | `30` | Command timeout (seconds) |
| `BSOD_DET__READY__TIMEOUT` | No | `300` | Watcher readiness timeout |
| `BSOD_DET__PREFLIGHT__TIMEOUT` | No | `300` | Positive-integer validation only; trigger currently uses a fixed 1800s preflight timeout |
| `BSOD_DET__GUEST_FS__CTR_IMG` | No | `quay.io/konveyor/oadp-vmfr-access:latest` | guestfs helper image; unset or empty uses the default, with no legacy environment fallback |
| `BSOD_RECOVERY_IMAGE` | No | — | Digest-pinned recovery image |
