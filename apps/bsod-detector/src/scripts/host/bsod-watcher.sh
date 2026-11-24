#!/bin/bash
# Per-VM RHOV crash watcher: arm on a healthy guest agent plus a pvpanic event watch, detect a corroborated BSOD/freeze, capture the at-crash evidence,
#   stop the VM (it is never restarted), run the offline guest OS crash extraction and write evidence-summary.json. See `--help`; BSOD_DET__TIMEOUT__ARMED
#   (seconds) is required. The run directory gets watcher.log (also on STDOUT), its JSON twin watcher-events.jsonl (plus state transitions),
#   stage-errors.jsonl and evidence-summary.json. Sourcing this file only defines functions and defaults, so tests can drive single functions.
# Apply runtime settings only when executed, not when sourced by tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euxo pipefail
    shopt -s inherit_errexit
    umask 077
fi

# ---- Configuration ----
typeset -g scriptDir=''; scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Settings and their defaults; ParseArgs applies the command line and ValidateMetadata loads the target (Pod, domain, node, disk target,
#   memory-dump PVC) from the preflight metadata. The preflight-only settings start empty: PrepareRun resolves the evidence mount
#   (BSOD_DET__EVIDENCE__MOUNT, else --out) and volume kind (BSOD_DET__EVIDENCE__VOLUME_KIND) itself and forwards only values that are set, so
#   preflight-rhov.sh applies its own BSOD_DET__* defaults to the rest. Timeout budgets (seconds) come from BSOD_DET__TIMEOUT__*; the earlier
#   names are still accepted for existing callers.
typeset -gA cfgArr=(
    [ns]='' [vm]='' [outArg]='' [metadataFile]='' [runId]='' [readyFile]=''
    [diskTarget]='' [summaryMode]='natural-rhov'
    [evidenceRoot]='' [evidenceKind]='' [evidenceId]=''
    [snapClass]='' [recoveryImage]='' [memoryPvc]=''
    [interval]=5 [miss]=2 [quiesceWait]=900 [idleSamples]=3
    [preflightTimeout]="${BSOD_DET__TIMEOUT__PREFLIGHT:-${BSOD_DET__PREFLIGHT__TIMEOUT:-300}}"
    [captureTimeout]="${BSOD_DET__TIMEOUT__CAPTURE:-${BSOD_DET__CAPTURE__TIMEOUT:-300}}"
    [memoryTimeout]="${BSOD_DET__TIMEOUT__MEMORY:-${BSOD_MEMORY_CAPTURE_TIMEOUT:-1800}}"
    [armedTimeout]="${BSOD_DET__TIMEOUT__ARMED:-${BSOD_DET__ARMED__TIMEOUT:-}}"
    [hostSignalsBin]="${BSOD_DET__HOST_SIGNALS__BIN:-${scriptDir}/collect-host-signals.sh}"
    [pod]='' [dom]='' [node]=''
)
typeset -ga guestAgentArr=(python3 "${scriptDir}/guest-agent.py")
[[ -z "${BSOD_DET__GUEST_AGENT__BIN:-}" ]] || guestAgentArr=("${BSOD_DET__GUEST_AGENT__BIN}")
# Run state: background processes (StartProcess), run and temporary directories and files, log files, crash-response state.
typeset -gA pidArr=()
typeset -g outDir='' runDir=''
typeset -g pvpanicFile='' progressFile=''
typeset -g stageErrors='' pipelineLog='' eventLog=''
typeset -g watchState='init'
typeset -gi isMemoryAssociated=0

# ---- Logging, states and summary ----
function Die () { echo "bsod-watcher: ERROR: $*" >&2; exit 1; }
function RunTimed () { typeset seconds="${1:?}"; shift; timeout --signal=TERM --kill-after=5 "${seconds}" "$@"; }
# WriteEvent LEVEL MESSAGE [STAGE]: append {at,level,state,stage,msg} to watcher-events.jsonl (no-op until PrepareRun created it).
function WriteEvent () {
    typeset level="${1:?}" msg="${2?}" stage="${3:-}"
    [[ -z "${eventLog}" ]] || jq -cn --arg level "${level}" --arg state "${watchState}" --arg stage "${stage}" --arg msg "${msg}" \
        '{at:(now | todate),level:$level,state:$state,stage:$stage,msg:$msg}' >> "${eventLog}"
}
# Log MESSAGE...: the established `[HH:MM:SS] MESSAGE` line on STDOUT and in watcher.log, plus its JSON event (level / stage taken from the `WARN:` and
#   `ERROR [stage]:` message prefixes).
function Log () {
    typeset msg="$*" level=info stage='' errRe='^ERROR \[([^]]+)\]: '
    if [[ "${msg}" =~ ${errRe} ]]; then level=error stage="${BASH_REMATCH[1]}"; elif [[ "${msg}" == WARN:* ]]; then level=warn; fi
    printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "${msg}" | tee -a "${pipelineLog}"
    WriteEvent "${level}" "${msg}" "${stage}"
}
# SetState STATE: JSON-only transition through init, armed, capturing, captured, recovering, then recovered, failed or interrupted.
function SetState () { watchState="${1:?}"; WriteEvent state "${watchState}"; }
function RecordError () {
    typeset stage="${1:?}"; shift
    jq -cn --arg stage "${stage}" --arg error "$*" '{stage:$stage,error:$error,at:(now | todate)}' >> "${stageErrors}"
    Log "ERROR [${stage}]: $*"
}
function WriteSummary () {
    RunTimed 60 python3 "${scriptDir}/reliability.py" write-summary --out "${outDir}" --stage-errors "${stageErrors}" --mode "${cfgArr[summaryMode]}" \
        --vm "${cfgArr[vm]}" --namespace "${cfgArr[ns]}" --run-id "${cfgArr[runId]}" --filename evidence-summary.json
}

# ---- Background processes and exit handling ----
# StartProcess NAME OUT CMD...: run CMD in the background as pidArr[NAME]; OUT '-' inherits STDOUT/STDERR, otherwise STDOUT >> OUT, STDERR >> watcher.log.
#   A `setsid` CMD leads its own process group, so its PID is stored negated and `kill` signals the whole group.
function StartProcess () {
    typeset name="${1:?}" out="${2:?}"; shift 2
    if [[ "${out}" == - ]]; then "$@" & else "$@" >> "${out}" 2>> "${pipelineLog}" & fi
    pidArr[${name}]=$!
    [[ "${1##*/}" != setsid ]] || pidArr[${name}]="-$!"
}
function IsProcessRunning () { [[ -n "${pidArr[${1:?}]:-}" ]] && kill -0 "${pidArr[${1}]#-}" 2>/dev/null; }
# WaitProcess NAME: reap a started process, then forget it; returns its exit status (0 when NAME is not registered).
function WaitProcess () {
    typeset name="${1:?}"
    typeset pid="${pidArr[${name}]:-}"
    typeset -i status=0
    [[ -z "${pid}" ]] || wait "${pid#-}" || status=$?
    unset "pidArr[${name}]"
    return "${status}"
}
# CleanupProcesses [NAME...]: terminate and reap the named (default: all) started processes, ignoring their exit status.
function CleanupProcesses () {
    typeset name=''
    (($#)) || set -- "${!pidArr[@]}"
    for name in "$@"; do
        [[ -z "${pidArr[${name}]:-}" ]] || { kill -- "${pidArr[${name}]}" 2>/dev/null || true; WaitProcess "${name}" || true; }
    done
}
# Fatal [STAGE MESSAGE...]: stop the background processes, record the optional stage error, write the summary and exit 1.
function Fatal () {
    CleanupProcesses
    SetState failed
    if (($#)); then RecordError "$@"; fi
    WriteSummary || true
    exit 1
}
# Cleanup: EXIT trap — stop background processes, drop a left-over memory-dump association, close an unfinished state and remove the run temp dir.
function Cleanup () {
    CleanupProcesses
    ((isMemoryAssociated == 0)) || RemoveMemoryDump || true
    [[ "${watchState}" =~ ^(init|recovered|failed|interrupted)$ ]] || SetState failed
    [[ -z "${runDir}" ]] || rm -rf "${runDir}"
    true
}
function OnSignal () {
    typeset status="${1:?}"
    [[ -z "${stageErrors}" ]] || { SetState interrupted; RecordError interrupted "received signal; exiting with status ${status}"; }
    exit "${status}"
}

# ---- Command line, configuration and run preparation ----
# ParseArgs ARGS...: map the CLI options onto cfgArr; optArr names the options that take a value.
function ParseArgs () {
    typeset -A optArr=(
        [--ns]=ns [--vm]=vm [--out]=outArg [--metadata]=metadataFile [--run-id]=runId [--ready-file]=readyFile [--evidence-mount]=evidenceRoot
        [--evidence-volume-kind]=evidenceKind [--evidence-storage-id]=evidenceId [--interval]=interval [--miss]=miss [--quiesce-wait]=quiesceWait
        [--idle-samples]=idleSamples [--snap-class]=snapClass [--recovery-image]=recoveryImage [--memory-dump-pvc]=memoryPvc [--disk-target]=diskTarget)
    while (($#)); do
        case "${1}" in
          (--intentional) cfgArr[summaryMode]='intentional-rhov'; shift;;
          (--no-restart)  # Deprecated no-op kept for existing callers: the watcher never restarts the VM, it is always left Stopped.
            echo 'bsod-watcher: WARN: --no-restart is deprecated and has no effect; the VM is always left Stopped' >&2 || true
            shift;;
          (-h|--help)
            echo 'usage: bsod-watcher.sh --ns NS --vm VM --out EVIDENCE_MOUNT_OR_RUN_DIR [--metadata PREFLIGHT.json --run-id ID] --evidence-mount MOUNT --evidence-volume-kind KIND --evidence-storage-id ID --snap-class CLASS --recovery-image IMAGE@sha256:DIGEST --memory-dump-pvc PVC [options]'
            exit 0;;
          (*)
            [[ -n "${1}" && -n "${optArr[${1}]:-}" ]] || Die "unknown argument: ${1}"
            cfgArr[${optArr[${1}]}]="${2:?}"
            shift 2;;
        esac
    done
}
# ValidateConfig: before any cluster call, require the target and the armed timeout, and positive-integer counts / timeouts (named by option / variable,
#   checked in this order).
function ValidateConfig () {
    typeset pair=''
    [[ -n "${cfgArr[ns]}" && -n "${cfgArr[vm]}" && -n "${cfgArr[outArg]}" ]] || Die '--ns, --vm, and --out are required'
    [[ -n "${cfgArr[armedTimeout]}" ]] ||
        Die 'BSOD_DET__TIMEOUT__ARMED must be set by the caller (seconds to stay armed waiting for a crash; legacy BSOD_DET__ARMED__TIMEOUT is accepted)'
    for pair in interval:--interval miss:--miss quiesceWait:--quiesce-wait idleSamples:--idle-samples \
        armedTimeout:BSOD_DET__TIMEOUT__ARMED/BSOD_DET__ARMED__TIMEOUT preflightTimeout:BSOD_DET__TIMEOUT__PREFLIGHT/BSOD_DET__PREFLIGHT__TIMEOUT \
        captureTimeout:BSOD_DET__TIMEOUT__CAPTURE/BSOD_DET__CAPTURE__TIMEOUT memoryTimeout:BSOD_DET__TIMEOUT__MEMORY/BSOD_MEMORY_CAPTURE_TIMEOUT; do
        [[ "${cfgArr[${pair%%:*}]}" =~ ^[1-9][0-9]*$ ]] || Die "all timeout/count values must be positive integers: ${pair#*:}='${cfgArr[${pair%%:*}]}'"
    done
    [[ -z "${cfgArr[metadataFile]}" || ( -r "${cfgArr[metadataFile]}" && -n "${cfgArr[runId]}" ) ]] || Die '--metadata requires a readable file and --run-id'
}
function ValidateTools () {
    typeset tool=''
    for tool in setsid timeout jq oc virtctl python3 realpath; do command -v "${tool}" >/dev/null || Die "required local tool '${tool}' is not installed"; done
}
# ValidateMetadata FILE OUT_DIR: reject preflight metadata with a wrong field type or describing another run / target (each problem names the field),
#   then load the launcher Pod, domain, disk target, memory-dump PVC and node into cfgArr. guestPvc is only checked, for the extractor.
function ValidateMetadata () {
    typeset file="${1:?}" expectedOutDir="${2:?}"
    typeset problems='' fields=''
    typeset -a fieldArr=()
    problems="$(jq -rs --arg outDir "${expectedOutDir}" --arg runId "${cfgArr[runId]}" --arg ns "${cfgArr[ns]}" --arg vm "${cfgArr[vm]}" '
        def badString: type != "string" or . == "" or test("[\r\n]");
        if length != 1 or (.[0] | type) != "object" then "it must hold exactly one JSON object" else .[0] |
            (("runId", "outputDir", "namespace", "vm", "launcherPod", "domain", "diskTarget", "memoryDumpPvc", "guestPvc") as $k
                | select(.[$k] | badString) | "\($k) must be a non-empty single-line string (found \(.[$k] | tojson))"),
            (select(.node // "" | type != "string" or test("[\r\n]")) | "node must be a single-line string when present (found \(.node | tojson))"),
            (select(.outputDir != $outDir or .runId != $runId) | "preflight metadata does not identify this run output (outputDir/runId "
                + "\(.outputDir | tojson)/\(.runId | tojson), expected \($outDir)/\($runId)): pass the --out and --run-id used for preflight"),
            (select(.namespace != $ns or .vm != $vm) | "metadata target does not match watcher target (\(.namespace)/\(.vm), expected \($ns)/\($vm))")
        end' "${file}")" || Die "preflight metadata ${file} is unreadable or not valid JSON; re-run preflight-rhov.sh"
    [[ -z "${problems}" ]] || Die "invalid preflight metadata ${file}: ${problems//$'\n'/; }"
    fields="$(jq -r '.launcherPod, .domain, .diskTarget, .memoryDumpPvc, .node // ""' "${file}")" || Die "cannot read preflight metadata ${file}"
    readarray -t fieldArr <<<"${fields}"
    cfgArr[pod]="${fieldArr[0]}" cfgArr[dom]="${fieldArr[1]}" cfgArr[diskTarget]="${fieldArr[2]}" cfgArr[memoryPvc]="${fieldArr[3]}" cfgArr[node]="${fieldArr[4]:-}"
}
# PrepareRun: resolve the run output directory (running preflight-rhov.sh first when no --metadata was given), validate the metadata and create the
#   run log files and the run-scoped temporary directory. Optional preflight settings are forwarded only when set; otherwise preflight-rhov.sh
#   applies its own BSOD_DET__* defaults (and the legacy BSOD_EVIDENCE_VOLUME_KIND it still reads).
function PrepareRun () {
    typeset pair=''
    typeset -a preflightArr=()
    if [[ -n "${cfgArr[metadataFile]}" ]]; then
        outDir="$(realpath -m "${cfgArr[outArg]}")"
    else
        [[ -n "${cfgArr[evidenceRoot]}" ]] || cfgArr[evidenceRoot]="${BSOD_DET__EVIDENCE__MOUNT:-${cfgArr[outArg]}}"
        [[ -n "${cfgArr[evidenceKind]}" ]] || cfgArr[evidenceKind]="${BSOD_DET__EVIDENCE__VOLUME_KIND:-}"
        [[ -n "${cfgArr[runId]}" ]] || cfgArr[runId]="$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM}"
        outDir="$(realpath -m "${cfgArr[evidenceRoot]}")/${cfgArr[runId]}"
        mkdir "${outDir}" || Die "cannot create unique run directory ${outDir}"
        cfgArr[metadataFile]="${outDir}/recovery-metadata.json"
        preflightArr=(--ns "${cfgArr[ns]}" --vm "${cfgArr[vm]}" --out "${outDir}" --metadata "${cfgArr[metadataFile]}" --run-id "${cfgArr[runId]}"
            --evidence-mount "${cfgArr[evidenceRoot]}")
        for pair in evidenceKind:--evidence-volume-kind evidenceId:--evidence-storage-id snapClass:--snap-class recoveryImage:--recovery-image \
            memoryPvc:--memory-dump-pvc diskTarget:--disk-target; do
            [[ -z "${cfgArr[${pair%%:*}]}" ]] || preflightArr+=("${pair#*:}" "${cfgArr[${pair%%:*}]}")
        done
        RunTimed "${cfgArr[preflightTimeout]}" "${scriptDir}/preflight-rhov.sh" "${preflightArr[@]}" || Die 'preflight failed or timed out'
    fi
    ValidateMetadata "${cfgArr[metadataFile]}" "${outDir}"
    export BSOD_DET__NAMESPACE="${cfgArr[ns]}" BSOD_DET__VM__NAME="${cfgArr[vm]}" BSOD_DET__POD__NAME="${cfgArr[pod]}" BSOD_DET__DOMAIN__NAME="${cfgArr[dom]}"
    mkdir -p "${outDir}"
    chmod 0700 "${outDir}"
    stageErrors="${outDir}/stage-errors.jsonl" pipelineLog="${outDir}/watcher.log" eventLog="${outDir}/watcher-events.jsonl"
    : > "${stageErrors}"
    : > "${pipelineLog}"
    : > "${eventLog}"
    chmod 0600 "${stageErrors}" "${pipelineLog}" "${eventLog}"
    runDir="$(mktemp -d "${TMPDIR:-/tmp}/bsod-watcher.XXXXXX")"
    pvpanicFile="${runDir}/pvpanic.current" progressFile="${runDir}/dump-progress.json"
}

# ---- Arming and crash detection ----
function PingGuest () { RunTimed 15 "${guestAgentArr[@]}" ping >/dev/null 2>&1; }
# ArmWatcher: prove the guest agent answers, start the pvpanic event watch for the armed period and publish the run ID to the --ready-file.
function ArmWatcher () {
    typeset readyTmp="${cfgArr[readyFile]}.tmp.$$"
    Log "preflight passed; preparing watcher for ${cfgArr[ns]}/${cfgArr[vm]} (run=${cfgArr[runId]}, disk=${cfgArr[diskTarget]})"
    PingGuest || Fatal preflight 'qemu guest agent became unavailable before arming'
    StartProcess pvpanic "${pvpanicFile}" setsid timeout --signal=TERM --kill-after=5 "${cfgArr[armedTimeout]}" oc --request-timeout="${cfgArr[armedTimeout]}s" \
        get events -n "${cfgArr[ns]}" --watch-only --field-selector "reason=Panicked,involvedObject.name=${cfgArr[vm]}" -o name
    sleep 1
    IsProcessRunning pvpanic || Fatal preflight 'event watcher exited before arming'
    if [[ -n "${cfgArr[readyFile]}" ]]; then
        printf '%s\n' "${cfgArr[runId]}" > "${readyTmp}"
        chmod 0600 "${readyTmp}"
        mv -f "${readyTmp}" "${cfgArr[readyFile]}"
    fi
    SetState armed
    Log 'qemu guest agent and event watch healthy; watcher armed'
}
# WaitForCrash DOMSTATE_REF: poll the guest agent until `reliability.py decision` rules "capture" on the corroborating evidence (domstate returned via the
#   nameref, pvpanic watch stopped). Ambiguous evidence, or the armed timeout passing without a crash, is fatal.
function WaitForCrash () {
    typeset -n domStateRef="${1:?}"
    typeset -i misses=0 deadline=$((SECONDS + cfgArr[armedTimeout]))
    typeset phase='' decision=''
    typeset -a flagArr=()
    while ((SECONDS < deadline)); do
        if PingGuest; then
            misses=0
            sleep "${cfgArr[interval]}"
            continue
        fi
        misses+=1
        domStateRef="$(oc --request-timeout=10s exec -n "${cfgArr[ns]}" "${cfgArr[pod]}" -- virsh domstate "${cfgArr[dom]}" 2>/dev/null | tr -d '[:space:]' || printf unavailable)"
        Log "missed ping ${misses}/${cfgArr[miss]} (domstate=${domStateRef})"
        if ((misses >= cfgArr[miss])); then
            phase="$(oc --request-timeout=30s get vmi "${cfgArr[vm]}" -n "${cfgArr[ns]}" -o jsonpath='{.status.phase}' 2>/dev/null || printf unavailable)"
            flagArr=(--misses "${misses}" --threshold "${cfgArr[miss]}" --domstate "${domStateRef}" --vmi-phase "${phase}")
            [[ -s "${pvpanicFile}" ]] && flagArr+=(--pvpanic)
            oc --request-timeout=30s get pod "${cfgArr[pod]}" -n "${cfgArr[ns]}" >/dev/null 2>&1 && flagArr+=(--pod-present)
            decision="$(RunTimed 20 python3 "${scriptDir}/reliability.py" decision "${flagArr[@]}")" || Fatal detection 'ambiguous or unavailable crash evidence'
            [[ "$(jq -r .decision <<<"${decision}")" != capture ]] || { CleanupProcesses pvpanic; return 0; }
        fi
        sleep "${cfgArr[interval]}"
    done
    Fatal detection "armed observation phase exceeded ${cfgArr[armedTimeout]}s without a crash"
}

# ---- Evidence capture ----
# IsPodTerminated PHASE_REF: true when the virt-launcher Pod is Failed or Succeeded; its phase (or Unknown) is returned through the nameref.
function IsPodTerminated () {
    typeset -n phaseRef="${1:?}"
    phaseRef="$(oc --request-timeout=30s get pod "${cfgArr[pod]}" -n "${cfgArr[ns]}" -o jsonpath='{.status.phase}' 2>/dev/null || echo 'Unknown')"
    [[ "${phaseRef}" == 'Failed' || "${phaseRef}" == 'Succeeded' ]]
}
# RecordUnlessPodGone STAGE PREFIX NOTE ERROR: with the virt-launcher Pod terminated (QEMU died with the guest) the failure is expected and only logged.
function RecordUnlessPodGone () {
    typeset stage="${1:?}" prefix="${2:?}" note="${3:?}" error="${4:?}" podPhase=''
    if IsPodTerminated podPhase; then Log "${prefix}: virt-launcher pod is ${podPhase} — ${note} (expected)"; else RecordError "${stage}" "${error}"; fi
}
function EvtxSize () { oc --request-timeout=30s exec -n "${cfgArr[ns]}" "${cfgArr[pod]}" -- powershell.exe -NoProfile -Command "(Get-Item 'C:\Windows\System32\winevt\Logs\\${1:?}.evtx' -ErrorAction SilentlyContinue).Length" 2>/dev/null || echo 0; }
function ArtifactTemp () { printf '%s/.%s.tmp\n' "${outDir}" "${1:?}"; }
# ValidateAndStoreArtifact TYPE NAME [CMD...]: atomically promote the ArtifactTemp file to "${outDir}/NAME" once it validates, so evidence files are
#   complete or absent; CMD, if given, first writes the temporary file on STDOUT (STDERR >> watcher.log). TYPE nonempty only checks the size, while
#   screenshot / memory use `reliability.py validate-artifact`: the screenshot gets its detected format as extension and an invalid memory dump is
#   still kept as NAME for inspection. Prints the stored name; returns non-zero when nothing valid was stored.
function ValidateAndStoreArtifact () {
    typeset artifactType="${1:?}" name="${2:?}"; shift 2
    typeset tmpFile='' result=''
    typeset -i seconds=30
    [[ "${artifactType}" != memory ]] || seconds=60
    tmpFile="$(ArtifactTemp "${name}")"
    if (($#)) && ! "$@" > "${tmpFile}" 2>> "${pipelineLog}"; then rm -f "${tmpFile}"; return 1; fi
    if [[ "${artifactType}" == nonempty ]]; then
        [[ -s "${tmpFile}" ]] || { rm -f "${tmpFile}"; return 1; }
    elif result="$(RunTimed "${seconds}" python3 "${scriptDir}/reliability.py" validate-artifact --type "${artifactType}" --path "${tmpFile}")"; then
        [[ "${artifactType}" != screenshot ]] || name+=".$(jq -r .format <<<"${result}")"
    else
        # Keep an invalid memory dump under its final name for inspection; delete any other invalid artifact.
        if [[ "${artifactType}" != memory ]] || ! mv -f "${tmpFile}" "${outDir}/${name}" 2>> "${pipelineLog}"; then rm -f "${tmpFile}"; fi
        return 1
    fi
    mv -f "${tmpFile}" "${outDir}/${name}" 2>> "${pipelineLog}" || { rm -f "${tmpFile}"; return 1; }
    printf '%s\n' "${name}"
}
function CaptureDomainXml () {
    ValidateAndStoreArtifact nonempty domain-bsod.xml oc --request-timeout=30s exec -n "${cfgArr[ns]}" "${cfgArr[pod]}" -- virsh dumpxml "${cfgArr[dom]}" >/dev/null
}
function CaptureScreenshot () {
    typeset tmpFile='' shot=''
    tmpFile="$(ArtifactTemp bsod-screenshot)"
    rm -f "${tmpFile}"
    RunTimed "${cfgArr[captureTimeout]}" virtctl vnc screenshot "${cfgArr[vm]}" -n "${cfgArr[ns]}" --file="${tmpFile}" >>"${pipelineLog}" 2>&1 ||
        { RecordError screenshot 'virtctl vnc screenshot failed or timed out'; return 1; }
    shot="$(ValidateAndStoreArtifact screenshot bsod-screenshot)" || { RecordError screenshot 'screenshot is structurally invalid'; return 1; }
    Log "validated screenshot: ${shot}"
}
function DeleteExports () { oc --request-timeout=30s delete virtualmachineexport "$@" -n "${cfgArr[ns]}" --ignore-not-found >>"${pipelineLog}" 2>&1 || true; }
function RemoveMemoryDump () { RunTimed 60 virtctl memory-dump remove "${cfgArr[vm]}" -n "${cfgArr[ns]}" >>"${pipelineLog}" 2>&1 && isMemoryAssociated=0; }
# CaptureMemory: best effort — request the KubeVirt memory dump, wait for it, export the dump PVC, download it with stall detection, then validate and
#   store vm-memory.elf.tar.gz and drop the memory-dump association. Every failure is recorded and returns non-zero.
function CaptureMemory () {
    typeset memoryFile=vm-memory.elf.tar.gz tmpFile='' exportName="bsod-memdump-${cfgArr[runId],,}"
    typeset phase='' exportPhase='' podPhase='' currentSize=''
    typeset -i deadline=0 lastSize=0 downloadStatus=0
    typeset -i stallCount=0 stallThreshold=10  # 10 * 30s = 5 min stall limit
    typeset -a staleArr=()
    tmpFile="$(ArtifactTemp "${memoryFile}")"
    exportName="${exportName:0:63}"
    exportName="${exportName%-}"
    rm -f "${tmpFile}"
    RunTimed 90 virtctl memory-dump get "${cfgArr[vm]}" -n "${cfgArr[ns]}" --claim-name="${cfgArr[memoryPvc]}" >>"${pipelineLog}" 2>&1 ||
        { RecordError memory 'KubeVirt memory-dump request failed or timed out'; return 1; }
    isMemoryAssociated=1
    deadline=$((SECONDS + cfgArr[memoryTimeout]))
    while ((SECONDS < deadline)); do
        phase="$(oc --request-timeout=30s get vm "${cfgArr[vm]}" -n "${cfgArr[ns]}" -o jsonpath='{.status.memoryDumpRequest.phase}' 2>>"${pipelineLog}" || true)"
        [[ "${phase}" == Completed ]] && break
        [[ "${phase}" == Failed ]] && { RecordError memory 'KubeVirt memory-dump API reported Failed'; return 1; }
        IsPodTerminated podPhase && { Log "memory dump: virt-launcher pod is ${podPhase} — memory dump cannot complete, skipping"; return 1; }
        sleep 3
    done
    [[ "${phase}" == Completed ]] || { RecordError memory "KubeVirt memory-dump phase timed out (last=${phase:-unset})"; return 1; }
    readarray -t staleArr < <(oc --request-timeout=30s get virtualmachineexport -n "${cfgArr[ns]}" -o json 2>/dev/null |
        jq -r --arg pvc "${cfgArr[memoryPvc]}" '.items[] | select(.spec.source.name==$pvc) | .metadata.name' || true)
    ((${#staleArr[@]} == 0)) || { Log "cleaning up stale VirtualMachineExport(s) on PVC ${cfgArr[memoryPvc]}: ${staleArr[*]}"; DeleteExports "${staleArr[@]}"; }
    jq -n --arg name "${exportName}" --arg ns "${cfgArr[ns]}" --arg pvc "${cfgArr[memoryPvc]}" '{apiVersion:"export.kubevirt.io/v1beta1",
        kind:"VirtualMachineExport",metadata:{name:$name,namespace:$ns},spec:{source:{apiGroup:"",kind:"PersistentVolumeClaim",name:$pvc},ttlDuration:"12h"}}' |
        oc --request-timeout=30s apply -f - >>"${pipelineLog}" 2>&1 ||
        { RecordError memory 'VirtualMachineExport creation failed'; DeleteExports "${exportName}"; return 1; }
    deadline=$((SECONDS + 300))
    while ((SECONDS < deadline)); do
        exportPhase="$(oc --request-timeout=30s get virtualmachineexport "${exportName}" -n "${cfgArr[ns]}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        [[ "${exportPhase}" == Ready ]] && break
        sleep 5
    done
    [[ "${exportPhase}" == Ready ]] || { RecordError memory 'VirtualMachineExport did not become ready'; DeleteExports "${exportName}"; return 1; }
    Log 'downloading memory dump via virtctl vmexport (progress-monitored, no hard timeout)...'
    StartProcess download "${pipelineLog}" virtctl vmexport download "${exportName}" -n "${cfgArr[ns]}" --output "${tmpFile}" --format gzip \
        --port-forward --insecure --keep-vme
    while IsProcessRunning download; do
        sleep 30
        currentSize=0
        [[ -f "${tmpFile}" ]] && currentSize=$(stat -c%s "${tmpFile}" 2>/dev/null || echo 0)
        if ((currentSize > lastSize)); then
            Log "download progress: $(numfmt --to=iec-i --suffix=B "${currentSize}" 2>/dev/null || echo "${currentSize} bytes")"
            lastSize=${currentSize}
            stallCount=0
        elif ((++stallCount > stallThreshold)); then
            Log 'WARN: download stalled (no writes for 5 min) — terminating'
            kill -TERM "${pidArr[download]}" 2>/dev/null || true; break
        fi
    done
    WaitProcess download || downloadStatus=$?
    DeleteExports "${exportName}"
    ((downloadStatus == 0)) || { rm -f "${tmpFile}"; RecordError memory 'virtctl vmexport download failed'; return 1; }
    if ! ValidateAndStoreArtifact memory "${memoryFile}" >/dev/null; then
        Log "WARN: memory dump failed ELF validation — kept as ${memoryFile} for inspection"
        RecordError memory 'downloaded memory dump is not a structurally valid ELF file'
        return 1
    fi
    RemoveMemoryDump || { RecordError memory 'memory-dump association cleanup failed'; return 1; }
    Log "validated KubeVirt memory dump: ${memoryFile}"
}
# CaptureHostSignals: domain XML (unless captured at crash time), the compute container log and the host-signal summary. With the virt-launcher Pod
#   terminated a missing launcher file is only logged; any missing file still fails the capture.
function CaptureHostSignals () {
    typeset -i capturedCount=0
    if [[ -s "${outDir}/domain-bsod.xml" ]]; then
        Log "host-signals: domain-bsod.xml already pre-captured ($(wc -c < "${outDir}/domain-bsod.xml") bytes) — skipping re-capture"; capturedCount+=1
    elif CaptureDomainXml; then capturedCount+=1
    else RecordUnlessPodGone host-signals host-signals 'domain XML not available' 'domain XML capture failed'; fi
    if ValidateAndStoreArtifact nonempty launcher-compute.log oc --request-timeout=30s logs -n "${cfgArr[ns]}" "${cfgArr[pod]}" -c compute >/dev/null; then capturedCount+=1
    else RecordUnlessPodGone host-signals host-signals 'launcher log not available' 'launcher log capture failed'; fi
    ((capturedCount == 2)) || return 1
    ValidateAndStoreArtifact nonempty host-signals.json RunTimed 60 "${cfgArr[hostSignalsBin]}" --vm "${cfgArr[dom]}" --log-file "${outDir}/launcher-compute.log" \
        --domain-xml "${outDir}/domain-bsod.xml" >/dev/null || { RecordError host-signals 'host-signal parser failed'; return 1; }
    Log "captured launcher/domain diagnostics for node ${cfgArr[node]:-unknown}"
}
# ProgressSample: one disk-write sample through `reliability.py progress-step`; 0 = dump complete, 1 = not yet, 2 = statistics/evaluation failure.
function ProgressSample () {
    typeset raw='' decision=''
    raw="$(oc --request-timeout=30s exec -n "${cfgArr[ns]}" "${cfgArr[pod]}" -- virsh domstats --block "${cfgArr[dom]}" 2>>"${pipelineLog}")" || return 2
    decision="$(printf '%s\n' "${raw}" | RunTimed 20 python3 "${scriptDir}/reliability.py" progress-step --device "${cfgArr[diskTarget]}" \
        --state "${progressFile}" --idle-samples "${cfgArr[idleSamples]}")" || return 2
    Log "dump progress: $(jq -r '"\(.status) (\(.reason), writes=\(.writeBytes))"' <<<"${decision}")"
    [[ "$(jq -r .status <<<"${decision}")" == complete ]]
}
# MonitorDumpProgress: background job (StartDumpMonitor) sampling until the guest dump writes quiesce; non-zero (with a recorded reason) otherwise.
function MonitorDumpProgress () {
    typeset -i deadline=$((SECONDS + cfgArr[quiesceWait]))
    typeset -i sampleStatus=0 statFailures=0 maxStatFailures=5
    typeset reason='no write progress was observed'
    while ((SECONDS < deadline)); do
        if ProgressSample; then return 0; else sampleStatus=$?; fi
        if ((sampleStatus != 2)); then
            statFailures=0
        elif ((++statFailures < maxStatFailures)); then
            Log "dump progress: virsh domstats transient failure (${statFailures}/${maxStatFailures}), retrying..."
        else
            RecordUnlessPodGone dump-completion 'dump progress' 'dump monitor skipped' 'disk statistics or progress evaluation failed/timed out'
            return 1
        fi
        sleep "${cfgArr[interval]}"
    done
    [[ "$(jq -r '.observedProgress // false' "${progressFile}" 2>/dev/null || echo false)" != true ]] || reason='write progress did not quiesce'
    RecordError dump-completion "${reason} before the wall-clock deadline"
    return 1
}
function StartDumpMonitor () {
    typeset -i sampleStatus=0
    if ProgressSample; then RecordError dump-completion 'unexpected completed state at baseline'; return 1; else sampleStatus=$?; fi
    ((sampleStatus == 1)) || { RecordError dump-completion 'cannot establish bounded pre-capture disk-write baseline'; return 1; }
    [[ -f "${progressFile}" ]] || { RecordError dump-completion 'cannot establish pre-capture disk-write baseline'; return 1; }
    StartProcess progress - MonitorDumpProgress
}
# WaitForEventLogs: wait (at most 10 min) until the guest System and Application event logs are non-empty and unchanged on two consecutive checks.
function WaitForEventLogs () {
    typeset -i deadline=$((SECONDS + 600)) stableCount=0
    typeset systemSize='' appSize=''
    Log 'waiting for Windows event logs to flush and stabilize...'
    while ((SECONDS < deadline)); do
        systemSize="$(EvtxSize System)"
        appSize="$(EvtxSize Application)"
        if [[ "${systemSize}" != '0' && "${appSize}" != '0' ]]; then
            sleep 5
            if [[ "${systemSize}" != "$(EvtxSize System)" || "${appSize}" != "$(EvtxSize Application)" ]]; then stableCount=0
            elif ((++stableCount >= 2)); then Log "event logs stable (System: ${systemSize} bytes, Application: ${appSize} bytes)"; break; fi
        fi
        sleep 3
    done
}
# CaptureCrashArtifacts DOMSTATE: at-crash evidence in the established order (crash-time domain XML, VNC settle wait, dump-progress baseline, screenshot,
#   best-effort memory dump, launcher diagnostics), then wait for the dump monitor and the guest event logs. A failed mandatory capture is fatal.
function CaptureCrashArtifacts () {
    typeset domState="${1:?}"
    typeset -i hasFailedCapture=0
    SetState capturing
    Log "corroborated crash/freeze detected (domstate=${domState})"
    Log "capturing domain-bsod.xml at crash time (state=${domState})..."
    if CaptureDomainXml; then
        Log "domain-bsod.xml captured at crash time ($(wc -c < "${outDir}/domain-bsod.xml") bytes)"
    else
        Log 'WARN: domain-bsod.xml crash-time capture failed — pre-crash copy (if any) will be used by CaptureHostSignals'
    fi
    Log 'waiting 60 seconds for VNC to become responsive...'
    sleep 60
    StartDumpMonitor || hasFailedCapture=1
    CaptureScreenshot || hasFailedCapture=1
    CaptureMemory || Log 'WARN: memory dump capture failed — recovery will extract from ODF snapshot'
    CaptureHostSignals || hasFailedCapture=1
    ((hasFailedCapture == 0)) || Fatal
    if ! WaitProcess progress; then
        Log 'WARN: dump progress monitor did not confirm completion — proceeding (captured artifact may still be valid)'
        RecordError dump-completion 'dump progress monitor failed; recovery will validate artifact integrity'
    fi
    WaitForEventLogs
    SetState captured
}

# ---- Recovery and crash response ----
# StopVM: `virtctl stop`, then wait (120 s) until the VMI is gone (or Succeeded/Failed) and the VM reports Stopped, as the offline extractor requires.
function StopVM () {
    typeset phase='' vmStatus=''
    typeset -i deadline=0
    Log 'requesting VMI stop through virtctl'
    RunTimed 90 virtctl stop "${cfgArr[vm]}" -n "${cfgArr[ns]}" >>"${pipelineLog}" 2>&1 || { RecordError stop 'virtctl stop failed or timed out'; return 1; }
    deadline=$((SECONDS + 120))
    while ((SECONDS < deadline)); do
        phase="$(oc --request-timeout=30s get vmi "${cfgArr[vm]}" -n "${cfgArr[ns]}" --ignore-not-found -o jsonpath='{.status.phase}' 2>>"${pipelineLog}")" ||
            { RecordError stop 'cannot verify VMI stop'; return 1; }
        if [[ -z "${phase}" || "${phase}" == Succeeded || "${phase}" == Failed ]]; then
            vmStatus="$(oc --request-timeout=30s get vm "${cfgArr[vm]}" -n "${cfgArr[ns]}" -o jsonpath='{.status.printableStatus}' 2>>"${pipelineLog}")" ||
                { RecordError stop 'cannot verify VM stop'; return 1; }
            [[ "${vmStatus}" == Stopped ]] && return 0
        fi
        sleep 3
    done
    RecordError stop "offline deadline exceeded (phase=${phase}, printableStatus=${vmStatus:-unknown})"
    return 1
}
# RecoverGuestOS: stop the VM (its disk must be offline before the read-only guestfs mount), then extract the guest OS crash information.
function RecoverGuestOS () {
    typeset recoveryBin="${scriptDir}/extract--guest-os--crash-info.sh"
    SetState recovering
    StopVM || return 1
    [[ -x "${recoveryBin}" ]] || { RecordError recovery "recovery script missing: ${recoveryBin}"; return 1; }
    "${recoveryBin}" --metadata "${cfgArr[metadataFile]}" >>"${pipelineLog}" 2>&1
}
# CrashResponse DOMSTATE: capturing -> captured -> recovering -> recovered | failed. A stop or extraction failure is fatal (summary written, exit 1);
#   otherwise the evidence-summary verdict is the exit status and decides the final state.
function CrashResponse () {
    typeset -i status=0
    CaptureCrashArtifacts "${1:?}"
    RecoverGuestOS || Fatal
    WriteSummary || status=$?
    if ((status == 0)); then SetState recovered; else SetState failed; fi
    return "${status}"
}

# ---- Entry point ----
# Main ARGS...: validate, prepare and arm, then wait for a crash and respond to it (EXIT/INT/TERM traps keep the cleanup and exit-status contracts).
function Main () {
    typeset domState=''
    trap Cleanup EXIT
    trap 'OnSignal 130' INT
    trap 'OnSignal 143' TERM
    ParseArgs "$@"
    ValidateConfig
    ValidateTools
    PrepareRun
    ArmWatcher
    WaitForCrash domState
    CrashResponse "${domState}"
}

[[ "${BASH_SOURCE[0]}" != "${0}" ]] || Main "$@"
true
