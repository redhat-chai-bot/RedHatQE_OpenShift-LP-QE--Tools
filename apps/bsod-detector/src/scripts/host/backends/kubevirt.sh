#!/usr/bin/env bash
# kubevirt.sh — virtctl/oc-based backend for the BSOD detector.
#
# Implements the common VM-operation function signatures defined in dispatch.sh
# for OpenShift Virtualization (KubeVirt). Uses virtctl and oc.
#
# *** UNTESTED — requires a live KubeVirt/OpenShift cluster. ***
# All functions are structurally complete but have not been validated against
# a real cluster. Use with caution and expect adjustments.
#
# Requires: oc, virtctl (or oc virt plugin).
# Optional env: BSOD_DET__NAMESPACE (default: auto-detected from VMI).

typeset _kubevirt_ns="${BSOD_DET__NAMESPACE:-}"

# _resolve_ns — auto-detect namespace if not set.
function _resolve_ns () {
  if [[ -z "${_kubevirt_ns}" ]]; then
    _kubevirt_ns="$(oc get vmi -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)" || true
  fi
  [[ -n "${_kubevirt_ns}" ]] || { echo "kubevirt: cannot resolve namespace; set BSOD_DET__NAMESPACE" >&2; return 1; }
}

# _virt_launcher_pod <vm> — find the virt-launcher pod for a VM.
function _virt_launcher_pod () {
  oc get pod -n "${_kubevirt_ns}" -o name 2>/dev/null \
    | sed -n "/virt-launcher-${1}-/p" | head -n1 | cut -d/ -f2
}

# DomainState <vm> — print the VM state as one of the canonical vocabulary.
# UNTESTED: requires live KubeVirt cluster.
function DomainState () {
  _resolve_ns || { echo "unknown"; return; }
  typeset phase
  phase="$(oc get vmi "$1" -n "${_kubevirt_ns}" -o jsonpath='{.status.phase}' 2>/dev/null)" || { echo "unknown"; return; }
  case "${phase}" in
    Running|Scheduled) echo "running" ;;
    Succeeded|Failed)  echo "off" ;;
    *)                 echo "unknown" ;;
  esac
}

# DetectCrash <vm> — exit 0 if the VM appears crashed or hung.
# UNTESTED: uses qemu-guest-agent ping via the virt-launcher pod.
function DetectCrash () {
  _resolve_ns || return 1
  typeset state
  state="$(DomainState "$1")"
  if [[ "${state}" != "running" ]]; then
    [[ "${state}" == "off" ]] && return 1
    return 0
  fi
  # Running but agent dead = hung
  typeset pod
  pod="$(_virt_launcher_pod "$1")"
  [[ -n "${pod}" ]] || return 1
  typeset dom="${_kubevirt_ns}_${1}"
  if ! timeout 5 oc exec -n "${_kubevirt_ns}" "${pod}" -- \
    virsh qemu-agent-command "${dom}" '{"execute":"guest-ping"}' >/dev/null 2>&1; then
    return 0  # agent dead while running = crashed/hung
  fi
  return 1  # running and healthy
}

# StartVM <vm> — start the VM via virtctl.
# UNTESTED: requires live KubeVirt cluster.
function StartVM () {
  _resolve_ns || return 1
  virtctl start "$1" -n "${_kubevirt_ns}" 2>/dev/null || \
    oc patch vm "$1" -n "${_kubevirt_ns}" --type merge -p '{"spec":{"running":true}}' 2>/dev/null
}

# StopVM <vm> — graceful shutdown via virtctl.
# UNTESTED: requires live KubeVirt cluster.
function StopVM () {
  _resolve_ns || return 1
  virtctl stop "$1" -n "${_kubevirt_ns}" 2>/dev/null || \
    oc patch vm "$1" -n "${_kubevirt_ns}" --type merge -p '{"spec":{"running":false}}' 2>/dev/null
}

# KillVM <vm> — force stop via virtctl.
# UNTESTED: requires live KubeVirt cluster.
function KillVM () {
  _resolve_ns || return 1
  virtctl stop "$1" -n "${_kubevirt_ns}" --force 2>/dev/null || \
    oc delete vmi "$1" -n "${_kubevirt_ns}" 2>/dev/null
}

# Screenshot <vm> <outfile> — capture via virsh screenshot inside virt-launcher.
# UNTESTED: requires live KubeVirt cluster.
function Screenshot () {
  _resolve_ns || return 1
  typeset pod
  pod="$(_virt_launcher_pod "$1")"
  [[ -n "${pod}" ]] || return 1
  typeset dom="${_kubevirt_ns}_${1}"
  oc exec -n "${_kubevirt_ns}" "${pod}" -- \
    virsh screenshot "${dom}" /tmp/screenshot.ppm >/dev/null 2>&1 || return 1
  oc cp "${_kubevirt_ns}/${pod}:/tmp/screenshot.ppm" "$2" >/dev/null 2>&1
}

# SnapshotCreate <vm> <name> — NOT SUPPORTED on KubeVirt.
# KubeVirt VMs use PVC-based storage; snapshotting requires
# VolumeSnapshot CRDs, which is a different workflow.
function SnapshotCreate () {
  echo "kubevirt: SnapshotCreate not supported (use VolumeSnapshot CRDs)" >&2
  return 1
}

# SnapshotRevert <vm> <name> — NOT SUPPORTED on KubeVirt.
function SnapshotRevert () {
  echo "kubevirt: SnapshotRevert not supported (use VolumeSnapshot CRDs)" >&2
  return 1
}

# MemoryDump <vm> <outfile> — capture via virsh dump inside virt-launcher.
# UNTESTED: requires live KubeVirt cluster.
function MemoryDump () {
  _resolve_ns || return 1
  typeset pod
  pod="$(_virt_launcher_pod "$1")"
  [[ -n "${pod}" ]] || return 1
  typeset dom="${_kubevirt_ns}_${1}"
  oc exec -n "${_kubevirt_ns}" "${pod}" -- \
    virsh dump "${dom}" /tmp/guest-memory.elf --memory-only 2>&1 || return 1
  oc cp "${_kubevirt_ns}/${pod}:/tmp/guest-memory.elf" "$2" >/dev/null 2>&1
}

# GuestIP <vm> — print the guest IP from the VMI status.
# UNTESTED: requires live KubeVirt cluster.
function GuestIP () {
  _resolve_ns || return 1
  oc get vmi "$1" -n "${_kubevirt_ns}" \
    -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null
}

# GuestDisk <vm> — NOT DIRECTLY ACCESSIBLE on KubeVirt.
# The guest disk is inside a PVC on the cluster, not a host path.
# Returns the PVC name for documentation; extraction requires a
# privileged pod or CDI-based export.
function GuestDisk () {
  _resolve_ns || return 1
  oc get vm "$1" -n "${_kubevirt_ns}" \
    -o jsonpath='{.spec.template.spec.volumes[0].persistentVolumeClaim.claimName}' 2>/dev/null
}
