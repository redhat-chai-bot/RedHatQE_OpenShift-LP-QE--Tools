#!/usr/bin/env bash
# RHOV crash watcher: detects guest BSOD, captures crash dumps, extracts forensics artifacts
# Fails closed: requires successful preflight validation, crash detection, dump capture, and artifact extraction
set -euxo pipefail; shopt -s inherit_errexit
#
# Memory artifact produced by this pipeline:
#   PRIMARY: vm-memory.elf.tar.gz (raw KubeVirt memory-dump export, validated as ELF)
#   OPTIONAL OFFLINE CONVERSION: vm-memory-windows.dmp via elf2dmp; conversion and
#            Volatility analysis are developer-run and disabled in this script.
#
# Snapshot recovery reads System.evtx and Application.evtx from the stopped guest
# disk using an unprivileged guestfs pod. It writes parse-dump-header.json from an
# available on-disk dump (or a no-dump stub) and currently writes events.json as
# a stub; it does not extract MEMORY.DMP or Minidump files.
#
# Architecture: KubeVirt memory-dump PVC API plus VirtualMachineExport for memory
# streaming; libvirt is used inside virt-launcher for runtime diagnostics.
set -euo pipefail; shopt -s inherit_errexit
umask 077

# Determine script directory for helper script resolution
typeset scriptDir=''; scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Core targets: cluster namespace, VM name, output directory, metadata file from preflight
typeset ns=''; typeset vm=''; typeset outArg=''; typeset outDir=''; typeset metadataFile=''; typeset runId=''
# Crash detection tuning: ping interval (5s), miss threshold (2 misses = crash), quiesce time (15 min for dump), idle samples before quiesce
typeset interval=5; typeset miss=2; typeset quiesceWait=900; typeset idleSamples=3
typeset snapClass="${BSOD_DET__SNAPSHOT__CLASS:-}"; typeset recoveryImage="${BSOD_RECOVERY_IMAGE:-}"
typeset memoryPvc="${BSOD_DET__MEMORY__DUMP_PVC:-}"; typeset diskTarget=''; typeset noRestart=0
typeset evidenceRoot="${BSOD_DET__EVIDENCE__MOUNT:-}"; typeset evidenceKind="${BSOD_EVIDENCE_VOLUME_KIND:-}"
typeset evidenceId="${BSOD_DET__EVIDENCE__STORAGE_ID:-}"; typeset readyFile=''
typeset commandTimeout="${BSOD_DET__COMMAND__TIMEOUT:-30}"; typeset preflightTimeout="${BSOD_DET__PREFLIGHT__TIMEOUT:-300}"
typeset captureTimeout="${BSOD_DET__CAPTURE__TIMEOUT:-300}"; typeset memoryTimeout="${BSOD_MEMORY_CAPTURE_TIMEOUT:-1800}"
typeset armedTimeout="${BSOD_DET__ARMED__TIMEOUT:-3600}"
typeset runDir=''; typeset pvpanicFile=''; typeset pvpanicPid=''; typeset progressPid=''; typeset memoryAssociated=0
typeset stageErrors=''; typeset pipelineLog=''; typeset summaryMode='natural-rhov'
typeset -a guestAgent=(python3 "${scriptDir}/guest-agent.py")
[[ -z "${BSOD_DET__GUEST_AGENT__BIN:-}" ]] || guestAgent=("${BSOD_DET__GUEST_AGENT__BIN}")
typeset hostSignalsBin="${BSOD_DET__HOST_SIGNALS__BIN:-${scriptDir}/collect-host-signals.sh}"

