#!/usr/bin/env bash
# dispatch.sh — source the correct hypervisor backend based on BSOD_DET__HYP_PROV.
#
# Source this file from any host-side script that needs VM operations. It
# exports common function signatures (DetectCrash, StartVM, StopVM, etc.)
# implemented by the selected backend.
#
# Supported backends:
#   kvm      — virsh (libvirt). Default.
#   kubevirt — virtctl / oc (OpenShift Virtualization).
#
# Usage:
#   export BSOD_DET__HYP_PROV=kvm   # or kubevirt
#   source "$(dirname "${BASH_SOURCE[0]}")/backends/dispatch.sh"
#   DetectCrash "$vm"
#
# Each backend must define these functions:
#   DomainState <vm>            — print one of: running|off|hung|crashed|rebooting|unknown
#   DetectCrash <vm>            — exit 0 if crashed/hung, 1 otherwise
#   StartVM <vm>                — start the VM
#   StopVM <vm>                 — graceful shutdown (ACPI)
#   KillVM <vm>                 — hard power-off
#   Screenshot <vm> <outfile>   — capture framebuffer to a file
#   SnapshotCreate <vm> <name>  — create a named snapshot
#   SnapshotRevert <vm> <name>  — revert to a named snapshot
#   MemoryDump <vm> <outfile>   — capture raw memory (ELF format)
#   GuestIP <vm>                — print the guest IP address
#   GuestDisk <vm>              — print the path to the primary guest disk image

typeset _dispatchDir
_dispatchDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

typeset _provider="${BSOD_DET__HYP_PROV:-kvm}"

case "${_provider}" in
  kvm)
    # shellcheck source=kvm.sh
    source "${_dispatchDir}/kvm.sh"
    ;;
  kubevirt)
    # shellcheck source=kubevirt.sh
    source "${_dispatchDir}/kubevirt.sh"
    ;;
  *)
    echo "dispatch: unknown BSOD_DET__HYP_PROV='${_provider}' (valid: kvm, kubevirt)" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac
