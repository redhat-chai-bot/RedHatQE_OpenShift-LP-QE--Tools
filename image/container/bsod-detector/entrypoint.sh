#!/usr/bin/env bash
# entrypoint.sh — unified BSOD detector container entrypoint.
#
# Reads MODE env var and dispatches to the appropriate script.
# All target parameters come from environment variables.
#
# MODE=watch    → watch-crash.sh   (natural crash detection)
# MODE=recover  → extract--guest-os--crach-info.sh  (hard-freeze recovery)
# MODE=extract  → extract-dump     (offline libguestfs extraction)
set -euo pipefail

MODE="${MODE:-watch}"
GA_VM="${GA_VM:-}"
GA_NS="${GA_NS:-}"
WATCH_INTERVAL="${WATCH_INTERVAL:-5}"
WATCH_MISS="${WATCH_MISS:-2}"
EVIDENCE_DIR="${EVIDENCE_DIR:-/evidence}"
BSOD_SNAPSHOT_CLASS="${BSOD_SNAPSHOT_CLASS:-}"
BSOD_RECOVERY_IMAGE="${BSOD_RECOVERY_IMAGE:-}"
BSOD_MEMORY_DUMP_PVC="${BSOD_MEMORY_DUMP_PVC:-}"
BSOD_EVIDENCE_VOLUME_KIND="${BSOD_EVIDENCE_VOLUME_KIND:-}"
BSOD_EVIDENCE_STORAGE_ID="${BSOD_EVIDENCE_STORAGE_ID:-}"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              BSOD Detector — Container Entrypoint            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "  MODE     : $MODE"
echo "  GA_VM    : ${GA_VM:-(not set)}"
echo "  GA_NS    : ${GA_NS:-(not set)}"
echo "  EVIDENCE : $EVIDENCE_DIR"
echo ""

mkdir -p "$EVIDENCE_DIR"
export GA_VM GA_NS EVIDENCE_DIR

case "$MODE" in

  watch)
    [[ -n "$GA_VM" ]] || { echo "ERROR: GA_VM is required for MODE=watch"; exit 1; }
    [[ -n "$GA_NS" ]] || { echo "ERROR: GA_NS is required for MODE=watch"; exit 1; }
    echo "Starting natural crash watcher..."
    echo "  VM       : $GA_VM"
    echo "  NS       : $GA_NS"
    echo "  Interval : ${WATCH_INTERVAL}s | Miss: $WATCH_MISS"
    echo ""
    [[ -n "$BSOD_SNAPSHOT_CLASS" ]] || { echo "ERROR: BSOD_SNAPSHOT_CLASS is required for MODE=watch"; exit 1; }
    [[ -n "$BSOD_RECOVERY_IMAGE" ]] || { echo "ERROR: BSOD_RECOVERY_IMAGE is required for MODE=watch"; exit 1; }
    [[ -n "$BSOD_MEMORY_DUMP_PVC" ]] || { echo "ERROR: BSOD_MEMORY_DUMP_PVC is required for MODE=watch"; exit 1; }
    [[ -n "$BSOD_EVIDENCE_VOLUME_KIND" ]] || { echo "ERROR: BSOD_EVIDENCE_VOLUME_KIND is required for MODE=watch"; exit 1; }
    [[ -n "$BSOD_EVIDENCE_STORAGE_ID" ]] || { echo "ERROR: BSOD_EVIDENCE_STORAGE_ID is required for MODE=watch"; exit 1; }
    exec /usr/local/bin/watch-crash.sh \
      --ns    "$GA_NS" \
      --vm    "$GA_VM" \
      --out   "$EVIDENCE_DIR" \
      --evidence-mount "$EVIDENCE_DIR" \
      --evidence-volume-kind "$BSOD_EVIDENCE_VOLUME_KIND" \
      --evidence-storage-id "$BSOD_EVIDENCE_STORAGE_ID" \
      --interval    "$WATCH_INTERVAL" \
      --miss        "$WATCH_MISS" \
      --snap-class "$BSOD_SNAPSHOT_CLASS" \
      --recovery-image "$BSOD_RECOVERY_IMAGE" \
      --memory-dump-pvc "$BSOD_MEMORY_DUMP_PVC"
    ;;

  recover)
    echo "Starting hard-freeze evidence recovery..."
    echo ""
    exec /usr/local/bin/extract--guest-os--crach-info.sh "$@"
    ;;

  extract)
    echo "Starting offline dump extraction (libguestfs)..."
    echo "  Pass --disk <path> --out <dir> as arguments."
    echo ""
    exec /usr/local/bin/extract-dump.sh "$@"
    ;;

  *)
    echo "ERROR: Unknown MODE '$MODE'. Valid values: watch | recover | extract"
    exit 1
    ;;

esac
