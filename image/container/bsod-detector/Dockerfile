# BSOD Detector — unified host-side container image.
#
# Supports three operating modes controlled by the MODE environment variable:
#
#   MODE=watch   (default)
#     Watch a KubeVirt Windows VM for natural or intentional BSODs via
#     qemu-guest-agent pings. Calls watch-crash.sh. Requires oc login
#     (in-cluster ServiceAccount or mounted KUBECONFIG).
#
#   MODE=recover
#     Post-stop evidence recovery from preflight metadata.
#     Calls extract--guest-os--crash-info.sh — snapshot-backed guestfish extraction.
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
#   EVIDENCE_DIR           Output directory                  (default: /evidence)
#
# Build from the repository root with pinned client URLs and SHA-256 values:
#   make -C image/container/bsod-detector build \
#     OCP_CLIENT_URL=<url> OCP_CLIENT_SHA256=<sha256> \
#     VIRTCTL_URL=<url> VIRTCTL_SHA256=<sha256>
#
# Run examples:
#   # Watch a VM for natural crashes
#   podman run --rm -e GA_VM=<vm> -e GA_NS=<namespace> \
#     -e BSOD_SNAPSHOT_CLASS=<class> \
#     -e BSOD_RECOVERY_IMAGE=<image@sha256:digest> \
#     -e BSOD_MEMORY_DUMP_PVC=<filesystem-pvc> \
#     -e BSOD_EVIDENCE_VOLUME_KIND=network -e BSOD_EVIDENCE_STORAGE_ID=<stable-id> \
#     -v /mnt/persistent-bsod-evidence:/evidence bsod-detector
#
#   # Recover evidence from a hard-frozen VM
#   podman run --rm -e MODE=recover \
#     -v /mnt/persistent-bsod-evidence:/evidence bsod-detector \
#     --metadata /evidence/<run>/recovery-metadata.json --out /evidence/<run>
#
#   # Offline dump extraction from a disk image (original use case)
#   podman run --rm -e MODE=extract \
#     -v /path/to/guest.qcow2:/disk.qcow2:ro -v ./out:/out \
#     bsod-detector --disk /disk.qcow2 --out /out
#
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# ── System packages ──────────────────────────────────────────────────────────
# libguestfs-tools : virt-copy-out / guestfish  (MODE=extract + MODE=recover PATH2)
# libvirt-client   : diagnostic client (virsh itself runs pod-local through oc)
# python3 + pip    : guest-agent.py, parse-dump-header.sh helper
# python-evtx      : offline .evtx event log parsing
# jq               : JSON processing in all shell scripts
# tar / curl       : oc CLI download
COPY image/container/bsod-detector/requirements.txt /tmp/requirements.txt
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
    tar \
    util-linux-core
pip3 install --no-cache-dir --require-hashes -r /tmp/requirements.txt
rm -f /tmp/requirements.txt
microdnf clean all
run-EOF

# ── oc CLI ───────────────────────────────────────────────────────────────────
# Required for MODE=watch and MODE=recover:
#   oc exec  → reach virt-launcher pod → virsh qemu-agent-command
#   oc get   → resolve VMI, pod names, node
#   oc logs  → capture virt-launcher compute logs
#   oc exec  → stream snapshot artifacts directly to durable evidence storage
ARG OCP_CLIENT_URL
ARG OCP_CLIENT_SHA256
ARG VIRTCTL_URL
ARG VIRTCTL_SHA256
RUN <<oc-EOF
set -euxo pipefail
[ -n "${OCP_CLIENT_URL}" ] && [ -n "${OCP_CLIENT_SHA256}" ]
[ -n "${VIRTCTL_URL}" ] && [ -n "${VIRTCTL_SHA256}" ]
curl -fsSL "${OCP_CLIENT_URL}" -o /tmp/openshift-client.tar.gz
printf '%s  %s\n' "${OCP_CLIENT_SHA256}" /tmp/openshift-client.tar.gz | sha256sum -c -
tar -xzf /tmp/openshift-client.tar.gz -C /usr/local/bin oc kubectl
curl -fsSL "${VIRTCTL_URL}" -o /usr/local/bin/virtctl
printf '%s  %s\n' "${VIRTCTL_SHA256}" /usr/local/bin/virtctl | sha256sum -c -
chmod +x /usr/local/bin/oc /usr/local/bin/kubectl /usr/local/bin/virtctl
oc version --client
virtctl version --client
rm -f /tmp/openshift-client.tar.gz
oc-EOF

# ── Scripts ──────────────────────────────────────────────────────────────────
# Build context is the repository root (set by the scoped Makefile).
# All host scripts are copied so the image is self-contained — no volume mounts
# required for scripts, only for evidence output and optional KUBECONFIG.
COPY apps/bsod-detector/src/scripts/host/watch-crash.sh             /usr/local/bin/watch-crash.sh
COPY apps/bsod-detector/src/scripts/host/preflight-rhov.sh          /usr/local/bin/preflight-rhov.sh
COPY apps/bsod-detector/src/scripts/host/extract--guest-os--crash-info.sh   /usr/local/bin/extract--guest-os--crash-info.sh
COPY apps/bsod-detector/src/scripts/host/guest-agent.py             /usr/local/bin/guest-agent.py
COPY apps/bsod-detector/src/scripts/host/reliability.py             /usr/local/bin/reliability.py
COPY apps/bsod-detector/src/scripts/host/parse-dump-header.sh       /usr/local/bin/parse-dump-header.sh
COPY apps/bsod-detector/src/scripts/host/collect-host-signals.sh    /usr/local/bin/collect-host-signals.sh
COPY apps/bsod-detector/archieve/src/scripts/host/extract-evtx.py    /usr/local/bin/extract-evtx.py
COPY apps/bsod-detector/src/scripts/guest/configure-dumps.ps1       /usr/share/bsod-detector/guest/configure-dumps.ps1
COPY apps/bsod-detector/src/data/                                  /usr/share/bsod-detector/data/
COPY apps/bsod-detector/archieve/host-tools/extract-dump.sh          /usr/local/bin/extract-dump.sh
RUN chmod +x \
    /usr/local/bin/watch-crash.sh \
    /usr/local/bin/preflight-rhov.sh \
    /usr/local/bin/extract--guest-os--crash-info.sh \
    /usr/local/bin/guest-agent.py \
    /usr/local/bin/reliability.py \
    /usr/local/bin/parse-dump-header.sh \
    /usr/local/bin/collect-host-signals.sh \
    /usr/local/bin/extract-evtx.py \
    /usr/local/bin/extract-dump.sh

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
ENV BSOD_CODES_FILE=/usr/share/bsod-detector/data/bugcheck-codes.json \
    BSOD_HOST_SIGNALS_FILE=/usr/share/bsod-detector/data/host-signals.json \
    BSOD_DATA_DIR=/usr/share/bsod-detector/data \
    BSOD_CONFIGURE_DUMPS=/usr/share/bsod-detector/guest/configure-dumps.ps1 \
    BSOD_CRASH_CONTROL_FILE=/usr/share/bsod-detector/data/crash-control.json

# ── Entrypoint ───────────────────────────────────────────────────────────────
COPY image/container/bsod-detector/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /evidence
ENTRYPOINT ["/entrypoint.sh"]
CMD []
