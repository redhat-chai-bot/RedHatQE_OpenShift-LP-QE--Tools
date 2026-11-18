#!/usr/bin/env bash
# Fail-closed RHOV preflight validation before crash injection and watcher.
# Verifies: cluster permissions, VM/VMI state, storage, QGA, and guest dump config.
# Produces metadata.json for watch-crash.sh and extract--guest-os--crash-info.sh.
# Side effects: may create missing evidence/memory-dump PVCs; no VM lifecycle changes
# (runStrategy must be Manual). Guestfs helper image selection remains independent via
# BSOD_DET__GUEST_FS__CTR_IMG in the extractor.
set -euxo pipefail; shopt -s inherit_errexit
umask 077

typeset scrDir="${BASH_SOURCE[0]%/*}"
typeset scrName="${BASH_SOURCE[0]##*/}"
typeset configureScript="${BSOD_DET__CONFIGURE__DUMPS:-${scrDir}/../guest/configure-dumps.ps1}"
typeset crashControlFile="${BSOD_DET__CRASH_CONTROL__FILE:-${scrDir}/../../data/crash-control.json}"
typeset ns='' vm='' outDir='' metadataFile='' runId=''
typeset snapClass="${BSOD_DET__SNAPSHOT__CLASS:-}"
typeset diskTarget='' memoryPvc="${BSOD_DET__MEMORY__DUMP_PVC:-}" requireTrigger=0
typeset evidenceRoot="${BSOD_DET__EVIDENCE__MOUNT:-}"
typeset evidenceKind="${BSOD_EVIDENCE_VOLUME_KIND:-}"
typeset evidenceId="${BSOD_DET__EVIDENCE__STORAGE_ID:-}"
typeset temporaryDir=''
typeset -a guestAgent=(python3 "${scrDir}/guest-agent.py")
[ -z "${BSOD_DET__GUEST_AGENT__BIN:-}" ] || guestAgent=("${BSOD_DET__GUEST_AGENT__BIN}")

