# crash-injector/ — The Pitcher (Manual BSOD Generator)

Everything here exists to **intentionally cause** a Windows bug check, for
*validating* the detector ("The Catcher" — the rest of `src/scripts/`). None of
it runs against production VMs. If you only care about **detecting** a real,
naturally-occurring BSOD/freeze on an OpenShift KubeVirt VM, you never need this
folder — use `../watch-crash.sh` and friends instead.

> ⚠️ **Destructive.** These scripts crash the guest on purpose. Never point them
> at anything but a disposable, snapshotted test VM.

## What's here

| File | Role |
|---|---|
| `trigger-bsod.ps1` | Driver-free crash → `0xEF CRITICAL_PROCESS_DIED` (`RtlSetProcessIsCritical` + `TerminateProcess(-1)`). Runs in-guest, synchronously. |
| `setup-notmyfault.ps1` | Downloads Sysinternals NotMyFault (ships `myfault.sys`) for a driver-based crash (e.g. `/crash 0x01` → `0xD1`). |
| `diag-critical-api.ps1` | Validates the `RtlSetProcessIsCritical` P/Invoke path **without** crashing — for debugging a trigger that silently no-ops. |
| `prep-guest.ps1` | One-time golden-guest prep: kernel-dump CrashControl, system-managed page file, and **installs the CrashMe driver**. |
| `run-dry-run.sh` | Host-side one-shot loop: revert → boot → trigger one bug check → delegate to `../collect-all.sh`. |
| `sweep-crashme.sh` | Host-side sweep of all 19 `KeBugCheckEx` codes from `../../data/trigger-methods.json`. |
| `test-driver/` | The **CrashMe** kernel driver (`crashme.sys` + `crashme-ctl.exe`) — the actual bug-check payload, built with mingw64. |

## Dependencies outside this folder

The host-side harnesses drive a local libvirt test VM using utilities that live
in the parent `src/scripts/` (they are shared with, or generic to, the detector):

- `../host/vmctl.sh` + `../host/bsod-test.domain.xml` — define/snapshot/revert the golden VM.
- `../host/guest-ssh.sh` — run PowerShell in the guest over SSH (trigger-only, not collection).
- `../host/collect-all.sh` — legacy evidence collection (invoked by `run-dry-run.sh`).
- `../host/collect-offline.sh` — offline-first evidence collection.
- `../../../src/data/trigger-methods.json` — per-code `KeBugCheckEx` parameters.

## Test VM model

- **`bsod-test`** — a single golden Windows Server 2025 guest (Q35 + UEFI, virtio
  disk/net, TPM 2.0, isa-serial pty, qemu guest agent), defined by
  [`../bsod-test.domain.xml`](../bsod-test.domain.xml).
- **`clean-baseline`** — snapshot to revert to before/after each test.

Test loop: `revert → trigger BSOD (guest) → collect (guest + host) → revert`.

## Running a test

All commands target `qemu:///system` (runs as root via libvirtd; be in the
`libvirt` group, no sudo). Run from the app root (`apps/bsod-detector`):

```bash
export LIBVIRT_DEFAULT_URI=qemu:///system

# one crash, specific code:
./src/scripts/crash-injector/run-dry-run.sh --code 0x19

# full KeBugCheckEx sweep (all 19 codes):
./src/scripts/crash-injector/sweep-crashme.sh
```

**Driver Verifier is enabled** in the golden guest (it changes several outcomes;
notably `0x0A` is observed as `0xD1`). If you disable it (`verifier /reset` +
reboot), re-run the sweep to re-baseline `../../data/trigger-methods.json`.

## Rebuilding the baseline

The `clean-baseline` snapshot is test-ready: automatic crash dump configured
(`CrashDumpEnabled=7`, `AlwaysKeepMemoryDump=1`, `AutoReboot=0`), page file
system-managed (~8 GB), the CrashMe driver staged in `C:\Tools`, the project
`src/scripts/` and `src/data/` staged under `C:\bsod-detector\`, SSH key auth
installed, and Driver Verifier enabled. To rebuild from scratch:

```bash
./src/scripts/host/vmctl.sh start
./src/scripts/host/guest-ssh.sh -f src/scripts/crash-injector/prep-guest.ps1   # idempotent
./src/scripts/host/guest-ssh.sh -c 'Restart-Computer -Force'                   # activates page file
./src/scripts/host/vmctl.sh stop
virsh snapshot-delete bsod-test clean-baseline; ./src/scripts/host/vmctl.sh snapshot
```

## Recreating the VM from scratch

```bash
./src/scripts/host/vmctl.sh define      # (re)define domain from host/bsod-test.domain.xml
./src/scripts/host/vmctl.sh start
```

The domain XML references a disk at `/var/lib/libvirt/images/bsod-test.qcow2`
and install ISOs (now ejected). To reinstall, re-attach the Server 2025 +
virtio-win ISOs with `virsh change-media`.
