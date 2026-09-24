#!/usr/bin/env bash
# run.sh - run the bsod-host-tools container with the right podman mounts.
#
# Wraps `podman run` so the containerized libguestfs can read the guest qcow2
# and write recovered dumps into the project's git-ignored output dir.
# See README.md for podman configuration details.
#
# Usage:
#   host-tools/run.sh --disk <imgFile> [--out <outDir>]
#
# Examples:
#   host-tools/run.sh --disk /var/lib/libvirt/images/bsod-test.qcow2
#   host-tools/run.sh --disk <img> --out ./output/dumps
#
# See README.md for build instructions and BSOD_HOST_IMAGE override.
set -euxo pipefail; shopt -s inherit_errexit

typeset image="${BSOD_HOST_IMAGE:-bsod-host-tools}"
typeset here=''
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset project=''
project="$(cd "${here}/.." && pwd)"

typeset disk=''; typeset out="${project}/output/dumps"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --disk) disk="$2"; shift 2 ;;
    --out)  out="$2"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "run.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "${disk}" ]] || { echo "run.sh: --disk is required" >&2; exit 2; }
[[ -r "${disk}" ]] || { echo "run.sh: cannot read disk: ${disk} (need libvirt group or root)" >&2; exit 2; }
mkdir -p "${out}"

# The disk image lives under /var/lib/libvirt/images (root-owned). Rootless
# podman may not be able to read it; if so, run this wrapper via sudo or add an
# ACL. We bind the *file* read-only.
#
# SELinux: the disk under /var/lib/libvirt/images is typically root-owned with a
# libvirt label (virt_image_t). We must NOT use ':Z' on it - relabeling a file
# you don't own fails with EPERM and would also break libvirt's own access.
# Instead bind it ':ro' and disable label separation for this container so it
# can read the existing label. The output dir we own, so ':Z' is correct there.
typeset -a selinuxOpt=()
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" != "Disabled" ]]; then
  selinuxOpt=(--security-opt label=disable)
fi

exec podman run --rm \
  --userns=keep-id \
  "${selinuxOpt[@]}" \
  -v "${disk}":/images/"$(basename "${disk}")":ro \
  -v "${out}":/out:Z \
  "${image}" \
  --disk /images/"$(basename "${disk}")" --out /out
