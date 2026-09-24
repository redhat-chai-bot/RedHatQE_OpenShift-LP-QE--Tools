#!/usr/bin/env bash
# collect-all.sh - host-side BSOD evidence collection orchestrator.
#
# Single entry point for the detector deliverable. Captures all post-mortem
# evidence from a crashed Windows VM: framebuffer screenshot, guest-side report
# (event logs, dumps, system context), and host-side signals (kernel log,
# hypervisor config).
#
# Invoked by test harnesses (src/scripts/crash-injector/run-dry-run.sh) or by a CI post-step after any
# test run that may have triggered a BSOD.
#
# Usage:
#   collect-all.sh --vm <name> --out <dir> --ssh <guest-ssh-path> \
#     [--guest-scripts <path>] [--timeout 300]
#
# Outputs: <out>/ containing:
#   bsod-screenshot.png    - framebuffer capture (best frame from rapid burst)
#   guest-memory.elf       - host-side raw memory capture (when VM preserved)
#   collect-guest.json     - structured guest-side report
#   host-signals.json      - host-side kernel log + hyperv evidence
#   Minidump/*.dmp         - crash dump files copied from guest
#   evidence-summary.json  - manifest of all collected artifacts
exec {BASH_XTRACEFD}>/dev/null
set -euxo pipefail; shopt -s inherit_errexit

typeset scriptDir; scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset repoRoot; repoRoot="$(cd "${scriptDir}/../../.." && pwd)"

export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

