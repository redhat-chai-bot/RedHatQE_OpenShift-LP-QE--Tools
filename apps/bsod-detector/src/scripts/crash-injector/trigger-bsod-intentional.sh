#!/usr/bin/env bash
# Intentional RHOV BSOD orchestration for an explicitly disposable test VM.
# This script orchestrates the full pipeline: preflight validation → crash injection → watcher → recovery
set -euxo pipefail; shopt -s inherit_errexit
umask 077

# Parse input: crash type (0x01-0x09 from NotMyFault) — required, no default
typeset crashType="${1:-}"; typeset vm="${BSOD_DET__VM__NAME:-}"; typeset ns="${BSOD_DET__NAMESPACE:-}"
# Storage configuration: evidence root (mounted PVC), volume kind, and storage identity
typeset evidenceRoot="${BSOD_DET__EVIDENCE__DIR:-/mnt/persistent-bsod-evidence}"; typeset evidenceKind="${BSOD_EVIDENCE_VOLUME_KIND:-pvc}"
typeset evidenceId="${BSOD_DET__EVIDENCE__STORAGE_ID:-shared-bsod-evidence}"; typeset memoryPvc="${BSOD_DET__MEMORY__DUMP_PVC:-${BSOD_DET__VM__NAME}-memdump}"
# Kubernetes storage classes and container image for extraction pod
typeset snapClass="${BSOD_DET__SNAPSHOT__CLASS:-ocs-storagecluster-rbdplugin-snapclass}"; typeset recoveryImage="${BSOD_DET__RECOVERY__IMAGE:-quay.io/konveyor/oadp-vmfr-access:latest@sha256:e26c74ce8957768bd0bca7fdec01e28874c834cfdbea6fb9e8a5136ec7548cf0}"
# Timeouts: how long to wait for watcher readiness and preflight validation
typeset readyTimeout="${BSOD_DET__READY__TIMEOUT:-300}"
typeset preflightTimeout="${BSOD_DET__PREFLIGHT__TIMEOUT:-300}"
# Directory structure: script location, app root, host scripts location
typeset scriptDir=''; scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset appDir=''; appDir="$(cd "${scriptDir}/../../.." && pwd)"; typeset hostDir="${appDir}/src/scripts/host"
# Project root for cleanup of libguestfs cache files (file.0x*)
# guestfish writes cache files to CWD which is the git repo root (two levels above appDir)
typeset projectRoot=''; projectRoot="$(cd "${appDir}/../.." && pwd)"
typeset watcherPid=''; typeset runId=''; runId="$(date -u +%Y%m%dT%H%M%SZ)-intentional-$$-$RANDOM"
typeset outDir="${evidenceRoot}/${runId}"; typeset metadataFile="${outDir}/recovery-metadata.json"; typeset readyFile="${outDir}/watcher-ready"
# Run-scoped temp dir for guestfish cache — cleaned up only by this run, never touches shared paths
typeset runTmpDir=''; runTmpDir="$(mktemp -d "${TMPDIR:-/tmp}/bsod-injector-${runId}.XXXXXX")"

function Die () { echo "trigger-bsod-intentional: ERROR: $*" >&2; exit 1; }
# Remove only this run's scoped cache files — never touches shared /tmp or project paths
function CleanupGuestfishCache () {
  [[ -n "${runTmpDir}" && -d "${runTmpDir}" ]] && rm -rf "${runTmpDir}" 2>/dev/null || true
}
# Cleanup on exit: kill background watcher process, delete temporary storage, and remove this run's cache.
# This runs on both success and failure to ensure cluster doesn't accumulate stale DVs/PVCs.
function Cleanup () {
  if [[ -n "${watcherPid}" ]]; then kill "${watcherPid}" 2>/dev/null || true; wait "${watcherPid}" 2>/dev/null || true; watcherPid=''; fi
  # Cleanup temporary storage even on failure — prevents cluster clutter on aborted runs
  CleanupTemporaryStorage 2>/dev/null || true
  CleanupGuestfishCache
  true
}
function OnSignal () { typeset status="${1:?}"; exit "${status}"; }
trap Cleanup EXIT
trap 'OnSignal 130' INT
trap 'OnSignal 143' TERM

