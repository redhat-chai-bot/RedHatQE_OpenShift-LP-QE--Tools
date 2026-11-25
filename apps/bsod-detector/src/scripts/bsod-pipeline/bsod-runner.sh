#!/usr/bin/env bash
# Disposable-VM RHOV BSOD pipeline: preflight, arm the watcher, optionally crash with NotMyFault, verify the evidence.
typeset useMsg=''; read -rd '' useMsg 0<<'useMsg-EOF'
RHOV BSOD pipeline for an explicitly disposable test VM:
preflight -> [intentional: check NotMyFault, clear old dumps] -> watcher armed -> [intentional: inject] -> offline extraction.
The watcher runs with `--no-restart`, so a successful run leaves the VM Stopped. This script never starts it.

Usage:
    bsod-runner.sh --mode intentional <crashType>
    bsod-runner.sh --mode watch

Where:
    --mode      intentional  Crash the VM on purpose with NotMyFault <crashType>. Preflight runs with
                             --require-trigger and fails unless NotMyFault is on the guest after its
                             configure-dumps.ps1 step. This script never copies NotMyFault itself.
                watch        Wait for a natural crash. NotMyFault is not required or run and existing
                             guest crash dumps are not deleted.
                Prompted for when omitted on a terminal. Required otherwise.
    crashType   NotMyFault crash type, 0x01 - 0x09. Intentional mode only, no default.

Environment:
    BSOD_DET__NAMESPACE, BSOD_DET__VM__NAME  Target VM (required).
    BSOD_DET__RECOVERY__IMAGE                Recovery image (required, no default). The watcher gets it with any
                                             @sha256 digest pin dropped; preflight-rhov.sh is not passed it and
                                             reads this variable itself if it needs it.
    BSOD_DET__CONFIRM_TARGET                 Must equal BSOD_DET__VM__NAME (intentional mode only).
    BSOD_DET__EVIDENCE__DIR                  Evidence mount (default: /mnt/persistent-bsod-evidence).
    BSOD_EVIDENCE_VOLUME_KIND, BSOD_DET__EVIDENCE__STORAGE_ID, BSOD_DET__MEMORY__DUMP_PVC,
    BSOD_DET__SNAPSHOT__CLASS, BSOD_DET__GUEST_AGENT__BIN (default: python3 ../host/guest-agent.py),
    BSOD_DET__READY__TIMEOUT (300), BSOD_DET__PREFLIGHT__TIMEOUT (1800)  Optional overrides.
    The required watcher ../host/watch-crash.sh keeps its own settings (e.g. BSOD_DET__ARMED__TIMEOUT, default 3600).
useMsg-EOF
set -euxo pipefail; shopt -s inherit_errexit
umask 077

typeset scrDir=''; scrDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset scrName="${BASH_SOURCE[0]##*/}"
typeset hostDir="${scrDir}/../host"
typeset watcherBin="${hostDir}/watch-crash.sh" nmfGuest='C:\Temp\nmf\notmyfaultc64.exe'
# Settings from the command line and the environment (see the usage text); read-only once Main has validated them.
typeset -A cfgArr=(
    [mode]='' [crashType]=''
    [vm]="${BSOD_DET__VM__NAME:-}" [ns]="${BSOD_DET__NAMESPACE:-}"
    [evidenceRoot]="${BSOD_DET__EVIDENCE__DIR:-/mnt/persistent-bsod-evidence}"
    [evidenceKind]="${BSOD_EVIDENCE_VOLUME_KIND:-pvc}" [evidenceID]="${BSOD_DET__EVIDENCE__STORAGE_ID:-shared-bsod-evidence}"
    [memoryPVC]="${BSOD_DET__MEMORY__DUMP_PVC:-${BSOD_DET__VM__NAME:-}-memdump}"
    [snapClass]="${BSOD_DET__SNAPSHOT__CLASS:-ocs-storagecluster-rbdplugin-snapclass}"
    [recoveryImage]="${BSOD_DET__RECOVERY__IMAGE:-}"
    [readyTimeout]="${BSOD_DET__READY__TIMEOUT:-300}" [preflightTimeout]="${BSOD_DET__PREFLIGHT__TIMEOUT:-1800}"
)
# Only the watcher gets this copy, without any @sha256 pin; preflight reads BSOD_DET__RECOVERY__IMAGE itself if needed.
cfgArr[recoveryImage]="${cfgArr[recoveryImage]%%@*}"
typeset -a guestAgentArr=(python3 "${hostDir}/guest-agent.py")
[ -z "${BSOD_DET__GUEST_AGENT__BIN:-}" ] || guestAgentArr=("${BSOD_DET__GUEST_AGENT__BIN}")
# Run state, set by RunPreflight (run identity), ReadMetadata (typed metadata) and ArmWatcher.
typeset runID='' outDir='' metadataFile='' readyFile='' watcherPID=''
typeset -a commonArgArr=()
typeset -A metaArr=()

