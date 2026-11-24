#!/usr/bin/env bash
# collect-offline.sh — offline evidence collection orchestrator.
#
# Replaces the former SSH-based collect-all.sh with an offline-first flow:
#   1. Capture a raw memory backup via virsh dump (if VM is preserved/paused).
#   2. Stop (destroy) the VM so the disk is consistent.
#   3. Extract crash dumps + .evtx event logs from the guest disk via guestfs.
#   4. Parse the extracted dumps with parse-dump-header.sh.
#   5. Parse the extracted .evtx files with extract-evtx.py.
#   6. Collect host-side signals (kernel log, Hyper-V enlightenments).
#   7. Assemble evidence-summary.json tying everything together.
#
# No guest-side scripts, SSH, or guest agent needed for evidence collection.
#
# Usage:
#   collect-offline.sh --vm <name> --out <dir> [--disk <path>]
#                      [--windows-root <winRootDir>] [--skip-memory-dump]
#
# Output: <out>/ containing evidence-summary.json and all artifacts.
####
exec {BASH_XTRACEFD}>/dev/null
set -euxo pipefail; shopt -s inherit_errexit

typeset scriptDir
scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset repoRoot
repoRoot="$(cd "${scriptDir}/../../.." && pwd)"
typeset hostTools="${repoRoot}/host-tools"
typeset dataDir="${repoRoot}/src/data"

# Source the backend dispatcher for VM operations.
# shellcheck source=backends/dispatch.sh
source "${scriptDir}/backends/dispatch.sh"