# Finding 1: crash type must be supplied explicitly — no silent default selects a destructive action
[[ -n "${crashType}" ]] || Die "crash type argument is required (e.g. 0x01); no default — this is a destructive operation"
case "${crashType}" in 0x01|0x02|0x03|0x04|0x05|0x06|0x07|0x08|0x09) ;; *) Die "unsupported NotMyFault crash type '${crashType}' — supported: 0x01..0x09" ;; esac

# Finding 1: target location is not authorization — require an explicit confirmation token
# BSOD_DET__CONFIRM_TARGET must equal BSOD_DET__VM__NAME to prove the operator intends
# to crash this specific VM (guards against env-var typos or accidental wrong-target runs)
[[ -n "${vm}" && -n "${ns}" ]] || Die 'BSOD_DET__VM__NAME and BSOD_DET__NAMESPACE must explicitly identify the disposable RHOV test VM'
[[ "${BSOD_DET__CONFIRM_TARGET:-}" == "${vm}" ]] || \
  Die "BSOD_DET__CONFIRM_TARGET must be set to '${vm}' to authorize crashing this VM (got: '${BSOD_DET__CONFIRM_TARGET:-<unset>}')"
[[ -n "${evidenceRoot}" ]] || Die 'EVIDENCE_DIR must identify the validated persistent mount'
[[ "${readyTimeout}" =~ ^[1-9][0-9]*$ && "${preflightTimeout}" =~ ^[1-9][0-9]*$ ]] || Die 'watch/ready/preflight timeouts must be positive integers'

# Phase 1: export run-scoped cache dir so nested guestfish calls use it
export LIBGUESTFS_CACHEDIR="${runTmpDir}" LIBGUESTFS_TMPDIR="${runTmpDir}"

# Phase 1a: Pre-cleanup — delete stale temporary DVs/PVCs from previous failed runs
echo "trigger-bsod-intentional: cleaning up stale temporary storage from previous runs..."
typeset memoryDumpDv="${BSOD_DET__VM__NAME}-memdump-dv"; typeset memoryDumpPvc="${memoryPvc}"
typeset evidenceDv="shared-bsod-evidence-dv"; typeset evidencePvc="${evidenceId}"
for resource in "dv/${memoryDumpDv}" "pvc/${memoryDumpPvc}" "dv/${evidenceDv}" "pvc/${evidencePvc}"; do
  timeout --signal=TERM --kill-after=5 30 oc delete "${resource}" -n "${ns}" --ignore-not-found=true 2>/dev/null && \
    echo "trigger-bsod-intentional: cleaned up stale ${resource}" || \
    echo "trigger-bsod-intentional: WARN: ${resource} cleanup skipped (may not exist or is in use)"
done

# Phase 1b: validate NotMyFault binary exists on host (upload happens after preflight in Phase 2b)
typeset nmfBin="${scriptDir}/notmyfaultc64.exe"
[[ -f "${nmfBin}" ]] || Die "notmyfaultc64.exe not found at ${nmfBin} — add it to crash-injector/"
typeset nmfExpectedSize; nmfExpectedSize="$(stat -c%s "${nmfBin}")"

# Phase 2: Preflight validation - verify cluster state, VM existence, and mount points are valid
mkdir "${outDir}" || Die "cannot create unique run directory ${outDir}"
timeout --signal=TERM --kill-after=5 1800 "${hostDir}/preflight-rhov.sh" --ns "${ns}" --vm "${vm}" --out "${outDir}" --metadata "${metadataFile}" --run-id "${runId}" \
  --evidence-mount "${evidenceRoot}" --evidence-volume-kind "${evidenceKind}" --evidence-storage-id "${evidenceId}" \
  --snap-class "${snapClass}" --recovery-image "${recoveryImage}" --memory-dump-pvc "${memoryPvc}" --require-trigger