typeset vm=""
typeset outDir=""
typeset sshCmd=""
typeset guestScripts='C:/bsod-detector/scripts'
typeset timeout=300

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm)             [[ $# -ge 2 ]] || { echo "collect-all: --vm requires a value" >&2; exit 2; }; vm="$2"; shift 2 ;;
    --out)            [[ $# -ge 2 ]] || { echo "collect-all: --out requires a value" >&2; exit 2; }; outDir="$2"; shift 2 ;;
    --ssh)            [[ $# -ge 2 ]] || { echo "collect-all: --ssh requires a value" >&2; exit 2; }; sshCmd="$2"; shift 2 ;;
    --guest-scripts)  [[ $# -ge 2 ]] || { echo "collect-all: --guest-scripts requires a value" >&2; exit 2; }; guestScripts="$2"; shift 2 ;;
    --timeout)        [[ $# -ge 2 ]] || { echo "collect-all: --timeout requires a value" >&2; exit 2; }; timeout="$2"; shift 2 ;;
    -h|--help)        sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "collect-all: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "${vm}" ]]     || { echo "collect-all: --vm required" >&2; exit 2; }
[[ -n "${outDir}" ]] || { echo "collect-all: --out required" >&2; exit 2; }
[[ -n "${sshCmd}" ]] || { echo "collect-all: --ssh required" >&2; exit 2; }

mkdir -p "${outDir}"

function Log () { echo "[collect-all] $*" >&2; true; }

# --- Phase 1: Capture BSOD screenshot (background) ---
Log "starting framebuffer capture"
"${scriptDir}/capture-vm-screen.sh" --vm "${vm}" --out "${outDir}" --frames 30 --interval 0.3 &
typeset capturePid=$!

# --- Phase 2: Host-side crash dump (if domain is preserved after crash) ---
typeset domState=''
domState="$(virsh domstate "${vm}" 2>/dev/null)" || domState="unknown"
Log "domain state: ${domState}"

if [[ "${domState}" == "crashed" || "${domState}" == "paused" ]]; then
  kill "${capturePid}" 2>/dev/null || true
  wait "${capturePid}" 2>/dev/null || true

  Log "domain is preserved; capturing raw memory via virsh dump"
  if "${scriptDir}/capture-host-dump.sh" --vm "${vm}" --out "${outDir}" > "${outDir}/capture-host-dump.json"; then
    if [[ -f "${outDir}/guest-memory.elf" ]]; then
      Log "host-side raw memory captured: guest-memory.elf"
    fi
  else
    Log "WARNING: host-side dump failed (see capture-host-dump.json for details)"
  fi

  Log "destroying and restarting domain to trigger guest reboot"
  virsh destroy "${vm}" 2>/dev/null || true
  sleep 2
  virsh start "${vm}" 2>/dev/null || Log "WARNING: could not restart domain '${vm}'"
fi

# --- Phase 3: Wait for VM reboot (SSH becomes reachable again) ---
Log "waiting for guest reboot (timeout=${timeout}s)"
typeset rebooted=0
typeset elapsed=0
typeset pollInterval=8
while [[ "${elapsed}" -lt "${timeout}" ]]; do
  if "${sshCmd}" -c '"up"' 2>/dev/null | grep -q up; then
    rebooted=1
    break
  fi
  sleep "${pollInterval}"
  elapsed=$((elapsed + pollInterval))
done

if [[ "${domState}" != "crashed" && "${domState}" != "paused" ]]; then
  kill "${capturePid}" 2>/dev/null || true
  wait "${capturePid}" 2>/dev/null || true
fi

# --- Phase 4: Select best screenshot frame ---
typeset bestFrame=""
if compgen -G "${outDir}/bsod-frame-*.png" &>/dev/null; then
  bestFrame="$(ls -S "${outDir}"/bsod-frame-*.png 2>/dev/null | head -n1)" || true
fi
if [[ -n "${bestFrame}" ]]; then
  mv "${bestFrame}" "${outDir}/bsod-screenshot.png"
  Log "screenshot captured: bsod-screenshot.png"
else
  Log "WARNING: no screenshot frames captured"
fi
rm -f "${outDir}"/bsod-frame-*.png

# --- Phase 5: Collect guest-side evidence (if VM rebooted) ---
typeset guestCollected=false
if [[ "${rebooted}" == 1 ]]; then
  Log "guest is up; collecting guest-side evidence"
  typeset guestOut='C:/bsod-detector/output/collect-current'
  typeset guestCommandOk=false
  if "${sshCmd}" -c "Remove-Item -Recurse -Force ${guestOut} -EA SilentlyContinue; & ${guestScripts}/collect-guest.ps1 -OutputDir ${guestOut//\//\\}" \
    2>/dev/null | sed -E '/^#< CLIXML|<Objs /d' > "${outDir}/collect-guest.json"; then
    guestCommandOk=true
  else
    Log "WARNING: guest collection pipeline returned non-zero"
  fi

  if [[ "${guestCommandOk}" == true && -s "${outDir}/collect-guest.json" ]] && python3 -c "import json,sys;json.load(open(sys.argv[1]))" "${outDir}/collect-guest.json" 2>/dev/null; then
    guestCollected=true
    typeset ip=""
    if ip="$(virsh -q domifaddr "${vm}" 2>/dev/null | awk 'NR==1{print $4}' | cut -d/ -f1)"; then
      true
    fi
    if [[ -n "${ip}" ]]; then
      typeset -a scpOpts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
      typeset keyFile="${repoRoot}/.ssh/bsod-test"
      [[ -f "${keyFile}" ]] && scpOpts+=(-i "${keyFile}" -o IdentitiesOnly=yes)
      scp -r "${scpOpts[@]}" "Administrator@${ip}:${guestOut}/*" "${outDir}/" 2>/dev/null || true
    fi
    Log "guest evidence collected"
  else
    Log "WARNING: collect-guest.ps1 produced no output"
  fi
else
  Log "WARNING: guest did not reboot within ${timeout}s; guest-side collection skipped"
fi

# --- Phase 6: Collect host-side signals ---
Log "collecting host-side signals"
"${scriptDir}/collect-host-signals.sh" --vm "${vm}" > "${outDir}/host-signals.json" 2>/dev/null || true

# --- Phase 7: Assemble evidence summary manifest ---
Log "writing evidence summary"
typeset hasScreenshot=false; [[ -f "${outDir}/bsod-screenshot.png" ]] && hasScreenshot=true
typeset hasHostSignals=false; [[ -s "${outDir}/host-signals.json" ]] && hasHostSignals=true
typeset -a dumpFiles=()
if [[ -d "${outDir}/Minidump" ]]; then
  while IFS= read -r f; do
    dumpFiles+=("Minidump/$(basename "${f}")")
  done < <(find "${outDir}/Minidump" -name '*.dmp' 2>/dev/null)
fi
if [[ -f "${outDir}/MEMORY.DMP" ]]; then
  dumpFiles+=("MEMORY.DMP")
fi

typeset hasHostDump=false; [[ -f "${outDir}/guest-memory.elf" ]] && hasHostDump=true

python3 - "${outDir}" "${hasScreenshot}" "${guestCollected}" "${hasHostSignals}" "${hasHostDump}" "${dumpFiles[@]}" <<'PY'
import json, sys, os
out_dir = sys.argv[1]
has_screenshot = sys.argv[2] == "true"
guest_collected = sys.argv[3] == "true"
has_host_signals = sys.argv[4] == "true"
has_host_dump = sys.argv[5] == "true"
dump_files = sys.argv[6:] if len(sys.argv) > 6 else []

crash_info = None
if guest_collected:
    try:
        with open(os.path.join(out_dir, "collect-guest.json")) as f:
            guest = json.load(f)
            crash_info = guest.get("crash", {})
    except (json.JSONDecodeError, FileNotFoundError):
        pass

host_dump_info = None
if has_host_dump:
    try:
        with open(os.path.join(out_dir, "capture-host-dump.json")) as f:
            host_dump_info = json.load(f)
    except (json.JSONDecodeError, FileNotFoundError):
        pass

summary = {
    "ok": True,
    "collectedAt": __import__("datetime").datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "artifacts": {
        "screenshot": "bsod-screenshot.png" if has_screenshot else None,
        "hostDump": "guest-memory.elf" if has_host_dump else None,
        "guestReport": "collect-guest.json" if guest_collected else None,
        "hostSignals": "host-signals.json" if has_host_signals else None,
        "dumpFiles": dump_files,
    },
    "hostDumpDetails": host_dump_info,
    "crash": crash_info,
}

with open(os.path.join(out_dir, "evidence-summary.json"), "w") as f:
    json.dump(summary, f, indent=2)
print(json.dumps(summary, indent=2))
PY

Log "done. Evidence package: ${outDir}"
true
