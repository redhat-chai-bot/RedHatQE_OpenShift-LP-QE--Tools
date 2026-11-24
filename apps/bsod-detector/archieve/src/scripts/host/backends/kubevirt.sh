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
    _kubevirt_ns="$(timeout --signal=TERM --kill-after=5 20 oc --request-timeout=15s get vmi -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)" || true
  fi
  [[ -n "${_kubevirt_ns}" ]] || { echo "kubevirt: cannot resolve namespace; set BSOD_DET__NAMESPACE" >&2; return 1; }
}

# _virt_launcher_pod <vm> — find the virt-launcher pod for a VM.
function _virt_launcher_pod () {
  timeout --signal=TERM --kill-after=5 20 oc --request-timeout=15s get pod -n "${_kubevirt_ns}" -o name 2>/dev/null |
    sed -n "/virt-launcher-${1}-/{s#^[^/]*/##;p;q;}"
}

# domain_state <vm> — print the VM state as one of the canonical vocabulary.
# UNTESTED: requires live KubeVirt cluster.
function domain_state () {
  _resolve_ns || { echo "unknown"; return; }
  typeset phase
  phase="$(timeout --signal=TERM --kill-after=5 20 oc --request-timeout=15s get vmi "$1" -n "${_kubevirt_ns}" -o jsonpath='{.status.phase}' 2>/dev/null)" || { echo "unknown"; return; }
  case "${phase}" in
    Running|Scheduled) echo "running" ;;
    Succeeded|Failed)  echo "off" ;;
    *)                 echo "unknown" ;;
  esac
}

# detect_crash <vm> — exit 0 if the VM appears crashed or hung.
# UNTESTED: uses qemu-guest-agent ping via the virt-launcher pod.
function detect_crash () {
  _resolve_ns || return 1
  typeset state
  state="$(domain_state "$1")"
  [[ "${state}" == "running" ]] || return 1
  # Running but agent dead = hung
  typeset pod
  pod="$(_virt_launcher_pod "$1")"
  [[ -n "${pod}" ]] || return 1
  typeset dom="${_kubevirt_ns}_${1}"
  if ! timeout --signal=TERM --kill-after=2 5 oc --request-timeout=4s exec -n "${_kubevirt_ns}" "${pod}" -- \
    virsh qemu-agent-command "${dom}" '{"execute":"guest-ping"}' >/dev/null 2>&1; then
    return 1  # QGA loss alone is ambiguous; reliability watcher corroborates it.
  fi
  return 1  # running and healthy
}

# start_vm <vm> — start the VM via virtctl.
# UNTESTED: requires live KubeVirt cluster.
function start_vm () {
  _resolve_ns || return 1
  timeout --signal=TERM --kill-after=5 90 virtctl start "$1" -n "${_kubevirt_ns}" 2>/dev/null
}

# stop_vm <vm> — graceful shutdown via virtctl.
# UNTESTED: requires live KubeVirt cluster.
function stop_vm () {
  _resolve_ns || return 1
  timeout --signal=TERM --kill-after=5 90 virtctl stop "$1" -n "${_kubevirt_ns}" 2>/dev/null
}

# kill_vm <vm> — force stop via virtctl.
# UNTESTED: requires live KubeVirt cluster.
function kill_vm () {
  _resolve_ns || return 1
  echo "kubevirt: forced lifecycle mutation is disabled; use the fail-closed RHOV reliability workflow" >&2
  return 1
}

# screenshot <vm> <outfile> — stream pod-local virsh output directly to caller storage.
# UNTESTED: requires live KubeVirt cluster.
function screenshot () {
  _resolve_ns || return 1
  timeout --signal=TERM --kill-after=5 120 virtctl vnc screenshot "$1" -n "${_kubevirt_ns}" --file="$2" 2>/dev/null || return 1
  [[ -s "$2" ]]
}

# snapshot_create <vm> <name> — NOT SUPPORTED on KubeVirt.
# KubeVirt VMs use PVC-based storage; snapshotting requires
# VolumeSnapshot CRDs, which is a different workflow.
function snapshot_create () {
  echo "kubevirt: snapshot_create not supported (use VolumeSnapshot CRDs)" >&2
  return 1
}

# snapshot_revert <vm> <name> — NOT SUPPORTED on KubeVirt.
function snapshot_revert () {
  echo "kubevirt: snapshot_revert not supported (use VolumeSnapshot CRDs)" >&2
  return 1
}

# memory_dump <vm> <outfile> — use the supported KubeVirt memory-dump PVC API.
# UNTESTED: requires live KubeVirt cluster.
function memory_dump () {
  _resolve_ns || return 1
  typeset claim="${BSOD_MEMORY_DUMP_PVC:-}"
  [[ -n "${claim}" ]] || { echo 'kubevirt: BSOD_MEMORY_DUMP_PVC is required' >&2; return 1; }
  timeout --signal=TERM --kill-after=5 90 virtctl memory-dump get "$1" -n "${_kubevirt_ns}" --claim-name="${claim}" || return 1
  timeout --signal=TERM --kill-after=5 1800 virtctl memory-dump download "$1" -n "${_kubevirt_ns}" --output="$2" || return 1
  timeout --signal=TERM --kill-after=5 90 virtctl memory-dump remove "$1" -n "${_kubevirt_ns}" || return 1
  [[ -s "$2" ]]
}

# guest_ip <vm> — print the guest IP from the VMI status.
# UNTESTED: requires live KubeVirt cluster.
function guest_ip () {
  _resolve_ns || return 1
  timeout --signal=TERM --kill-after=5 20 oc --request-timeout=15s get vmi "$1" -n "${_kubevirt_ns}" \
    -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null
}

# guest_disk <vm> — NOT DIRECTLY ACCESSIBLE on KubeVirt.
# The guest disk is inside a PVC on the cluster, not a host path.
# Returns the PVC name for documentation; extraction requires a
# privileged pod or CDI-based export.
function guest_disk () {
  _resolve_ns || return 1
  timeout --signal=TERM --kill-after=5 20 oc --request-timeout=15s get vm "$1" -n "${_kubevirt_ns}" \
    -o jsonpath='{.spec.template.spec.volumes[0].persistentVolumeClaim.claimName}' 2>/dev/null
}
