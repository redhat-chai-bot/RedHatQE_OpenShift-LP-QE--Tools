# Archive - Legacy BSOD Detector Components

This folder contains legacy code that is no longer actively used in the RHOV POC pipeline.

## Status
These components were used in earlier iterations of the BSOD detector (KVM/libvirt-based) but have been superseded by the RHOV (Red Hat OpenShift Virtualization) native implementation.

## Structure

### src/scripts/crash-injector/
**Legacy crash injection methods** - Pre-RHOV era, used KVM/libvirt or direct Windows methods:
- `trigger-bsod.ps1` — Old PowerShell-based BSOD trigger via WinRM/SSH
- `setup-notmyfault.ps1` — Old NotMyFault installer for legacy VMs
- `kvm-msr-write.py` — KVM MSR-based crash injection (deprecated, unsafe)
- `run-dry-run.sh` — Old dry-run testing framework
- `sweep-chaos.sh` — Chaos engineering test suite (legacy)
- `sweep-crashme.sh` — Old crashme-based BSOD method
- `diag-critical-api.ps1` — Debug/diagnostics script (obsolete)
- `test-driver/` — Old C++ test driver (superseded by Python reliability.py)

**Why archived:** RHOV POC uses `trigger-bsod-intentional.sh` with NotMyFault binary + intentional crash codes instead.

### src/scripts/host/
**Legacy collection and control methods** - Pre-RHOV, used SSH/libvirt:
- `capture-host-dump.sh` — Host-side memory dump capture (libvirt-specific)
- `capture-vm-screen.sh` — VM screenshot via VNC (old method)
- `collect-all.sh` — Old monolithic collection script
- `collect-from-host.sh` — Legacy host-side evidence collection
- `collect-offline.sh` — Old offline snapshot collection method
- `guest-ssh.sh` — SSH-based guest shell access (superseded by QGA)
- `vmctl.sh` — VM control wrapper for virsh (superseded by virtctl)

**Why archived:** RHOV POC uses:
- `watch-crash.sh` for real-time crash detection and memory capture
- `extract-crash-info.sh` for ODF snapshot-based offline extraction
- `guest-agent.py` for QGA-based guest communication

### src/scripts/guest/
**Legacy guest-side setup** - Pre-RHOV era:
- `clear-dumps.ps1` — Old dump cleanup script
- `prep-guest.ps1` — Old guest preparation script
- `stage-toolkit.ps1` — Old toolkit staging (superseded by cloud-init)

**Why archived:** RHOV POC uses cloud-init + `configure-dumps.ps1` for configuration.

### host-tools/
**Legacy wrapper scripts** - Development-era runners:
- `run.sh` — Old multi-purpose runner wrapper
- `extract-dump.sh` — Old manual dump extraction

**Why archived:** RHOV POC orchestrates through `trigger-bsod-intentional.sh`.

---

## Active RHOV POC Pipeline

See the root-level README and `src/scripts/crash-injector/trigger-bsod-intentional.sh` for the current, maintained pipeline.

### Core RHOV components (actively maintained):
- `src/scripts/crash-injector/trigger-bsod-intentional.sh` — Orchestration
- `src/scripts/host/preflight-rhov.sh` — Cluster validation
- `src/scripts/host/watch-crash.sh` — Crash detection & memory capture
- `src/scripts/host/extract-crash-info.sh` — ODF extraction
- `src/scripts/host/guest-agent.py` — QGA communication
- `src/scripts/host/reliability.py` — Validation
- `src/scripts/guest/configure-dumps.ps1` — Dump config
- Data files: `crash-control.json`, `bugcheck-codes.json`, `event-sources.json`

---

## If you need to use archived code:

1. **For legacy KVM/libvirt environments:** Refer to commit history before this archival for the old pipeline.
2. **For reference:** These files document earlier implementation approaches and may be useful for understanding crash injection techniques.
3. **For restoration:** Simply move files back to their original `src/scripts/` locations if needed.

---

Last updated: 2026-09-28