# Extract launcher pod name and domain from preflight metadata for guest agent access
BSOD_DET__POD__NAME="$(jq -er .launcherPod "${metadataFile}")"; export BSOD_DET__POD__NAME
BSOD_DET__DOMAIN__NAME="$(jq -er .domain "${metadataFile}")"; export BSOD_DET__DOMAIN__NAME

# Phase 2b: Patch domain crash behavior so QEMU preserves the domain after BSOD (non-fatal).
# Adds pvpanic device live (virtio panic port) so Win11 signals crash via pvpanic instead of
# hard-resetting the machine — without this, QEMU gets a hard reset signal and may crash itself.
# Also sets on_crash=preserve in the persistent domain config (takes effect on next VM start).
# KubeVirt regenerates domain XML on each start so persistent patch only helps when KubeVirt
# spec already includes the device — but live pvpanic attach helps the current run immediately.
typeset launcherPod; launcherPod="$(jq -er .launcherPod "${metadataFile}")"
typeset domainName; domainName="$(jq -er .domain "${metadataFile}")"
echo "trigger-bsod-intentional: adding pvpanic device via QMP and patching on_crash=preserve..."
timeout --signal=TERM --kill-after=5 30 oc --request-timeout=25s exec -n "${ns}" "${launcherPod}" -- \
  bash -c "
    # Add pvpanic device to RUNNING QEMU process via QMP device_add (works where attach-device fails)
    # This makes Win11 signal crash via pvpanic ISA port instead of hard-resetting the machine,
    # allowing QEMU to handle it with on_crash=preserve (pod stays Running, domain paused).
    virsh qemu-monitor-command '${domainName}' --hmp 'device_add pvpanic,id=pvpanic0' 2>/dev/null && \
      echo 'pvpanic device added via QMP' || \
      echo 'WARN: pvpanic QMP device_add failed (non-fatal)'

    # Patch on_crash=preserve in persistent config (takes effect if KubeVirt honours it on restart)
    virsh dumpxml '${domainName}' > /tmp/dom-patch.xml 2>/dev/null &&
    sed -i 's|<on_crash>.*</on_crash>|<on_crash>preserve</on_crash>|' /tmp/dom-patch.xml &&
    virsh define /tmp/dom-patch.xml > /dev/null 2>&1 &&
    rm -f /tmp/dom-patch.xml &&
    echo 'on_crash=preserve set in persistent domain config' || true
  " 2>/dev/null && echo "trigger-bsod-intentional: domain patched successfully" || \
  echo "trigger-bsod-intentional: WARN: domain patch failed (non-fatal — evidence capture may be limited)"

# Pre-capture domain.xml while pod is still Running (domain config doesn't change on crash).
# If pod goes Failed after BSOD, oc exec will fail — this pre-captured copy is the fallback.
timeout --signal=TERM --kill-after=5 30 oc --request-timeout=25s exec -n "${ns}" "${launcherPod}" -- \
  virsh dumpxml "${domainName}" > "${outDir}/domain.xml" 2>/dev/null && \
  echo "trigger-bsod-intentional: domain.xml pre-captured ($(wc -c < "${outDir}/domain.xml") bytes)" || \
  echo "trigger-bsod-intentional: WARN: domain.xml pre-capture failed (non-fatal)"

# Always capture VMI spec via Kubernetes API — available even when pod is Failed/OOMKilled.
# Contains identical VM configuration (CPU, memory, devices) to domain.xml.
timeout --signal=TERM --kill-after=5 15 oc --request-timeout=10s get vmi "${vm}" -n "${ns}" -o json \
  > "${outDir}/vmi-spec.json" 2>/dev/null && \
  echo "trigger-bsod-intentional: vmi-spec.json captured (always available via Kubernetes API)" || \
  echo "trigger-bsod-intentional: WARN: vmi-spec.json capture failed (non-fatal)"