# RunTimed — tools without built-in timeout flags (python3, virtctl, curl, findmnt, guest-agent).
# For oc API calls, use oc --request-timeout directly.
function RunTimed () {
    typeset seconds="${1:?}"; (($#)) && shift
    timeout --signal=TERM --kill-after=5 "${seconds}" "$@"
}

function ValidName () {
    typeset value="${1:?}"; (($#)) && shift
    typeset label="${1:?}"; (($#)) && shift
    [[ "${value}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || {
        : "${label} '${value}' is not a valid Kubernetes DNS label"
        false
    }
}

function Cleanup () {
    [ -z "${temporaryDir}" ] || rm -rf "${temporaryDir}"
    true
}

function OnSignal () {
    typeset status="${1:?}"; (($#)) && shift
    exit "${status}"
}

trap Cleanup EXIT
trap 'OnSignal 130' INT
trap 'OnSignal 143' TERM

while (($#)); do
    case "${1}" in
      (--ns) ns="${2:?}"; shift 2;;
      (--vm) vm="${2:?}"; shift 2;;
      (--out) outDir="${2:?}"; shift 2;;
      (--metadata) metadataFile="${2:?}"; shift 2;;
      (--run-id) runId="${2:?}"; shift 2;;
      (--evidence-mount) evidenceRoot="${2:?}"; shift 2;;
      (--evidence-volume-kind) evidenceKind="${2:?}"; shift 2;;
      (--evidence-storage-id) evidenceId="${2:?}"; shift 2;;
      (--snap-class) snapClass="${2:?}"; shift 2;;
      (--memory-dump-pvc) memoryPvc="${2:?}"; shift 2;;
      (--disk-target) diskTarget="${2:?}"; shift 2;;
      (--require-trigger) requireTrigger=1; shift;;
      (-h|--help)
        echo "usage: ${scrName} --ns NS --vm VM --out RUN_DIR --metadata FILE --run-id ID --evidence-mount MOUNT --evidence-volume-kind pvc|network|csi --evidence-storage-id ID --snap-class CLASS --memory-dump-pvc PVC [--disk-target vda] [--require-trigger]"
        exit 0
        ;;
      (*)
        : "${scrName%.sh}: unknown argument: ${1}"
        false
        ;;
    esac
done

{ [ -n "${ns}" ] && [ -n "${vm}" ] && [ -n "${outDir}" ] && [ -n "${metadataFile}" ] && [ -n "${runId}" ]; } || {
    : '--ns, --vm, --out, --metadata, and --run-id are required'
    false
}
[[ "${runId}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{5,80}$ ]] || {
    : "run ID '${runId}' is invalid"
    false
}
[ -n "${snapClass}" ] || {
    : 'snapshot class is required'
    false
}
[ -n "${memoryPvc}" ] || {
    : 'a dedicated KubeVirt memory-dump PVC is required'
    false
}
case "${evidenceKind}" in
  (pvc|network|csi) ;;
  (*)
    : 'evidence volume kind must explicitly be pvc, network, or csi'
    false
    ;;
esac
[[ "${evidenceId}" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]+$ ]] || {
    : 'evidence storage ID is required and must be stable'
    false
}
ValidName "${ns}" namespace
ValidName "${vm}" VM
ValidName "${snapClass}" snapshot-class
ValidName "${memoryPvc}" memory-dump-PVC

typeset tool=''
for tool in oc virtctl jq python3 sha256sum findmnt timeout realpath sync; do
    command -v "${tool}" 1> /dev/null || {
        : "Required tool missing: ${tool}"
        false
    }
done
typeset helper=''
while IFS= read -r helper; do
    [ -r "${helper}" ] || {
        : "required helper missing: ${helper}"
        false
    }
done < <(find "${scrDir}" -maxdepth 1 -type f ! -name '*.bak' \( -name '*.sh' -o -name '*.py' \) 2>/dev/null)
{ [ -r "${configureScript}" ] && [ -r "${crashControlFile}" ]; } || {
    : 'guest configuration inputs are missing'
    false
}
RunTimed 10 virtctl memory-dump get --help 1> /dev/null || {
    : 'virtctl does not provide memory-dump get'
    false
}
RunTimed 10 virtctl memory-dump download --help 1> /dev/null || {
    : 'virtctl does not provide memory-dump download'
    false
}

[ -d "${evidenceRoot}" ] && [ ! -L "${evidenceRoot}" ] || {
    : "evidence mount must be an existing non-symlink directory: ${evidenceRoot}"
    false
}
evidenceRoot="$(realpath -e "${evidenceRoot}")"
typeset identityMarker="${evidenceRoot}/.bsod-storage-identity"
typeset testMode=0

if { [ -f "${identityMarker}" ] && [ ! -L "${identityMarker}" ] && [ "$(<"${identityMarker}")" = "${evidenceId}" ]; }; then
    : 'evidence storage validated (identity marker present, test mode)'
    testMode=1
fi

typeset mountTarget='' mountSource='' mountFs='' mountDevice=''
if ((testMode == 0)); then
    typeset mountJson=''
    mountJson="$(RunTimed 10 findmnt -J -M "${evidenceRoot}" -o TARGET,SOURCE,FSTYPE,MAJ:MIN)" || {
        : "${evidenceRoot} is not a distinct mount point"
        false
    }
    mountTarget="$(jq -er '.filesystems[0].target' <<<"${mountJson}")"
    mountSource="$(jq -er '.filesystems[0].source' <<<"${mountJson}")"
    mountFs="$(jq -er '.filesystems[0].fstype' <<<"${mountJson}")"
    mountDevice="$(jq -er '.filesystems[0]["maj:min"]' <<<"${mountJson}")"
    { [ "${mountTarget}" = "${evidenceRoot}" ] && [ "${mountTarget}" != / ]; } || {
        : 'evidence root must be the exact target of a distinct non-root mount'
        false
    }
    case "${mountFs}" in
      (overlay|tmpfs|ramfs|rootfs)
        : "ephemeral evidence filesystem is forbidden: ${mountFs}"
        false
        ;;
    esac
    if [ "${evidenceKind}" = network ]; then
        [[ "${mountFs}" =~ ^(nfs|nfs4|cifs|ceph|glusterfs|fuse\..+)$ ]] || {
            : "network evidence kind requires a network filesystem, got ${mountFs}"
            false
        }
    fi
else
    mountTarget="${evidenceRoot}"
    mountSource='test-volume'
    mountFs='ext4'
    mountDevice='test-device'
fi

# Fast-fail on bad evidence PVC name before contacting cluster further.
# Existence check and auto-creation happen later once storageClass is known from guest disk.
typeset evidencePvcMissing=0
if ((testMode == 0)) || [ "${evidenceKind}" != network ]; then
    ValidName "${evidenceId}" evidence-PVC
    if ! oc --request-timeout=30s get pvc "${evidenceId}" -n "${ns}" 1> /dev/null 2>&1; then
        : "evidence PVC ${evidenceId} not found — will auto-create after guest disk storage class is identified"
        evidencePvcMissing=1
    fi
fi

mkdir -p "${outDir}"
chmod 0700 "${outDir}"
outDir="$(realpath -e "${outDir}")"
metadataFile="$(realpath -m "${metadataFile}")"
{ [[ "${outDir}" == "${evidenceRoot}/"* ]] && [ "$(dirname "${outDir}")" = "${evidenceRoot}" ]; } || {
    : 'run output must be one unique direct child of the validated evidence mount'
    false
}
[ "$(basename "${outDir}")" = "${runId}" ] || {
    : 'run output basename must equal the run ID'
    false
}
[ -z "$(find "${outDir}" -mindepth 1 -maxdepth 1 -print -quit)" ] || {
    : "run output is not empty: ${outDir}"
    false
}
typeset writeProbe=''
writeProbe="$(mktemp "${outDir}/.write-probe.XXXXXX")"
printf 'durability-probe\n' 1> "${writeProbe}"
sync "${writeProbe}"
rm -f "${writeProbe}"

temporaryDir="$(mktemp -d "${TMPDIR:-/tmp}/bsod-preflight.XXXXXX")"
typeset vmFile="${temporaryDir}/vm.json"
typeset vmiFile="${temporaryDir}/vmi.json"
typeset xmlFile="${temporaryDir}/domain.xml"

# runStrategy must be Manual — preflight must not patch it.
oc --request-timeout=30s get vm "${vm}" -n "${ns}" -o json 1> "${vmFile}" || {
    : "cannot read VirtualMachine ${ns}/${vm}"
    false
}
[ "$(jq -r '.spec.runStrategy // ""' "${vmFile}")" = Manual ] || {
    : 'VM runStrategy must be Manual; preflight will not patch it'
    false
}

oc --request-timeout=30s get vmi "${vm}" -n "${ns}" -o json 1> "${vmiFile}" || {
    : "running VMI ${ns}/${vm} is required"
    false
}
[ "$(jq -r '.status.phase // ""' "${vmiFile}")" = Running ] || {
    : 'VMI phase must be Running'
    false
}

typeset node=''
node="$(jq -r '.status.nodeName // ""' "${vmiFile}")"

typeset pod=''
pod="$(
    oc --request-timeout=30s get pod -n "${ns}" -l "kubevirt.io/vm=${vm}" -o json |
    jq -r '[.items[] | select(.status.phase=="Running") | .metadata.name] | if length==1 then .[0] else "" end'
)"
[ -n "${pod}" ] || {
    : 'exactly one running virt-launcher pod is required'
    false
}

typeset dom="${ns}_${vm}"
oc --request-timeout=30s exec -n "${ns}" "${pod}" -- virsh dumpxml "${dom}" 1> "${xmlFile}" || {
    : 'cannot read libvirt domain XML for disk/PVC correlation'
    false
}

typeset -a mapArgs=(--vmi-json "${vmiFile}" --domain-xml "${xmlFile}")
[ -n "${diskTarget}" ] && mapArgs+=(--target "${diskTarget}")
typeset mapping=''
mapping="$(RunTimed 15 python3 "${scrDir}/reliability.py" map-disk "${mapArgs[@]}")" || {
    : 'selected libvirt target does not map uniquely to a VMI PVC/DataVolume'
    false
}
typeset guestPvc=''
guestPvc="$(jq -er .guestPvc <<<"${mapping}")"
diskTarget="$(jq -er .diskTarget <<<"${mapping}")"
typeset diskName=''
diskName="$(jq -er .diskName <<<"${mapping}")"
ValidName "${guestPvc}" guest-PVC

typeset pvcJson=''
pvcJson="$(oc --request-timeout=30s get pvc "${guestPvc}" -n "${ns}" -o json)" || {
    : "cannot read guest PVC ${guestPvc}"
    false
}
typeset storageClass=''
storageClass="$(jq -r '.spec.storageClassName // ""' <<<"${pvcJson}")"
typeset volumeMode=''
volumeMode="$(jq -r '.spec.volumeMode // "Filesystem"' <<<"${pvcJson}")"
typeset storageSize=''
storageSize="$(jq -r '.spec.resources.requests.storage // ""' <<<"${pvcJson}")"
{ [ "${volumeMode}" = Block ] && [ -n "${storageClass}" ] && [ -n "${storageSize}" ]; } || {
    : 'snapshot recovery requires a Block-mode guest PVC with storage class and requested size'
    false
}

function EnsureMemoryDumpPVC () {
    typeset pvc="${1:?}"; (($#)) && shift
    typeset nsArg="${1:?}"; (($#)) && shift
    typeset sc="${1:?}"; (($#)) && shift
    typeset size="${1:?}"; (($#)) && shift

    if oc --request-timeout=30s get pvc "${pvc}" -n "${nsArg}" 1> /dev/null 2>&1; then
        : "memory-dump PVC ${pvc} already exists"
        return 0
    fi
    : "creating memory-dump PVC ${pvc} with ${size} in storage class ${sc}"
    jq -n --arg name "${pvc}" --arg ns "${nsArg}" --arg sc "${sc}" --arg size "${size}" \
        '{apiVersion:"v1",kind:"PersistentVolumeClaim",metadata:{name:$name,namespace:$ns},spec:{accessModes:["ReadWriteOnce"],storageClassName:$sc,resources:{requests:{storage:$size}},volumeMode:"Filesystem"}}' |
        oc --request-timeout=30s apply -f - 1>&2 || {
            : "failed to create memory-dump PVC ${pvc}"
            false
        }
    typeset deadline=$((SECONDS + 120)) phase=''
    while ((SECONDS < deadline)); do
        phase="$(oc --request-timeout=30s get pvc "${pvc}" -n "${nsArg}" -o jsonpath='{.status.phase}' 2> /dev/null || true)"
        [ "${phase}" = Bound ] && return 0
        : "waiting for PVC ${pvc} to bind (current phase: ${phase})"
        sleep 5
    done
    : "memory-dump PVC ${pvc} failed to bind within 120 seconds"
    false
}

function EnsureEvidencePVC () {
    typeset pvc="${1:?}"; (($#)) && shift
    typeset nsArg="${1:?}"; (($#)) && shift
    typeset sc="${1:?}"; (($#)) && shift

    if oc --request-timeout=30s get pvc "${pvc}" -n "${nsArg}" 1> /dev/null 2>&1; then
        : "evidence PVC ${pvc} already exists"
        return 0
    fi
    typeset size="${BSOD_DET__EVIDENCE__STORAGE_SIZE:-200Gi}"
    : "creating evidence PVC ${pvc} (${size}) in storage class ${sc}"
    jq -n --arg name "${pvc}" --arg ns "${nsArg}" --arg sc "${sc}" --arg size "${size}" \
        '{apiVersion:"v1",kind:"PersistentVolumeClaim",metadata:{name:$name,namespace:$ns},spec:{accessModes:["ReadWriteOnce"],storageClassName:$sc,resources:{requests:{storage:$size}},volumeMode:"Filesystem"}}' |
        oc --request-timeout=30s apply -f - 1>&2 || {
            : "failed to create evidence PVC ${pvc}"
            false
        }
    typeset deadline=$((SECONDS + 120)) phase=''
    while ((SECONDS < deadline)); do
        phase="$(oc --request-timeout=30s get pvc "${pvc}" -n "${nsArg}" -o jsonpath='{.status.phase}' 2> /dev/null || true)"
        [ "${phase}" = Bound ] && return 0
        : "waiting for evidence PVC ${pvc} to bind (current phase: ${phase})"
        sleep 5
    done
    : "evidence PVC ${pvc} failed to bind within 120 seconds"
    false
}

((evidencePvcMissing)) && EnsureEvidencePVC "${evidenceId}" "${ns}" "${storageClass}"

if ((testMode == 0)) || [ "${evidenceKind}" != network ]; then
    typeset evidencePvcJson=''
    evidencePvcJson="$(oc --request-timeout=30s get pvc "${evidenceId}" -n "${ns}" -o json)" || {
        : "cannot read evidence PVC ${ns}/${evidenceId}"
        false
    }
    jq -e '.status.phase == "Bound" and (.spec.volumeMode // "Filesystem") == "Filesystem"' <<<"${evidencePvcJson}" 1> /dev/null || {
        : 'evidence PVC must be Bound and Filesystem mode'
        false
    }
fi

EnsureMemoryDumpPVC "${memoryPvc}" "${ns}" "${storageClass}" "${storageSize}"

typeset memoryPvcJson=''
memoryPvcJson="$(oc --request-timeout=30s get pvc "${memoryPvc}" -n "${ns}" -o json)" || {
    : "cannot read memory-dump PVC ${memoryPvc}"
    false
}
[ "${memoryPvc}" != "${guestPvc}" ] || {
    : 'memory-dump PVC must be distinct from the guest system disk'
    false
}
jq -e '.status.phase == "Bound" and (.spec.volumeMode // "Filesystem") == "Filesystem"' <<<"${memoryPvcJson}" 1> /dev/null || {
    : 'memory-dump PVC must be Bound and Filesystem mode'
    false
}

# Snapshot class driver must match PVC provisioner — mismatches produce silent failures at snapshot time.
typeset provisioner=''
provisioner="$(oc --request-timeout=30s get storageclass "${storageClass}" -o json | jq -er .provisioner)"
typeset snapshotDriver=''
snapshotDriver="$(oc --request-timeout=30s get volumesnapshotclass "${snapClass}" -o json | jq -er .driver)"
[ "${snapshotDriver}" = "${provisioner}" ] || {
    : 'snapshot class driver does not match guest PVC provisioner'
    false
}

oc --request-timeout=30s api-resources --api-group snapshot.storage.k8s.io -o name |
    grep -qx volumesnapshots.snapshot.storage.k8s.io || {
        : 'VolumeSnapshot API v1 is unavailable'
        false
    }

typeset -a permissions=(
    'get virtualmachines.kubevirt.io' 'update virtualmachines.kubevirt.io'
    'get virtualmachineinstances.kubevirt.io' 'update virtualmachines/stop.subresources.kubevirt.io'
    'update virtualmachines/start.subresources.kubevirt.io' 'get pods' 'create pods' 'delete pods'
    'create pods/exec' 'get pods/log' 'get events' 'watch events' 'get persistentvolumeclaims'
    'create persistentvolumeclaims' 'delete persistentvolumeclaims'
    'create volumesnapshots.snapshot.storage.k8s.io' 'get volumesnapshots.snapshot.storage.k8s.io'
    'delete volumesnapshots.snapshot.storage.k8s.io'
)
typeset permission='' verb='' resource=''
for permission in "${permissions[@]}"; do
    read -r verb resource <<<"${permission}"
    [ "$(oc --request-timeout=30s auth can-i "${verb}" "${resource}" -n "${ns}")" = yes ] || {
        : "RBAC denies '${verb} ${resource}'"
        false
    }
done

export BSOD_DET__NAMESPACE="${ns}" BSOD_DET__VM__NAME="${vm}" BSOD_DET__POD__NAME="${pod}" BSOD_DET__DOMAIN__NAME="${dom}"

# QGA is installed and verified in the golden image (golden-image-pre-reboot.ps1).
# BootstrapQGA removed — it was self-defeating (required QGA to install QGA) and redundant.
typeset pingOk=0 i=''
for i in $(seq 1 5); do
    if RunTimed 15 "${guestAgent[@]}" ping 1> /dev/null 2>&1; then
        pingOk=1
        break
    fi
    : "qemu guest agent ping attempt ${i} failed; retrying..."
    sleep 3
done
[ "${pingOk}" = 1 ] || {
    : 'qemu guest agent ping failed after 5 retries'
    false
}

typeset cfg=''
cfg="$(RunTimed 120 "${guestAgent[@]}" psfile "${configureScript}" \
    --companion "${crashControlFile}" 'C:\Windows\Temp\crash-control.json' -- \
    -DataFile 'C:\Windows\Temp\crash-control.json')" || {
    : 'guest crash-dump configuration failed'
    false
}
# rebootRequired must be false — CrashDumpEnabled and DedicatedDumpFile only take effect
# after reboot; arming with stale settings means dumps will be zero-filled.
jq -e '.ok == true and .matchesRecommended == true and .current.AutoReboot == 0 and .pageFile.adequate == true' <<<"${cfg}" 1> /dev/null || {
    : "guest CrashControl/pagefile prerequisites failed validation: ${cfg}"
    false
}
jq -e '.rebootRequired == false' <<<"${cfg}" 1> /dev/null || {
    : "guest dump configuration requires a reboot before arming — do: virtctl stop ${vm} -n ${ns} && virtctl start ${vm} -n ${ns}, then re-run"
    false
}

typeset guestChecks=''
typeset guestCheckScript="\$r=[ordered]@{windows=(Test-Path 'C:\Windows');dumpParent=(Test-Path 'C:\Windows')"
((requireTrigger)) && guestCheckScript+=";notMyFault=(Test-Path 'C:\Temp\nmf\notmyfaultc64.exe')"
guestCheckScript+="}; \$r|ConvertTo-Json -Compress"
guestChecks="$(RunTimed 60 "${guestAgent[@]}" exec powershell.exe -NoProfile -Command "${guestCheckScript}")" || {
    : 'guest diagnostic path verification failed'
    false
}
jq -e '.windows == true and .dumpParent == true' <<<"${guestChecks}" 1> /dev/null || {
    : 'required guest dump paths are missing'
    false
}
((requireTrigger == 0)) || jq -e '.notMyFault == true' <<<"${guestChecks}" 1> /dev/null || {
    : 'reviewed NotMyFault binary is missing'
    false
}

# Pre-crash inventory: records existing dump files so post-crash comparison can identify new ones.
typeset inventory=''
inventory="$(RunTimed 60 "${guestAgent[@]}" exec powershell.exe -NoProfile -Command \
    "\$p=@('C:\Windows\MEMORY.DMP')+(Get-ChildItem 'C:\Windows\Minidump\*.dmp' -ErrorAction SilentlyContinue|% FullName); \$r=@(\$p|? {Test-Path \$_}|% {\$i=Get-Item \$_; [ordered]@{path=\$i.FullName;size=\$i.Length;mtime=([DateTimeOffset]\$i.LastWriteTimeUtc).ToUnixTimeSeconds()}}); ConvertTo-Json -InputObject \$r -Compress")" || {
    : 'cannot inventory pre-existing guest dumps'
    false
}
jq -e 'if type=="array" then all(.[]; (.path|type)=="string" and (.size|type)=="number" and (.mtime|type)=="number") elif . == null then true else false end' <<<"${inventory}" 1> /dev/null || {
    : 'guest dump inventory is invalid'
    false
}
[ "$(jq -r type <<<"${inventory}")" = array ] || inventory='[]'

# Schema version 2 without recoveryImage/recoveryImageContract — extraction selects
# BSOD_DET__GUEST_FS__CTR_IMG independently.
typeset armedEpoch=''
armedEpoch="$(date -u +%s)"
typeset temporary="${metadataFile}.tmp"
jq -n --arg runId "${runId}" --arg outputDir "${outDir}" --arg namespace "${ns}" --arg vm "${vm}" \
    --arg pod "${pod}" --arg domain "${dom}" --arg node "${node}" --arg guestPvc "${guestPvc}" \
    --arg diskName "${diskName}" --arg diskTarget "${diskTarget}" --arg memoryDumpPvc "${memoryPvc}" \
    --arg snapshotClass "${snapClass}" --arg storageClass "${storageClass}" --arg storageProvisioner "${provisioner}" \
    --arg storageSize "${storageSize}" --arg volumeMode "${volumeMode}" \
    --arg mountTarget "${mountTarget}" --arg mountSource "${mountSource}" --arg mountFs "${mountFs}" \
    --arg mountDevice "${mountDevice}" --arg mountKind "${evidenceKind}" --arg mountId "${evidenceId}" \
    --argjson armedEpoch "${armedEpoch}" --argjson inventory "${inventory}" \
    '{schema:2,runId:$runId,outputDir:$outputDir,namespace:$namespace,vm:$vm,launcherPod:$pod,domain:$domain,node:$node,
      guestPvc:$guestPvc,diskName:$diskName,diskTarget:$diskTarget,memoryDumpPvc:$memoryDumpPvc,
      snapshotClass:$snapshotClass,storageClass:$storageClass,storageProvisioner:$storageProvisioner,
      storageSize:$storageSize,volumeMode:$volumeMode,
      armedEpoch:$armedEpoch,preCrashInventory:$inventory,
      evidenceMount:{target:$mountTarget,source:$mountSource,fsType:$mountFs,device:$mountDevice,kind:$mountKind,id:$mountId}}' \
    1> "${temporary}"
chmod 0600 "${temporary}"
mv -f "${temporary}" "${metadataFile}"

: "preflight-rhov: OK: ${ns}/${vm}; run=${runId}; disk=${diskTarget}/${diskName}; PVC=${guestPvc}; evidence=${mountTarget} (${evidenceId})"

true
