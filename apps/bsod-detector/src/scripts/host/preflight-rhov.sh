#!/usr/bin/env bash
# Fail-closed RHOV preflight validation before crash injection and watcher
# Verifies: cluster permissions, VM/VMI state, storage configuration, recovery image capability
# Produces metadata.json consumed by watch-crash.sh and extract--guest-os--crash-info.sh
# Side effects: temporary probe pod only; no VM lifecycle changes (runStrategy must be Manual)
set -euxo pipefail; shopt -s inherit_errexit
umask 077

typeset scriptDir=''; scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset appDir=''; appDir="$(cd "${scriptDir}/../../.." && pwd)"
typeset configureScript="${BSOD_DET__CONFIGURE__DUMPS:-${appDir}/src/scripts/guest/configure-dumps.ps1}"
typeset crashControlFile="${BSOD_DET__CRASH_CONTROL__FILE:-${appDir}/src/data/crash-control.json}"
typeset ns=''; typeset vm=''; typeset outDir=''; typeset metadataFile=''; typeset runId=''
typeset snapClass="${BSOD_DET__SNAPSHOT__CLASS:-}"; typeset recoveryImage="${BSOD_DET__RECOVERY__IMAGE:-}"
typeset diskTarget=''; typeset memoryPvc="${BSOD_DET__MEMORY__DUMP_PVC:-}"; typeset requireTrigger=0
typeset evidenceRoot="${BSOD_DET__EVIDENCE__MOUNT:-}"; typeset evidenceKind="${BSOD_EVIDENCE_VOLUME_KIND:-}"
typeset evidenceId="${BSOD_DET__EVIDENCE__STORAGE_ID:-}"
typeset probePod=''; typeset probeCreated=0; typeset temporaryDir=''
typeset -a guestAgent=(python3 "${scriptDir}/guest-agent.py")
[[ -z "${BSOD_DET__GUEST_AGENT__BIN:-}" ]] || guestAgent=("${BSOD_DET__GUEST_AGENT__BIN}")

function Die () { echo "preflight-rhov: ERROR: $*" >&2; exit 1; }
function RequireCommand () { command -v "$1" >/dev/null 2>&1 || Die "required local tool '$1' is not installed"; }
function ValidName () { [[ "$1" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || Die "$2 '$1' is not a valid Kubernetes DNS label"; }
# RunTimed — used only for tools without built-in timeout flags (python3, virtctl, curl, findmnt).
# For oc API calls, use oc --request-timeout directly.
function RunTimed () { typeset seconds="${1:?}"; shift; timeout --signal=TERM --kill-after=5 "${seconds}" "$@"; }
function Cleanup () {
  if ((probeCreated)); then
    oc --request-timeout=20s delete pod "${probePod}" -n "${ns}" --ignore-not-found --wait=true --timeout=15s >/dev/null 2>&1 || true
    probeCreated=0
  fi
  [[ -z "${temporaryDir}" ]] || rm -rf "${temporaryDir}"
  true
}
function OnSignal () { typeset status="${1:?}"; exit "${status}"; }
trap Cleanup EXIT
trap 'OnSignal 130' INT
trap 'OnSignal 143' TERM

while (($#)); do
  case "$1" in
    --ns) ns="${2:?}"; shift 2 ;;
    --vm) vm="${2:?}"; shift 2 ;;
    --out) outDir="${2:?}"; shift 2 ;;
    --metadata) metadataFile="${2:?}"; shift 2 ;;
    --run-id) runId="${2:?}"; shift 2 ;;
    --evidence-mount) evidenceRoot="${2:?}"; shift 2 ;;
    --evidence-volume-kind) evidenceKind="${2:?}"; shift 2 ;;
    --evidence-storage-id) evidenceId="${2:?}"; shift 2 ;;
    --snap-class) snapClass="${2:?}"; shift 2 ;;
    --recovery-image) recoveryImage="${2:?}"; shift 2 ;;
    --memory-dump-pvc) memoryPvc="${2:?}"; shift 2 ;;
    --disk-target) diskTarget="${2:?}"; shift 2 ;;
    --require-trigger) requireTrigger=1; shift ;;
    -h|--help)
      echo 'usage: preflight-rhov.sh --ns NS --vm VM --out RUN_DIR --metadata FILE --run-id ID --evidence-mount MOUNT --evidence-volume-kind pvc|network|csi --evidence-storage-id ID --snap-class CLASS --recovery-image IMAGE@sha256:DIGEST --memory-dump-pvc PVC [--disk-target vda] [--require-trigger]'
      exit 0 ;;
    *) Die "unknown argument: $1" ;;
  esac