# Phase 2c: Upload NotMyFault binary — runs after preflight so QGA is confirmed working
# Skipped if binary already present with correct size (golden image pre-installs it).
typeset nmfGuestSize; nmfGuestSize="$(timeout --signal=TERM --kill-after=5 15 python3 "${hostDir}/guest-agent.py" exec powershell.exe -NoProfile -Command \
  "(Get-Item 'C:\Temp\nmf\notmyfaultc64.exe' -ErrorAction SilentlyContinue)?.Length" 2>/dev/null || true)"
if [[ "${nmfGuestSize}" == *"${nmfExpectedSize}"* ]]; then
  echo "trigger-bsod-intentional: NotMyFault present with correct size (${nmfExpectedSize} bytes) — skipping upload"
else
  echo "trigger-bsod-intentional: NotMyFault missing or wrong size (guest=${nmfGuestSize}, expected=${nmfExpectedSize}) — uploading..."
  timeout --signal=TERM --kill-after=5 60 python3 "${hostDir}/guest-agent.py" exec powershell.exe -NoProfile -Command \
    "New-Item -ItemType Directory -Force -Path 'C:\Temp\nmf' | Out-Null" || Die 'cannot create C:\Temp\nmf on guest'
  timeout --signal=TERM --kill-after=5 120 python3 "${hostDir}/guest-agent.py" put "${nmfBin}" 'C:\Temp\nmf\notmyfaultc64.exe' || Die 'NotMyFault upload to guest failed'
  typeset nmfActualSize; nmfActualSize="$(timeout --signal=TERM --kill-after=5 15 python3 "${hostDir}/guest-agent.py" exec powershell.exe -NoProfile -Command \
    "(Get-Item 'C:\Temp\nmf\notmyfaultc64.exe').Length" 2>/dev/null || true)"
  [[ "${nmfActualSize}" == *"${nmfExpectedSize}"* ]] || Die "NotMyFault upload corrupted: expected ${nmfExpectedSize} bytes, got ${nmfActualSize}"
  timeout --signal=TERM --kill-after=5 15 python3 "${hostDir}/guest-agent.py" exec powershell.exe -NoProfile -Command \
    "Unblock-File -Path 'C:\Temp\nmf\notmyfaultc64.exe' -ErrorAction SilentlyContinue" 2>/dev/null || true
  echo "trigger-bsod-intentional: NotMyFault uploaded and unblocked (${nmfExpectedSize} bytes)"
fi

# Phase 3: Guest cleanup - ensure no stale dumps from previous runs exist on the VM
# This prevents false positives from old dumps: we must verify empty state BEFORE injecting crash
typeset cleanupResult=''
cleanupResult="$(timeout --signal=TERM --kill-after=5 60 python3 "${hostDir}/guest-agent.py" exec powershell.exe -NoProfile -Command \
  "Remove-Item 'C:\Windows\MEMORY.DMP' -Force -ErrorAction SilentlyContinue; Remove-Item 'C:\Windows\Minidump\*.dmp' -Force -ErrorAction SilentlyContinue; [ordered]@{memory=(Test-Path 'C:\Windows\MEMORY.DMP');minidumpCount=@(Get-ChildItem 'C:\Windows\Minidump\*.dmp' -ErrorAction SilentlyContinue).Count}|ConvertTo-Json -Compress")" || Die 'guest dump cleanup command failed or timed out'
jq -e '.memory == false and .minidumpCount == 0' <<<"${cleanupResult}" >/dev/null || Die "guest dump cleanup could not be proven: ${cleanupResult}"

# Phase 4: Start watcher in background - watches for crash occurrence and captures dumps/logs
bash "${hostDir}/watch-crash.sh" \
  --ns "${ns}" --vm "${vm}" --out "${outDir}" --metadata "${metadataFile}" --run-id "${runId}" --ready-file "${readyFile}" \
  --evidence-mount "${evidenceRoot}" --evidence-volume-kind "${evidenceKind}" --evidence-storage-id "${evidenceId}" \
  --snap-class "${snapClass}" --recovery-image "${recoveryImage}" --memory-dump-pvc "${memoryPvc}" --intentional &
