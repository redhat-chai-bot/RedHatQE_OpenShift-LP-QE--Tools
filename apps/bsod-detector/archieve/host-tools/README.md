# host-tools/ — containerized host-side tooling (podman)

Host-side crash-dump recovery, packaged as a podman image so the workflow is
reproducible and does not install libguestfs/qemu tooling directly on the host.

## Why a container

On a **Linux/KVM** host, the host-side job from
[`../docs/tool-selection.md`](../docs/tool-selection.md) ("mount the guest VHDX
to pull MEMORY.DMP when the guest won't boot") maps to: open the guest **qcow2**
offline with **libguestfs** and copy the dumps out of the NTFS filesystem. The
image bundles libguestfs, qemu-img, and libvirt-client for that purpose.

> The `src/scripts/collect-from-host.ps1` script targets a **Hyper-V** host
> (Mount-VHD / LiveKd). This container is the **Linux/KVM** equivalent for the
> actual host we run on. Both do the same job from their respective host OS.

## Contents

- `extract-dump.sh` — (runs in-container) copies `MEMORY.DMP`,
  `Minidump\*.dmp`, and `.evtx` event log files (System.evtx,
  Application.evtx) out of a disk image; emits one JSON result to stdout.
- `run.sh` — (runs on host) `podman run` wrapper wiring the correct mounts.

The container **Dockerfile** and build **Makefile** live in the repo's image
tree at [`image/container/bsod-detector/`](../../../image/container/bsod-detector/),
following the repository convention (source under `apps/`, build under
`image/container/`). The Dockerfile's build context is this app directory
(`apps/bsod-detector/`), so it `COPY`s `host-tools/extract-dump.sh` from here.

## Build & run

```bash
# Build (from the repo root). Tag it bsod-host-tools so run.sh finds it:
podman build -t bsod-host-tools \
  -f image/container/bsod-detector/Dockerfile apps/bsod-detector

# or via the Makefile:
make -C image/container/bsod-detector build IMAGE_TAG=host-tools
# (then set BSOD_HOST_IMAGE to the resulting quay.io/redhatqe/bsod-detector:host-tools tag)

# Extract dumps from the (offline) golden VM disk into ./output/dumps
apps/bsod-detector/host-tools/run.sh \
  --disk /var/lib/libvirt/images/bsod-test.qcow2
```

Output JSON (stdout):

```json
{ "ok": true, "disk": "...", "outputDir": "/out",
  "dumpFiles": ["MEMORY.DMP", "Minidump/..."], "warnings": [] }
```

## Podman conventions

- `--rm` — ephemeral containers, nothing left behind.
- `-v <disk>:...:ro` — disk image bound **read-only**. We do NOT add `:Z` to the
  disk: it is root-owned with a libvirt SELinux label (`virt_image_t`), and
  relabeling a file you don't own fails with EPERM (and would break libvirt's
  own access). Instead `run.sh` adds `--security-opt label=disable` so the
  container can read the existing label without relabeling.
- `-v <out>:/out:Z` — output bound read-write; `Z` relabels it (we own it).
- `--userns=keep-id` — recovered files are owned by the invoking user (rootless).
- `LIBGUESTFS_BACKEND=direct` — libguestfs runs its own appliance; works without
  `/dev/kvm` in the container (slower via TCG).

## Caveats

- The disk under `/var/lib/libvirt/images` is root-owned but world-readable
  (`0644`) in this setup, so rootless podman can read it directly. If your disk
  is mode `0600`, run `run.sh` via `sudo`, add a read ACL, or copy the qcow2
  somewhere readable first.
- **Only read the disk when the VM is shut off.** Reading a running guest's
  qcow2 offline can see an inconsistent filesystem. For a live guest use the
  guest-side collector or LiveKd over the serial pipe instead.