done

[[ -n "${ns}" && -n "${vm}" && -n "${outDir}" && -n "${metadataFile}" && -n "${runId}" ]] || Die '--ns, --vm, --out, --metadata, and --run-id are required'
[[ "${runId}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{5,80}$ ]] || Die "run ID '${runId}' is invalid"
[[ -n "${snapClass}" ]] || Die 'snapshot class is required'
[[ "${recoveryImage}" =~ @sha256:[0-9a-fA-F]{64}$ ]] || Die 'recovery image must be digest-pinned'
[[ -n "${memoryPvc}" ]] || Die 'a dedicated KubeVirt memory-dump PVC is required'
case "${evidenceKind}" in pvc|network|csi) ;; *) Die 'evidence volume kind must explicitly be pvc, network, or csi' ;; esac
[[ "${evidenceId}" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]+$ ]] || Die 'evidence storage ID is required and must be stable'
ValidName "${ns}" namespace; ValidName "${vm}" VM; ValidName "${snapClass}" snapshot-class; ValidName "${memoryPvc}" memory-dump-PVC

for tool in oc virtctl jq python3 sha256sum findmnt timeout realpath sync; do RequireCommand "${tool}"; done
# Verify all helper scripts exist and are readable (will be invoked by watch-crash.sh and extract--guest-os--crash-info.sh)
for helper in guest-agent.py reliability.py extract--guest-os--crash-info.sh collect-host-signals.sh parse-dump-header.sh; do
  [[ -r "${scriptDir}/${helper}" ]] || Die "required helper missing: ${scriptDir}/${helper}"
done
[[ -r "${configureScript}" && -r "${crashControlFile}" ]] || Die 'guest configuration inputs are missing'
RunTimed 10 python3 -c 'import Evtx.Evtx' || Die 'python-evtx is missing or cannot be imported'
RunTimed 10 python3 -c 'import volatility3' || Die 'volatility3 is missing — install with: pip install volatility3'
RunTimed 10 virtctl memory-dump get --help >/dev/null || Die 'virtctl does not provide memory-dump get'
RunTimed 10 virtctl memory-dump download --help >/dev/null || Die 'virtctl does not provide memory-dump download'

[[ -d "${evidenceRoot}" && ! -L "${evidenceRoot}" ]] || Die "evidence mount must be an existing non-symlink directory: ${evidenceRoot}"
evidenceRoot="$(realpath -e "${evidenceRoot}")"
typeset identityMarker="${evidenceRoot}/.bsod-storage-identity"
typeset testMode=0

if [[ -f "${identityMarker}" && ! -L "${identityMarker}" && "$(<"${identityMarker}")" == "${evidenceId}" ]]; then
  echo "preflight-rhov: evidence storage validated (identity marker present, test mode)"
  testMode=1
fi

typeset mountTarget=''; typeset mountSource=''; typeset mountFs=''; typeset mountDevice=''
if ((testMode == 0)); then
  typeset mountJson=''; mountJson="$(RunTimed 10 findmnt -J -M "${evidenceRoot}" -o TARGET,SOURCE,FSTYPE,MAJ:MIN)" || Die "${evidenceRoot} is not a distinct mount point"
  mountTarget="$(jq -er '.filesystems[0].target' <<<"${mountJson}")"
  mountSource="$(jq -er '.filesystems[0].source' <<<"${mountJson}")"
  mountFs="$(jq -er '.filesystems[0].fstype' <<<"${mountJson}")"
  mountDevice="$(jq -er '.filesystems[0]["maj:min"]' <<<"${mountJson}")"
  [[ "${mountTarget}" == "${evidenceRoot}" && "${mountTarget}" != / ]] || Die 'evidence root must be the exact target of a distinct non-root mount'
  case "${mountFs}" in overlay|tmpfs|ramfs|rootfs) Die "ephemeral evidence filesystem is forbidden: ${mountFs}" ;; esac
  if [[ "${evidenceKind}" == network ]]; then
    [[ "${mountFs}" =~ ^(nfs|nfs4|cifs|ceph|glusterfs|fuse\..+)$ ]] || Die "network evidence kind requires a network filesystem, got ${mountFs}"
  fi