typeset vm=""
typeset outDir=""
typeset disk=""
typeset winRoot="/Windows"
typeset skipMemDump=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm)            [[ $# -ge 2 ]] || { echo "collect-offline: --vm requires a value" >&2; exit 2; }; vm="$2"; shift 2 ;;
    --out)           [[ $# -ge 2 ]] || { echo "collect-offline: --out requires a value" >&2; exit 2; }; outDir="$2"; shift 2 ;;
    --disk)          [[ $# -ge 2 ]] || { echo "collect-offline: --disk requires a value" >&2; exit 2; }; disk="$2"; shift 2 ;;
    --windows-root)  [[ $# -ge 2 ]] || { echo "collect-offline: --windows-root requires a value" >&2; exit 2; }; winRoot="$2"; shift 2 ;;
    --skip-memory-dump) skipMemDump=1; shift ;;
    -h|--help)       sed -n '/^#!/,/^####$/{/^#!/d;/^####$/d;s/^# \{0,1\}//p;}' "$0"; exit 0 ;;
    *) echo "collect-offline: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "${vm}" ]]     || { echo "collect-offline: --vm required" >&2; exit 2; }
[[ -n "${outDir}" ]] || { echo "collect-offline: --out required" >&2; exit 2; }

mkdir -p "${outDir}"

# log — print a timestamped diagnostic message to stderr.
function log () { echo "[collect-offline] $*" >&2; true; }

typeset -a warnings=()

# --- Phase 1: Raw memory backup (if domain is preserved after crash) ---
typeset domState
domState="$(domain_state "${vm}")"
log "domain state: ${domState}"

typeset hasMemDump=false
if [[ "${skipMemDump}" != "1" ]] && [[ "${domState}" == "crashed" || "${domState}" == "hung" ]]; then
  log "capturing raw memory via virsh dump --memory-only"
  if "${scriptDir}/capture-host-dump.sh" --vm "${vm}" --out "${outDir}" > "${outDir}/capture-host-dump.json" 2>/dev/null; then
    [[ -f "${outDir}/guest-memory.elf" ]] && hasMemDump=true
    log "raw memory captured: guest-memory.elf"
  else
    warnings+=("raw memory dump failed (see capture-host-dump.json)")
  fi
fi

# --- Phase 2: Stop the VM so the disk is consistent ---
if [[ "${domState}" != "off" ]]; then
  log "stopping VM for consistent disk access"
  kill_vm "${vm}" || true
  sleep 2
fi

# --- Phase 3: Extract dumps + evtx from guest disk offline ---
if [[ -z "${disk}" ]]; then
  disk="$(guest_disk "${vm}")" || true
fi

# shellcheck disable=SC2034  # extractOk/extractJson reserved for future use
typeset extractOk=false
typeset extractJson=""
if [[ -z "${disk}" ]]; then
  warnings+=("could not resolve guest disk; pass --disk <path>")
elif [[ ! -r "${disk}" ]]; then
  warnings+=("guest disk not readable: ${disk}")
else
  log "extracting dumps + evtx from ${disk} via guestfs"
  if command -v virt-copy-out >/dev/null 2>&1; then
    # shellcheck disable=SC2034  # extractOk/extractJson reserved for future use
    extractJson="$("${hostTools}/extract-dump.sh" --disk "${disk}" --out "${outDir}" --windows-root "${winRoot}" 2>/dev/null)" || true
    # shellcheck disable=SC2034
    extractOk=true
  elif command -v podman >/dev/null 2>&1; then
    # shellcheck disable=SC2034
    extractJson="$("${hostTools}/run.sh" --disk "${disk}" --out "${outDir}" 2>/dev/null)" || true
    # shellcheck disable=SC2034
    extractOk=true
  else
    warnings+=("no libguestfs (virt-copy-out) and no podman; cannot extract offline")
  fi
fi

# --- Phase 4: Parse extracted dump headers ---
typeset bugCheck=""
typeset -a dumpFiles=()
if [[ -d "${outDir}/Minidump" ]]; then
  while IFS= read -r f; do
    dumpFiles+=("Minidump/$(basename "${f}")")
  done < <(find "${outDir}/Minidump" -name '*.dmp' 2>/dev/null)
fi
[[ -f "${outDir}/MEMORY.DMP" ]] && dumpFiles+=("MEMORY.DMP")

if [[ "${#dumpFiles[@]}" -gt 0 ]]; then
  log "parsing dump headers"
  typeset firstDmp=""
  for d in "${dumpFiles[@]}"; do
    [[ -f "${outDir}/${d}" ]] && firstDmp="${outDir}/${d}" && break
  done
  if [[ -n "${firstDmp}" ]]; then
    "${scriptDir}/parse-dump-header.sh" "${firstDmp}" > "${outDir}/parse-dump-header.json" 2>/dev/null || true
    bugCheck="$(jq -r '.dumps[0].bugCheckName // empty' "${outDir}/parse-dump-header.json" 2>/dev/null)" || true
  fi
fi

# --- Phase 5: Parse extracted .evtx files ---
typeset evtxParsed=false
shopt -s nullglob
typeset -a evtxFiles=("${outDir}"/*.evtx "${outDir}"/winevt/*.evtx)
shopt -u nullglob
if [[ "${#evtxFiles[@]}" -gt 0 ]]; then
  log "parsing ${#evtxFiles[@]} .evtx file(s)"
  python3 "${scriptDir}/extract-evtx.py" --data-dir "${dataDir}" "${evtxFiles[@]}" \
    > "${outDir}/evtx-events.json" 2>/dev/null || true
  [[ -s "${outDir}/evtx-events.json" ]] && evtxParsed=true
fi

# --- Phase 6: Host-side signals ---
log "collecting host-side signals"
"${scriptDir}/collect-host-signals.sh" --vm "${vm}" > "${outDir}/host-signals.json" 2>/dev/null || true

# --- Phase 7: Assemble evidence summary ---
log "assembling evidence summary"
# shellcheck disable=SC2034  # hasScreenshot reserved for screenshot capture phase
typeset hasScreenshot=false
typeset hasHostSignals=false
[[ -s "${outDir}/host-signals.json" ]] && hasHostSignals=true

typeset crashDetected=false
[[ "${#dumpFiles[@]}" -gt 0 ]] && crashDetected=true
if [[ "${evtxParsed}" == true ]]; then
  typeset evtxCrash
  evtxCrash="$(jq -r '.crash.detected // false' "${outDir}/evtx-events.json" 2>/dev/null)" || evtxCrash="false"
  [[ "${evtxCrash}" == "true" ]] && crashDetected=true
fi

typeset splitLock="null"
[[ -s "${outDir}/host-signals.json" ]] && splitLock="$(jq -c '.splitLockDetected // null' "${outDir}/host-signals.json" 2>/dev/null || echo null)"

typeset warnsJson
warnsJson="$(printf '%s\n' "${warnings[@]:-}" | jq -R . | jq -s 'map(select(length>0))')"
typeset dumpFilesJson
dumpFilesJson="$(printf '%s\n' "${dumpFiles[@]:-}" | jq -R . | jq -s 'map(select(length>0))')"

jq -n \
  --arg vm "${vm}" \
  --arg collectedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg method "offline-guestfs" \
  --arg bugcheck "${bugCheck:-}" \
  --argjson crashDetected "${crashDetected}" \
  --argjson hasMemDump "${hasMemDump}" \
  --argjson hasHostSignals "${hasHostSignals}" \
  --argjson evtxParsed "${evtxParsed}" \
  --argjson splitLockDetected "${splitLock}" \
  --argjson dumpFiles "${dumpFilesJson}" \
  --argjson warnings "${warnsJson}" \
  '{ok: true, vm: $vm, collectedAt: $collectedAt, method: $method,
    crashDetected: $crashDetected,
    bugCheck: (if $bugcheck == "" then null else $bugcheck end),
    splitLockDetected: $splitLockDetected,
    artifacts: {
      memoryDump: (if $hasMemDump then "guest-memory.elf" else null end),
      hostSignals: (if $hasHostSignals then "host-signals.json" else null end),
      dumpFiles: $dumpFiles,
      evtxEvents: (if $evtxParsed then "evtx-events.json" else null end),
      dumpHeader: "parse-dump-header.json"
    },
    warnings: $warnings}' \
  > "${outDir}/evidence-summary.json" 2>/dev/null || true

jq '.' "${outDir}/evidence-summary.json" 2>/dev/null || true
log "done. Evidence package: ${outDir}"
true
