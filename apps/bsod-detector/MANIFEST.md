# bsod-detector — File Manifest

A catalog of what ships in this tool and why each file is kept.

## Architecture

- **Offline-first:** the guest is a pure crash target. After a BSOD, the host
  stops the VM, mounts the disk via guestfs, and extracts dumps + event logs
  offline. No guest-side scripts, staging, or SSH needed for evidence collection.

- **Backend-abstracted:** VM operations go through `backends/dispatch.sh` which
  selects `kvm.sh` (virsh) or `kubevirt.sh` (virtctl/oc) based on
  `BSOD_DET__HYP_PROV`.

---

## src/scripts/host/ — host-side detection, collection, analysis

### Detect / watch
| File | Description |
|---|---|
| `watch-crash.sh` | Primary KubeVirt entry point. Watch a Windows VM for a natural BSOD/freeze via the guest agent and collect evidence offline. |
| `preflight-rhov.sh` | Fail-closed platform/guest/RBAC/storage validation plus a short-lived recovery-image capability probe before arming. |
| `reliability.py` | Pure state-machine, disk-progress, artifact-signature, checksum, and summary primitives. |
| `extract--guest-os--crach-info.sh` | Snapshot-based RHOV recovery using pre-stop metadata and direct durable streams. |
| `collect-from-host.sh` | Libvirt host-side BSOD/freeze detector + offline dump recovery. |
| `collect-host-signals.sh` | Capture host-side crash-correlation signals (split-lock `#AC`, Hyper-V enlightenments). |

### Collect / capture
| File | Description |
|---|---|
| `collect-offline.sh` | **Primary orchestrator.** Stop VM → extract dumps+evtx via guestfs → parse → assemble evidence. |
| `capture-host-dump.sh` | Raw VM memory capture via `virsh dump --memory-only` (ELF backup artifact). |
| `capture-vm-screen.sh` | Rapid-fire VM framebuffer capture for BSOD screenshot. |

### Analyze
| File | Description |
|---|---|
| `parse-dump-header.sh` | Read bug-check code and parameters from a Windows crash dump header (no debugger). |
| `extract-evtx.py` | Parse offline-extracted `.evtx` event log files into crash-detection JSON. |

### Access / lifecycle
| File | Description |
|---|---|
| `guest-agent.py` | Drive a KubeVirt guest via the qemu-guest-agent. |
| `guest-ssh.sh` | Run PowerShell in the guest over SSH. **Trigger-only** — not used for collection. |
| `vmctl.sh` | Manage the local libvirt test VM and its snapshots. |
| `bsod-test.domain.xml` | Libvirt domain definition for the golden test VM. |

### Backend abstraction
| File | Description |
|---|---|
| `backends/dispatch.sh` | Source the correct backend based on `BSOD_DET__HYP_PROV`. |
| `backends/kvm.sh` | virsh-based VM operations (tested). |
| `backends/kubevirt.sh` | virtctl/oc-based VM operations (untested — requires live cluster). |

---

## src/scripts/guest/ — guest-side configuration (one-time setup)

| File | Description |
|---|---|
| `configure-dumps.ps1` | Configure CrashControl registry settings (`AutoReboot=0`, dump type). |
| `clear-dumps.ps1` | Delete existing dumps before a test run. |

---

## src/data/ — reference data

| File | Consumed by |
|---|---|
| `bugcheck-codes.json` | parse-dump-header.sh, extract-evtx.py |
| `crash-control.json` | configure-dumps.ps1, prep-guest.ps1 |
| `event-sources.json` | extract-evtx.py |
| `host-signals.json` | collect-host-signals.sh (host-only) |
| `trigger-methods.json` | sweep-crashme.sh (host-only) |
| `chaos-triggers.json` | sweep-chaos.sh (host-only) |
| `blkdebug-read-errors.conf` | QEMU blkdebug chaos trigger (host-only) |

---

## src/scripts/crash-injector/ — The Pitcher (test-only)

Quarantined destructive tooling used only to validate the detector against a
disposable snapshotted test VM. See
[`src/scripts/crash-injector/README.md`](src/scripts/crash-injector/README.md).

---

## host-tools/ — containerized offline extraction

| File | Description |
|---|---|
| `extract-dump.sh` | (in-container) Extract MEMORY.DMP, minidumps, and .evtx files from a guest disk. |
| `run.sh` | (host) `podman run` wrapper with correct mounts. |

Container image definition: `image/container/bsod-detector/`.
