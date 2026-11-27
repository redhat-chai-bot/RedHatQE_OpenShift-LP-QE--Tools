#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit
umask 077
# Passive crash watcher for one Windows guest VM on OpenShift Virtualization. Phases (Main): preflight -> arm -> watch -> respond | expired.
#   preflight  Run preflight-rhov.sh into a new run directory, or accept the metadata it already wrote (--metadata, --run-id).
#   arm        Check the guest agent, start the pvpanic event watch and publish --ready-file.
#   watch      Ping the guest agent; after missed pings reliability.py decides whether the evidence shows a crash.
#   respond    Capture evidence, wait for the dump and the event logs, stop the VM and run the offline extractor.
#   expired    No crash before the armed timeout: record it, write the summary and exit 1.
# The VM is never restarted. Options: see ParseArgs (--help prints a short usage). Environment names and defaults: see cfgArr below.

typeset scriptDir=''; scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==== Settings and run state ====
# Settings; read-only once ValidateConfig has passed.
typeset -A cfgArr=(
    [ns]=''                         # --ns (required)
    [vm]=''                         # --vm (required)
    [out]=''                        # --out: the run directory with --metadata, else the default evidence mount (required)
    [metadata]=''                   # --metadata: metadata already written by preflight-rhov.sh (requires --run-id)
    [runId]=''                      # --run-id; generated when absent and preflight runs here
    [readyFile]=''                  # --ready-file: receives the run ID once armed
    [summaryMode]='natural-rhov'    # --intentional selects intentional-rhov
    [interval]=5                    # --interval: seconds between guest-agent pings and dump progress samples
    [miss]=2                        # --miss: missed pings before the crash decision
    [quiesceWait]=900               # --quiesce-wait: seconds to wait for crash dump writes to quiesce
    [idleSamples]=3                 # --idle-samples: idle disk samples that count as quiesced
    # Preflight inputs, used only when preflight runs here (no --metadata). Unset ones are not forwarded, so preflight-rhov.sh
    # applies its own default (named in parentheses).
    [evidenceMount]=''              # --evidence-mount, else BSOD_DET__EVIDENCE__MOUNT, else --out; always forwarded
    [evidenceKind]=''               # --evidence-volume-kind, else BSOD_DET__EVIDENCE__VOLUME_KIND, else legacy BSOD_EVIDENCE_VOLUME_KIND
    [evidenceId]=''                 # --evidence-storage-id (BSOD_DET__EVIDENCE__STORAGE_ID)
    [snapClass]=''                  # --snap-class (BSOD_DET__SNAPSHOT__CLASS)
    [recoveryImage]=''              # --recovery-image (BSOD_DET__RECOVERY__IMAGE)
    [memoryPvc]=''                  # --memory-dump-pvc (BSOD_DET__MEMORY__DUMP_PVC)
    [diskTarget]=''                 # --disk-target (discovered from the VMI and domain XML)
    # Timeout budgets in seconds: BSOD_DET__TIMEOUT__*, else the legacy name in parentheses, else the default.
    [armedTimeout]="${BSOD_DET__TIMEOUT__ARMED:-${BSOD_DET__ARMED__TIMEOUT:-}}"                 # (BSOD_DET__ARMED__TIMEOUT) required
    [preflightTimeout]="${BSOD_DET__TIMEOUT__PREFLIGHT:-${BSOD_DET__PREFLIGHT__TIMEOUT:-300}}"  # (BSOD_DET__PREFLIGHT__TIMEOUT)
    [captureTimeout]="${BSOD_DET__TIMEOUT__CAPTURE:-${BSOD_DET__CAPTURE__TIMEOUT:-300}}"        # (BSOD_DET__CAPTURE__TIMEOUT)
    [memoryTimeout]="${BSOD_DET__TIMEOUT__MEMORY:-${BSOD_MEMORY_CAPTURE_TIMEOUT:-1800}}"        # (BSOD_MEMORY_CAPTURE_TIMEOUT)
    # Helper override (tests); BSOD_DET__GUEST_AGENT__BIN likewise replaces guest-agent.py below.
    [hostSignalsBin]="${BSOD_DET__HOST_SIGNALS__BIN:-${scriptDir}/collect-host-signals.sh}"
)
typeset -a guestAgentArr=(python3 "${scriptDir}/guest-agent.py")
[[ -z "${BSOD_DET__GUEST_AGENT__BIN:-}" ]] || guestAgentArr=("${BSOD_DET__GUEST_AGENT__BIN}")

# Run state, set while the watcher runs.
typeset -A metaArr=()               # Validated preflight metadata fields.
typeset runId=''
typeset outDir=''                   # Run output directory (evidence).
typeset metadataFile=''
typeset stageErrors=''              # ${outDir}/stage-errors.jsonl
typeset pipelineLog=''              # ${outDir}/watcher.log
typeset runDir=''                   # Private temporary directory, removed on exit.
typeset pvpanicFile=''              # Output of the pvpanic event watch.
typeset progressFile=''             # State of the dump progress monitor.
typeset pvpanicPid=''               # Event watch (process group leader).
typeset progressPid=''              # Background dump progress monitor.
typeset -i isMemoryAssociated=0     # A KubeVirt memory dump is associated with the VM; removed on exit.
typeset createdExport=''            # VirtualMachineExport this run created, and the UID the API server assigned to it:
typeset createdExportUid=''         # the only export the run ever deletes (see DeleteCreatedExport).

