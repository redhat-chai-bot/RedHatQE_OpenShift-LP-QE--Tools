#!/usr/bin/env bash
#
# watch-crash.sh -- watch a KubeVirt Windows VM for a NATURAL BSOD/freeze and
# auto-capture evidence. NO trigger is used: this is for crashes that happen on
# their own (e.g. the Intel split-lock #AC during the Hyper-V enlightened
# TLB-flush hypercall -> HYPERVISOR_ERROR 0x00020001), so NotMyFault / the 0xEF
# trigger are NOT needed.
#
# It polls the qemu-guest-agent. When the guest stops answering while the domain
# is still alive (domstate running/paused/crashed/pmsuspended -- pvpanic can move a
# bugcheck out of 'running') -- the classic BSOD/hang signature -- it immediately:
#   1. bursts `virsh screenshot` from the virt-launcher pod to catch the blue screen,
#   2. captures HOST-side signals (worker-node kernel log + domain XML) and runs
#      collect-host-signals.sh -- this is the ONLY place a TLB-flush/HYPERVISOR_ERROR
#      is visible; it never appears in the guest dump,
#   3. waits for the guest to reboot; if it does, runs collect-guest.ps1, pulls the
#      minidump, and cross-checks it offline with parse-dump-header.sh; if it stays
#      frozen (common for HYPERVISOR_ERROR), it records that and stops.
#
# Everything lands in one evidence directory, tied together by evidence-summary.json
# (crashDetected, guestRebooted/hardFreeze, bugCheck, splitLockDetected). Uses the
# qemu-guest-agent (no SSH).
#
# Requires: oc, python3, jq, and (same dir) guest-agent.py, collect-host-signals.sh,
#           parse-dump-header.sh. The toolkit must already be staged in the guest
#           (stage-toolkit.ps1) for the collect-guest step.
#
# --ns/--vm are OPTIONAL: with a single VMI on the cluster they are auto-detected;
# pass them only to disambiguate. Nothing is tied to a particular VM.
#
# Usage:
#   export KUBECONFIG=<cluster kubeconfig>
#   ./watch-crash.sh [--ns NS] [--vm NAME] [--out DIR]
#                    [--interval 5] [--miss 3] [--node <worker>] [--reboot-wait 300]
#
set -euxo pipefail
shopt -s inherit_errexit
exec {BASH_XTRACEFD}>/dev/null

typeset ns=""                # namespace; auto-detected from the VMI when not given
typeset vm=""                # VM name; auto-detected if there is exactly one VMI (in $ns if set)
typeset outDir=""
typeset interval=5            # seconds between health polls
typeset miss=3               # consecutive missed pings (while domain 'running') => crash
typeset node=""              # worker node for the kernel log; auto-detected if empty
typeset rebootWait=300      # seconds to wait for the guest agent to return after a crash
typeset burst=25             # screenshot frames to grab across the blue-screen window
typeset ssMin=8000          # screenshot size band (bytes): floor excludes ~3KB DPMS-black frames
typeset ssMax=400000        # ceiling excludes ~874KB desktop/lock frames; blue screen sits ~36KB

typeset scriptDir=''
scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --ns) ns="$2"; shift 2;;
    --vm) vm="$2"; shift 2;;
    --out) outDir="$2"; shift 2;;
    --interval) interval="$2"; shift 2;;
    --miss) miss="$2"; shift 2;;
    --node) node="$2"; shift 2;;
    --reboot-wait) rebootWait="$2"; shift 2;;
    --burst) burst="$2"; shift 2;;
    -h|--help) sed -n '2,40p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -n "${outDir}" ] || outDir="./output/natural-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${outDir}"

# Resolve the target from the cluster so nothing is tied to one VM. Explicit
# --ns/--vm always win; only the missing pieces are looked up. Lists "<ns> <vm>"
# rows scoped to --ns if given, else cluster-wide, then optionally filtered by --vm.
if [ -z "${vm}" ] || [ -z "${ns}" ]; then
  typeset -a scope=(-A); [ -n "${ns}" ] && scope=(-n "${ns}")
  typeset -a rows=()
  mapfile -t rows < <(oc get vmi "${scope[@]}" \
    -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' 2>/dev/null | sed '/^$/d')
  [ -n "${vm}" ] && mapfile -t rows < <(printf '%s\n' "${rows[@]}" | awk -v v="${vm}" '$2==v')
  case "${#rows[@]}" in
    1) read -r ns vm <<<"${rows[0]}"; echo "auto-detected target: ns=${ns} vm=${vm}" >&2;;
    0) echo "ERROR: no matching VMI found; pass --ns <ns> --vm <name>" >&2; exit 1;;
    *) echo "ERROR: ambiguous target; pass --ns and/or --vm. Candidates:" >&2
       printf '  %s\n' "${rows[@]}" >&2; exit 1;;
  esac