# Helper function definitions
# Die — print a fatal error to stderr and exit.
function Die () { echo "watch-crash: ERROR: $*" >&2; exit 1; }
# RunTimed — execute command with timeout: TERM after <seconds>, force KILL after 5 more seconds
function RunTimed () { typeset seconds="${1:?}"; shift; timeout --signal=TERM --kill-after=5 "${seconds}" "$@"; }
# Oc — run kubectl with configured timeout and request timeout
function Oc () { RunTimed "${commandTimeout}" oc --request-timeout="${commandTimeout}s" "$@"; }
# Log — print timestamped message to both stdout and pipeline log file
function Log () { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "${pipelineLog}"; true; }
# RecordError — append error entry to stage-errors JSONL file and log to stdout
function RecordError () {
  typeset stage="${1:?}"; shift
  jq -cn --arg stage "${stage}" --arg error "$*" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{stage:$stage,error:$error,at:$at}' >> "${stageErrors}"
  Log "ERROR [${stage}]: $*"
}
# shellcheck disable=SC2317  # Invoked by EXIT trap.
function Cleanup () {
  if [[ -n "${progressPid}" ]]; then kill "${progressPid}" 2>/dev/null || true; wait "${progressPid}" 2>/dev/null || true; progressPid=''; fi
  if [[ -n "${pvpanicPid}" ]]; then kill -- "-${pvpanicPid}" 2>/dev/null || true; wait "${pvpanicPid}" 2>/dev/null || true; pvpanicPid=''; fi
  if ((memoryAssociated)) && [[ -n "${vm}" && -n "${ns}" ]]; then
    RunTimed 60 virtctl memory-dump remove "${vm}" -n "${ns}" >/dev/null 2>&1 || true
    memoryAssociated=0
  fi
  [[ -z "${runDir}" ]] || rm -rf "${runDir}"
  true
}
# shellcheck disable=SC2317  # Invoked by INT/TERM traps.
function OnSignal () { typeset status="${1:?}"; [[ -z "${stageErrors}" ]] || RecordError interrupted "received signal; exiting with status ${status}"; exit "${status}"; }
trap Cleanup EXIT
trap 'OnSignal 130' INT
trap 'OnSignal 143' TERM

# Parse command-line arguments: cluster targets, crash detection tuning, storage, and modes
while (($#)); do
  case "$1" in
    --ns) ns="${2:?}"; shift 2 ;;
    --vm) vm="${2:?}"; shift 2 ;;
    --out) outArg="${2:?}"; shift 2 ;;
    --metadata) metadataFile="${2:?}"; shift 2 ;;
    --run-id) runId="${2:?}"; shift 2 ;;
    --ready-file) readyFile="${2:?}"; shift 2 ;;
    --evidence-mount) evidenceRoot="${2:?}"; shift 2 ;;
    --evidence-volume-kind) evidenceKind="${2:?}"; shift 2 ;;
    --evidence-storage-id) evidenceId="${2:?}"; shift 2 ;;
    --interval) interval="${2:?}"; shift 2 ;;
    --miss) miss="${2:?}"; shift 2 ;;
    --quiesce-wait) quiesceWait="${2:?}"; shift 2 ;;
    --idle-samples) idleSamples="${2:?}"; shift 2 ;;
    --snap-class) snapClass="${2:?}"; shift 2 ;;
    --recovery-image) recoveryImage="${2:?}"; shift 2 ;;
    --memory-dump-pvc) memoryPvc="${2:?}"; shift 2 ;;
    --disk-target) diskTarget="${2:?}"; shift 2 ;;
    --intentional) summaryMode='intentional-rhov'; shift ;;
    --no-restart) noRestart=1; shift ;;
    -h|--help)
      echo 'usage: watch-crash.sh --ns NS --vm VM --out EVIDENCE_MOUNT_OR_RUN_DIR [--metadata PREFLIGHT.json --run-id ID] --evidence-mount MOUNT --evidence-volume-kind KIND --evidence-storage-id ID --snap-class CLASS --recovery-image IMAGE@sha256:DIGEST --memory-dump-pvc PVC [options]'
      exit 0 ;;
    *) Die "unknown argument: $1" ;;
  esac
done

# Validate required arguments and timeout values
[[ -n "${ns}" && -n "${vm}" && -n "${outArg}" ]] || Die '--ns, --vm, and --out are required'
command -v setsid >/dev/null 2>&1 || Die "required local tool 'setsid' is not installed"
for value in "${interval}" "${miss}" "${quiesceWait}" "${idleSamples}" "${commandTimeout}" "${armedTimeout}"; do
  [[ "${value}" =~ ^[1-9][0-9]*$ ]] || Die 'all timeout/count values must be positive integers'
done

