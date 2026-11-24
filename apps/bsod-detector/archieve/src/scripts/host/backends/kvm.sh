#!/usr/bin/env bash
# kvm.sh — virsh-based (libvirt/KVM) backend for the BSOD detector.
#
# Implements the common VM-operation function signatures defined in dispatch.sh
# using virsh. This is the default backend (BSOD_DET__HYP_PROV=kvm).
#
# Requires: virsh (libvirt-client).

export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

# domain_state <vm> — print the VM state as one of the canonical vocabulary.
function domain_state () {
  typeset vm="$1"
  typeset raw
  raw="$(virsh domstate "${vm}" 2>/dev/null | head -n1 | sed 's/[[:space:]]*$//')" || { echo "unknown"; return; }
  case "${raw}" in
    running)            echo "running" ;;
    "shut off")         echo "off" ;;
    crashed)            echo "crashed" ;;
    paused|pmsuspended) echo "hung" ;;
    "in shutdown"|dying) echo "rebooting" ;;
    *)                  echo "unknown" ;;
  esac
}

# detect_crash <vm> — exit 0 if the VM appears crashed or hung, 1 otherwise.
function detect_crash () {
  typeset state
  state="$(domain_state "$1")"
  [[ "${state}" == "crashed" || "${state}" == "hung" ]]
}

# start_vm <vm> — start the VM.
function start_vm () {
  virsh start "$1" >/dev/null 2>&1
}

# stop_vm <vm> — graceful shutdown via ACPI.
function stop_vm () {
  virsh shutdown "$1" >/dev/null 2>&1
}

# kill_vm <vm> — hard power-off (destroy).
function kill_vm () {
  virsh destroy "$1" >/dev/null 2>&1
}

# screenshot <vm> <outfile> — capture the framebuffer to a PNG file.
function screenshot () {
  virsh screenshot "$1" --file "$2" >/dev/null 2>&1
}

# snapshot_create <vm> <name> — create a named internal snapshot.
function snapshot_create () {
  virsh snapshot-create-as "$1" "$2" "bsod-detector snapshot" --atomic
}

# snapshot_revert <vm> <name> — revert to a named snapshot and start.
function snapshot_revert () {
  virsh snapshot-revert "$1" "$2" --running
}

# memory_dump <vm> <outfile> — capture raw guest memory as an ELF file.
function memory_dump () {
  virsh dump "$1" "$2" --memory-only --verbose 2>&1
}

# guest_ip <vm> — print the guest's IP address (best effort).
function guest_ip () {
  typeset ip
  ip="$(virsh -q domifaddr "$1" 2>/dev/null | awk 'NR==1{print $4}' | cut -d/ -f1)"
  if [[ -z "${ip}" ]]; then
    ip="$(virsh domifaddr "$1" --source agent 2>/dev/null | awk 'NR==2{print $4}' | cut -d/ -f1)"
  fi
  echo "${ip}"
}

# guest_disk <vm> — print the path to the primary disk image.
function guest_disk () {
  virsh domblklist "$1" --details 2>/dev/null \
    | awk '$2=="disk" && $4 ~ /^\// {print $4; exit}'
}