# `set +x` keeps xtrace from printing the usage text a second time.
function Usage () { set +x; echo "${scrName%.sh}: ${1:?}" 1>&2; echo "${useMsg}" 1>&2; exit 2; }
function Die () { echo "${scrName%.sh}: ERROR: ${1:?}" 1>&2; exit "${2:-1}"; }
function RunTimed () { typeset sec="${1:?}"; shift; timeout --signal=TERM --kill-after=5 "${sec}" "$@"; return "$?"; }
function GuestPS () { typeset sec="${1:?}"; shift; RunTimed "${sec}" "${guestAgentArr[@]}" exec powershell.exe -NoProfile -Command "$@"; return "$?"; }
# Stops a still-running watcher (it removes only its own temporary state). Never deletes evidence.
function Cleanup () {
    [ -z "${watcherPID}" ] || { kill "${watcherPID}" || true; wait "${watcherPID}" || true; }
    true
}
function ParseArgs () {
    while (($#)); do
        case "${1}" in
          (--mode)      (($# >= 2)) || Usage '--mode needs a value'; cfgArr[mode]="${2}"; shift 2;;
          (-h|--help)   set +x; echo "${useMsg}"; exit 0;;
          (-*)          Usage "unknown option: ${1}";;
          (*)           [ -z "${cfgArr[crashType]}" ] || Usage "unexpected argument: ${1}"
                        cfgArr[crashType]="${1}"; shift;;
        esac
    done
    true
}
# Resolves the mode and crash type (prompting only on a terminal) and checks every input before anything is created.
function ValidateConfig () {
    # Ask only on a terminal. A non-interactive caller must choose, so nothing is ever injected by default.
    [ -n "${cfgArr[mode]}" ] || ! [ -t 0 ] || read -rp 'Mode (intentional|watch): ' 'cfgArr[mode]' || true
    case "${cfgArr[mode]}" in
      (intentional)
        [ -n "${cfgArr[crashType]}" ] || ! [ -t 0 ] || read -rp 'NotMyFault crash type (0x01 - 0x09): ' 'cfgArr[crashType]' || true
        case "${cfgArr[crashType]}" in
          (0x0[1-9]) ;;
          ('') Usage 'a crash type is required with --mode intentional (no default: it crashes the VM)';;
          (*)  Usage "unsupported NotMyFault crash type '${cfgArr[crashType]}' (supported: 0x01 - 0x09)";;
        esac
        ;;
      (watch) [ -z "${cfgArr[crashType]}" ] || Usage 'a crash type is only valid with --mode intentional';;
      ('')    Usage '--mode intentional|watch is required';;
      (*)     Usage "unsupported mode '${cfgArr[mode]}' (supported: intentional, watch)";;
    esac
    [[ -n "${cfgArr[vm]}" && -n "${cfgArr[ns]}" ]] || Die 'BSOD_DET__VM__NAME and BSOD_DET__NAMESPACE must identify the disposable RHOV test VM'
    [[ "${cfgArr[readyTimeout]}" =~ ^[1-9][0-9]*$ && "${cfgArr[preflightTimeout]}" =~ ^[1-9][0-9]*$ ]] ||
        Die 'BSOD_DET__READY__TIMEOUT and BSOD_DET__PREFLIGHT__TIMEOUT must be positive integers'
    # There is no default image.
    [ -n "${cfgArr[recoveryImage]}" ] || Die "BSOD_DET__RECOVERY__IMAGE must name the recovery image, got: '${BSOD_DET__RECOVERY__IMAGE:-<unset>}'"
    # The target location is not authorization: the operator must name the VM again.
    [ "${cfgArr[mode]}" = watch ] || [ "${BSOD_DET__CONFIRM_TARGET:-}" = "${cfgArr[vm]}" ] ||
        Die "BSOD_DET__CONFIRM_TARGET must be set to '${cfgArr[vm]}' to authorize crashing this VM (got: '${BSOD_DET__CONFIRM_TARGET:-<unset>}')"
    # The watcher starts only after preflight, the domain patch and the guest dump cleanup: check it before any of them.
    [[ -f "${watcherBin}" && -r "${watcherBin}" ]] || Die "required watcher ${watcherBin} is missing or not a readable file"
    true
}
# The tools this script runs in both modes; checked after the usage gates (exit 2) and before anything is created.
function ValidateTools () {
    typeset tool=''
    for tool in bash jq oc timeout; do command -v "${tool}" 1> /dev/null || Die "required local tool '${tool}' is not installed"; done
    true
}

# preflight (phase functions run in the order Main sets): create the unique run directory and run preflight into it.
function RunPreflight () {
    runID="$(date -u +%Y%m%dT%H%M%SZ)-${cfgArr[mode]}-$$-${RANDOM}"
    outDir="${cfgArr[evidenceRoot]}/${runID}"
    metadataFile="${outDir}/recovery-metadata.json" readyFile="${outDir}/watcher-ready"
    commonArgArr=(
        --ns "${cfgArr[ns]}" --vm "${cfgArr[vm]}" --out "${outDir}" --metadata "${metadataFile}" --run-id "${runID}"
        --evidence-mount "${cfgArr[evidenceRoot]}" --evidence-volume-kind "${cfgArr[evidenceKind]}"
        --evidence-storage-id "${cfgArr[evidenceID]}" --snap-class "${cfgArr[snapClass]}" --memory-dump-pvc "${cfgArr[memoryPVC]}"
    )
    mkdir "${outDir}" || Die "cannot create unique run directory ${outDir}"
    # Only an intentional run passes --require-trigger, so preflight fails unless NotMyFault is on the guest.
    typeset -a argArr=("${commonArgArr[@]}")
    [ "${cfgArr[mode]}" = watch ] || argArr+=(--require-trigger)
    RunTimed "${cfgArr[preflightTimeout]}" "${hostDir}/preflight-rhov.sh" "${argArr[@]}" ||
        Die "preflight failed or timed out (status $?); inspect ${outDir}" "$?"
    true
}
# preflight: the launcher Pod and domain in the preflight metadata must be non-empty strings.
function ReadMetadata () {
    typeset key=''
    for key in launcherPod domain; do
        metaArr["${key}"]="$(jq -er --arg key "${key}" '.[$key] | select((type == "string") and (length > 0))' "${metadataFile}")" ||
            Die "preflight metadata ${metadataFile} has no ${key}"
    done
    export BSOD_DET__POD__NAME="${metaArr[launcherPod]}" BSOD_DET__DOMAIN__NAME="${metaArr[domain]}"
    true
}
# prepare, best effort: hot-add pvpanic so the BSOD is reported to QEMU instead of a hard reset, and persist
# on_crash=preserve (effective only if KubeVirt keeps that definition).
function PatchDomain () {
    # shellcheck disable=SC2016 # Expanded by the launcher Pod shell.
    RunTimed 30 oc --request-timeout=25s -n "${cfgArr[ns]}" exec "${metaArr[launcherPod]}" -- bash -o pipefail -O inherit_errexit -euxc '
        typeset dom="${1:?}"; (($#)) && shift
        typeset -i es=0
        virsh qemu-monitor-command "${dom}" --hmp "device_add pvpanic-pci,id=pvpanic0" || es=1
        { virsh dumpxml "${dom}" | sed "s|<on_crash>.*</on_crash>|<on_crash>preserve</on_crash>|" 1> /tmp/dom-patch.xml &&
            virsh define /tmp/dom-patch.xml 1> /dev/null; } || es=1
        rm -f /tmp/dom-patch.xml || true
        exit "${es}"
    ' '' "${metaArr[domain]}" ||
        echo "${scrName%.sh}: WARN: domain crash-behaviour patch failed (non-fatal, evidence capture may be limited)" 1>&2
    true
}
# prepare: pre-crash fallback copies; the VMI spec stays readable even if the launcher Pod fails after the BSOD.
function SavePreCrashCopies () {
    RunTimed 30 oc --request-timeout=25s -n "${cfgArr[ns]}" exec "${metaArr[launcherPod]}" -- virsh dumpxml "${metaArr[domain]}" \
        1> "${outDir}/pre-bsod-domain.xml" || rm -f "${outDir}/pre-bsod-domain.xml"
    RunTimed 15 oc --request-timeout=10s -n "${cfgArr[ns]}" get "vmi/${cfgArr[vm]}" -o json 1> "${outDir}/vmi-spec.json" ||
        rm -f "${outDir}/vmi-spec.json"
    true
}
# stage: NotMyFault must exist and be readable on the guest; any other answer, including a guest-agent
# failure, stops the run. This is an availability check, not an integrity check.
function RequireNotMyFault () {
    typeset nmfState=''
    nmfState="$(GuestPS 30 "try { \$s = [IO.File]::OpenRead('${nmfGuest}'); \$s.Close(); 'readable' } catch { 'unavailable' }")" ||
        nmfState='unavailable'
    nmfState="${nmfState//[[:space:]]/}"
    [ "${nmfState}" = readable ] || Die "NotMyFault ${nmfGuest} is not available and readable on the guest (got: '${nmfState}')"
    true
}
# stage: clear old dumps so any dump found after the crash belongs to this run, then prove the guest is clean.
function ClearGuestDumps () {
    typeset cleanState=''
    [ "${cfgArr[mode]}" = intentional ] || Die 'guest crash dumps are only deleted in intentional mode'
    cleanState="$(GuestPS 60 \
        "Remove-Item 'C:\Windows\MEMORY.DMP' -Force -ErrorAction SilentlyContinue; Remove-Item 'C:\Windows\Minidump\*.dmp' -Force -ErrorAction SilentlyContinue; [ordered]@{memory=(Test-Path 'C:\Windows\MEMORY.DMP');minidumpCount=@(Get-ChildItem 'C:\Windows\Minidump\*.dmp' -ErrorAction SilentlyContinue).Count}|ConvertTo-Json -Compress")" ||
        Die "guest dump cleanup command failed (status $?)" "$?"
    jq -e '.memory == false and .minidumpCount == 0' 0<<<"${cleanState}" 1> /dev/null ||
        Die "guest dump cleanup could not be proven: ${cleanState}"
    true
}
# arm: start the watcher and wait until it publishes this run's ID; nothing is injected before that.
function ArmWatcher () {
    typeset -a argArr=("${commonArgArr[@]}" --recovery-image "${cfgArr[recoveryImage]}" --ready-file "${readyFile}" --no-restart)
    [ "${cfgArr[mode]}" = watch ] || argArr+=(--intentional)
    bash "${watcherBin}" "${argArr[@]}" &
    watcherPID="$!"
    typeset -i es=0 readyDeadline=$((SECONDS + cfgArr[readyTimeout]))
    until [[ -s "${readyFile}" && "$(<"${readyFile}")" == "${runID}" ]]; do
        if ! kill -0 "${watcherPID}"; then
            wait "${watcherPID}" || es="$?"
            watcherPID=''
            Die "watcher exited (status ${es}) before publishing readiness; inspect ${outDir}" "$((es ? es : 1))"
        fi
        ((SECONDS < readyDeadline)) || Die "watcher readiness timed out after ${cfgArr[readyTimeout]}s"
        sleep 1
    done
    printf '%s: watcher armed for %s/%s (run %s).\n' "${scrName%.sh}" "${cfgArr[ns]}" "${cfgArr[vm]}" "${runID}"
    true
}
# inject: returns once the guest agent confirms the NotMyFault process started or the guest disconnects.
function InjectCrash () {
    [ "${cfgArr[mode]}" = intentional ] || Die 'a crash is only injected in intentional mode'
    printf 'Triggering NotMyFault crash %s.\n' "${cfgArr[crashType]}"
    RunTimed 90 "${guestAgentArr[@]}" exec-crash "${nmfGuest}" /accepteula /crash "${cfgArr[crashType]}" 1> /dev/null ||
        Die 'intentional guest crash command exited nonzero or did not disconnect as expected' "$?"
    true
}
# recover: the watcher captures the crash and runs the offline extraction; it must succeed and report this run.
function AwaitRecovery () {
    typeset -i es=0
    wait "${watcherPID}" || es="$?"
    watcherPID=''
    ((es == 0)) || Die "watcher/recovery pipeline failed with status ${es}; inspect ${outDir}" "${es}"
    jq -e --arg run "${runID}" '.ok == true and .runId == $run' "${outDir}/evidence-summary.json" 1> /dev/null ||
        Die 'current-run evidence summary is absent or reports failure'
    true
}
# verify: the watcher stopped the VM before the offline extraction and, with `--no-restart`, must have left it so.
function VerifyStopped () {
    typeset vmStatus=''
    vmStatus="$(oc --request-timeout=30s -n "${cfgArr[ns]}" get "vm/${cfgArr[vm]}" -o jsonpath='{.status.printableStatus}')" ||
        Die "cannot read the status of VM ${cfgArr[ns]}/${cfgArr[vm]}" "$?"
    [ "${vmStatus}" = Stopped ] || Die "VM ${cfgArr[ns]}/${cfgArr[vm]} is '${vmStatus}' after extraction, expected Stopped"
    printf '%s: evidence verified in %s; VM %s/%s left Stopped.\n' "${scrName%.sh}" "${outDir}" "${cfgArr[ns]}" "${cfgArr[vm]}"
    true
}

function Main () {
    typeset phase=preflight
    typeset -a pathArr=()
    typeset -A seenArr=()
    # The watch path; intentional mode adds `stage` before arming and replaces `observe` with `inject`.
    typeset -A nextPhaseArr=([preflight]=prepare [prepare]=arm [arm]=observe [observe]=recover [recover]=verify [verify]=complete)
    ParseArgs "$@"
    ValidateConfig
    ValidateTools
    readonly cfgArr
    [ "${cfgArr[mode]}" = watch ] || nextPhaseArr+=([prepare]=stage [stage]=arm [arm]=inject [inject]=recover)
    # Resolve the path before any side effect: each phase needs a successor and runs once (one watcher, cleanup and crash).
    until [ "${phase}" = complete ]; do
        [[ -n "${nextPhaseArr["${phase}"]:-}" && -z "${seenArr["${phase}"]:-}" ]] ||
            Die "pipeline phase '${phase}' is unknown or would run again"
        seenArr["${phase}"]=1; pathArr+=("${phase}")
        phase="${nextPhaseArr["${phase}"]}"
    done
    for phase in "${pathArr[@]}"; do
        case "${phase}" in
          (preflight) RunPreflight; ReadMetadata;;
          (prepare)   PatchDomain; SavePreCrashCopies;;
          (stage)     RequireNotMyFault; ClearGuestDumps;;
          (arm)       ArmWatcher;;
          (inject)    InjectCrash;;
          (observe)   printf '%s\n' 'Trigger the BSOD in the VM now. Evidence is captured automatically if it happens' \
                          'before the watcher deadline (BSOD_DET__ARMED__TIMEOUT, default 3600s).';;
          (recover)   AwaitRecovery;;
          (verify)    VerifyStopped;;
          (*)         Die "unknown pipeline phase '${phase}'";;
        esac
    done
    true
}

trap Cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
Main "$@"

true