fi

typeset podRaw=''
podRaw="$(oc get pod -n "${ns}" -o name 2>/dev/null)" || true
typeset pod=''
pod="$(printf '%s\n' "${podRaw}" | sed -n "/virt-launcher-${vm}-/p" | head -n1 | cut -d/ -f2)"
[ -n "${pod}" ] || { echo "ERROR: no virt-launcher pod for ${vm} in ${ns}" >&2; exit 1; }
typeset dom="${ns}_${vm}"
export GA_NS="${ns}" GA_POD="${pod}" GA_DOM="${dom}"

function Log () { echo "[$(date -u +%H:%M:%S)] $*"; true; }
function Ga () { python3 "${scriptDir}/guest-agent.py" "$@"; }
function PingOk () { Ga ping >/dev/null 2>&1; }
function Domstate () { oc exec -n "${ns}" "${pod}" -- virsh domstate "${dom}" 2>/dev/null | tr -d '[:space:]'; }

function CaptureScreens () {  # $1 = destination dir
  typeset dst="$1"; mkdir -p "${dst}"
  oc exec -n "${ns}" "${pod}" -- bash -c "
    mkdir -p /tmp/wsnap; rm -f /tmp/wsnap/*
    for i in \$(seq -w 1 ${burst}); do
      virsh screenshot ${dom} /tmp/wsnap/s_\$i.ppm >/dev/null 2>&1 || true
      sleep 1
    done" >/dev/null 2>&1 || true
  oc cp "${ns}/${pod}:/tmp/wsnap" "${dst}" >/dev/null 2>&1 || true
  # BSOD frames are a solid colour + text => they compress SMALL (~36KB) while the
  # desktop/lock screen is ~874KB and a DPMS-asleep display is a ~3KB solid black.
  # Pick the SMALLEST frame INSIDE the [ssMin,ssMax] band: that isolates the blue
  # screen from both the black (too small) and the desktop (too big) frames.
  typeset best='' bestSz=$((ssMax + 1))
  typeset sz=''
  shopt -s nullglob
  for f in "${dst}"/wsnap/*.ppm; do
    sz=$(stat -c%s "${f}")
    if [ "${sz}" -ge "${ssMin}" ] && [ "${sz}" -le "${ssMax}" ] && [ "${sz}" -lt "${bestSz}" ]; then bestSz="${sz}"; best="${f}"; fi
  done
  if [ -n "${best}" ]; then
    cp "${best}" "${dst}/bsod-screenshot.png"
    Log "likely blue screen: $(basename "${best}") (${bestSz}B) -> bsod-screenshot.png"
  else
    Log "no frame in the ${ssMin}-${ssMax}B band; guest display may have been black (DPMS) or no blue screen captured."
  fi
  true
}

function CaptureHostSignals () {  # host kernel log (split-lock #AC) + domain XML
  [ -n "${node}" ] || node="$(oc get vmi "${vm}" -n "${ns}" -o jsonpath='{.status.nodeName}' 2>/dev/null || true)"
  oc exec -n "${ns}" "${pod}" -- virsh dumpxml "${dom}" > "${outDir}/dom.xml" 2>/dev/null || true
  if [ -n "${node}" ]; then
    Log "reading kernel log from node ${node} ..."
    timeout 90 oc debug "node/${node}" -- chroot /host dmesg > "${outDir}/kern.log" 2>/dev/null || true
  fi
  if [ -s "${outDir}/kern.log" ] || [ -s "${outDir}/dom.xml" ]; then
    # only pass a source flag when that file was actually captured
    typeset -a args=(--vm "${dom}")
    [ -s "${outDir}/kern.log" ] && args+=(--log-file "${outDir}/kern.log")
    [ -s "${outDir}/dom.xml" ]  && args+=(--domain-xml "${outDir}/dom.xml")
    bash "${scriptDir}/collect-host-signals.sh" "${args[@]}" \
      > "${outDir}/host-signals.json" 2>/dev/null || true
    Log "host-signals.json written (splitLockDetected: $(jq -r .splitLockDetected "${outDir}/host-signals.json" 2>/dev/null))"
  else
    Log "no kernel log or domain XML captured; skipping host-signals (TLB-flush/#AC evidence lives ONLY here)."
  fi
  true
}

typeset rebooted=false
typeset bugCheck=""

function CollectAfterReboot () {
  Log "waiting up to ${rebootWait}s for the guest agent to return ..."
  typeset t=0
  while [ "${t}" -lt "${rebootWait}" ]; do
    if PingOk; then Log "guest agent back after ~${t}s"; break; fi
    sleep 5; t=$((t+5))
  done
  if ! PingOk; then
    Log "guest did NOT reboot within ${rebootWait}s -- likely HARD FREEZE (typical for HYPERVISOR_ERROR)."
    Log "guest dump is not retrievable from a frozen guest; rely on host-signals.json above."
    return 0
  fi
  rebooted=true
  Log "running collect-guest.ps1 ..."
  if ! Ga exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\bsod-detector\src\scripts\collect-guest.ps1' \
    2>/dev/null | sed -n '/^{/,$p' > "${outDir}/collect-guest.json"; then
    true
  fi
  # pull the newest minidump and cross-check offline
  typeset dmpRaw=''
  dmpRaw="$(Ga exec powershell.exe -NoProfile -Command "(Get-ChildItem C:\\Windows\\Minidump\\*.dmp | Sort-Object LastWriteTime -Desc | Select-Object -First 1).Name" 2>/dev/null)" || true
  typeset dmp=''
  dmp="$(printf '%s\n' "${dmpRaw}" | tr -d '\r' | sed -n '/\.[dD][mM][pP]/p')"
  if [ -n "${dmp}" ]; then
    mkdir -p "${outDir}/Minidump"
    Ga get "C:\\Windows\\Minidump\\${dmp}" "${outDir}/Minidump/${dmp}" >/dev/null 2>&1 || true
    if [ -f "${outDir}/Minidump/${dmp}" ]; then
      bash "${scriptDir}/parse-dump-header.sh" "${outDir}/Minidump/${dmp}" > "${outDir}/parse-dump-header.json" 2>/dev/null || true
      bugCheck="$(jq -r '.dumps[0].bugCheckName // empty' "${outDir}/parse-dump-header.json" 2>/dev/null)" || true
    fi
    Log "minidump pulled: ${dmp} ; bugcheck: ${bugCheck:-unknown}"
  else
    Log "no minidump found (a HYPERVISOR_ERROR often writes none)."
  fi
  true
}

function WriteSummary () {  # $1 = domstate seen at detection
  typeset splitLock="null"
  [ -s "${outDir}/host-signals.json" ] && splitLock="$(jq -c '.splitLockDetected // null' "${outDir}/host-signals.json" 2>/dev/null || echo null)"
  jq -n \
    --arg vm "${vm}" --arg ns "${ns}" --arg dom "${dom}" \
    --arg detectedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg domstate "$1" --arg bugcheck "${bugCheck:-}" \
    --argjson rebooted "${rebooted}" --argjson splitLockDetected "${splitLock}" \
    '{ok:true, mode:"natural", vm:$vm, namespace:$ns, domain:$dom,
      crashDetected:true, detectedAt:$detectedAt, domStateAtCrash:$domstate,
      guestRebooted:$rebooted, hardFreeze:($rebooted|not),
      bugCheck:(if $bugcheck=="" then null else $bugcheck end),
      splitLockDetected:$splitLockDetected,
      artifacts:{screenshot:"bsod-screenshot.png", hostSignals:"host-signals.json",
                 domainXml:"dom.xml", kernelLog:"kern.log",
                 guestCollect:"collect-guest.json", dumpHeader:"parse-dump-header.json"}}' \
    > "${outDir}/evidence-summary.json" 2>/dev/null || true
  Log "evidence-summary.json written."
  true
}

Log "watching ${vm} (pod=${pod}, dom=${dom}); poll ${interval}s, crash after ${miss} missed pings. Ctrl-C to stop."
typeset misses=0
until PingOk; do Log "waiting for guest agent to be reachable ..."; sleep "${interval}"; done
Log "guest agent healthy; watching for a natural crash ..."

# Keep the display awake so pre-crash/repaint frames aren't all-black (DPMS). Best-effort.
Ga exec powercfg /change monitor-timeout-ac 0 >/dev/null 2>&1 || true

# A natural bugcheck may leave the domain 'running' (pure hang) OR, if the VM has a
# pvpanic device, transition it to paused/crashed/pmsuspended. All of those, with a
# dead agent, mean "crashed" -- only a clean 'shutoff' does not.
function IsCrashState () { case "$1" in running|paused|crashed|pmsuspended) return 0;; *) return 1;; esac; }

typeset st=''
while true; do
  if PingOk; then
    misses=0
  else
    misses=$((misses+1))
    st="$(Domstate || echo unknown)"
    Log "missed ping ${misses}/${miss} (domstate=${st})"
    if [ "${misses}" -ge "${miss}" ] && IsCrashState "${st}"; then
      Log "*** CRASH/FREEZE DETECTED (agent dead, domstate=${st}) ***"
      CaptureScreens "${outDir}"
      CaptureHostSignals
      CollectAfterReboot
      WriteSummary "${st}"
      Log "evidence package: ${outDir}"
      exit 0
    fi
  fi
  sleep "${interval}"
done
true
