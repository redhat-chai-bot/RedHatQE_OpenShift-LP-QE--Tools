# BSOD Detector — unified host-side container image.
#
# Supports two operating modes controlled by the MODE environment variable:
#
#   MODE=watch   (default)
#     Watch a KubeVirt Windows VM for natural or intentional BSODs. Natural
#     crashes require a fresh Panicked event; QGA loss alone is insufficient.
#     Calls watch-crash.sh. Requires oc login
#     (in-cluster ServiceAccount or mounted KUBECONFIG).
#
#   MODE=recover
#     Evidence recovery for a hard-frozen VM (guest won't reboot).
#     Calls recover-natural-crash.sh — snapshots the stopped VM's OS PVC and
#     runs offline libguestfs extraction of dumps and EVTX.
#
#   MODE=extract
#     Offline dump extraction from a guest disk image via libguestfs.
#     Calls extract-dump. Pass --disk / --out as CMD args.
#     Original use case — run via host-tools/run.sh on a KVM host.
#
# All target parameters come from environment variables — nothing is
# hardcoded to a specific VM, namespace, or cluster:
#
#   GA_VM                  VM name (required for watch/recover)
#   GA_NS                  Kubernetes namespace (required for watch/recover)
#   WATCH_INTERVAL         Seconds between QGA pings        (default: 5)
#   WATCH_MISS             Missed pings before crash declared (default: 2)
#   WATCH_REBOOT_WAIT      Seconds to wait for guest reboot  (default: 300)
#   EVIDENCE_DIR           Output directory                  (default: /evidence)
#
# Build (from the repository root):
#   podman build -t bsod-detector -f image/container/bsod-detector/Dockerfile .
#   make -C image/container/bsod-detector build
#
# Run examples:
#   # Watch a VM for natural crashes
#   podman run --rm -e GA_VM=win2022-vm-hjoshi1 -e GA_NS=windows-bsod \
#     -v ./evidence:/evidence bsod-detector
#
#   # Recover evidence from a hard-frozen VM
#   podman run --rm -e MODE=recover \
#     -e GA_VM=win2022-vm-hjoshi1 -e GA_NS=windows-bsod \
#     -v ./evidence:/evidence bsod-detector
#
#   # Offline dump extraction from a disk image (original use case)
#   podman run --rm -e MODE=extract \
#     -v /path/to/guest.qcow2:/disk.qcow2:ro -v ./out:/out \
#     bsod-detector --disk /disk.qcow2 --out /out
#
FROM registry.fedoraproject.org/fedora-minimal:41

# ── System packages ──────────────────────────────────────────────────────────
# libguestfs-tools : virt-copy-out / guestfish  (MODE=extract + MODE=recover PATH2)
# libvirt-client   : local/offline host-signal compatibility helpers
# python3 + pip    : guest-agent.py, parse-dump-header.sh helper
# python-evtx      : offline .evtx event log parsing
# jq               : JSON processing in all shell scripts
# tar / curl       : oc CLI download
RUN <<run-EOF
set -euxo pipefail; shopt -s inherit_errexit
microdnf install -y \
    libguestfs-tools-c \
    qemu-img \
    libvirt-client \
    python3 \
    python3-pip \
    jq \
    curl \
    tar
pip3 install --no-cache-dir python-evtx==0.8.1
microdnf clean all
run-EOF

# ── oc CLI ───────────────────────────────────────────────────────────────────
# Required for MODE=watch and MODE=recover:
#   oc exec  → reach virt-launcher pod → virsh qemu-agent-command
#   oc get   → resolve VMI, pod names, node
#   oc cp    → copy extracted dumps from recovery pod
ARG OCP_VERSION=4.18.23
ARG OCP_CLIENT_SHA256=65cd7a30309e1dd6f5d90ac1125dbf100117cbf1ce5118fc832a401082ed3dd8
RUN <<oc-EOF
set -euxo pipefail
curl -fsSL -o /tmp/openshift-client.tar.gz \
  "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_VERSION}/openshift-client-linux.tar.gz"
