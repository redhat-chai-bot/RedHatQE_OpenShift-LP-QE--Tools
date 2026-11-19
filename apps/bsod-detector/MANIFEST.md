# bsod-detector — File Manifest

A catalog of what ships in this tool and why each file is kept.

## Architecture

- **Offline-first:** the guest is a pure crash target. After a BSOD, the host
  stops the VM, mounts the disk via guestfs, and extracts dumps + event logs
  offline. No guest-side scripts, staging, or SSH needed for evidence collection.

---

## src/scripts/host/ — host-side detection, collection, analysis

### Detect / watch
| File | Description |
|---|---|
| `watch-crash.sh` | Primary KubeVirt entry point. Watch a Windows VM for a natural BSOD/freeze via the guest agent and collect evidence offline. |
| `preflight-rhov.sh` | Fail-closed platform/guest/RBAC/storage validation plus a short-lived recovery-image capability probe before arming. |
| `reliability.py` | Pure state-machine, disk-progress, artifact-signature, checksum, and summary primitives. |
| `extract--guest-os--crash-info.sh` | Snapshot-based RHOV recovery using pre-stop metadata and direct durable streams. |
| `collect-host-signals.sh` | Capture host-side crash-correlation signals (split-lock `#AC`, Hyper-V enlightenments). |

### Analyze
| File | Description |
|---|---|
| `parse-dump-header.sh` | Read bug-check code and parameters from a Windows crash dump header (no debugger). |

### Access / lifecycle
| File | Description |
|---|---|
| `guest-agent.py` | Drive a KubeVirt guest via the qemu-guest-agent. |

---

## src/scripts/guest/ — guest-side configuration (one-time setup)

| File | Description |
|---|---|
| `validate-crash-settings.ps1` | Read-only comparison of the guest's CrashControl settings with `crash-control.json` (no writes or reboot); with `-stageNotMyFault` stages the latest NotMyFault and reports its SHA-256. |
| `golden-image-pre-reboot.ps1` | Prepare the golden image before sealing: fetch the latest virtio-win ISO over HTTPS and record its SHA-256 (a cached copy is reused only when it is that same release and still matches its recorded SHA-256), install the QEMU Guest Agent, attempt to install the VirtIO storage drivers, write the CrashControl values (Automatic memory dump, `AutoReboot=0`, no `DedicatedDumpFile`) and configure one fixed `C:\pagefile.sys` of RAM + 257 MB (reboots at the end). It installs no pvpanic driver and leaves Windows boot-recovery settings at their defaults. |
| `golden-image-post-reboot.ps1` | Verify after that reboot that the golden-image crash settings are active; all checks must pass before sealing. |

---

## src/data/ — reference data

| File | Consumed by |
|---|---|
| `bugcheck-codes.json` | parse-dump-header.sh |
| `crash-control.json` | validate-crash-settings.ps1 (read-only comparison); golden-image-pre-reboot.ps1 writes the same values; preflight-rhov.sh copies it to the guest and runs the validator against it |
| `event-sources.json` | Reference data only (no active script consumer) |
| `host-signals.json` | collect-host-signals.sh (host-only) |

---

## src/scripts/crash-injector/ — The Pitcher (test-only)

Quarantined destructive tooling used only to validate the detector against a
disposable snapshotted test VM. See
[`src/scripts/crash-injector/README.md`](src/scripts/crash-injector/README.md).

| File | Description |
|---|---|
| `trigger-bsod-intentional.sh` | Intentional BSOD orchestration for an explicitly disposable test VM: preflight, crash injection, watcher and recovery. |
