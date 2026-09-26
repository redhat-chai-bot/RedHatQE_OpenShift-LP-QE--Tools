#!/usr/bin/env bash
# entrypoint.sh — unified BSOD detector container entrypoint.
#
# Reads MODE env var and dispatches to the appropriate script.
# All target parameters come from environment variables.
#
# MODE=watch    → watch-crash.sh   (natural crash detection)
# MODE=recover  → recover-natural-crash.sh  (hard-freeze recovery)
# MODE=extract  → extract-dump     (offline libguestfs extraction)
set -euo pipefail
umask 077

MODE="${MODE:-watch}"
GA_VM="${GA_VM:-}"
GA_NS="${GA_NS:-}"
WATCH_INTERVAL="${WATCH_INTERVAL:-5}"
WATCH_MISS="${WATCH_MISS:-2}"
EVIDENCE_DIR="${EVIDENCE_DIR:-/evidence}"
BSOD_RECOVERY_IMAGE="${BSOD_RECOVERY_IMAGE:-}"
GA_PVC="${GA_PVC:-}"
RHOV_COMMON_FILE="${BSOD_RHOV_COMMON_FILE:-/usr/local/bin/rhov-common.sh}"

function require_recovery_image() {
  [[ -r "${RHOV_COMMON_FILE}" ]] || {
    echo "ERROR: RHOV validation helper not found: ${RHOV_COMMON_FILE}"
    exit 1
  }
  # shellcheck source=/dev/null
  source "${RHOV_COMMON_FILE}"
  rhov_valid_image_digest "${BSOD_RECOVERY_IMAGE}" || {
    echo "ERROR: BSOD_RECOVERY_IMAGE must be a valid immutable OCI image digest"
    exit 1
  }
}

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              BSOD Detector — Container Entrypoint            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "  MODE     : $MODE"
echo "  GA_VM    : ${GA_VM:-(not set)}"
echo "  GA_NS    : ${GA_NS:-(not set)}"
echo "  EVIDENCE : $EVIDENCE_DIR"
echo ""

mkdir -p "$EVIDENCE_DIR"
chmod 0700 "$EVIDENCE_DIR"
export GA_VM GA_NS EVIDENCE_DIR

case "$MODE" in

  watch)
    [[ -n "$GA_VM" ]] || {
      echo "ERROR: GA_VM is required for MODE=watch"
      exit 1
    }
    [[ -n "$GA_NS" ]] || {
      echo "ERROR: GA_NS is required for MODE=watch"
      exit 1
    }
    echo "Starting natural crash watcher..."
    echo "  VM       : $GA_VM"
    echo "  NS       : $GA_NS"
    require_recovery_image
    echo "  Interval : ${WATCH_INTERVAL}s | Miss: $WATCH_MISS"
    echo ""
    exec /usr/local/bin/watch-crash.sh \
      --ns "$GA_NS" \
      --vm "$GA_VM" \
      --out "$EVIDENCE_DIR" \
      --interval "$WATCH_INTERVAL" \
      --miss "$WATCH_MISS" \
      --recovery-image "$BSOD_RECOVERY_IMAGE" \
      "$@"
    ;;

  recover)
    [[ -n "$GA_VM" ]] || {
      echo "ERROR: GA_VM is required for MODE=recover"
      exit 1
    }
    [[ -n "$GA_NS" ]] || {
      echo "ERROR: GA_NS is required for MODE=recover"
      exit 1
    }
    [[ -n "$GA_PVC" ]] || {
      echo "ERROR: GA_PVC is required for MODE=recover"
      exit 1
    }
    require_recovery_image
    echo "Starting hard-freeze evidence recovery..."
    echo "  VM : $GA_VM"
    echo "  NS : $GA_NS"
    echo ""
    exec /usr/local/bin/recover-natural-crash.sh \
      --ns "$GA_NS" \
      --vm "$GA_VM" \
      --out "$EVIDENCE_DIR" \
      --pvc "$GA_PVC" \
      --path2-only \
      --recovery-image "$BSOD_RECOVERY_IMAGE" \
      "$@"
    ;;

  extract)
    echo "Starting offline dump extraction (libguestfs)..."
    echo "  Pass --disk <path> --out <dir> as arguments."
    echo ""
    exec /usr/local/bin/extract-dump "$@"
    ;;

  *)
    echo "ERROR: Unknown MODE '$MODE'. Valid values: watch | recover | extract"
    exit 1
    ;;

esac
