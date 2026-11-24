# Guest Scripts

PowerShell scripts that run **inside Windows VMs** via the qemu-guest-agent tunnel.

These scripts configure Windows crash dump settings and clean up pre-test state.

## Script Overview

### `configure-dumps.ps1`

**Purpose**: Apply and verify Windows crash dump registry settings before BSOD injection.

**Called by**: `preflight-rhov.sh` via `guest-agent.py psfile`

**What it configures** (reads from `crash-control.json`):

| Registry Key | Value | Why |
|---|---|---|
| `CrashDumpEnabled` | `7` (Automatic) | Kernel dump → MEMORY.DMP + Minidump. Blocked on KVM but needed for EventLog crash events |
| `AutoReboot` | `0` | **Critical** — keeps VM frozen at BSOD so pipeline can detect and capture |
| `AlwaysKeepMemoryDump` | `1` | Prevents Windows from auto-deleting MEMORY.DMP |
| `Overwrite` | `1` | Overwrite previous dump |
| `LogEvent` | `1` | Write crash event to System EventLog |
| `DumpFile` | `%SystemRoot%\MEMORY.DMP` | Output path for kernel dump |
| `MinidumpDir` | `%SystemRoot%\Minidump` | Minidump output directory |
| `DedicatedDumpFile` | `C:\DedicatedDump.sys` | Bypass pagefile for crash staging |

**DedicatedDumpFile pre-allocation**: If `C:\DedicatedDump.sys` doesn't exist, the script pre-creates it using `fsutil file createnew` sized to `TotalPhysicalMemory + 1MB`. This file is used by Windows for crash dump staging instead of pagefile.

**Reboot detection**: The script returns `rebootRequired=true` if any change requires a reboot (e.g., `CrashDumpEnabled` type change). Preflight will `Die` if reboot is pending — operator must do `virtctl stop && virtctl start` then re-run.

**Output JSON**:
```json
{
  "ok": true,
  "matchesRecommended": true,
  "rebootRequired": false,
  "action": "applied",
  "current": { "CrashDumpEnabled": 7, "AutoReboot": 0, ... },
  "pageFile": { "adequate": true, "configured": "..." }
}
```

**Pagefile note**: Preflight requires `pageFile.adequate=true`. With `DedicatedDumpFile` configured this is satisfied without `pagefile.sys`. The pagefile block was removed from configure-dumps.ps1 because `pagefile.sys` cannot be reliably created on KVM with VirtIO Balloon (Windows Server 2022 lazy pagefile allocation defers creation until memory pressure — which rarely occurs on VMs with ≥16GB RAM).

---

### `clear-dumps.ps1`

**Purpose**: Remove stale crash artifacts from the guest before a new test run.

**Called by**: `trigger-bsod-intentional.sh` (Phase 3 — guest cleanup)

**What it clears**:
- `C:\Windows\MEMORY.DMP`
- `C:\Windows\Minidump\*.dmp`

**What it preserves**:
- `CrashControl` registry settings (do not reset)
- `C:\DedicatedDump.sys` (pre-allocated file — keep it)
- All other system state

**Output JSON** (verified by trigger script):
```json
{ "memory": false, "minidumpCount": 0 }
```
Pipeline fails if `memory=true` or `minidumpCount>0` — ensures clean state before injection.

---

## Platform Limitations (KVM + VirtIO)