echo "${OCP_CLIENT_SHA256}  /tmp/openshift-client.tar.gz" | sha256sum -c -
tar -xzf /tmp/openshift-client.tar.gz -C /usr/local/bin oc kubectl
rm -f /tmp/openshift-client.tar.gz
chmod +x /usr/local/bin/oc /usr/local/bin/kubectl
oc version --client
oc-EOF

# Pinned KubeVirt client. v1.6.6 includes the upstream-supported
# `virtctl vnc screenshot` and `virtctl memory-dump` commands used at runtime.
ARG VIRTCTL_VERSION=v1.6.6
ARG VIRTCTL_SHA256=5957be4150505711f9bdabeb66fc4f9cc343f68c0f3c2e9950e1523a998de1ce
RUN <<virtctl-EOF
set -euxo pipefail
curl -fsSL -o /usr/local/bin/virtctl \
  "https://github.com/kubevirt/kubevirt/releases/download/${VIRTCTL_VERSION}/virtctl-${VIRTCTL_VERSION}-linux-amd64"
echo "${VIRTCTL_SHA256}  /usr/local/bin/virtctl" | sha256sum -c -
chmod 0755 /usr/local/bin/virtctl
virtctl version --client
virtctl-EOF

# ── Scripts ──────────────────────────────────────────────────────────────────
# Build context is repository root (set by the image Makefile).
# All host scripts are copied so the image is self-contained — no volume mounts
# required for scripts, only for evidence output and optional KUBECONFIG.
COPY apps/bsod-detector/src/scripts/host/watch-crash.sh /usr/local/bin/watch-crash.sh
COPY apps/bsod-detector/src/scripts/host/recover-natural-crash.sh /usr/local/bin/recover-natural-crash.sh
COPY apps/bsod-detector/src/scripts/host/rhov-common.sh /usr/local/bin/rhov-common.sh
COPY apps/bsod-detector/src/scripts/host/guest-agent.py /usr/local/bin/guest-agent.py
COPY apps/bsod-detector/src/scripts/host/parse-dump-header.sh /usr/local/bin/parse-dump-header.sh
COPY apps/bsod-detector/src/scripts/host/collect-host-signals.sh /usr/local/bin/collect-host-signals.sh
COPY apps/bsod-detector/src/scripts/host/extract-evtx.py /usr/local/bin/extract-evtx.py
COPY apps/bsod-detector/src/data/bugcheck-codes.json /usr/share/bsod-detector/bugcheck-codes.json
COPY apps/bsod-detector/src/data/event-sources.json /usr/share/bsod-detector/event-sources.json
COPY apps/bsod-detector/src/data/host-signals.json /usr/share/bsod-detector/host-signals.json
COPY apps/bsod-detector/host-tools/extract-dump.sh /usr/local/bin/extract-dump
RUN chmod +x \
    /usr/local/bin/watch-crash.sh \
    /usr/local/bin/recover-natural-crash.sh \
    /usr/local/bin/rhov-common.sh \
    /usr/local/bin/parse-dump-header.sh \
    /usr/local/bin/collect-host-signals.sh \
    /usr/local/bin/extract-evtx.py \
    /usr/local/bin/extract-dump

# ── Environment defaults ─────────────────────────────────────────────────────
# All overridable at runtime via -e / env: in a pod spec / Deployment.
# GA_VM and GA_NS have no default — they are required for watch/recover.
ENV MODE=watch \
    GA_VM="" \
    GA_NS="" \
    WATCH_INTERVAL=5 \
    WATCH_MISS=2 \
    EVIDENCE_DIR=/evidence \
    LIBGUESTFS_BACKEND=direct \
    HOME=/tmp

# Evidence and bugcheck-codes data paths
RUN mkdir -p /evidence
# Let parse-dump-header.sh find bugcheck-codes.json via BSOD_CODES_FILE
ENV BSOD_CODES_FILE=/usr/share/bsod-detector/bugcheck-codes.json
ENV BSOD_DATA_DIR=/usr/share/bsod-detector \
    BSOD_HOST_SIGNALS_FILE=/usr/share/bsod-detector/host-signals.json \
    BSOD_RECOVERY_IMAGE=""

# ── Entrypoint ───────────────────────────────────────────────────────────────
COPY image/container/bsod-detector/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /evidence
ENTRYPOINT ["/entrypoint.sh"]
CMD []