watcherPid=$!
# Wait for watcher to signal readiness - means it's armed and watching for crash
typeset readyDeadline=$((SECONDS + readyTimeout))
while ((SECONDS < readyDeadline)); do
  if [[ -s "${readyFile}" && "$(<"${readyFile}")" == "${runId}" ]]; then break; fi
  kill -0 "${watcherPid}" 2>/dev/null || { wait "${watcherPid}" 2>/dev/null || true; watcherPid=''; Die 'watcher exited before publishing readiness'; }
  sleep 1
done
[[ -s "${readyFile}" && "$(<"${readyFile}")" == "${runId}" ]] || Die "watcher readiness timed out after ${readyTimeout}s"

# Phase 5: Inject crash - use NotMyFault to trigger intentional BSOD on guest VM
# This waits for QGA to confirm process creation and delivery before returning
timeout --signal=TERM --kill-after=5 90 python3 "${hostDir}/guest-agent.py" exec-crash \
  'C:\Temp\nmf\notmyfaultc64.exe' /accepteula /crash "${crashType}" >/dev/null || Die 'intentional guest crash command exited nonzero or did not disconnect as expected'

# Phase 6: Wait for watcher completion - captures memory, logs, and extracted artifacts
typeset watcherStatus=0; wait "${watcherPid}" || watcherStatus=$?; watcherPid=''
((watcherStatus == 0)) || Die "watcher/recovery pipeline failed with status ${watcherStatus}; inspect ${outDir}"
# Verify that evidence summary exists and reports success (all artifacts extracted)
jq -e --arg run "${runId}" '.ok == true and .runId == $run' "${outDir}/evidence-summary.json" >/dev/null || Die 'current-run evidence summary is absent or reports failure'
echo "trigger-bsod-intentional: verified evidence package: ${outDir}"

# Phase 7: Delete temporary DVs and PVCs (memory-dump and evidence) so next run gets fresh ones.
# Evidence artifacts have been exported to the evidence directory; DVs and PVCs are recreated dynamically on next run.
# This cleanup runs on success; on failure, the trap handler still executes this to avoid cluster clutter.
function CleanupTemporaryStorage () {
  echo "trigger-bsod-intentional: cleaning up temporary DVs and PVCs for fresh creation on next run..."
  typeset storageDeleteStatus=0
  typeset memoryDumpDv="${BSOD_DET__VM__NAME}-memdump-dv"
  typeset evidenceDv="shared-bsod-evidence-dv"
  # Delete DVs first (they own the PVCs)
  for dv in "${memoryDumpDv}" "${evidenceDv}"; do
    echo "trigger-bsod-intentional: deleting DataVolume ${dv}..."
    timeout --signal=TERM --kill-after=5 60 oc --request-timeout=55s delete dv "${dv}" -n "${ns}" \
      --ignore-not-found=true 2>/dev/null && \
      echo "trigger-bsod-intentional: DataVolume ${dv} deleted" || \
      { storageDeleteStatus=$?; echo "trigger-bsod-intentional: WARN: DataVolume ${dv} deletion failed (non-fatal)"; }
  done
  # Then delete PVCs
  for pvc in "${memoryPvc}" "shared-bsod-evidence"; do
    echo "trigger-bsod-intentional: deleting PVC ${pvc}..."
    timeout --signal=TERM --kill-after=5 60 oc --request-timeout=55s delete pvc "${pvc}" -n "${ns}" \
      --ignore-not-found=true 2>/dev/null && \
      echo "trigger-bsod-intentional: PVC ${pvc} deleted" || \
      { storageDeleteStatus=$?; echo "trigger-bsod-intentional: WARN: PVC ${pvc} deletion failed (non-fatal)"; }
  done
  ((storageDeleteStatus == 0)) || echo "trigger-bsod-intentional: WARN: some storage deletions encountered errors (evidence still exported, cluster may have leftovers)"
}
CleanupTemporaryStorage

true
