# Guest Scripts

PowerShell scripts that run **inside Windows VMs** via the qemu-guest-agent tunnel.

These scripts prepare the golden image, which is where the Windows crash dump settings should be set. Before each run,
preflight also checks the guest's crash settings against `crash-control.json`.

## Script Overview

### Crash-settings validation

Before arming a crash test, preflight runs a guest-side crash-settings step and fails unless the guest reports settings
that match `crash-control.json` (see [Registry Reference](#registry-reference)), with `AutoReboot=0`, an adequate page
file and no pending reboot. Golden-image setup is where these settings should be prepared (see [Golden Image Requirements](#golden-image-requirements)); the
current guest-side step can still apply recommended values that differ before it reports. A read-only validator for this
step, `validate-crash-settings.ps1`, which only checks the settings, is proposed in [#8](https://github.com/redhat-chai-bot/RedHatQE_OpenShift-LP-QE--Tools/pull/8) and is not part of this
tree yet.

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

**At pipeline runtime**, a guest prepared this way reports matching settings with no pending reboot, so preflight passes.

---

## Guest-Agent Communication

```
host: guest-agent.py psfile <script.ps1> --companion crash-control.json C:\Windows\Temp\crash-control.json -- <script arguments>
  ↓
oc exec virt-launcher-<vm>-<hash>
  ↓
virsh qemu-agent-command <ns>_<vm> '<QMP JSON>'
  ↓
qemu-guest-agent (Windows service)
  ↓
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\<script.ps1> <script arguments>
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
- `preflight-rhov.sh` — Runs the guest crash-settings validation and checks its output (`src/scripts/host/`)