| Artifact | Status | Reason |
|---|---|---|
| `System.evtx` | ✅ Extracted | Offline NTFS read via guestfish |
| `Application.evtx` | ✅ Extracted | Offline NTFS read via guestfish |
| `vm-memory.elf.tar.gz` | ✅ Captured | KubeVirt virtctl memory-dump — always works |
| `MEMORY.DMP` (on-disk) | ⚠️ Zero-filled on VirtIO | viostor (virtio-blk) and vioscsi (virtio-scsi) fail in crash dump miniport mode — `StorPortGetUncachedExtension` returns error ([issue #1629](https://github.com/virtio-win/kvm-guest-drivers-windows/issues/1629)). Expected to work with SATA (storahci.sys — inbox driver) |
| `Minidump/*.dmp` | ⚠️ Empty on VirtIO | Same StorPort miniport failure. Infrastructure ready (pagefile.sys pre-created in golden image); blocked only by VirtIO driver issue |
| `vm-memory-windows.dmp` | ❌ Not in pipeline | elf2dmp conversion disabled (17GB — developer runs offline) |

**Why MEMORY.DMP is zero-filled on VirtIO**:
- Windows crash dump miniport mode calls `StorPortGetUncachedExtension` for DMA buffer allocation
- Both viostor (virtio-blk) and vioscsi (virtio-scsi) return `SP_RETURN_ERROR` at this call
- Crash dump write is abandoned — DedicatedDump.sys pre-allocated but never written
- This is a StorPort miniport architecture limitation, not a driver bug per se
- vioscsi had equivalent fixes in PR #110 (2017) and PR #811 (2022); viostor was never audited
- **Workaround**: `vm-memory.elf.tar.gz` (hypervisor-level ELF dump) provides equivalent forensic value; convert offline with `elf2dmp`

---

## Golden Image Requirements

Use the provided scripts to set up the VM **before sealing the image**. Requires one reboot after applying.

**Scripts** (in `src/scripts/guest/`):

| Script | When to run | Purpose |
|---|---|---|
| `golden-image-pre-reboot.ps1` | Before reboot | Install QGA + pvpanic, disable recovery, set crash dump registry, pre-allocate DedicatedDump.sys + pagefile.sys |
| `golden-image-post-reboot.ps1` | After reboot | Verify all 8 settings are active in running kernel — must all pass before sealing |

**Run as Administrator**:
```powershell
# Step 1 — pre-reboot setup (auto-reboots at end)
.\golden-image-pre-reboot.ps1

# Step 2 — post-reboot verification
.\golden-image-post-reboot.ps1
# All checks passed — safe to seal the golden image.
```

**Download note**: Use `.NET WebClient` instead of `curl.exe` or BITS (both fail in VM context):
```powershell
$wc = New-Object System.Net.WebClient
$wc.DownloadFile("https://...", "C:\Temp\virtio-win.iso")
```

**At pipeline runtime**, `configure-dumps.ps1` finds settings already in place → `rebootRequired=false` → preflight passes cleanly.

---

## Guest-Agent Communication

```
host: guest-agent.py psfile configure-dumps.ps1 --companion crash-control.json C:\Windows\Temp\crash-control.json -- -DataFile C:\Windows\Temp\crash-control.json
  ↓
oc exec virt-launcher-<vm>-<hash>
  ↓
virsh qemu-agent-command <ns>_<vm> '<QMP JSON>'
  ↓
qemu-guest-agent (Windows service)
  ↓
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\configure-dumps.ps1 -DataFile C:\Windows\Temp\crash-control.json
  ↓
stdout/stderr captured → returned to host
```

Scripts run as `NT AUTHORITY\SYSTEM` — full Windows privilege, no interactive input.

## Registry Reference

**CrashControl** (`HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl`):

| Key | Type | Pipeline value |
|---|---|---|
| `CrashDumpEnabled` | DWORD | `7` (Automatic) |
| `AutoReboot` | DWORD | `0` |
| `AlwaysKeepMemoryDump` | DWORD | `1` |
| `Overwrite` | DWORD | `1` |
| `LogEvent` | DWORD | `1` |
| `DumpFile` | ExpandString | `%SystemRoot%\MEMORY.DMP` |
| `MinidumpDir` | ExpandString | `%SystemRoot%\Minidump` |
| `DedicatedDumpFile` | ExpandString | `C:\DedicatedDump.sys` |

**CrashDumpEnabled values**:

| Value | Name | Behavior |
|---|---|---|
| `0` | None | No dump |
| `1` | Complete | Full RAM — needs pagefile ≥ RAM (blocked on KVM) |
| `2` | Kernel | Kernel pages only — needs pagefile (blocked on KVM) |
| `3` | Small/Minidump | 256KB — needs pagefile (blocked on KVM) |
| `7` | **Automatic** | Like kernel, Windows manages pagefile size — **pipeline default** |
| `11` | Filtered | Variable — needs DedicatedDumpFile |

## Related

- `crash-control.json` — Recommended values database (`src/data/`)
- `guest-agent.py` — Execution tunnel (`src/scripts/host/`)
- `preflight-rhov.sh` — Calls configure-dumps.ps1 and validates output (`src/scripts/host/`)