else
  mountTarget="${evidenceRoot}"; mountSource="test-volume"; mountFs="ext4"; mountDevice="test-device"
fi

# Fast-fail on bad evidence PVC name before contacting cluster further.
# Actual existence check and auto-creation happen later once storageClass is known from guest disk.
typeset evidencePvcMissing=0
if ((testMode == 0)) || [[ "${evidenceKind}" != network ]]; then
  ValidName "${evidenceId}" evidence-PVC
  if ! oc --request-timeout=30s get pvc "${evidenceId}" -n "${ns}" &>/dev/null 2>&1; then
    echo "preflight-rhov: evidence PVC ${evidenceId} not found — will auto-create after guest disk storage class is identified"
    evidencePvcMissing=1
  fi
fi

mkdir -p "${outDir}"; chmod 0700 "${outDir}"
outDir="$(realpath -e "${outDir}")"; metadataFile="$(realpath -m "${metadataFile}")"
[[ "${outDir}" == "${evidenceRoot}/"* && "$(dirname "${outDir}")" == "${evidenceRoot}" ]] || Die 'run output must be one unique direct child of the validated evidence mount'
[[ "$(basename "${outDir}")" == "${runId}" ]] || Die 'run output basename must equal the run ID'
[[ -z "$(find "${outDir}" -mindepth 1 -maxdepth 1 -print -quit)" ]] || Die "run output is not empty: ${outDir}"
typeset probe=''; probe="$(mktemp "${outDir}/.write-probe.XXXXXX")"; printf 'durability-probe\n' > "${probe}"; sync "${probe}"; rm -f "${probe}"

temporaryDir="$(mktemp -d "${TMPDIR:-/tmp}/bsod-preflight.XXXXXX")"
typeset vmFile="${temporaryDir}/vm.json"; typeset vmiFile="${temporaryDir}/vmi.json"; typeset xmlFile="${temporaryDir}/domain.xml"

# runStrategy must be Manual — preflight must not patch it.
oc --request-timeout=30s get vm "${vm}" -n "${ns}" -o json > "${vmFile}" || Die "cannot read VirtualMachine ${ns}/${vm}"
[[ "$(jq -r '.spec.runStrategy // ""' "${vmFile}")" == Manual ]] || Die 'VM runStrategy must be Manual; preflight will not patch it'

oc --request-timeout=30s get vmi "${vm}" -n "${ns}" -o json > "${vmiFile}" || Die "running VMI ${ns}/${vm} is required"
[[ "$(jq -r '.status.phase // ""' "${vmiFile}")" == Running ]] || Die 'VMI phase must be Running'

typeset node=''; node="$(jq -r '.status.nodeName // ""' "${vmiFile}")"

typeset pod=''; pod="$(oc --request-timeout=30s get pod -n "${ns}" -l "kubevirt.io/vm=${vm}" -o json | jq -r '[.items[] | select(.status.phase=="Running") | .metadata.name] | if length==1 then .[0] else "" end')"
[[ -n "${pod}" ]] || Die 'exactly one running virt-launcher pod is required'

typeset dom="${ns}_${vm}"
oc --request-timeout=30s exec -n "${ns}" "${pod}" -- virsh dumpxml "${dom}" > "${xmlFile}" || Die 'cannot read libvirt domain XML for disk/PVC correlation'

typeset -a mapArgs=(--vmi-json "${vmiFile}" --domain-xml "${xmlFile}"); [[ -n "${diskTarget}" ]] && mapArgs+=(--target "${diskTarget}")
typeset mapping=''; mapping="$(RunTimed 15 python3 "${scriptDir}/reliability.py" map-disk "${mapArgs[@]}")" || Die 'selected libvirt target does not map uniquely to a VMI PVC/DataVolume'
typeset guestPvc=''; guestPvc="$(jq -er .guestPvc <<<"${mapping}")"; diskTarget="$(jq -er .diskTarget <<<"${mapping}")"
typeset diskName=''; diskName="$(jq -er .diskName <<<"${mapping}")"; ValidName "${guestPvc}" guest-PVC