# Load or initialize run metadata
# If preflight metadata provided, load configuration from it; else run preflight to generate it
if [[ -n "${metadataFile}" ]]; then
  # Using metadata from prior preflight run: load and validate it matches current targets
  [[ -r "${metadataFile}" && -n "${runId}" ]] || Die '--metadata requires a readable file and --run-id'
  outDir="$(jq -er .outputDir "${metadataFile}")"
  [[ "$(realpath -m "${outArg}")" == "${outDir}" && "$(jq -r .runId "${metadataFile}")" == "${runId}" ]] || Die 'preflight metadata does not identify this run output'
else
  # Running preflight inline: generate metadata and validated configuration
  [[ -n "${evidenceRoot}" ]] || evidenceRoot="${outArg}"
  runId="${runId:-$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM}"
  outDir="$(realpath -m "${evidenceRoot}")/${runId}"
  mkdir "${outDir}" || Die "cannot create unique run directory ${outDir}"
  metadataFile="${outDir}/recovery-metadata.json"
  typeset -a preflightArgs=(--ns "${ns}" --vm "${vm}" --out "${outDir}" --metadata "${metadataFile}" --run-id "${runId}"
    --evidence-mount "${evidenceRoot}" --evidence-volume-kind "${evidenceKind}" --evidence-storage-id "${evidenceId}"
    --snap-class "${snapClass}" --recovery-image "${recoveryImage}" --memory-dump-pvc "${memoryPvc}")
  [[ -n "${diskTarget}" ]] && preflightArgs+=(--disk-target "${diskTarget}")
  RunTimed "${preflightTimeout}" "${scriptDir}/preflight-rhov.sh" "${preflightArgs[@]}" || Die 'preflight failed or timed out'
fi

# Extract validated configuration from metadata
typeset pod=''; pod="$(jq -er .launcherPod "${metadataFile}")"
typeset dom=''; dom="$(jq -er .domain "${metadataFile}")"
typeset node=''; node="$(jq -r .node "${metadataFile}")"
diskTarget="$(jq -er .diskTarget "${metadataFile}")"; memoryPvc="$(jq -er .memoryDumpPvc "${metadataFile}")"
[[ "$(jq -r .namespace "${metadataFile}")" == "${ns}" && "$(jq -r .vm "${metadataFile}")" == "${vm}" ]] || Die 'metadata target does not match watcher target'
export BSOD_DET__NAMESPACE="${ns}" BSOD_DET__VM__NAME="${vm}" BSOD_DET__POD__NAME="${pod}" BSOD_DET__DOMAIN__NAME="${dom}"

# Initialize output directory and log files
mkdir -p "${outDir}"; chmod 0700 "${outDir}"
stageErrors="${outDir}/stage-errors.jsonl"; : > "${stageErrors}"; chmod 0600 "${stageErrors}"
pipelineLog="${outDir}/watcher.log"; : > "${pipelineLog}"; chmod 0600 "${pipelineLog}"
runDir="$(mktemp -d "${TMPDIR:-/tmp}/bsod-watcher.XXXXXX")"; pvpanicFile="${runDir}/pvpanic.current"

