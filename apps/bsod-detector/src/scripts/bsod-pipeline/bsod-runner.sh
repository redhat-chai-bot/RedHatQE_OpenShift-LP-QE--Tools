#!/usr/bin/env bash
typeset useMsg=''; read -rd '' useMsg 0<<'useMsg-EOF'
RHOV BSOD pipeline for an explicitly disposable test VM:
preflight -> [intentional: stage NotMyFault, clear old dumps] -> watcher armed -> [intentional: inject] -> offline extraction.
The watcher runs with `--no-restart`, so a successful run leaves the VM Stopped. This script never starts it.

Usage:
    bsod-runner.sh --mode intentional <crashType>
    bsod-runner.sh --mode watch

Where:
    --mode      intentional  Crash the VM on purpose with NotMyFault <crashType>.
                watch        Wait for a natural crash. NotMyFault is not staged or run and existing
                             guest crash dumps are not deleted.
                Prompted for when omitted on a terminal. Required otherwise.
    crashType   NotMyFault crash type, 0x01 - 0x09. Intentional mode only, no default.

Environment:
    BSOD_DET__NAMESPACE, BSOD_DET__VM__NAME  Target VM (required).
    BSOD_DET__CONFIRM_TARGET                 Must equal BSOD_DET__VM__NAME (intentional mode only).
    BSOD_DET__EVIDENCE__DIR                  Evidence mount (default: /mnt/persistent-bsod-evidence).
    BSOD_EVIDENCE_VOLUME_KIND, BSOD_DET__EVIDENCE__STORAGE_ID, BSOD_DET__MEMORY__DUMP_PVC,
    BSOD_DET__SNAPSHOT__CLASS, BSOD_DET__RECOVERY__IMAGE,
    BSOD_DET__READY__TIMEOUT (300), BSOD_DET__PREFLIGHT__TIMEOUT (1800)  Optional overrides.
    The watcher's own settings (e.g. BSOD_DET__ARMED__TIMEOUT, default 3600) still apply.
useMsg-EOF
set -euxo pipefail; shopt -s inherit_errexit
umask 077

typeset scrDir=''; scrDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset scrName="${BASH_SOURCE[0]##*/}"
typeset hostDir="${scrDir}/../host"
typeset mode='' crashType='' watcherPid=''
typeset vm="${BSOD_DET__VM__NAME:-}" ns="${BSOD_DET__NAMESPACE:-}"
typeset evidenceRoot="${BSOD_DET__EVIDENCE__DIR:-/mnt/persistent-bsod-evidence}"
typeset evidenceKind="${BSOD_EVIDENCE_VOLUME_KIND:-pvc}"
typeset evidenceId="${BSOD_DET__EVIDENCE__STORAGE_ID:-shared-bsod-evidence}"
typeset memoryPvc="${BSOD_DET__MEMORY__DUMP_PVC:-${vm}-memdump}"
typeset snapClass="${BSOD_DET__SNAPSHOT__CLASS:-ocs-storagecluster-rbdplugin-snapclass}"
typeset recoveryImage="${BSOD_DET__RECOVERY__IMAGE:-quay.io/konveyor/oadp-vmfr-access:latest}"
# Strip digest pin (@sha256:...) — always use the tag so a stale digest doesn't block the pipeline.
recoveryImage="${recoveryImage%%@*}"
typeset readyTimeout="${BSOD_DET__READY__TIMEOUT:-300}"
typeset preflightTimeout="${BSOD_DET__PREFLIGHT__TIMEOUT:-1800}"
typeset nmfGuest='C:\Temp\nmf\notmyfaultc64.exe'
typeset -a guestAgent=(python3 "${hostDir}/guest-agent.py")
[ -z "${BSOD_DET__GUEST_AGENT__BIN:-}" ] || guestAgent=("${BSOD_DET__GUEST_AGENT__BIN}")

# `set +x` keeps xtrace from printing the usage text a second time.
function Usage () { set +x; echo "${scrName%.sh}: ${1:?}" 1>&2; echo "${useMsg}" 1>&2; exit 2; }
function Die () { echo "${scrName%.sh}: ERROR: ${1:?}" 1>&2; exit "${2:-1}"; }
function RunTimed () { typeset sec="${1:?}"; shift; timeout --signal=TERM --kill-after=5 "${sec}" "$@"; }
function GuestPs () { typeset sec="${1:?}"; shift; RunTimed "${sec}" "${guestAgent[@]}" exec powershell.exe -NoProfile -Command "$@"; }

# Lower-case SHA-256 of the guest's NotMyFault copy; empty when it is absent or the guest agent fails.
function GuestNmfHash () {
    typeset hash=''
    hash="$(GuestPs 30 "(Get-FileHash -Algorithm SHA256 -LiteralPath '${nmfGuest}' -ErrorAction SilentlyContinue).Hash")" ||
        hash=''
    hash="${hash//[[:space:]]/}"
    echo "${hash,,}"

    true
}