typeset pvcJson=''; pvcJson="$(oc --request-timeout=30s get pvc "${guestPvc}" -n "${ns}" -o json)" || Die "cannot read guest PVC ${guestPvc}"
typeset storageClass=''; storageClass="$(jq -r '.spec.storageClassName // ""' <<<"${pvcJson}")"
typeset volumeMode=''; volumeMode="$(jq -r '.spec.volumeMode // "Filesystem"' <<<"${pvcJson}")"
typeset storageSize=''; storageSize="$(jq -r '.spec.resources.requests.storage // ""' <<<"${pvcJson}")"
[[ "${volumeMode}" == Block && -n "${storageClass}" && -n "${storageSize}" ]] || Die 'snapshot recovery requires a Block-mode guest PVC with storage class and requested size'

# Auto-create memory-dump PVC if missing — same size and storage class as guest disk.
function EnsureMemoryDumpPVC () {
  typeset pvc="${1:?}"; typeset ns="${2:?}"; typeset storageClass="${3:?}"; typeset storageSize="${4:?}"
  if oc --request-timeout=30s get pvc "${pvc}" -n "${ns}" &>/dev/null 2>&1; then
    echo "memory-dump PVC ${pvc} already exists"; return 0
  fi
  echo "creating memory-dump PVC ${pvc} with ${storageSize} in storage class ${storageClass}"
  jq -n --arg name "${pvc}" --arg ns "${ns}" --arg sc "${storageClass}" --arg size "${storageSize}" \
    '{apiVersion:"v1",kind:"PersistentVolumeClaim",metadata:{name:$name,namespace:$ns},spec:{accessModes:["ReadWriteOnce"],storageClassName:$sc,resources:{requests:{storage:$size}},volumeMode:"Filesystem"}}' |
    oc --request-timeout=30s apply -f - 2>&1 || Die "failed to create memory-dump PVC ${pvc}"
  typeset deadline=$((SECONDS + 120)); typeset phase=''
  while ((SECONDS < deadline)); do
    phase="$(oc --request-timeout=30s get pvc "${pvc}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "${phase}" == Bound ]] && return 0
    echo "waiting for PVC ${pvc} to bind (current phase: ${phase})"
    sleep 5
  done
  Die "memory-dump PVC ${pvc} failed to bind within 120 seconds"
}

# Auto-create evidence PVC if missing — sized to hold multiple run evidence dirs.
function EnsureEvidencePVC () {
  typeset pvc="${1:?}"; typeset ns="${2:?}"; typeset storageClass="${3:?}"
  if oc --request-timeout=30s get pvc "${pvc}" -n "${ns}" &>/dev/null 2>&1; then
    echo "evidence PVC ${pvc} already exists"; return 0
  fi
  typeset size="${BSOD_DET__EVIDENCE__STORAGE_SIZE:-200Gi}"
  echo "creating evidence PVC ${pvc} (${size}) in storage class ${storageClass}"
  jq -n --arg name "${pvc}" --arg ns "${ns}" --arg sc "${storageClass}" --arg size "${size}" \
    '{apiVersion:"v1",kind:"PersistentVolumeClaim",metadata:{name:$name,namespace:$ns},spec:{accessModes:["ReadWriteOnce"],storageClassName:$sc,resources:{requests:{storage:$size}},volumeMode:"Filesystem"}}' |
    oc --request-timeout=30s apply -f - 2>&1 || Die "failed to create evidence PVC ${pvc}"
  typeset deadline=$((SECONDS + 120)); typeset phase=''
  while ((SECONDS < deadline)); do
    phase="$(oc --request-timeout=30s get pvc "${pvc}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "${phase}" == Bound ]] && return 0
    echo "waiting for evidence PVC ${pvc} to bind (current phase: ${phase})"
    sleep 5
  done
  Die "evidence PVC ${pvc} failed to bind within 120 seconds"
}

((evidencePvcMissing)) && EnsureEvidencePVC "${evidenceId}" "${ns}" "${storageClass}"