# ==== Common helpers ====
function Die () { echo "bsod-watcher: ERROR: $*" >&2; exit 1; }
function RunTimed () { typeset seconds="${1:?}"; shift; timeout --signal=TERM --kill-after=5 "${seconds}" "$@"; }
function Log () { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "${pipelineLog}"; true; }
function RecordError () {
    typeset stage="${1:?}"; shift
    jq -cn --arg stage "${stage}" --arg error "$*" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{stage:$stage,error:$error,at:$at}' >> "${stageErrors}"
    Log "ERROR [${stage}]: $*"
}
function WriteSummary () {
    RunTimed 60 python3 "${scriptDir}/reliability.py" write-summary --out "${outDir}" --stage-errors "${stageErrors}" \
        --mode "${cfgArr[summaryMode]}" --vm "${cfgArr[vm]}" --namespace "${cfgArr[ns]}" --run-id "${runId}" --filename evidence-summary.json
}
function StopProgressMonitor () {
    [[ -n "${progressPid}" ]] || return 0
    kill "${progressPid}" 2>/dev/null || true; wait "${progressPid}" 2>/dev/null || true; progressPid=''
}
function StopEventWatch () {
    # The event watch runs under setsid, so signal its whole process group.
    [[ -n "${pvpanicPid}" ]] || return 0
    kill -- "-${pvpanicPid}" 2>/dev/null || true; wait "${pvpanicPid}" 2>/dev/null || true; pvpanicPid=''
}
function Fatal () {
    # Fatal [stage message...]: record the error (if given), write the summary and exit 1.
    StopProgressMonitor
    if (($#)); then RecordError "$@"; fi
    WriteSummary || true
    exit 1
}
function Cleanup () {
    StopProgressMonitor
    StopEventWatch
    DeleteCreatedExport 1>&2
    if ((isMemoryAssociated)) && [[ -n "${cfgArr[vm]}" && -n "${cfgArr[ns]}" ]]; then
        RunTimed 60 virtctl memory-dump remove "${cfgArr[vm]}" -n "${cfgArr[ns]}" >/dev/null 2>&1 || true
        isMemoryAssociated=0
    fi
    [[ -z "${runDir}" ]] || rm -rf "${runDir}"
    [[ -z "${outDir}" ]] || rm -f "${outDir}/.domain-bsod.xml.tmp"
    true
}
function OnSignal () {
    typeset status="${1:?}"
    [[ -z "${stageErrors}" ]] || RecordError interrupted "received signal; exiting with status ${status}"
    exit "${status}"
}

# ==== Arguments and configuration ====
function ParseArgs () {
    while (($#)); do
        case "${1}" in
          (--ns) cfgArr[ns]="${2:?}"; shift 2;;
          (--vm) cfgArr[vm]="${2:?}"; shift 2;;
          (--out) cfgArr[out]="${2:?}"; shift 2;;
          (--metadata) cfgArr[metadata]="${2:?}"; shift 2;;
          (--run-id) cfgArr[runId]="${2:?}"; shift 2;;
          (--ready-file) cfgArr[readyFile]="${2:?}"; shift 2;;
          (--evidence-mount) cfgArr[evidenceMount]="${2:?}"; shift 2;;
          (--evidence-volume-kind) cfgArr[evidenceKind]="${2:?}"; shift 2;;
          (--evidence-storage-id) cfgArr[evidenceId]="${2:?}"; shift 2;;
          (--interval) cfgArr[interval]="${2:?}"; shift 2;;
          (--miss) cfgArr[miss]="${2:?}"; shift 2;;
          (--quiesce-wait) cfgArr[quiesceWait]="${2:?}"; shift 2;;
          (--idle-samples) cfgArr[idleSamples]="${2:?}"; shift 2;;
          (--snap-class) cfgArr[snapClass]="${2:?}"; shift 2;;
          (--recovery-image) cfgArr[recoveryImage]="${2:?}"; shift 2;;
          (--memory-dump-pvc) cfgArr[memoryPvc]="${2:?}"; shift 2;;
          (--disk-target) cfgArr[diskTarget]="${2:?}"; shift 2;;
          (--intentional) cfgArr[summaryMode]='intentional-rhov'; shift;;
          (--no-restart)
            # Deprecated: still accepted because external callers such as bsod-pipeline/bsod-runner.sh pass it. The VM is never restarted.
            echo 'bsod-watcher: WARN: --no-restart is deprecated and has no effect; the watcher never restarts the VM' >&2
            shift;;
          (-h|--help)
            echo 'usage: bsod-watcher.sh --ns NS --vm VM --out EVIDENCE_MOUNT_OR_RUN_DIR [--metadata PREFLIGHT.json --run-id ID]' \
                '--evidence-mount MOUNT --evidence-volume-kind KIND --evidence-storage-id ID --snap-class CLASS' \
                '--recovery-image IMAGE@sha256:DIGEST --memory-dump-pvc PVC [options]'
            exit 0;;
          (*) Die "unknown argument: ${1}";;
        esac
    done
}
function ValidateTools () {
    typeset tool=''
    for tool in oc virtctl jq python3 setsid timeout; do
        command -v "${tool}" >/dev/null || Die "required local tool '${tool}' is not installed"
    done
    true
}
function ValidateConfig () {
    typeset key=''
    [[ -n "${cfgArr[ns]}" && -n "${cfgArr[vm]}" && -n "${cfgArr[out]}" ]] || Die '--ns, --vm, and --out are required'
    [[ -n "${cfgArr[armedTimeout]}" ]] ||
        Die 'BSOD_DET__TIMEOUT__ARMED (or legacy BSOD_DET__ARMED__TIMEOUT) must be set by the caller, e.g. bsod-runner.sh'
    # Counts and the budgets used in shell arithmetic must be plain positive integers; the preflight and capture budgets only
    # reach timeout(1), which also accepts suffixed durations.
    for key in interval miss quiesceWait idleSamples armedTimeout memoryTimeout; do
        [[ "${cfgArr[${key}]}" =~ ^[1-9][0-9]*$ ]] || Die 'all timeout/count values must be positive integers'
    done
    if [[ -n "${cfgArr[metadata]}" ]]; then
        [[ -r "${cfgArr[metadata]}" && -n "${cfgArr[runId]}" ]] || Die '--metadata requires a readable file and --run-id'
    fi
    true
}

# ==== Phase: preflight ====
function ReadMetadata () {
    # Reads the preflight metadata, which must hold exactly one JSON document, in one jq run whose exit status is checked. Fields
    # the watcher relies on must be non-empty single-line strings; .guestPvc (checked before recovery) is kept only if it is one;
    # .node is informational only and read as is. jq prints `ok`, one line per field and .guestPvc, the .node lines and `end`, or
    # why the metadata is invalid. Values are shaped as `$(jq -r ...)` returns them (NUL bytes dropped, trailing newlines removed).
    typeset -a keyArr=(runId outputDir namespace vm launcherPod domain diskTarget memoryDumpPvc) lineArr=()
    typeset output='' key=''
    typeset -i i=0
    output="$(jq -sr '
        def shell: if type == "string" then gsub("\u0000"; "") | until(endswith("\n") | not; .[:-1]) else . end;
        def valid: type == "string" and length > 0 and (shell | contains("\n") | not);
        if length != 1 then "documents \(length)"
        elif (.[0] | type) as $type | $type != "object" and $type != "null" then "field \($ARGS.positional[0])"
        else .[0] as $meta | ([$ARGS.positional[] | select($meta[.] | valid | not)] | first) as $invalid
            | if $invalid then "field \($invalid)"
              else "ok", ($ARGS.positional[] | $meta[.] | shell), ($meta.guestPvc | if valid then shell else "" end),
                  ($meta.node | shell), "end"
              end
        end' "${metadataFile}" --args "${keyArr[@]}")" || Die "cannot read preflight metadata ${metadataFile} as JSON"
    mapfile -t lineArr <<<"${output}"
    case "${lineArr[0]}" in
      (ok) ;;
      ('documents '*) Die "preflight metadata ${metadataFile} must hold exactly one JSON document (found ${lineArr[0]#documents })";;
      ('field '*) Die "missing or invalid \`.${lineArr[0]#field }\` in preflight metadata ${metadataFile}";;
      (*) Die "cannot read preflight metadata ${metadataFile} as JSON";;
    esac
    [[ ${#lineArr[@]} -ge $((${#keyArr[@]} + 4)) && "${lineArr[-1]}" == end ]] || Die "cannot read preflight metadata ${metadataFile} as JSON"
    for key in "${keyArr[@]}" guestPvc; do metaArr[${key}]="${lineArr[++i]}"; done
    printf -v 'metaArr[node]' '%s\n' "${lineArr[@]:i + 1:${#lineArr[@]} - i - 2}"; metaArr[node]="${metaArr[node]%$'\n'}"
}
function RunPreflight () {
    # Creates a new run directory under the evidence mount and runs preflight-rhov.sh into it.
    typeset evidenceMount="${cfgArr[evidenceMount]:-${BSOD_DET__EVIDENCE__MOUNT:-${cfgArr[out]}}}"
    typeset evidenceKind="${cfgArr[evidenceKind]:-${BSOD_DET__EVIDENCE__VOLUME_KIND:-${BSOD_EVIDENCE_VOLUME_KIND:-}}}"
    typeset option=''
    typeset -a argArr=()
    runId="${cfgArr[runId]:-$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM}}"
    outDir="$(realpath -m "${evidenceMount}")/${runId}"
    mkdir "${outDir}" || Die "cannot create unique run directory ${outDir}"
    metadataFile="${outDir}/recovery-metadata.json"
    argArr=(--ns "${cfgArr[ns]}" --vm "${cfgArr[vm]}" --out "${outDir}" --metadata "${metadataFile}" --run-id "${runId}"
        --evidence-mount "${evidenceMount}")
    # Each entry is OPTION=VALUE; options without a value are not forwarded (see the preflight inputs in cfgArr).
    for option in --evidence-volume-kind="${evidenceKind}" --evidence-storage-id="${cfgArr[evidenceId]}" \
        --snap-class="${cfgArr[snapClass]}" --recovery-image="${cfgArr[recoveryImage]}" \
        --memory-dump-pvc="${cfgArr[memoryPvc]}" --disk-target="${cfgArr[diskTarget]}"; do
        [[ -z "${option#*=}" ]] || argArr+=("${option%%=*}" "${option#*=}")
    done
    RunTimed "${cfgArr[preflightTimeout]}" "${scriptDir}/preflight-rhov.sh" "${argArr[@]}" || Die 'preflight failed or timed out'
}
function PrepareRun () {
    if [[ -n "${cfgArr[metadata]}" ]]; then
        metadataFile="${cfgArr[metadata]}"; runId="${cfgArr[runId]}"
        ReadMetadata
        [[ "$(realpath -m "${cfgArr[out]}")" == "${metaArr[outputDir]}" && "${metaArr[runId]}" == "${runId}" ]] ||
            Die 'preflight metadata does not identify this run output'
        outDir="${metaArr[outputDir]}"
    else
        RunPreflight
        ReadMetadata
    fi
    [[ "${metaArr[namespace]}" == "${cfgArr[ns]}" && "${metaArr[vm]}" == "${cfgArr[vm]}" ]] || Die 'metadata target does not match watcher target'
    # Consumed by guest-agent.py.
    export BSOD_DET__NAMESPACE="${cfgArr[ns]}" BSOD_DET__VM__NAME="${cfgArr[vm]}" \
        BSOD_DET__POD__NAME="${metaArr[launcherPod]}" BSOD_DET__DOMAIN__NAME="${metaArr[domain]}"
    mkdir -p "${outDir}"; chmod 0700 "${outDir}"
    stageErrors="${outDir}/stage-errors.jsonl"; : > "${stageErrors}"; chmod 0600 "${stageErrors}"
    pipelineLog="${outDir}/watcher.log"; : > "${pipelineLog}"; chmod 0600 "${pipelineLog}"
    runDir="$(mktemp -d "${TMPDIR:-/tmp}/bsod-watcher.XXXXXX")"
    pvpanicFile="${runDir}/pvpanic.current"
    progressFile="${runDir}/dump-progress.json"
}

# ==== Phase: arm ====
function Arm () {
    # Arming failures keep the stage name `preflight`: stage names are part of the evidence summary contract.
    Log "preflight passed; preparing watcher for ${cfgArr[ns]}/${cfgArr[vm]} (run=${runId}, disk=${metaArr[diskTarget]})"
    RunTimed 15 "${guestAgentArr[@]}" ping >/dev/null 2>&1 || Fatal preflight 'qemu guest agent became unavailable before arming'
    setsid timeout --signal=TERM --kill-after=5 "${cfgArr[armedTimeout]}" oc --request-timeout="${cfgArr[armedTimeout]}s" get events \
        -n "${cfgArr[ns]}" --watch-only --field-selector "reason=Panicked,involvedObject.name=${cfgArr[vm]}" -o name \
        >"${pvpanicFile}" 2>>"${pipelineLog}" &
    pvpanicPid=$!
    sleep 1; kill -0 "${pvpanicPid}" 2>/dev/null || Fatal preflight 'event watcher exited before arming'
    if [[ -n "${cfgArr[readyFile]}" ]]; then
        typeset readyTmp="${cfgArr[readyFile]}.tmp.$$"
        printf '%s\n' "${runId}" > "${readyTmp}"; chmod 0600 "${readyTmp}"; mv -f "${readyTmp}" "${cfgArr[readyFile]}"
    fi
    Log 'qemu guest agent and event watch healthy; watcher armed'
}

# ==== Phase: watch ====
# shellcheck disable=SC2034 # nextPhaseRef and crashStateRef are namerefs to the caller's variables.
function Watch () {
    # Sets the next phase (respond or expired) and, on respond, the domain state seen at the capture decision.
    typeset -n nextPhaseRef="${1:?}"; (($#)) && shift
    typeset -n crashStateRef="${1:?}"; (($#)) && shift
    typeset state='' vmiPhase='' decision=''
    typeset -i misses=0
    typeset -i deadline=$((SECONDS + cfgArr[armedTimeout]))
    typeset -a flagArr=()
    while ((SECONDS < deadline)); do
        if RunTimed 15 "${guestAgentArr[@]}" ping >/dev/null 2>&1; then misses=0; sleep "${cfgArr[interval]}"; continue; fi
        misses=$((misses + 1))
        state="$(oc --request-timeout=10s exec -n "${cfgArr[ns]}" "${metaArr[launcherPod]}" -- virsh domstate "${metaArr[domain]}" 2>/dev/null |
            tr -d '[:space:]' || printf unavailable)"
        Log "missed ping ${misses}/${cfgArr[miss]} (domstate=${state})"
        if ((misses >= cfgArr[miss])); then
            vmiPhase="$(oc --request-timeout=30s get vmi "${cfgArr[vm]}" -n "${cfgArr[ns]}" -o jsonpath='{.status.phase}' 2>/dev/null || printf unavailable)"
            flagArr=(--misses "${misses}" --threshold "${cfgArr[miss]}" --domstate "${state}" --vmi-phase "${vmiPhase}")
            [[ -s "${pvpanicFile}" ]] && flagArr+=(--pvpanic)
            oc --request-timeout=30s get pod "${metaArr[launcherPod]}" -n "${cfgArr[ns]}" >/dev/null 2>&1 && flagArr+=(--pod-present)
            decision="$(RunTimed 20 python3 "${scriptDir}/reliability.py" decision "${flagArr[@]}")" ||
                Fatal detection 'ambiguous or unavailable crash evidence'
            if [[ "$(jq -r .decision <<<"${decision}")" == capture ]]; then
                StopEventWatch
                crashStateRef="${state}"; nextPhaseRef='respond'
                return 0
            fi
        fi
        sleep "${cfgArr[interval]}"
    done
    nextPhaseRef='expired'
}

# ==== Phase: respond (evidence capture) ====
function IsPodTerminated () {
    typeset -n phaseRef="${1:?}"
    phaseRef="$(oc --request-timeout=30s get pod "${metaArr[launcherPod]}" -n "${cfgArr[ns]}" -o jsonpath='{.status.phase}' 2>/dev/null || echo 'Unknown')"
    [[ "${phaseRef}" == Failed || "${phaseRef}" == Succeeded ]]
}
function CaptureDomainXml () {
    # Captures the live domain XML into a temporary file in the same directory and atomically replaces domain-bsod.xml only with
    # a complete, non-empty capture: a failed attempt never truncates or removes a usable earlier copy.
    typeset target="${outDir}/domain-bsod.xml" temporary="${outDir}/.domain-bsod.xml.tmp"
    if oc --request-timeout=30s exec -n "${cfgArr[ns]}" "${metaArr[launcherPod]}" -- virsh dumpxml "${metaArr[domain]}" > "${temporary}" \
        2>>"${pipelineLog}" && [[ -s "${temporary}" ]] && mv -fT "${temporary}" "${target}"; then
        return 0
    fi
    rm -f "${temporary}"
    return 1
}
function CaptureScreenshot () {
    typeset temporary="${outDir}/.bsod-screenshot.tmp"
    typeset result='' format='' target=''
    rm -f "${temporary}"
    RunTimed "${cfgArr[captureTimeout]}" virtctl vnc screenshot "${cfgArr[vm]}" -n "${cfgArr[ns]}" --file="${temporary}" >>"${pipelineLog}" 2>&1 ||
        { RecordError screenshot 'virtctl vnc screenshot failed or timed out'; return 1; }
    if ! result="$(RunTimed 30 python3 "${scriptDir}/reliability.py" validate-artifact --type screenshot --path "${temporary}")"; then
        rm -f "${temporary}"; RecordError screenshot 'screenshot is structurally invalid'; return 1
    fi
    format="$(jq -r .format <<<"${result}")"; target="${outDir}/bsod-screenshot.${format}"; mv -f "${temporary}" "${target}"
    Log "validated screenshot: $(basename "${target}")"
}
function RequestMemoryDump () {
    # Asks KubeVirt to dump guest memory to the memory-dump PVC and waits until the request completes.
    typeset phase='' podPhase=''
    typeset -i deadline=0
    RunTimed 90 virtctl memory-dump get "${cfgArr[vm]}" -n "${cfgArr[ns]}" --claim-name="${metaArr[memoryDumpPvc]}" >>"${pipelineLog}" 2>&1 ||
        { RecordError memory 'KubeVirt memory-dump request failed or timed out'; return 1; }
    isMemoryAssociated=1
    deadline=$((SECONDS + cfgArr[memoryTimeout]))
    while ((SECONDS < deadline)); do
        phase="$(oc --request-timeout=30s get vm "${cfgArr[vm]}" -n "${cfgArr[ns]}" -o jsonpath='{.status.memoryDumpRequest.phase}' \
            2>>"${pipelineLog}" || true)"
        [[ "${phase}" == Completed ]] && return 0
        [[ "${phase}" == Failed ]] && { RecordError memory 'KubeVirt memory-dump API reported Failed'; return 1; }
        IsPodTerminated podPhase && { Log "memory dump: virt-launcher pod is ${podPhase} — memory dump cannot complete, skipping"; return 1; }
        sleep 3
    done
    RecordError memory "KubeVirt memory-dump phase timed out (last=${phase:-unset})"
    return 1
}
function DeleteCreatedExport () {
    # Deletes the VirtualMachineExport this run created, and nothing else: by its exact name, with its UID as a precondition, so
    # an export that replaced it under the same name is refused (409 Conflict) rather than deleted. KubeVirt makes the export the
    # controller owner of its exporter pod, service and token secret; background cascading deletion removes them. Output goes to
    # the caller's stdout/stderr. A failed delete keeps the identity for one more attempt at exit; the export's TTL is 12h.
    # No request is sent unless both path components are DNS-1123 names (URL-safe; never "/", "." or "..") and the complete
    # DeleteOptions with the UID precondition were serialized beforehand: a DELETE with an empty body deletes unconditionally.
    typeset deleteOptions=''
    [[ -n "${createdExport}" && -n "${createdExportUid}" ]] || return 0
    [[ "${cfgArr[ns]}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && "${createdExport}" =~ ^[a-z0-9]([-.a-z0-9]*[a-z0-9])?$ ]] ||
        { echo "bsod-watcher: WARN: not deleting VirtualMachineExport '${createdExport}': invalid namespace or name"; return 0; }
    deleteOptions="$(jq -cn --arg uid "${createdExportUid}" \
        '{kind:"DeleteOptions",apiVersion:"v1",propagationPolicy:"Background",preconditions:{uid:$uid}}')" || return 0
    [[ "${deleteOptions}" == *"\"preconditions\":{\"uid\":\"${createdExportUid}\"}"* ]] || return 0
    oc --request-timeout=30s delete -f - --raw "/apis/export.kubevirt.io/v1beta1/namespaces/${cfgArr[ns]}/virtualmachineexports/${createdExport}" \
        <<<"${deleteOptions}" >/dev/null || return 0
    echo "deleted VirtualMachineExport ${createdExport} (uid ${createdExportUid})"
    createdExport=''; createdExportUid=''
}
function WaitForExportReady () {
    typeset exportName="${1:?}"
    typeset exportPhase=''
    typeset -i deadline=$((SECONDS + 300))
    while ((SECONDS < deadline)); do
        exportPhase="$(oc --request-timeout=30s get virtualmachineexport "${exportName}" -n "${cfgArr[ns]}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        [[ "${exportPhase}" == Ready ]] && return 0
        sleep 5
    done
    return 1
}
function DownloadMemoryDump () {
    # Exports the memory-dump PVC through a VirtualMachineExport created by this run and downloads it to the given file.
    typeset target="${1:?}"
    typeset exportName="bsod-memdump-${runId,,}"; exportName="${exportName:0:63}"; exportName="${exportName%-}"
    typeset -i downloadPid=0 downloadStatus=0
    # `create`, not `apply`: an export of that name that already exists is not this run's, so it is neither changed nor deleted.
    # Only a successful create returns the UID that DeleteCreatedExport requires.
    createdExport="${exportName}"
    createdExportUid="$(jq -n --arg name "${exportName}" --arg ns "${cfgArr[ns]}" --arg pvc "${metaArr[memoryDumpPvc]}" \
        '{apiVersion:"export.kubevirt.io/v1beta1",kind:"VirtualMachineExport",metadata:{name:$name,namespace:$ns},
          spec:{source:{apiGroup:"",kind:"PersistentVolumeClaim",name:$pvc},ttlDuration:"12h"}}' |
        oc --request-timeout=30s create -f - -o jsonpath='{.metadata.uid}' 2>>"${pipelineLog}")" || createdExportUid=''
    if [[ -z "${createdExportUid}" ]]; then
        createdExport=''
        RecordError memory "VirtualMachineExport ${exportName} could not be created (see watcher.log)"
        return 1
    fi
    echo "created VirtualMachineExport ${exportName} (uid ${createdExportUid})" >>"${pipelineLog}"
    if ! WaitForExportReady "${exportName}"; then
        RecordError memory 'VirtualMachineExport did not become ready'
        DeleteCreatedExport >>"${pipelineLog}" 2>&1
        return 1
    fi
    Log 'downloading memory dump via virtctl vmexport (unlimited, no hard timeout)...'
    virtctl vmexport download "${exportName}" -n "${cfgArr[ns]}" --output "${target}" --format gzip --insecure --keep-vme >>"${pipelineLog}" 2>&1 &
    downloadPid=$!
    while kill -0 "${downloadPid}" 2>/dev/null; do
        sleep 30
        [[ -f "${target}" ]] && Log "download progress: $(numfmt --to=iec-i --suffix=B "$(stat -c%s "${target}" 2>/dev/null || echo 0)" 2>/dev/null)"
    done
    wait "${downloadPid}" 2>/dev/null || downloadStatus=$?
    DeleteCreatedExport >>"${pipelineLog}" 2>&1
    ((downloadStatus == 0)) || { RecordError memory 'virtctl vmexport download failed'; return 1; }
}
function CaptureMemory () {
    typeset temporary="${outDir}/.vm-memory.elf.tmp"
    typeset target="${outDir}/vm-memory.elf.tar.gz"
    rm -f "${temporary}"
    RequestMemoryDump || return 1
    DownloadMemoryDump "${temporary}" || return 1
    if ! RunTimed 60 python3 "${scriptDir}/reliability.py" validate-artifact --type memory --path "${temporary}" >/dev/null; then
        rm -f "${temporary}"; RecordError memory 'downloaded memory dump is not a structurally valid ELF file'; return 1
    fi
    mv -f "${temporary}" "${target}"
    RunTimed 60 virtctl memory-dump remove "${cfgArr[vm]}" -n "${cfgArr[ns]}" >>"${pipelineLog}" 2>&1 ||
        { RecordError memory 'memory-dump association cleanup failed'; return 1; }
    isMemoryAssociated=0; Log "validated KubeVirt memory dump: $(basename "${target}")"
}
function CaptureHostSignals () {
    typeset domainXml="${outDir}/domain-bsod.xml"
    typeset launcherLog="${outDir}/launcher-compute.log"
    typeset podPhase=''
    typeset -i capturedCount=0 isPodDead=0
    IsPodTerminated podPhase && isPodDead=1
    if [[ -s "${domainXml}" ]]; then
        Log "host-signals: domain-bsod.xml already pre-captured ($(wc -c < "${domainXml}") bytes) — skipping re-capture"
        capturedCount=$((capturedCount + 1))
    elif CaptureDomainXml; then
        capturedCount=$((capturedCount + 1))
    elif ((isPodDead)); then
        Log "host-signals: virt-launcher pod is ${podPhase} — domain XML not available (expected)"
    else
        RecordError host-signals 'domain XML capture failed'
    fi
    if oc --request-timeout=30s logs -n "${cfgArr[ns]}" "${metaArr[launcherPod]}" -c compute > "${launcherLog}" 2>>"${pipelineLog}" &&
        [[ -s "${launcherLog}" ]]; then
        capturedCount=$((capturedCount + 1))
    else
        rm -f "${launcherLog}"
        if ((isPodDead)); then Log "host-signals: virt-launcher pod is ${podPhase} — launcher log not available (expected)"
        else RecordError host-signals 'launcher log capture failed'; fi
    fi
    ((capturedCount == 2)) || return 1
    RunTimed 60 "${cfgArr[hostSignalsBin]}" --vm "${metaArr[domain]}" --log-file "${launcherLog}" --domain-xml "${domainXml}" \
        > "${outDir}/host-signals.json" 2>>"${pipelineLog}" || { RecordError host-signals 'host-signal parser failed'; return 1; }
    Log "captured launcher/domain diagnostics for node ${metaArr[node]:-unknown}"
}
function CaptureCrashEvidence () {
    typeset state="${1:?}"
    typeset -i hasFailed=0
    Log "capturing domain-bsod.xml at crash time (state=${state})..."
    if CaptureDomainXml; then
        Log "domain-bsod.xml captured at crash time ($(wc -c < "${outDir}/domain-bsod.xml") bytes)"
    else
        Log 'WARN: domain-bsod.xml crash-time capture failed — an earlier copy is kept; without one, CaptureHostSignals retries once'
    fi
    Log 'waiting 60 seconds for VNC to become responsive...'
    sleep 60
    StartDumpMonitor || hasFailed=1
    CaptureScreenshot || hasFailed=1
    CaptureMemory || Log 'WARN: memory dump capture failed — offline recovery still copies pagefile.sys from the guest disk PVC (no snapshot)'
    CaptureHostSignals || hasFailed=1
    ((hasFailed == 0)) || Fatal
}

# ==== Phase: respond (crash dump progress monitor) ====
function ProgressSample () {
    # Returns 0 when writes have quiesced, 1 while still in progress, 2 when statistics are unavailable.
    typeset raw='' decision=''
    raw="$(oc --request-timeout=30s exec -n "${cfgArr[ns]}" "${metaArr[launcherPod]}" -- virsh domstats --block "${metaArr[domain]}" \
        2>>"${pipelineLog}")" || return 2
    decision="$(printf '%s\n' "${raw}" | RunTimed 20 python3 "${scriptDir}/reliability.py" progress-step --device "${metaArr[diskTarget]}" \
        --state "${progressFile}" --idle-samples "${cfgArr[idleSamples]}")" || return 2
    Log "dump progress: $(jq -r '"\(.status) (\(.reason), writes=\(.writeBytes))"' <<<"${decision}")"
    [[ "$(jq -r .status <<<"${decision}")" == complete ]]
}
function MonitorDumpProgress () {
    typeset -i deadline=$((SECONDS + cfgArr[quiesceWait]))
    typeset -i sampleStatus=0 statFailures=0 maxStatFailures=5
    typeset podPhase=''
    while ((SECONDS < deadline)); do
        if ProgressSample; then return 0; else sampleStatus=$?; fi
        if ((sampleStatus != 2)); then
            statFailures=0
        elif ((++statFailures < maxStatFailures)); then
            Log "dump progress: virsh domstats transient failure (${statFailures}/${maxStatFailures}), retrying..."
        else
            if IsPodTerminated podPhase; then Log "dump progress: virt-launcher pod is ${podPhase} — dump monitor skipped (expected)"
            else RecordError dump-completion 'disk statistics or progress evaluation failed/timed out'; fi
            return 1
        fi
        sleep "${cfgArr[interval]}"
    done
    if [[ "$(jq -r '.observedProgress // false' "${progressFile}" 2>/dev/null || echo false)" == true ]]; then
        RecordError dump-completion 'write progress did not quiesce before the wall-clock deadline'
    else
        RecordError dump-completion 'no write progress was observed before the wall-clock deadline'
    fi
    return 1
}
function StartDumpMonitor () {
    typeset -i sampleStatus=0
    if ProgressSample; then RecordError dump-completion 'unexpected completed state at baseline'; return 1; else sampleStatus=$?; fi
    ((sampleStatus == 1)) || { RecordError dump-completion 'cannot establish bounded pre-capture disk-write baseline'; return 1; }
    [[ -f "${progressFile}" ]] || { RecordError dump-completion 'cannot establish pre-capture disk-write baseline'; return 1; }
    MonitorDumpProgress & progressPid=$!
}
function WaitForDumpMonitor () {
    typeset -i monitorStatus=0
    wait "${progressPid}" || monitorStatus=$?
    progressPid=''
    if ((monitorStatus != 0)); then
        Log 'WARN: dump progress monitor did not confirm completion — proceeding (captured artifact may still be valid)'
        RecordError dump-completion 'dump progress monitor failed; recovery will validate artifact integrity'
    fi
}

# ==== Phase: respond (event logs, stop and recovery) ====
# shellcheck disable=SC2034 # resultRef is a nameref to the caller's variable.
function EvtxSizes () {
    # EvtxSizes SECONDS KILL_GRACE RESULT_VAR: one probe reads the System.evtx and Application.evtx lengths; timeout(1) sends TERM
    # after SECONDS and KILL after KILL_GRACE more. Valid only when the probe succeeds and prints exactly two positive integers:
    # then RESULT_VAR is `SYSTEM_BYTES APPLICATION_BYTES`; otherwise returns 1 with the reason in RESULT_VAR. Transport, as before:
    # oc exec of powershell.exe in the virt-launcher pod (where this script also runs virsh), not in the Windows guest.
    typeset -i seconds="${1:?}"; (($#)) && shift
    typeset -i killGrace="${1:?}"; (($#)) && shift
    typeset -n resultRef="${1:?}"; (($#)) && shift
    typeset logDir='C:\Windows\System32\winevt\Logs' psCommand='' output=''
    typeset -i probeStatus=0
    resultRef='no time left for a bounded probe'
    ((seconds > 0 && killGrace > 0)) || return 1
    psCommand="'{0} {1}' -f (Get-Item -LiteralPath '${logDir}\System.evtx' -ErrorAction Stop).Length,"
    psCommand+=" (Get-Item -LiteralPath '${logDir}\Application.evtx' -ErrorAction Stop).Length"
    output="$(timeout --signal=TERM --kill-after="${killGrace}" "${seconds}" oc --request-timeout="${seconds}s" exec -n "${cfgArr[ns]}" \
        "${metaArr[launcherPod]}" -- powershell.exe -NoProfile -Command "${psCommand}" 2>>"${pipelineLog}")" ||
        { probeStatus=$?; resultRef="size probe failed or timed out (exit ${probeStatus})"; return 1; }
    resultRef='size probe did not print two positive integer lengths'
    [[ "${output}" =~ ^[[:space:]]*([1-9][0-9]*)[[:space:]]+([1-9][0-9]*)[[:space:]]*$ ]] || return 1
    resultRef="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
    return 0
}
function WaitForEventLogs () {
    # Best effort; always returns 0, so the response continues with StopVMAndRecover. Within a 600s budget, samples both event log
    # sizes (EvtxSizes) nominally every 5s until they stay unchanged for a quiet window of over 10s: a valid sample equal to the
    # baseline whose probe starts more than 10 whole SECONDS after the probe that set the baseline ended (so over 10s of real time;
    # probe time never counts as quiet time). Each changed sample becomes the new baseline; a failed or invalid sample discards it
    # (consecutive identical failures are logged once). Every probe, including its kill grace, and every pause is clamped to the
    # time left. Unchanged sizes are only a heuristic: they do not prove that Windows has flushed the logs.
    typeset -i budget=600 quietWindow=10 pollInterval=5 probeCap=30 killGrace=5
    typeset -i deadline=$((SECONDS + budget)) left=0 probeSeconds=0 probeStart=0 baselineAt=0 pause=0 validCount=0 invalidCount=0
    typeset sample='' baseline='' lastFailure=''
    Log "waiting up to ${budget}s for the Windows event log sizes to stay unchanged for over ${quietWindow}s (best effort)..."
    while true; do
        left=$((deadline - SECONDS)); ((left > killGrace)) || break
        probeSeconds=$((left - killGrace)); ((probeSeconds <= probeCap)) || probeSeconds="${probeCap}"
        probeStart="${SECONDS}"
        if EvtxSizes "${probeSeconds}" "${killGrace}" sample; then
            validCount=$((validCount + 1)); lastFailure=''
            if [[ "${sample}" != "${baseline}" ]]; then
                Log "event logs: ${baseline:+sizes changed; }new baseline System ${sample% *} bytes, Application ${sample#* } bytes"
                baseline="${sample}"; baselineAt="${SECONDS}"
            elif ((probeStart - baselineAt > quietWindow)); then
                Log "event log sizes unchanged for over ${quietWindow}s (System: ${sample% *} bytes, Application: ${sample#* } bytes)" \
                    '— not proof that the logs were flushed'
                return 0
            fi
        else
            invalidCount=$((invalidCount + 1)); baseline=''
            [[ "${sample}" == "${lastFailure}" ]] || Log "event logs: invalid sample — ${sample}"
            lastFailure="${sample}"
        fi
        pause=$((probeStart + pollInterval - SECONDS)); left=$((deadline - SECONDS))
        ((pause <= left)) || pause="${left}"
        ((pause <= 0)) || sleep "${pause}"
    done
    if ((validCount == 0)); then
        Log "WARN: no valid event log size sample within ${budget}s (${invalidCount} failed or invalid; last: ${lastFailure:-none})" \
            '— proceeding to stop the VM'
    else
        Log "WARN: event log sizes did not stay unchanged for over ${quietWindow}s within ${budget}s (${validCount} valid," \
            "${invalidCount} failed or invalid samples) — proceeding to stop the VM"
    fi
    true
}
function ReleaseProbe () {
    # ReleaseProbe DEADLINE oc-get-args...: `oc get` in the VM namespace within the time left before DEADLINE (a SECONDS value);
    # returns 124 without a request when no time is left.
    typeset -i left=$((${1:?} - SECONDS)); shift
    ((left > 0)) || return 124
    RunTimed "${left}" oc --request-timeout="${left}s" get "$@" -n "${cfgArr[ns]}" 2>>"${pipelineLog}"
}
function StopVMAndRecover () {
    # Stops the VM (never restarted), runs the offline guest OS crash extraction and writes the evidence summary. The extraction
    # requires the VM to report Stopped; its helper (virtctl guestfs) mounts the guest disk PVC directly and refuses it while any
    # pod still references it. So within one 120s budget, which also bounds every probe and pause, the extraction waits until the
    # VM reports Stopped (KubeVirt reports that also while a final VMI still exists), the exact-name virt-launcher pod no longer
    # exists, and the guest PVC is Bound and not being deleted. A failed or timed-out probe is never taken as proof. These are
    # readiness checks, not a storage lock: the helper's own in-use check (a pod list) remains the final gate.
    typeset recoveryBin="${scriptDir}/extract--guest-os--crash-info.sh"
    typeset vmStatus='' podRef='' pvcState='' pending=''
    typeset -i deadline=0 pause=0
    Log 'requesting VMI stop through virtctl'
    RunTimed 90 virtctl stop "${cfgArr[vm]}" -n "${cfgArr[ns]}" >>"${pipelineLog}" 2>&1 || Fatal stop 'virtctl stop failed or timed out'
    deadline=$((SECONDS + 120))
    while true; do
        ((SECONDS < deadline)) || Fatal stop "VM stop and recovery readiness not confirmed within 120s (${pending})"
        vmStatus="$(ReleaseProbe "${deadline}" vm "${cfgArr[vm]}" -o jsonpath='{.status.printableStatus}')" ||
            Fatal stop 'cannot verify within 120s that the VM stopped'
        pending="VM status ${vmStatus:-unset}"
        if [[ "${vmStatus}" == Stopped ]]; then
            podRef="$(ReleaseProbe "${deadline}" pod "${metaArr[launcherPod]}" --ignore-not-found -o name)" ||
                Fatal stop 'cannot verify within 120s that the virt-launcher pod is gone'
            pending="${podRef} still exists"
            if [[ -z "${podRef}" ]]; then
                [[ -n "${metaArr[guestPvc]:-}" ]] || Fatal recovery 'preflight metadata has no .guestPvc; cannot verify the guest PVC'
                pvcState="$(ReleaseProbe "${deadline}" pvc "${metaArr[guestPvc]}" -o jsonpath='{.status.phase}{"/"}{.metadata.deletionTimestamp}')" ||
                    Fatal stop 'cannot verify the guest PVC within 120s'
                [[ "${pvcState}" == Bound/ ]] && break
                pending="guest PVC ${metaArr[guestPvc]} is ${pvcState}"
            fi
        fi
        pause=$((deadline - SECONDS)); ((pause <= 3)) || pause=3
        ((pause <= 0)) || sleep "${pause}"
    done
    ((SECONDS <= deadline)) || Fatal stop 'VM stop and recovery readiness confirmed only after the 120s deadline'
    Log "VM stopped, virt-launcher pod gone, guest PVC ${metaArr[guestPvc]} Bound; starting the offline extraction"
    [[ -x "${recoveryBin}" ]] || Fatal recovery "recovery script missing: ${recoveryBin}"
    "${recoveryBin}" --metadata "${metadataFile}" >>"${pipelineLog}" 2>&1 || Fatal
    Log 'waiting for recovery artifacts to stabilize...'
    sleep 10
    WriteSummary
}

# ==== Phase: respond (sequence) ====
function CrashResponse () {
    typeset state="${1:?}"
    Log "corroborated crash/freeze detected (domstate=${state})"
    CaptureCrashEvidence "${state}"
    WaitForDumpMonitor
    WaitForEventLogs
    StopVMAndRecover
}

# ==== Main ====
function Main () {
    typeset phase='preflight' crashState=''
    ParseArgs "$@"
    ValidateTools
    ValidateConfig
    readonly cfgArr
    while true; do
        case "${phase}" in
          (preflight) PrepareRun; phase='arm';;
          (arm) Arm; phase='watch';;
          (watch) Watch phase crashState;;
          (respond) CrashResponse "${crashState}"; return;;
          (expired) Fatal detection "armed observation phase exceeded ${cfgArr[armedTimeout]}s without a crash";;
        esac
    done
}

trap Cleanup EXIT
trap 'OnSignal 130' INT
trap 'OnSignal 143' TERM
Main "$@"

true