# Stops a still-running watcher (it removes only its own temporary state). Never deletes evidence.
function Cleanup () {
    [ -z "${watcherPid}" ] || { kill "${watcherPid}" || true; wait "${watcherPid}" || true; }

    true
}
trap Cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while (($#)); do
    case "${1}" in
      (--mode)      (($# >= 2)) || Usage '--mode needs a value'; mode="${2}"; shift 2;;
      (-h|--help)   set +x; echo "${useMsg}"; exit 0;;
      (-*)          Usage "unknown option: ${1}";;
      (*)
        [ -z "${crashType}" ] || Usage "unexpected argument: ${1}"
        crashType="${1}"; shift
        ;;
    esac
done

# Ask only on a terminal. A non-interactive caller must choose, so nothing is ever injected by default.
[ -n "${mode}" ] || ! [ -t 0 ] || read -rp 'Mode (intentional|watch): ' mode || true
case "${mode}" in
  (intentional)
    [ -n "${crashType}" ] || ! [ -t 0 ] || read -rp 'NotMyFault crash type (0x01 - 0x09): ' crashType || true
    case "${crashType}" in
      (0x0[1-9]) ;;
      ('') Usage 'a crash type is required with --mode intentional (no default: it crashes the VM)';;
      (*)  Usage "unsupported NotMyFault crash type '${crashType}' (supported: 0x01 - 0x09)";;
    esac
    ;;
  (watch) [ -z "${crashType}" ] || Usage 'a crash type is only valid with --mode intentional';;
  ('')    Usage '--mode intentional|watch is required';;
  (*)     Usage "unsupported mode '${mode}' (supported: intentional, watch)";;
esac

[[ -n "${vm}" && -n "${ns}" ]] || Die 'BSOD_DET__VM__NAME and BSOD_DET__NAMESPACE must identify the disposable RHOV test VM'
[[ "${readyTimeout}" =~ ^[1-9][0-9]*$ && "${preflightTimeout}" =~ ^[1-9][0-9]*$ ]] ||
    Die 'BSOD_DET__READY__TIMEOUT and BSOD_DET__PREFLIGHT__TIMEOUT must be positive integers'
if [ "${mode}" = intentional ]; then
    # The target location is not authorization: the operator must name the VM again.
    [ "${BSOD_DET__CONFIRM_TARGET:-}" = "${vm}" ] ||
        Die "BSOD_DET__CONFIRM_TARGET must be set to '${vm}' to authorize crashing this VM (got: '${BSOD_DET__CONFIRM_TARGET:-<unset>}')"
    # notmyfaultc64.exe is downloaded on the guest by configure-dumps.ps1 — no local copy required.
fi

typeset runId=''; runId="$(date -u +%Y%m%dT%H%M%SZ)-${mode}-$$-${RANDOM}"
typeset outDir="${evidenceRoot}/${runId}"
typeset metadataFile="${outDir}/recovery-metadata.json" readyFile="${outDir}/watcher-ready"
typeset -a commonArgs=(
    --ns "${ns}" --vm "${vm}" --out "${outDir}" --metadata "${metadataFile}" --run-id "${runId}"
    --evidence-mount "${evidenceRoot}" --evidence-volume-kind "${evidenceKind}" --evidence-storage-id "${evidenceId}"
    --snap-class "${snapClass}" --memory-dump-pvc "${memoryPvc}"
)
mkdir "${outDir}" || Die "cannot create unique run directory ${outDir}"

# Same preflight for both modes. --recovery-image not passed — preflight doesn't use it.
RunTimed "${preflightTimeout}" "${hostDir}/preflight-rhov.sh" "${commonArgs[@]}"
typeset pod='' dom=''
pod="$(jq -er .launcherPod "${metadataFile}")"
dom="$(jq -er .domain "${metadataFile}")"
export BSOD_DET__POD__NAME="${pod}" BSOD_DET__DOMAIN__NAME="${dom}"

# Best effort: hot-add pvpanic so the BSOD is reported to QEMU instead of a hard reset, and persist
# on_crash=preserve (effective only if KubeVirt keeps that definition).
# shellcheck disable=SC2016 # Expanded by the launcher Pod shell.
RunTimed 30 oc --request-timeout=25s -n "${ns}" exec "${pod}" -- bash -o pipefail -xc '
    es=0
    virsh qemu-monitor-command "${1}" --hmp "device_add pvpanic-pci,id=pvpanic0" || es=1
    { virsh dumpxml "${1}" | sed "s|<on_crash>.*</on_crash>|<on_crash>preserve</on_crash>|" 1> /tmp/dom-patch.xml &&
        virsh define /tmp/dom-patch.xml 1> /dev/null; } || es=1
    rm -f /tmp/dom-patch.xml
    exit "${es}"
' '' "${dom}" || : 'WARN: domain crash-behaviour patch failed (non-fatal, evidence capture may be limited)'

# Pre-crash fallback copies; the VMI spec stays readable even if the launcher Pod fails after the BSOD.
RunTimed 30 oc --request-timeout=25s -n "${ns}" exec "${pod}" -- virsh dumpxml "${dom}" 1> "${outDir}/pre-bsod-domain.xml" ||
    rm -f "${outDir}/pre-bsod-domain.xml"
RunTimed 15 oc --request-timeout=10s -n "${ns}" get "vmi/${vm}" -o json 1> "${outDir}/vmi-spec.json" ||
    rm -f "${outDir}/vmi-spec.json"

if [ "${mode}" = intentional ]; then
    # Verify notmyfaultc64.exe is present on the guest (downloaded by configure-dumps.ps1 during preflight).
    [ -n "$(GuestNmfHash)" ] || Die "notmyfaultc64.exe not found on guest — configure-dumps.ps1 download may have failed"

    # Clear old dumps so any dump found after the crash belongs to this run, then prove the guest is clean.
    typeset cleanState=''
    cleanState="$(GuestPs 60 \
        "Remove-Item 'C:\Windows\MEMORY.DMP' -Force -ErrorAction SilentlyContinue; Remove-Item 'C:\Windows\Minidump\*.dmp' -Force -ErrorAction SilentlyContinue; [ordered]@{memory=(Test-Path 'C:\Windows\MEMORY.DMP');minidumpCount=@(Get-ChildItem 'C:\Windows\Minidump\*.dmp' -ErrorAction SilentlyContinue).Count}|ConvertTo-Json -Compress")"
    jq -e '.memory == false and .minidumpCount == 0' 0<<<"${cleanState}" 1> /dev/null ||
        Die "guest dump cleanup could not be proven: ${cleanState}"
fi

# Armed timeout: default 3600s for intentional; watch mode prompts interactively or requires explicit value in CI.
if [ "${mode}" = watch ] && [ -z "${BSOD_DET__ARMED__TIMEOUT:-}" ]; then
    if [ -t 0 ]; then
        typeset armedInput=''
        read -rp "Watch timeout in seconds (press Enter for default 3600s = 1 hour): " armedInput
        export BSOD_DET__ARMED__TIMEOUT="${armedInput:-3600}"
    else
        Die 'watch mode in CI requires BSOD_DET__ARMED__TIMEOUT to be set explicitly'
    fi
else
    export BSOD_DET__ARMED__TIMEOUT="${BSOD_DET__ARMED__TIMEOUT:-3600}"
fi
echo "bsod-runner: watcher armed timeout = ${BSOD_DET__ARMED__TIMEOUT}s"
typeset -a watchArgs=("${commonArgs[@]}" --recovery-image "${recoveryImage}" --ready-file "${readyFile}" --no-restart)
[ "${mode}" = watch ] || watchArgs+=(--intentional)
bash "${hostDir}/bsod-watcher.sh" "${watchArgs[@]}" &
watcherPid=$!

typeset -i es=0 readyDeadline=$((SECONDS + readyTimeout))
until [[ -s "${readyFile}" && "$(<"${readyFile}")" == "${runId}" ]]; do
    if ! kill -0 "${watcherPid}"; then
        wait "${watcherPid}" || es=$?
        watcherPid=''
        Die "watcher exited (status ${es}) before publishing readiness; inspect ${outDir}" $((es ? es : 1))
    fi
    ((SECONDS < readyDeadline)) || Die "watcher readiness timed out after ${readyTimeout}s"
    sleep 1
done

printf '%s: watcher armed for %s/%s (run %s).\n' "${scrName%.sh}" "${ns}" "${vm}" "${runId}"
if [ "${mode}" = intentional ]; then
    printf 'Triggering NotMyFault crash %s.\n' "${crashType}"
    # Returns once the guest agent confirms the process started or the guest disconnects.
    RunTimed 90 "${guestAgent[@]}" exec-crash "${nmfGuest}" /accepteula /crash "${crashType}" 1> /dev/null ||
        Die 'intentional guest crash command exited nonzero or did not disconnect as expected' $?
else
    printf '%s\n' 'Trigger the BSOD in the VM now. Evidence is captured automatically if it happens' \
        'before the watcher deadline (BSOD_DET__ARMED__TIMEOUT, default 3600s).'
fi

wait "${watcherPid}" || es=$?
watcherPid=''
((es == 0)) || Die "watcher/recovery pipeline failed with status ${es}; inspect ${outDir}" "${es}"
jq -e --arg run "${runId}" '.ok == true and .runId == $run' "${outDir}/evidence-summary.json" 1> /dev/null ||
    Die 'current-run evidence summary is absent or reports failure'

# The watcher stopped the VM before the offline extraction and, with `--no-restart`, must have left it so.
typeset vmStatus=''
vmStatus="$(oc --request-timeout=30s -n "${ns}" get "vm/${vm}" -o jsonpath='{.status.printableStatus}')"
[ "${vmStatus}" = Stopped ] || Die "VM ${ns}/${vm} is '${vmStatus}' after extraction, expected Stopped"
printf '%s: evidence verified in %s; VM %s/%s left Stopped.\n' "${scrName%.sh}" "${outDir}" "${ns}" "${vm}"

true