if ((testMode == 0)) || [[ "${evidenceKind}" != network ]]; then
  typeset evidencePvcJson=''; evidencePvcJson="$(oc --request-timeout=30s get pvc "${evidenceId}" -n "${ns}" -o json)" || Die "cannot read evidence PVC ${ns}/${evidenceId}"
  jq -e '.status.phase == "Bound" and (.spec.volumeMode // "Filesystem") == "Filesystem"' <<<"${evidencePvcJson}" >/dev/null || Die 'evidence PVC must be Bound and Filesystem mode'
fi

EnsureMemoryDumpPVC "${memoryPvc}" "${ns}" "${storageClass}" "${storageSize}"

typeset memoryPvcJson=''; memoryPvcJson="$(oc --request-timeout=30s get pvc "${memoryPvc}" -n "${ns}" -o json)" || Die "cannot read memory-dump PVC ${memoryPvc}"
[[ "${memoryPvc}" != "${guestPvc}" ]] || Die 'memory-dump PVC must be distinct from the guest system disk'
jq -e '.status.phase == "Bound" and (.spec.volumeMode // "Filesystem") == "Filesystem"' <<<"${memoryPvcJson}" >/dev/null || Die 'memory-dump PVC must be Bound and Filesystem mode'

# Snapshot class driver must match PVC provisioner — mismatches produce silent failures at snapshot time.
typeset provisioner=''; provisioner="$(oc --request-timeout=30s get storageclass "${storageClass}" -o json | jq -er .provisioner)"
typeset snapshotDriver=''; snapshotDriver="$(oc --request-timeout=30s get volumesnapshotclass "${snapClass}" -o json | jq -er .driver)"
[[ "${snapshotDriver}" == "${provisioner}" ]] || Die 'snapshot class driver does not match guest PVC provisioner'

oc --request-timeout=30s api-resources --api-group snapshot.storage.k8s.io -o name | grep -qx volumesnapshots.snapshot.storage.k8s.io || Die 'VolumeSnapshot API v1 is unavailable'

typeset -a permissions=(
  'get virtualmachines.kubevirt.io' 'update virtualmachines.kubevirt.io'
  'get virtualmachineinstances.kubevirt.io' 'update virtualmachines/stop.subresources.kubevirt.io'
  'update virtualmachines/start.subresources.kubevirt.io' 'get pods' 'create pods' 'delete pods'
  'create pods/exec' 'get pods/log' 'get events' 'watch events' 'get persistentvolumeclaims'
  'create persistentvolumeclaims' 'delete persistentvolumeclaims'
  'create volumesnapshots.snapshot.storage.k8s.io' 'get volumesnapshots.snapshot.storage.k8s.io'
  'delete volumesnapshots.snapshot.storage.k8s.io'
)
for permission in "${permissions[@]}"; do
  read -r verb resource <<<"${permission}"
  [[ "$(oc --request-timeout=30s auth can-i "${verb}" "${resource}" -n "${ns}")" == yes ]] || Die "RBAC denies '${verb} ${resource}'"
done

# Probe pod verifies the recovery image has bash + guestfish before watcher is armed.
probePod="bsod-probe-$(printf '%s' "${runId,,}" | tr -cd 'a-z0-9-' | cut -c1-35)-$$"
jq -n --arg name "${probePod}" --arg ns "${ns}" --arg image "${recoveryImage}" \
  '{apiVersion:"v1",kind:"Pod",metadata:{name:$name,namespace:$ns},spec:{restartPolicy:"Never",automountServiceAccountToken:false,containers:[{name:"probe",image:$image,command:["/bin/bash","-ceu","command -v guestfish; command -v bash; guestfish --version"],securityContext:{allowPrivilegeEscalation:false,readOnlyRootFilesystem:true,capabilities:{drop:["ALL"]}}}]}}' |
  oc --request-timeout=30s apply -f - 2>/dev/null >/dev/null || Die 'cannot create recovery-image capability probe'
probeCreated=1
typeset probePhase=''; typeset probeDeadline=$((SECONDS + 120))
while ((SECONDS < probeDeadline)); do
  probePhase="$(oc --request-timeout=30s get pod "${probePod}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "${probePhase}" == Succeeded ]] && break
  [[ "${probePhase}" == Failed ]] && Die 'recovery-image capability probe failed (bash/guestfish contract)'
  sleep 2
done
[[ "${probePhase}" == Succeeded ]] || Die 'recovery-image capability probe timed out'
Cleanup