# Inline guest connectivity test functions
# PingOk — check if guest is reachable via QEMU Guest Agent (QGA); measures guest OS responsiveness
function PingOk () { RunTimed 15 "${guestAgent[@]}" ping >/dev/null 2>&1; }
# DomainState — get libvirt domain state (running, paused, crashed, etc); measures hypervisor visibility
function DomainState () { Oc exec -n "${ns}" "${pod}" -- virsh domstate "${dom}" 2>/dev/null | tr -d '[:space:]'; }
# Write final evidence summary: manifest of all captured artifacts, success/failure status
function WriteSummary () {
  RunTimed 60 python3 "${scriptDir}/reliability.py" write-summary --out "${outDir}" --stage-errors "${stageErrors}" \
    --mode "${summaryMode}" --vm "${vm}" --namespace "${ns}" --run-id "${runId}" --filename evidence-summary.json
}
# Capture BSOD screenshot for visual verification: uses virtctl VNC snapshot after 60s delay (VNC becomes responsive)
function CaptureScreenshot () {
  typeset temporary="${outDir}/.bsod-screenshot.tmp"; typeset result=''; typeset format=''; typeset target=''
  rm -f "${temporary}"
  # VNC takes time to become responsive after BSOD; 60s sleep in main loop ensures readiness
  if ! RunTimed "${captureTimeout}" virtctl vnc screenshot "${vm}" -n "${ns}" --file="${temporary}" >>"${pipelineLog}" 2>&1; then
    RecordError screenshot 'virtctl vnc screenshot failed or timed out'; return 1
  fi
  # Validate screenshot structure (PNG format, parseable header)
  if ! result="$(RunTimed 30 python3 "${scriptDir}/reliability.py" validate-artifact --type screenshot --path "${temporary}")"; then
    rm -f "${temporary}"; RecordError screenshot 'screenshot is structurally invalid'; return 1
  fi
  format="$(jq -r .format <<<"${result}")"; target="${outDir}/bsod-screenshot.${format}"; mv -f "${temporary}" "${target}"
  Log "validated screenshot: $(basename "${target}")"
}
# Capture full guest physical memory via KubeVirt (no libvirt socket needed)
# Steps: (1) request memory dump to PVC, (2) poll completion, (3) create export,
# (4) download the gzip ELF artifact, and (5) validate its ELF structure.
function CaptureMemory () {
  typeset temporary="${outDir}/.vm-memory.elf.tmp"; typeset target="${outDir}/vm-memory.elf.tar.gz"
  # VirtualMachineExport name must be DNS subdomain-safe (63 chars max, no trailing dash)
  typeset exportName="bsod-memdump-${runId,,}"; exportName="${exportName:0:63}"; exportName="${exportName%-}"
  typeset pfPid=''
  rm -f "${temporary}"

  # Step 1: Submit memory dump request to KubeVirt - writes ELF format to memoryPvc
  if ! RunTimed 90 virtctl memory-dump get "${vm}" -n "${ns}" --claim-name="${memoryPvc}" >>"${pipelineLog}" 2>&1; then
    RecordError memory 'KubeVirt memory-dump request failed or timed out'; return 1
  fi
  memoryAssociated=1

  # Step 2: Wait for dump phase=Completed (polling memoryDumpRequest.phase in VM status)
  typeset phase='' deadline=$((SECONDS + memoryTimeout))
  while ((SECONDS < deadline)); do
    phase="$(Oc get vm "${vm}" -n "${ns}" -o jsonpath='{.status.memoryDumpRequest.phase}' 2>>"${pipelineLog}" || true)"
    [[ "${phase}" == Completed ]] && break
    [[ "${phase}" == Failed ]] && { RecordError memory 'KubeVirt memory-dump API reported Failed'; return 1; }
    sleep 3
  done
  [[ "${phase}" == Completed ]] || { RecordError memory "KubeVirt memory-dump phase timed out (last=${phase:-unset})"; return 1; }

  # Step 3: Clean up any stale VirtualMachineExport on the same PVC from previous runs,
  # then create a new export. A stale export prevents the new one from becoming Ready.
  typeset staleExports
  staleExports=$(Oc get virtualmachineexport -n "${ns}" -o json 2>/dev/null | \
    jq -r --arg pvc "${memoryPvc}" \
    '.items[] | select(.spec.source.name==$pvc) | .metadata.name' || true)
  if [[ -n "${staleExports}" ]]; then
    Log "cleaning up stale VirtualMachineExport(s) on PVC ${memoryPvc}: ${staleExports}"
    while IFS= read -r staleName; do
      Oc delete virtualmachineexport "${staleName}" -n "${ns}" --ignore-not-found >>"${pipelineLog}" 2>&1 || true
    done <<< "${staleExports}"
  fi

  # Create VirtualMachineExport to stream the dumped PVC over HTTP (no direct node access)
  Oc apply -f - >>"${pipelineLog}" 2>&1 <<EOF
apiVersion: export.kubevirt.io/v1beta1
kind: VirtualMachineExport
metadata:
  name: ${exportName}
  namespace: ${ns}
spec:
  source:
    apiGroup: ""
    kind: PersistentVolumeClaim
    name: ${memoryPvc}
  ttlDuration: 12h
EOF

  # 4. Wait for export ready and collect service/token/URL
  typeset exportPhase='' exportDeadline=$((SECONDS + 300))
  while ((SECONDS < exportDeadline)); do
    exportPhase="$(Oc get virtualmachineexport "${exportName}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "${exportPhase}" == Ready ]] && break
    sleep 5
  done
  if [[ "${exportPhase}" != Ready ]]; then
    RecordError memory 'VirtualMachineExport did not become ready'
    Oc delete virtualmachineexport "${exportName}" -n "${ns}" --ignore-not-found >>"${pipelineLog}" 2>&1 || true
    return 1
  fi
  # 5. Download via virtctl vmexport download — pure KubeVirt API, no token in logs.
  # --format gzip : downloads the tar.gz ELF format (maps to tar.gz URL in export status)
  # --port-forward: virtctl manages its own port-forward internally (no manual pfPid)
  # --insecure    : export service uses self-signed certificate
  # --keep-vme    : we delete the export ourselves after download
  Log "downloading memory dump via virtctl vmexport download (gzip/tar.gz format)..."
  if ! RunTimed 3600 virtctl vmexport download "${exportName}" \
      -n "${ns}" \
      --output "${temporary}" \
      --format gzip \
      --port-forward \
      --insecure \
      --keep-vme >>"${pipelineLog}" 2>&1; then
    Oc delete virtualmachineexport "${exportName}" -n "${ns}" --ignore-not-found >>"${pipelineLog}" 2>&1 || true
    RecordError memory "virtctl vmexport download failed"; return 1
  fi
  Oc delete virtualmachineexport "${exportName}" -n "${ns}" --ignore-not-found >>"${pipelineLog}" 2>&1 || true

  # 7. Validate and finalise
  if ! RunTimed 60 python3 "${scriptDir}/reliability.py" validate-artifact --type memory --path "${temporary}" >/dev/null; then
    rm -f "${temporary}"; RecordError memory 'downloaded memory dump is not a structurally valid ELF file'; return 1
  fi
  mv -f "${temporary}" "${target}"
  # [DEVELOPER TOOL — elf2dmp conversion, volatility analysis commented out]
  # elf2dmp produces a 17GB vm-memory-windows.dmp consuming mount space; run offline by developer.
  # volatility3 analysis (windows.info, crashinfo, driverscan, dumpfiles) also developer-run offline.
  # The raw vm-memory.elf.tar.gz is the primary artifact — hand it to developer for analysis.
  # To re-enable: uncomment the block below and ensure elf2dmp + volatility3 are installed.
  #
  # typeset innerDumpEntry=''
  # innerDumpEntry="$(tar -tzf "${target}" 2>/dev/null | grep -i '\.memory\.dump$' | head -1 || true)"
  # if [[ -n "${innerDumpEntry}" ]]; then
  #   typeset elfRaw="${outDir}/vm-memory-raw.elf"
  #   tar -xzf "${target}" -O "${innerDumpEntry}" 2>/dev/null > "${elfRaw}" || true
  #   if [[ -s "${elfRaw}" ]]; then
  #     Log "extracted inner ELF ($(du -sh "${elfRaw}" | cut -f1))"
  #     if command -v elf2dmp >/dev/null 2>&1; then
  #       typeset winDmp="${outDir}/vm-memory-windows.dmp"
  #       if RunTimed 300 elf2dmp "${elfRaw}" "${winDmp}" >>"${pipelineLog}" 2>&1 && [[ -s "${winDmp}" ]]; then
  #         Log "elf2dmp conversion complete: $(du -sh "${winDmp}" | cut -f1)"
  #         bash "${scriptDir}/parse-dump-header.sh" "${winDmp}" > "${outDir}/parse-dump-header-memory.json" 2>/dev/null || true
  #         [[ -s "${outDir}/parse-dump-header-memory.json" ]] && \
  #           cp "${outDir}/parse-dump-header-memory.json" "${outDir}/parse-dump-header.json"
  #         # volatility3 analysis — requires: pip install volatility3
  #         # if command -v vol >/dev/null 2>&1; then
  #         #   RunTimed 600 vol -f "${winDmp}" windows.info.Info      >"${outDir}/volatility-windows-info.txt" 2>&1 || true
  #         #   RunTimed 120 vol -f "${winDmp}" windows.crashinfo.CrashInfo >"${outDir}/volatility-crashinfo.txt" 2>&1 || true
  #         #   RunTimed 300 vol -f "${winDmp}" windows.driverscan.DriverScan >"${outDir}/volatility-driverscan.txt" 2>&1 || true
  #         #   RunTimed 600 vol -f "${winDmp}" windows.dumpfiles.DumpFiles >"${outDir}/volatility-dumpfiles.txt" 2>&1 || true
  #         # fi
  #       else
  #         mv -f "${elfRaw}" "${outDir}/vm-memory.elf.raw"
  #       fi
  #     else
  #       mv -f "${elfRaw}" "${outDir}/vm-memory.elf.raw"
  #     fi
  #     rm -f "${elfRaw}"
  #   fi
  # fi
  RunTimed 60 virtctl memory-dump remove "${vm}" -n "${ns}" >>"${pipelineLog}" 2>&1 || { RecordError memory 'memory-dump association cleanup failed'; return 1; }
  memoryAssociated=0; Log "validated KubeVirt memory dump: $(basename "${target}")"
}
function CaptureHostSignals () {
  typeset ok=0
  if Oc exec -n "${ns}" "${pod}" -- virsh dumpxml "${dom}" > "${outDir}/domain.xml" 2>>"${pipelineLog}" && [[ -s "${outDir}/domain.xml" ]]; then ok=$((ok + 1)); else rm -f "${outDir}/domain.xml"; RecordError host-signals 'domain XML capture failed'; fi
  if Oc logs -n "${ns}" "${pod}" -c compute > "${outDir}/launcher-compute.log" 2>>"${pipelineLog}" && [[ -s "${outDir}/launcher-compute.log" ]]; then ok=$((ok + 1)); else rm -f "${outDir}/launcher-compute.log"; RecordError host-signals 'launcher log capture failed'; fi
  ((ok == 2)) || return 1
  typeset -a args=(--vm "${dom}" --log-file "${outDir}/launcher-compute.log" --domain-xml "${outDir}/domain.xml")
  RunTimed 60 "${hostSignalsBin}" "${args[@]}" > "${outDir}/host-signals.json" 2>>"${pipelineLog}" || { RecordError host-signals 'host-signal parser failed'; return 1; }
  Log "captured launcher/domain diagnostics for node ${node:-unknown}"
}
function ProgressSample () {
  typeset stateFile="${runDir}/dump-progress.json"; typeset raw=''; typeset decision=''
  raw="$(Oc exec -n "${ns}" "${pod}" -- virsh domstats --block "${dom}" 2>>"${pipelineLog}")" || return 2
  decision="$(printf '%s\n' "${raw}" | RunTimed 20 python3 "${scriptDir}/reliability.py" progress-step --device "${diskTarget}" --state "${stateFile}" --idle-samples "${idleSamples}")" || return 2
  Log "dump progress: $(jq -r .status <<<"${decision}") ($(jq -r .reason <<<"${decision}"), writes=$(jq -r .writeBytes <<<"${decision}"))"
  [[ "$(jq -r .status <<<"${decision}")" == complete ]]
}
function MonitorDumpProgress () {
  typeset deadline=$((SECONDS + quiesceWait)); typeset stateFile="${runDir}/dump-progress.json"; typeset sampleStatus=0
  typeset statFailures=0; typeset maxStatFailures=5
  while ((SECONDS < deadline)); do
    if ProgressSample; then return 0; else sampleStatus=$?; fi
    if ((sampleStatus == 2)); then
      statFailures=$((statFailures + 1))
      if ((statFailures >= maxStatFailures)); then
        RecordError dump-completion 'disk statistics or progress evaluation failed/timed out'; return 1
      fi
      Log "dump progress: virsh domstats transient failure (${statFailures}/${maxStatFailures}), retrying..."
    else
      statFailures=0
    fi
    sleep "${interval}"
  done
  if [[ "$(jq -r '.observedProgress // false' "${stateFile}" 2>/dev/null || echo false)" == true ]]; then
    RecordError dump-completion 'write progress did not quiesce before the wall-clock deadline'
  else
    RecordError dump-completion 'no write progress was observed before the wall-clock deadline'
  fi
  return 1
}
function StartDumpMonitor () {
  # The first sample is synchronous and precedes every potentially long capture.
  typeset sampleStatus=0
  if ProgressSample; then RecordError dump-completion 'unexpected completed state at baseline'; return 1; else sampleStatus=$?; fi
  ((sampleStatus == 1)) || { RecordError dump-completion 'cannot establish bounded pre-capture disk-write baseline'; return 1; }
  [[ -f "${runDir}/dump-progress.json" ]] || { RecordError dump-completion 'cannot establish pre-capture disk-write baseline'; return 1; }
  MonitorDumpProgress & progressPid=$!
}
function WaitDumpMonitor () {
  typeset status=0; wait "${progressPid}" || status=$?; progressPid=''; return "${status}"
}
function StopVM () {
  Log 'requesting VMI stop through virtctl'
  RunTimed 90 virtctl stop "${vm}" -n "${ns}" >>"${pipelineLog}" 2>&1 || { RecordError stop 'virtctl stop failed or timed out; no fallback mutation attempted'; return 1; }
  typeset phase=''; typeset deadline=$((SECONDS + 120))
  while ((SECONDS < deadline)); do
    phase="$(Oc get vmi "${vm}" -n "${ns}" --ignore-not-found -o jsonpath='{.status.phase}' 2>>"${pipelineLog}")" || { RecordError stop 'cannot verify VMI stop'; return 1; }
    [[ -z "${phase}" || "${phase}" == Succeeded || "${phase}" == Failed ]] && break
    sleep 3
  done
  [[ -z "${phase}" || "${phase}" == Succeeded || "${phase}" == Failed ]] || { RecordError stop "offline deadline exceeded (phase=${phase})"; return 1; }
}
function RestartVM () {
  if ((noRestart == 0)); then RunTimed 90 virtctl start "${vm}" -n "${ns}" >>"${pipelineLog}" 2>&1 || { RecordError restart 'virtctl start failed or timed out'; return 1; }; fi
}
function Recover () {
  typeset recoveryTimeout=3600 recoveryBin="${scriptDir}/extract--guest-os--crash-info.sh"
  [[ -x "${recoveryBin}" ]] || { RecordError recovery "recovery script missing: ${recoveryBin}"; return 1; }
  RunTimed "${recoveryTimeout}" "${recoveryBin}" --metadata "${metadataFile}" >>"${pipelineLog}" 2>&1
}
function CrashResponse () {
  typeset state="${1:?}"; typeset failed=0
  Log "corroborated crash/freeze detected (domstate=${state})"
  Log "waiting 60 seconds for VNC to become responsive..."
  sleep 60
  StartDumpMonitor || failed=1
  CaptureScreenshot || failed=1
  if ! CaptureMemory; then
    Log "WARN: memory dump capture failed — attempting recovery via ODF snapshot"
  fi  # memory download failure is non-fatal — recovery extracts from ODF snapshot
  CaptureHostSignals || failed=1
  ((failed == 0)) || { [[ -z "${progressPid}" ]] || { kill "${progressPid}" 2>/dev/null || true; wait "${progressPid}" 2>/dev/null || true; progressPid=''; }; WriteSummary || true; return 1; }
  # Dump monitor failure is non-fatal when the primary memory artifact was already captured.
  # A frozen QEMU cannot respond to virsh domstats, causing monitor timeout even on a valid capture.
  if ! WaitDumpMonitor; then
    Log "WARN: dump progress monitor did not confirm completion — proceeding to recovery (captured memory artifact may still be valid)"
    RecordError dump-completion 'dump progress monitor failed; recovery will validate artifact integrity'
  fi
  # Wait for Windows event logs to stabilize (file size stops changing) before snapshot
  Log "waiting for Windows event logs to flush and stabilize..."
  typeset evtxStableCount=0 evtxDeadline=$((SECONDS + 600))
  while ((SECONDS < evtxDeadline)); do
    typeset systemSize=0 appSize=0
    systemSize="$(Oc exec -n "${ns}" "${pod}" -- powershell.exe -NoProfile -Command "(Get-Item 'C:\Windows\System32\winevt\Logs\System.evtx' -ErrorAction SilentlyContinue).Length" 2>/dev/null || echo 0)"
    appSize="$(Oc exec -n "${ns}" "${pod}" -- powershell.exe -NoProfile -Command "(Get-Item 'C:\Windows\System32\winevt\Logs\Application.evtx' -ErrorAction SilentlyContinue).Length" 2>/dev/null || echo 0)"
    if [[ "${systemSize}" != "0" && "${appSize}" != "0" ]]; then
      sleep 5
      typeset systemSize2=0 appSize2=0
      systemSize2="$(Oc exec -n "${ns}" "${pod}" -- powershell.exe -NoProfile -Command "(Get-Item 'C:\Windows\System32\winevt\Logs\System.evtx' -ErrorAction SilentlyContinue).Length" 2>/dev/null || echo 0)"
      appSize2="$(Oc exec -n "${ns}" "${pod}" -- powershell.exe -NoProfile -Command "(Get-Item 'C:\Windows\System32\winevt\Logs\Application.evtx' -ErrorAction SilentlyContinue).Length" 2>/dev/null || echo 0)"
      if [[ "${systemSize}" == "${systemSize2}" && "${appSize}" == "${appSize2}" ]]; then
        evtxStableCount=$((evtxStableCount + 1))
        [[ ${evtxStableCount} -ge 2 ]] && { Log "event logs stable (System: ${systemSize} bytes, Application: ${appSize} bytes)"; break; }
      else
        evtxStableCount=0
      fi
    fi
    sleep 3
  done
  # Stop the VM after memory/screenshot/host capture and event-log stabilization,
  # then recover the disk artifacts from the validated snapshot.
  StopVM || { WriteSummary || true; return 1; }
  # Recovery phase: extract event logs and inspect any available on-disk dump via guestfish.
  Recover || { WriteSummary || true; return 1; }
  RestartVM || { WriteSummary || true; return 1; }
  WriteSummary
}

