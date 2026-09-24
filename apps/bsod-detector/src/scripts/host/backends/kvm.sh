#!/usr/bin/env bash
# kvm.sh — virsh-based (libvirt/KVM) backend for the BSOD detector.
#
# Implements the common VM-operation function signatures defined in dispatch.sh
# using virsh. This is the default backend (BSOD_DET__HYP_PROV=kvm).
#
# Requires: virsh (libvirt-client).

export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

# DomainState <vm> — print the VM state as one of the canonical vocabulary.
function DomainState () {
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

# DetectCrash <vm> — exit 0 if the VM appears crashed or hung, 1 otherwise.
function DetectCrash () {
  typeset state
  state="$(DomainState "$1")"
  [[ "${state}" == "crashed" || "${state}" == "hung" ]]
}

# StartVM <vm> — start the VM.
function StartVM () {
  virsh start "$1" >/dev/null 2>&1
}

# StopVM <vm> — graceful shutdown via ACPI.
function StopVM () {
  virsh shutdown "$1" >/dev/null 2>&1
}

# KillVM <vm> — hard power-off (destroy).
function KillVM () {
  virsh destroy "$1" >/dev/null 2>&1
}

# Screenshot <vm> <outfile> — capture the framebuffer to a PNG file.
function Screenshot () {
  virsh screenshot "$1" --file "$2" >/dev/null 2>&1
}

# SnapshotCreate <vm> <name> — create a named internal snapshot.
function SnapshotCreate () {
  virsh snapshot-create-as "$1" "$2" "bsod-detector snapshot" --atomic
}

# SnapshotRevert <vm> <name> — revert to a named snapshot and start.
function SnapshotRevert () {
  virsh snapshot-revert "$1" "$2" --running
}

# MemoryDump <vm> <outfile> — capture raw guest memory as an ELF file.
function MemoryDump () {
  virsh dump "$1" "$2" --memory-only --verbose 2>&1
}

# GuestIP <vm> — print the guest's IP address (best effort).
function GuestIP () {
  typeset ip
  ip="$(virsh -q domifaddr "$1" 2>/dev/null | awk 'NR==1{print $4}' | cut -d/ -f1)"
  if [[ -z "${ip}" ]]; then
    ip="$(virsh domifaddr "$1" --source agent 2>/dev/null | awk 'NR==2{print $4}' | cut -d/ -f1)"
  fi
  echo "${ip}"
}

# GuestDisk <vm> — print the path to the primary disk image.
function GuestDisk () {
  virsh domblklist "$1" --details 2>/dev/null \
    | awk '$2=="disk" && $4 ~ /^\// {print $4; exit}'
}