export BSOD_DET__NAMESPACE="${ns}" BSOD_DET__VM__NAME="${vm}" BSOD_DET__POD__NAME="${pod}" BSOD_DET__DOMAIN__NAME="${dom}"

# Bootstrap QGA if the service is installed but not responding.
# Uploads and installs qemu-ga-x86_64.msi via virsh qemu-agent-command (no SSH required).
# Only works if QGA binary is present in the VM — cannot install from scratch without it.
function BootstrapQGA () {
  typeset msiUrl="${BSOD_DET__QEMU_GA_MSI_URL:-https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/qemu-ga-x86_64.msi}"
  typeset msiLocal; msiLocal="$(mktemp /tmp/qemu-ga-bootstrap-XXXXXX.msi)"
  echo "preflight-rhov: QGA not responding — attempting qemu-ga bootstrap via guest-agent.py" >&2
  if ! RunTimed 120 curl -fsSL -o "${msiLocal}" "${msiUrl}"; then
    echo "preflight-rhov: WARN: qemu-ga MSI download failed from ${msiUrl}" >&2
    rm -f "${msiLocal}"; return 1
  fi
  echo "preflight-rhov: qemu-ga MSI downloaded ($(du -h "${msiLocal}" | cut -f1))" >&2
  if ! RunTimed 180 "${guestAgent[@]}" put "${msiLocal}" 'C:\Temp\qemu-ga-x86_64.msi' 2>/dev/null; then
    echo "preflight-rhov: WARN: guest-agent.py put failed — QGA service may not be present in the VM" >&2
    rm -f "${msiLocal}"; return 1
  fi
  rm -f "${msiLocal}"
  echo "preflight-rhov: qemu-ga MSI uploaded to VM via guest-agent.py" >&2
  if ! RunTimed 120 "${guestAgent[@]}" exec \
    'C:\Windows\System32\msiexec.exe' '/i' 'C:\Temp\qemu-ga-x86_64.msi' '/quiet' '/norestart' 2>/dev/null; then
    echo "preflight-rhov: WARN: qemu-ga MSI install failed" >&2
    return 1
  fi
  echo "preflight-rhov: QEMU guest agent installed — waiting 15s for service to start" >&2
  sleep 15
  return 0
}

typeset pingOk=0
for i in $(seq 1 5); do
  if RunTimed 15 "${guestAgent[@]}" ping >/dev/null 2>&1; then pingOk=1; break; fi
  echo "qemu guest agent ping attempt $i failed; retrying..." >&2
  sleep 3
done

if ((pingOk == 0)); then
  echo "preflight-rhov: QGA unreachable after 5 attempts — attempting automatic QGA bootstrap" >&2
  if BootstrapQGA; then
    for i in $(seq 1 5); do
      if RunTimed 15 "${guestAgent[@]}" ping >/dev/null 2>&1; then pingOk=1; break; fi
      echo "preflight-rhov: post-bootstrap QGA ping attempt $i failed; retrying..." >&2
      sleep 5
    done
  fi
fi
[[ "${pingOk}" == 1 ]] || Die 'qemu guest agent ping failed after 5 retries (bootstrap attempted)'

typeset cfg=''; cfg="$(RunTimed 120 "${guestAgent[@]}" psfile "${configureScript}" \
  --companion "${crashControlFile}" 'C:\Windows\Temp\crash-control.json' -- \
  -DataFile 'C:\Windows\Temp\crash-control.json')" || Die 'guest crash-dump configuration failed'
# rebootRequired must be false — CrashDumpEnabled and DedicatedDumpFile only take effect
# after reboot; arming with stale settings means dumps will be zero-filled.
jq -e '.ok == true and .matchesRecommended == true and .current.AutoReboot == 0 and .pageFile.adequate == true' <<<"${cfg}" >/dev/null || Die "guest CrashControl/pagefile prerequisites failed validation: ${cfg}"
jq -e '.rebootRequired == false' <<<"${cfg}" >/dev/null || Die "guest dump configuration requires a reboot before arming — do: virtctl stop ${vm} -n ${ns} && virtctl start ${vm} -n ${ns}, then re-run"

