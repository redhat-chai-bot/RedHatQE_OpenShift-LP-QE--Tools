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
| `configure-dumps.ps1` | Configure CrashControl registry settings (`AutoReboot=0`, dump type). |
| `golden-image-pre-reboot.ps1` | Prepare the golden image before sealing: VirtIO drivers, guest agent, pvpanic, recovery disabled, crash-dump registry, pre-allocated `DedicatedDump.sys` and `pagefile.sys` (reboots at the end). |
| `golden-image-post-reboot.ps1` | Verify after that reboot that the golden-image crash settings are active; all checks must pass before sealing. |

---

## src/data/ — reference data

| File | Consumed by |
|---|---|
| `bugcheck-codes.json` | parse-dump-header.sh |
| `crash-control.json` | configure-dumps.ps1, preflight-rhov.sh |
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
