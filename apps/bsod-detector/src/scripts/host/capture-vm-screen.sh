#!/usr/bin/env bash
# capture-vm-screen.sh - rapid-fire VM framebuffer capture for BSOD evidence.
#
# Captures multiple frames from the VM's display in rapid succession. Designed
# to run concurrently with a crash trigger so at least one frame catches the
# BSOD screen before auto-reboot clears it.
#
# Requires: virsh (libvirt). The VM MUST use a QXL or VGA video device; virtio
# video does NOT expose the framebuffer during a kernel crash (shows "Display
# output is not active" because the guest driver stops submitting frames).
#
# For KubeVirt/OpenShift Virtualization, replace `virsh screenshot` with the
# equivalent `virtctl` or API call against the VNC/SPICE endpoint.
#
# Usage:
#   capture-vm-screen.sh --vm <name> --out <dir> [--frames 30] [--interval 0.3]
#
# Outputs: <dir>/bsod-frame-{1..N}.png (one PNG per captured frame)
set -euxo pipefail; shopt -s inherit_errexit

export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

typeset vm=""
typeset outDir=""
typeset frames=30
typeset interval="0.3"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm)       [[ $# -ge 2 ]] || { echo "capture-vm-screen: --vm requires a value" >&2; exit 2; }; vm="$2"; shift 2 ;;
    --out)      [[ $# -ge 2 ]] || { echo "capture-vm-screen: --out requires a value" >&2; exit 2; }; outDir="$2"; shift 2 ;;
    --frames)   [[ $# -ge 2 ]] || { echo "capture-vm-screen: --frames requires a value" >&2; exit 2; }; frames="$2"; shift 2 ;;
    --interval) [[ $# -ge 2 ]] || { echo "capture-vm-screen: --interval requires a value" >&2; exit 2; }; interval="$2"; shift 2 ;;
    -h|--help)  sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "capture-vm-screen: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "${vm}" ]]     || { echo "capture-vm-screen: --vm required" >&2; exit 2; }
[[ -n "${outDir}" ]] || { echo "capture-vm-screen: --out required" >&2; exit 2; }

mkdir -p "${outDir}"

typeset i=''
while IFS= read -r i; do
  virsh screenshot "${vm}" --file "${outDir}/bsod-frame-${i}.png" >/dev/null 2>&1 || true
  sleep "${interval}"
done < <(seq 1 "${frames}")

true
