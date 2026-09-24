#!/usr/bin/env bash
# run-dry-run.sh - BSOD test trigger for the local bsod-test guest.
#
# Runs on the HOST. Orchestrates one test cycle:
#   1. (optional) revert the guest to the crashme-installed snapshot
#   2. start the guest and wait for SSH
#   3. trigger a BSOD via the CrashMe driver with a specified code
#   4. delegate to src/scripts/host/collect-all.sh for evidence collection
#   5. print summary
#
# All guest interaction goes through src/scripts/host/guest-ssh.sh (SSH key auth). Never
# point this at anything but a disposable/snapshotted test VM.
#
# Usage:
#   src/scripts/crash-injector/run-dry-run.sh [--code <hex>] [--no-revert] [--out <dir>]
#
# Defaults: code=0x19 (BAD_POOL_HEADER), revert=yes,
#           out=<repo>/output/dryrun-<timestamp>
set -euxo pipefail; shopt -s inherit_errexit

export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
typeset here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset repo; repo="$(cd "${here}/../../.." && pwd)"   # crash-injector -> scripts -> src -> app root
typeset vmName="${VM_NAME:-bsod-test}"
typeset gssh="${repo}/src/scripts/host/guest-ssh.sh"
typeset snapshot="${SNAPSHOT:-crashme-installed}"

typeset code="0x19"
typeset revert=1
typeset out; out="${repo}/output/dryrun-$(date +%Y%m%d-%H%M%S)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --code)       code="$2"; shift 2 ;;
    --no-revert)  revert=0; shift ;;
    --out)        out="$2"; shift 2 ;;
    --snapshot)   snapshot="$2"; shift 2 ;;
    -h|--help)    sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "run-dry-run: unknown arg: $1" >&2; exit 2 ;;
  esac
done

function Log () { echo "[dry-run] $*" >&2; true; }

# Resolve a bug check code to its KeBugCheckEx parameters from trigger-methods.json.
function LookupParams () {
  python3 -c "
import json, sys
tm = json.load(open('${repo}/src/data/trigger-methods.json'))['codes']
code = sys.argv[1].upper().replace('0X', '0x')
if not code.startswith('0x'):
    code = '0x' + code
code = '0x' + code[2:].zfill(8)
if code not in tm:
    print(f'ERROR: {code} not in trigger-methods.json', file=sys.stderr)
    sys.exit(1)
print(' '.join(tm[code]['parameters']))
" "$1"
  true
}

# Poll SSH until the guest responds (8s intervals, 25 attempts).
function WaitForSsh () {
  typeset attempt=0
  for (( attempt=1; attempt<=25; ++attempt )); do
    "${gssh}" -c '"up"' 2>/dev/null | grep -q up && return 0
    sleep 8
  done
  return 1
}

typeset params; params="$(LookupParams "${code}")"
typeset codeNorm; codeNorm="$(python3 -c "c='${code}'.upper(); print('0x'+c[2:].zfill(8) if c.startswith('0x') or c.startswith('0X') else '0x'+c.zfill(8))")"
Log "code=${codeNorm} params=${params}"

if [[ "${revert}" == 1 ]]; then
  Log "reverting ${vmName} to ${snapshot}"
  virsh snapshot-revert "${vmName}" "${snapshot}"
fi

if [[ "$(virsh -q domstate "${vmName}")" != "running" ]]; then
  Log "starting ${vmName}"
  virsh start "${vmName}" >/dev/null
fi

Log "waiting for guest SSH"
WaitForSsh || { echo "guest never came up" >&2; exit 1; }

# --- Trigger the crash ---
Log "triggering BSOD: ${codeNorm} ${params}"
"${gssh}" -c "C:\\Tools\\crashme-ctl.exe ${code} ${params}" 2>&1 || true

# --- Delegate all evidence collection to the detector ---
Log "collecting evidence via collect-all.sh"
"${repo}/src/scripts/host/collect-all.sh" \
  --vm "${vmName}" \
  --out "${out}" \
  --ssh "${gssh}"

# --- Print summary ---
python3 - "${out}/evidence-summary.json" "${codeNorm}" <<'PY' 2>/dev/null || true
import json, sys
d = json.load(open(sys.argv[1]))
c = d.get("crash") or {}
code = c.get("bugCheckCode")
name = c.get("bugCheckName")
print(f"bugCheck : {code} ({name})")
print("params   :", ", ".join(c.get("parameters", [])) or "(none)")
print("dumps    :", ", ".join(c.get("dumpFiles", [])) or "(none)")
arts = d.get("artifacts", {})
print("screenshot:", arts.get("screenshot") or "(none)")
expected = sys.argv[2] if len(sys.argv) > 2 else None
if expected and code != expected:
    print(f"FAIL: expected {expected}, got {code}")
    sys.exit(1)
elif code:
    print("PASS")
PY

true
