#!/usr/bin/env bash
# capture-host-dump.sh - host-side raw VM memory capture via virsh dump.
#
# When a Windows guest crashes and the domain enters the "crashed" state
# (requires <on_crash>preserve</on_crash> in the domain XML), this script
# captures a full physical memory dump from the host side as a raw ELF
# file. The raw ELF is delivered as-is — no runtime conversion, no PDB
# downloads, no network dependency.
#
# The raw ELF can be analyzed offline with Volatility, or converted to a
# WinDbg DMP later via elf2dmp if needed. Keeping the raw capture avoids
# discarding the source data after a lossy conversion.
#
# This is a fallback for cases where the guest-side crash dump mechanism
# fails (e.g., viostor StorPortGetUncachedExtension failure under
# allocation pressure). See:
#   https://github.com/virtio-win/kvm-guest-drivers-windows/issues/1629
#
# Prerequisites:
#   - virsh (libvirt)
#   - Domain must be in "crashed" or "paused" state
#
# Usage:
#   capture-host-dump.sh --vm <name> --out <dir>
#
# Output (stdout JSON):
#   { "ok": true, "dumpFile": "guest-memory.elf", "method": "virsh-memory-only",
#     "sizeBytes": N, "warnings": [] }
exec {BASH_XTRACEFD}>/dev/null
set -euxo pipefail; shopt -s inherit_errexit

export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

typeset vm=""
typeset outDir=""

# Warn — print a diagnostic message to stderr.
function Warn () { echo "capture-host-dump: $*" >&2; true; }
# Die — print a fatal error to stderr and exit.
function Die ()  { Warn "$*"; exit 2; }
# Have — return 0 if the named command is available on PATH.
function Have () { command -v "$1" >/dev/null 2>&1; }

# Emit a JSON failure object to stdout and exit 1.
function EmitFailure () {
  typeset error="$1"; shift
  typeset warnsJson='[]'
  if [[ $# -gt 0 ]]; then
    warnsJson="$(printf '%s\n' "$@" | jq -R . | jq -s '.')"
  fi
  jq -n --arg e "${error}" --argjson w "${warnsJson}" \
    '{ ok: false, error: $e, warnings: $w }'
  exit 1
}

Have virsh    || Die "virsh not found"
Have jq       || Die "jq not found"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm)  [[ $# -ge 2 ]] || Die "--vm requires a value";  vm="$2"; shift 2 ;;
    --out) [[ $# -ge 2 ]] || Die "--out requires a value"; outDir="$2"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) Die "unknown arg: $1" ;;
  esac
done

[[ -n "${vm}" ]]     || Die "--vm required"
[[ -n "${outDir}" ]] || Die "--out required"

mkdir -p "${outDir}"

typeset -a warnings=()
typeset elfFile="${outDir}/guest-memory.elf"

typeset domState=''
domState="$(virsh domstate "${vm}" 2>/dev/null)" || EmitFailure "could not query domain state for '${vm}'"

case "${domState}" in
  crashed|paused)
    Warn "domain '${vm}' is in '${domState}' state; proceeding with memory dump"
    ;;
  *)
    EmitFailure "domain '${vm}' is in '${domState}' state (expected 'crashed' or 'paused')"
    ;;
esac

Warn "capturing guest memory via virsh dump --memory-only (this may take a while for large VMs)"
if ! virsh dump "${vm}" "${elfFile}" --memory-only --verbose 2>&1 | while IFS= read -r line; do Warn "virsh: ${line}"; done; then
  EmitFailure "virsh dump --memory-only failed" "ELF file may be incomplete at ${elfFile}"
fi

if [[ ! -f "${elfFile}" ]]; then
  EmitFailure "virsh dump completed but ELF file not found at ${elfFile}"
fi

chmod u+rw "${elfFile}" 2>/dev/null || warnings+=("could not fix permissions on ${elfFile}")

typeset elfSize=''
elfSize="$(stat -c%s "${elfFile}" 2>/dev/null)" || elfSize="unknown"
Warn "ELF dump captured: ${elfFile} (${elfSize} bytes)"

Warn "raw ELF memory capture preserved at ${elfFile} (convert offline with elf2dmp if needed)"

typeset warnsJson=''
warnsJson="$(printf '%s\n' "${warnings[@]:-}" | jq -R . | jq -s 'map(select(length>0))')"

jq -n \
  --arg file "guest-memory.elf" \
  --arg method "virsh-memory-only" \
  --argjson size "${elfSize}" \
  --argjson warnings "${warnsJson}" \
  '{ ok: true, dumpFile: $file, method: $method, sizeBytes: $size, warnings: $warnings }'
true
