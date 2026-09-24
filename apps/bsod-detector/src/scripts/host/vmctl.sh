#!/usr/bin/env bash
# vmctl.sh - manage the BSOD-detector test VM and its clean snapshot.
#
# Runs on: the Linux HOST (libvirt/KVM). Talks to qemu:///system, which runs as
# root via libvirtd, so no sudo is needed if you are in the 'libvirt' group.
#
# One golden VM ('bsod-test') plus a 'clean-baseline' snapshot is the whole
# model: revert -> trigger BSOD -> collect -> revert. No per-experiment VM clones.
#
# Usage:
#   vmctl.sh define        # (re)define the domain from src/scripts/bsod-test.domain.xml
#   vmctl.sh snapshot      # create/refresh the 'clean-baseline' snapshot
#   vmctl.sh revert        # revert to 'clean-baseline' (discard crash state)
#   vmctl.sh start|stop|kill|console|status|list
#   vmctl.sh ip            # best-effort guest IP (needs guest agent)
#
# Env overrides: VM_NAME (default bsod-test), SNAP_NAME (default clean-baseline).
set -euxo pipefail; shopt -s inherit_errexit

export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
typeset vmName="${VM_NAME:-bsod-test}"
typeset snapName="${SNAP_NAME:-clean-baseline}"
typeset here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset xml="${here}/bsod-test.domain.xml"

function Die () { echo "vmctl: $*" >&2; exit 1; }
function Have () { command -v "$1" >/dev/null 2>&1; }

Have virsh || Die "virsh not found; install libvirt-client"

typeset cmd="${1:-status}"; shift || true

case "${cmd}" in
  define)
    [[ -f "${xml}" ]] || Die "missing ${xml}"
    virsh define "${xml}"
    : "defined ${vmName} from ${xml}"
    ;;
  snapshot)
    # Internal qcow2 snapshot including RAM if running, disk-only if off.
    virsh snapshot-create-as "${vmName}" "${snapName}" \
      "clean baseline for BSOD testing" --atomic
    virsh snapshot-list "${vmName}"
    ;;
  revert)
    virsh snapshot-revert "${vmName}" "${snapName}" --running
    : "reverted ${vmName} to ${snapName}"
    ;;
  start)   virsh start "${vmName}" ;;
  stop)    virsh shutdown "${vmName}" ;;      # graceful ACPI
  kill)    virsh destroy "${vmName}" ;;       # hard power-off (simulates freeze recovery)
  console) virsh console "${vmName}" ;;
  status)  virsh dominfo "${vmName}" ;;
  list)    virsh list --all ;;
  ip)      virsh domifaddr "${vmName}" --source agent 2>/dev/null \
             || virsh domifaddr "${vmName}" 2>/dev/null \
             || Die "no IP (guest agent not responding?)" ;;
  *) Die "unknown command: ${cmd} (see header for usage)" ;;
esac
true