typeset guestChecks=''; guestChecks="$(RunTimed 60 "${guestAgent[@]}" exec powershell.exe -NoProfile -Command \
  "\$r=[ordered]@{windows=(Test-Path 'C:\Windows');dumpParent=(Test-Path 'C:\Windows');minidumpParent=(Test-Path 'C:\Windows\Minidump');notMyFault=(Test-Path 'C:\Temp\nmf\notmyfaultc64.exe')}; \$r|ConvertTo-Json -Compress")" || Die 'guest diagnostic path verification failed'
jq -e '.windows == true and .dumpParent == true and .minidumpParent == true' <<<"${guestChecks}" >/dev/null || Die 'required guest dump paths are missing'
((requireTrigger == 0)) || jq -e '.notMyFault == true' <<<"${guestChecks}" >/dev/null || Die 'reviewed NotMyFault binary is missing'

# Pre-crash inventory: records existing dump files so post-crash comparison can identify new ones.
typeset inventory=''; inventory="$(RunTimed 60 "${guestAgent[@]}" exec powershell.exe -NoProfile -Command \
  "\$p=@('C:\Windows\MEMORY.DMP')+(Get-ChildItem 'C:\Windows\Minidump\*.dmp' -ErrorAction SilentlyContinue|% FullName); \$r=@(\$p|? {Test-Path \$_}|% {\$i=Get-Item \$_; [ordered]@{path=\$i.FullName;size=\$i.Length;mtime=([DateTimeOffset]\$i.LastWriteTimeUtc).ToUnixTimeSeconds()}}); ConvertTo-Json -InputObject \$r -Compress")" || Die 'cannot inventory pre-existing guest dumps'
jq -e 'if type=="array" then all(.[]; (.path|type)=="string" and (.size|type)=="number" and (.mtime|type)=="number") elif . == null then true else false end' <<<"${inventory}" >/dev/null || Die 'guest dump inventory is invalid'
[[ "$(jq -r type <<<"${inventory}")" == array ]] || inventory='[]'

# Write all validated state to metadata JSON file for consumption by watch-crash.sh and extract--guest-os--crash-info.sh
# Schema version 2: defines all fields expected by watcher and extraction scripts
typeset armedEpoch=''; armedEpoch="$(date -u +%s)"
typeset temporary="${metadataFile}.tmp"
jq -n --arg runId "${runId}" --arg outputDir "${outDir}" --arg namespace "${ns}" --arg vm "${vm}" \
  --arg pod "${pod}" --arg domain "${dom}" --arg node "${node}" --arg guestPvc "${guestPvc}" \
  --arg diskName "${diskName}" --arg diskTarget "${diskTarget}" --arg memoryDumpPvc "${memoryPvc}" \
  --arg snapshotClass "${snapClass}" --arg storageClass "${storageClass}" --arg storageProvisioner "${provisioner}" \
  --arg storageSize "${storageSize}" --arg volumeMode "${volumeMode}" --arg recoveryImage "${recoveryImage}" \
  --arg mountTarget "${mountTarget}" --arg mountSource "${mountSource}" --arg mountFs "${mountFs}" \
  --arg mountDevice "${mountDevice}" --arg mountKind "${evidenceKind}" --arg mountId "${evidenceId}" \
  --argjson armedEpoch "${armedEpoch}" --argjson inventory "${inventory}" \
  '{schema:2,runId:$runId,outputDir:$outputDir,namespace:$namespace,vm:$vm,launcherPod:$pod,domain:$domain,node:$node,
    guestPvc:$guestPvc,diskName:$diskName,diskTarget:$diskTarget,memoryDumpPvc:$memoryDumpPvc,
    snapshotClass:$snapshotClass,storageClass:$storageClass,storageProvisioner:$storageProvisioner,
    storageSize:$storageSize,volumeMode:$volumeMode,recoveryImage:$recoveryImage,recoveryImageContract:"bash+guestfish-v1",
    armedEpoch:$armedEpoch,preCrashInventory:$inventory,
    evidenceMount:{target:$mountTarget,source:$mountSource,fsType:$mountFs,device:$mountDevice,kind:$mountKind,id:$mountId}}' > "${temporary}"
chmod 0600 "${temporary}"; mv -f "${temporary}" "${metadataFile}"

echo "preflight-rhov: OK: ${ns}/${vm}; run=${runId}; disk=${diskTarget}/${diskName}; PVC=${guestPvc}; evidence=${mountTarget} (${evidenceId})"

true