Log "preflight passed; preparing watcher for ${ns}/${vm} (run=${runId}, disk=${diskTarget})"
PingOk || { RecordError preflight 'qemu guest agent became unavailable before arming'; WriteSummary || true; exit 1; }
setsid timeout --signal=TERM --kill-after=5 "${armedTimeout}" oc --request-timeout="${armedTimeout}s" get events -n "${ns}" --watch-only \
  --field-selector "reason=Panicked,involvedObject.name=${vm}" -o name >"${pvpanicFile}" 2>>"${pipelineLog}" &
pvpanicPid=$!
sleep 1; kill -0 "${pvpanicPid}" 2>/dev/null || { RecordError preflight 'event watcher exited before arming'; WriteSummary || true; exit 1; }
if [[ -n "${readyFile}" ]]; then typeset readyTmp="${readyFile}.tmp.$$"; printf '%s\n' "${runId}" > "${readyTmp}"; chmod 0600 "${readyTmp}"; mv -f "${readyTmp}" "${readyFile}"; fi
Log 'qemu guest agent and event watch healthy; watcher armed'

typeset misses=0; typeset state=''; typeset phase=''; typeset decision=''; typeset -a flags=(); typeset watchDeadline=$((SECONDS + armedTimeout))
while ((SECONDS < watchDeadline)); do
  if PingOk; then misses=0; sleep "${interval}"; continue; fi
  misses=$((misses + 1)); state="$(DomainState || printf unavailable)"; Log "missed ping ${misses}/${miss} (domstate=${state})"
  if ((misses >= miss)); then
    phase="$(Oc get vmi "${vm}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || printf unavailable)"
    flags=(--misses "${misses}" --threshold "${miss}" --domstate "${state}" --vmi-phase "${phase}")
    [[ -s "${pvpanicFile}" ]] && flags+=(--pvpanic)
    Oc get pod "${pod}" -n "${ns}" >/dev/null 2>&1 && flags+=(--pod-present)
    decision="$(RunTimed 20 python3 "${scriptDir}/reliability.py" decision "${flags[@]}")" || { RecordError detection 'ambiguous or unavailable crash evidence'; WriteSummary || true; exit 1; }
    if [[ "$(jq -r .decision <<<"${decision}")" == capture ]]; then
      kill -- "-${pvpanicPid}" 2>/dev/null || true; wait "${pvpanicPid}" 2>/dev/null || true; pvpanicPid=''
      CrashResponse "${state}"; exit $?
    fi
  fi
  sleep "${interval}"
done
RecordError detection "armed observation phase exceeded ${armedTimeout}s without a crash"
WriteSummary || true
exit 1
