#!/usr/bin/env bash
# kubevirt.sh — virtctl/oc-based backend for the BSOD detector.
#
# Implements the common VM-operation function signatures defined in dispatch.sh
# for OpenShift Virtualization (KubeVirt). Uses virtctl and oc.
#
# Cluster behavior is runtime-unverified locally. Destructive operations fail
# closed and never patch the user's VM spec.
#
# Requires: oc, virtctl (or oc virt plugin).
# Required env: BSOD_DET__NAMESPACE.

typeset _kubevirt_ns="${BSOD_DET__NAMESPACE:-}"

# _resolve_ns — require an explicit namespace; never select the first VMI in a
# cluster-wide listing.
function _resolve_ns() {
  [[ -n "${_kubevirt_ns}" ]] || {
    echo "kubevirt: cannot resolve namespace; set BSOD_DET__NAMESPACE" >&2
    return 1
  }
}

# _require_manual_vm <vm> — fail closed before any lifecycle/capture action.
function _require_manual_vm() {
  _resolve_ns || return 1
  [[ "$(oc get vm "$1" -n "${_kubevirt_ns}" -o jsonpath='{.spec.runStrategy}' 2>/dev/null)" == "Manual" ]] || {
    echo "kubevirt: exact VM ${_kubevirt_ns}/$1 must exist and use runStrategy Manual" >&2
    return 1
  }
}

# domain_state <vm> — print the VM state as one of the canonical vocabulary.
# UNTESTED: requires live KubeVirt cluster.
function domain_state() {
  _resolve_ns || {
    echo "unknown"
    return
  }
  typeset phase
  phase="$(oc get vmi "$1" -n "${_kubevirt_ns}" -o jsonpath='{.status.phase}' 2>/dev/null)" || {
    echo "unknown"
    return
  }
  case "${phase}" in
    Running | Scheduled) echo "running" ;;
    Succeeded | Failed) echo "off" ;;
    *) echo "unknown" ;;
  esac
}

# detect_crash <vm> — exit 0 if the VM appears crashed or hung.
# UNTESTED: uses qemu-guest-agent ping via the virt-launcher pod.
function detect_crash() {
  _resolve_ns || return 1
  # This generic backend has no freshness timestamp, so it cannot safely
  # authorize destructive work. watch-crash.sh owns fresh Panicked detection.
  return 1
}

# start_vm <vm> — start the VM via virtctl.
# UNTESTED: requires live KubeVirt cluster.
function start_vm() {
  _require_manual_vm "$1" || return 1
  virtctl start "$1" -n "${_kubevirt_ns}"
}

# stop_vm <vm> — graceful shutdown via virtctl.
# UNTESTED: requires live KubeVirt cluster.
function stop_vm() {
  _require_manual_vm "$1" || return 1
  virtctl stop "$1" -n "${_kubevirt_ns}"
}

# kill_vm <vm> — force stop via virtctl.
# UNTESTED: requires live KubeVirt cluster.
function kill_vm() {
  _require_manual_vm "$1" || return 1
  virtctl stop "$1" -n "${_kubevirt_ns}" --force 2>/dev/null ||
    oc delete vmi "$1" -n "${_kubevirt_ns}" 2>/dev/null
}

# screenshot <vm> <outfile> — upstream virtctl VNC screenshot API.
function screenshot() {
  typeset signature
  _require_manual_vm "$1" || return 1
  virtctl vnc screenshot "$1" -n "${_kubevirt_ns}" -f "$2"
  [[ -s "$2" ]] || return 1
  signature="$(od -An -tx1 -N8 "$2" | tr -d ' \n')"
  [[ "${signature}" == "89504e470d0a1a0a" ]]
}

# snapshot_create <vm> <name> — NOT SUPPORTED on KubeVirt.
# KubeVirt VMs use PVC-based storage; snapshotting requires
# VolumeSnapshot CRDs, which is a different workflow.
function snapshot_create() {
  echo "kubevirt: snapshot_create not supported (use VolumeSnapshot CRDs)" >&2
  return 1
}

# snapshot_revert <vm> <name> — NOT SUPPORTED on KubeVirt.
function snapshot_revert() {
  echo "kubevirt: snapshot_revert not supported (use VolumeSnapshot CRDs)" >&2
  return 1
}

# memory_dump <vm> <outfile> — KubeVirt memory-dump API + VMExport download.
function memory_dump() {
  _require_manual_vm "$1" || return 1
  typeset claim size elapsed=0
  claim="bsod-mem-${1:0:28}-$(date -u +%Y%m%d%H%M%S)"
  virtctl memory-dump get "$1" -n "${_kubevirt_ns}" --claim-name="${claim}" \
    --create-claim --format=raw --output="$2" || return 1
  [[ -s "$2" ]] || return 1
  size="$(stat -c '%s' "$2")" || return 1
  ((size >= 1048576)) || return 1
  virtctl memory-dump remove "$1" -n "${_kubevirt_ns}" || return 1
  while ((elapsed < 120)); do
    if [[ "$(oc get vm "$1" -n "${_kubevirt_ns}" -o json | jq -r '.status.memoryDumpRequest // empty')" == "" ]]; then
      oc delete pvc "${claim}" -n "${_kubevirt_ns}" --ignore-not-found --wait=true >/dev/null
      return
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  echo "kubevirt: memory dump association did not clear for ${_kubevirt_ns}/$1" >&2
  return 1
}

# guest_ip <vm> — print the guest IP from the VMI status.
# UNTESTED: requires live KubeVirt cluster.
function guest_ip() {
  _resolve_ns || return 1
  oc get vmi "$1" -n "${_kubevirt_ns}" \
    -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null
}

# guest_disk <vm> — NOT DIRECTLY ACCESSIBLE on KubeVirt. The generic backend
# contract expects a local path, while RHOV has a PVC. Fail explicitly rather
# than returning a PVC that a caller could mistake for a host file.
function guest_disk() {
  echo "kubevirt: guest_disk is unsupported; use stopped-PVC snapshot recovery" >&2
  return 1
}
