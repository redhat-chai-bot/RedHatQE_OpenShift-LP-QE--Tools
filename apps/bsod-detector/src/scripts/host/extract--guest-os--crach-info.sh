#!/usr/bin/env bash
# Read offline Windows event logs after watch-crash.sh stops the VM.
set -euxo pipefail; shopt -s inherit_errexit
umask 077

typeset scriptDir=''
scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset metadataFile='' outDir=''
typeset cmdTimeout="${BSOD_DET__COMMAND__TIMEOUT:-30}"

while (($#)); do
  case "${1}" in
    --metadata) metadataFile="${2:?}"; shift 2 ;;
    --out) outDir="${2:?}"; shift 2 ;;
    -h|--help)
      echo 'usage: extract--guest-os--crach-info.sh --metadata PRE_STOP_METADATA.json --out VALIDATED_RUN_DIR'
      exit 0
      ;;
    *) echo "extract--guest-os--crach-info: unknown argument: ${1}" >&2; exit 2 ;;
  esac
done
[[ -r "${metadataFile}" && -n "${outDir}" ]] || {
  echo 'extract--guest-os--crach-info: --metadata and --out are required' >&2
  exit 2
}

function Die () {
  echo "extract--guest-os--crach-info: ERROR: $*" >&2
  exit 1
}

function Oc () {
  # Exec streams need a process deadline; API requests have their own timeout.
  if [[ "${1}" == exec ]]; then
    timeout --signal=TERM --kill-after=5 "${cmdTimeout}" \
      oc --request-timeout="${cmdTimeout}s" "$@" || return $?
  else
    oc --request-timeout="${cmdTimeout}s" "$@" || return $?
  fi
  return 0
}

typeset tool=''
for tool in oc jq python3 sha256sum findmnt timeout realpath; do
  command -v "${tool}" >/dev/null || Die "required tool missing: ${tool}"
done

typeset runId='' expectedOut=''
runId="$(jq -er .runId "${metadataFile}")"
expectedOut="$(jq -er .outputDir "${metadataFile}")"
outDir="$(realpath -e "${outDir}")"
[[ "${outDir}" == "${expectedOut}" && "${outDir##*/}" == "${runId}" ]] || Die 'output path/run ID does not match preflight metadata'
[[ ! -L "${outDir}" ]] || Die 'output path must not be a symlink'

typeset mountTarget='' storageId=''
mountTarget="$(jq -er .evidenceMount.target "${metadataFile}")"
case "$(jq -r .evidenceMount.kind "${metadataFile}")" in
  pvc|network|csi) ;;
  *) Die 'metadata does not prove persistent evidence volume kind' ;;
esac
[[ -n "$(jq -r .evidenceMount.id "${metadataFile}")" ]] || Die 'metadata lacks stable evidence storage ID'
storageId="$(jq -er .evidenceMount.id "${metadataFile}")"
typeset marker="${mountTarget}/.bsod-storage-identity"

# An identity marker permits the preflight test/dev storage contract.
if [[ ! -f "${marker}" || -L "${marker}" || "$(<"${marker}")" != "${storageId}" ]]; then
  typeset mountJson='' actualMount='' expectedMount=''
  mountJson="$(timeout --signal=TERM --kill-after=5 10 findmnt -J -M "${mountTarget}" -o TARGET,SOURCE,FSTYPE,MAJ:MIN)" || Die 'validated evidence mount is no longer mounted'
  actualMount="$(jq -c '.filesystems[0] | {target:.target,source:.source,fsType:.fstype,device:.["maj:min"]}' <<<"${mountJson}")"
  expectedMount="$(jq -c '.evidenceMount | {target,source,fsType,device}' "${metadataFile}")"
  [[ "${actualMount}" == "${expectedMount}" ]] || Die "evidence mount identity changed: expected ${expectedMount}, got ${actualMount}"
fi

# Watcher-owned captures may exist, but extraction must not overwrite stale data.
typeset stale=''
stale="$(find "${outDir}" -mindepth 1 \( -name MEMORY.DMP -o -name Minidump -o -name 'guestFS_*' -o -name events.json -o -name extraction-summary.json -o -name checksums.sha256 \) -print -quit)"
[[ -z "${stale}" ]] || Die "pre-existing extraction artifact rejected: ${stale}"

typeset ns='' vm='' guestPvc='' image=''
ns="$(jq -er .namespace "${metadataFile}")"
vm="$(jq -er .vm "${metadataFile}")"
guestPvc="$(jq -er .guestPvc "${metadataFile}")"
image="$(jq -er .recoveryImage "${metadataFile}")"
typeset field=''
for field in snapshotClass storageClass storageSize volumeMode armedEpoch; do
  jq -er ".${field}" "${metadataFile}" >/dev/null
done
jq -c .preCrashInventory "${metadataFile}" >/dev/null
[[ "${image}" =~ @sha256:[0-9a-fA-F]{64}$ && "$(jq -r .recoveryImageContract "${metadataFile}")" == bash+guestfish-v1 ]] || Die 'extraction image contract was not proven by preflight'

typeset stageErrors="${outDir}/stage-errors.jsonl"
touch "${stageErrors}"
chmod 0600 "${stageErrors}"
typeset extractLog="${outDir}/extraction.log"
: > "${extractLog}"
chmod 0600 "${extractLog}"
typeset -i hasPod=0 isClean=0
typeset pod='' container='libguestfs'

function RecordError () {
  typeset stage="${1:?}" at=''
  shift
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -cn --arg stage "${stage}" --arg error "$*" --arg at "${at}" \
    '{stage:$stage,error:$error,at:$at}' >> "${stageErrors}"
  echo "extract--guest-os--crach-info: ERROR [${stage}]: $*" >&2
  return 0
}

function Cleanup () {
  ((isClean == 0)) || return 0
  isClean=1
  typeset -i status=0
  if ((hasPod)); then
    if Oc get pod "${pod}" -n "${ns}" >/dev/null; then
      # Allow the 60s deletion wait to finish before the transport/process deadlines.
      timeout --signal=TERM --kill-after=5 70 oc --request-timeout=65s \
        delete pod "${pod}" -n "${ns}" --wait=true --timeout=60s >>"${extractLog}" 2>&1 || {
        RecordError cleanup "failed to delete guestfs-ntfs pod ${pod}"
        status=1
      }
    fi
    hasPod=0
  fi
  return "${status}"
}

function OnSignal () {
  typeset -i status="${1:?}"
  RecordError interrupted "received signal; exiting with status ${status}"
  exit "${status}"
}
trap Cleanup EXIT
trap 'OnSignal 130' INT
trap 'OnSignal 143' TERM

function FindNTFS () {
  typeset output='' device='' fsType=''
  output="$(Oc exec -n "${ns}" "${pod}" -c "${container}" -- \
    guestfish --ro -a /dev/vda run : list-filesystems 2>>"${extractLog}")" || return 1
  typeset -a partArr=()
  while IFS=': ' read -r device fsType; do
    if [[ -n "${device}" && "${fsType}" == ntfs ]]; then
      partArr+=("${device}")
    fi
  done <<< "${output}"
  ((${#partArr[@]})) || return 1
  printf '%s\n' "${partArr[@]}"
  return 0
}

# Uncertain attachment state must block extraction, including DataVolume references.
typeset vmiJson='' attachedVmis=''
vmiJson="$(Oc get vmi -n "${ns}" -o json)" || Die "cannot list VMIs in namespace ${ns} — API error prevents safe PVC attachment verification"
attachedVmis="$(jq -r --arg pvc "${guestPvc}" '
  .items[] | select(
    .status.phase == "Running" and
    (.spec.volumes // [] | map(.persistentVolumeClaim.claimName // "", .dataVolume.name // "") | any(. == $pvc))
  ) | .metadata.name' <<<"${vmiJson}")" || Die 'cannot parse VMI list — PVC attachment state uncertain'
if [[ -n "${attachedVmis}" ]]; then
  RecordError extraction 'source PVC is attached to a VMI (direct or DataVolume); cannot safely mount'
  exit 1
fi

typeset suffix=''
suffix="$(date -u +%s)-$$"
pod="guestfs-ntfs-${suffix}"
typeset guestfsImage="${BSOD_DET__GUESTFS__NTFS_IMAGE:-quay.io/konveyor/oadp-vmfr-access:latest}"
jq -n --arg name "${pod}" --arg ns "${ns}" --arg image "${guestfsImage}" --arg pvc "${guestPvc}" '
  {
    apiVersion:"v1", kind:"Pod",
    metadata:{name:$name,namespace:$ns,labels:{app:"bsod-guestfs-extraction"}},
    spec:{
      restartPolicy:"Never", automountServiceAccountToken:false,
      securityContext:{runAsNonRoot:true,fsGroup:1000800000,seccompProfile:{type:"RuntimeDefault"}},
      nodeSelector:{"kubernetes.io/arch":"amd64"},
      containers:[{
        name:"libguestfs", image:$image, imagePullPolicy:"Always",
        command:["/bin/bash","-c","set -euxo pipefail; shopt -s inherit_errexit; exec tail -f /dev/null"],
        env:[
          {name:"LIBGUESTFS_BACKEND",value:"direct"},
          {name:"LIBGUESTFS_BACKEND_SETTINGS",value:"force_tcg"},
          {name:"LIBGUESTFS_TMPDIR",value:"/tmp/guestfs"},
          {name:"LIBGUESTFS_CACHEDIR",value:"/tmp/guestfs"},
          {name:"HOME",value:"/home/guestfs"}
        ],
        securityContext:{allowPrivilegeEscalation:false,capabilities:{drop:["ALL"]}},
        resources:{requests:{memory:"512Mi",cpu:"500m"},limits:{memory:"2Gi",cpu:"2000m"}},
        volumeDevices:[{name:"guest-disk",devicePath:"/dev/vda"}],
        volumeMounts:[{name:"guestfs-tmp",mountPath:"/tmp/guestfs"},{name:"guestfs-home",mountPath:"/home/guestfs"}],
        workingDir:"/tmp/guestfs"
      }],
      volumes:[
        {name:"guest-disk",persistentVolumeClaim:{claimName:$pvc,readOnly:true}},
        {name:"guestfs-tmp",emptyDir:{}}, {name:"guestfs-home",emptyDir:{}}
      ]
    }
  }' | Oc apply -f - >>"${extractLog}"

hasPod=1
oc --request-timeout=185s wait pod "${pod}" -n "${ns}" --for=jsonpath='{.status.phase}'=Running --timeout=180s >>"${extractLog}" 2>&1 || {
  RecordError extraction-pod "guestfs-ntfs pod '${pod}' startup timed out"
  exit 1
}
Oc exec -n "${ns}" "${pod}" -c "${container}" -- \
  guestfish --ro -a /dev/vda run : list-filesystems >>"${extractLog}" 2>&1 || {
  RecordError extraction-pod 'guestfish not available or block device not accessible'
  exit 1
}

typeset -a ntfsArr=() evtxArr=(
  '/Windows/System32/winevt/Logs/System.evtx'
  '/Windows/System32/winevt/Logs/Application.evtx'
)
typeset ntfsPart=''
while IFS= read -r ntfsPart; do
  ntfsArr+=("${ntfsPart}")
done < <(FindNTFS)

# One QEMU session per partition avoids repeated startup OOMs. Copy each result
# independently: a missing Application.evtx must not discard a valid System.evtx.
for ntfsPart in "${ntfsArr[@]}"; do
  typeset partId="${ntfsPart##*/}"
  typeset -i hasLogs=0
  typeset -a tempArr=() batchArr=(--ro -a /dev/vda run : mount-ro "${ntfsPart}" /)
  typeset filePath='' podTemp=''
  for filePath in "${evtxArr[@]}"; do
    podTemp="/tmp/bsod-evtx-$$-${RANDOM}.bin"
    batchArr+=(: download "${filePath}" "${podTemp}")
    tempArr+=("${podTemp}")
  done
  batchArr+=(: umount-all)
  Oc exec -n "${ns}" "${pod}" -c "${container}" -- \
    guestfish "${batchArr[@]}" >>"${extractLog}" 2>&1 || true

  typeset -i index=0
  for filePath in "${evtxArr[@]}"; do
    podTemp="${tempArr[${index}]}"
    index+=1
    typeset dest="${outDir}/guestFS_${partId}${filePath}"
    mkdir -p "${dest%/*}"
    if oc cp "${ns}/${pod}:${podTemp}" "${dest}" -c "${container}" 2>>"${extractLog}" && [[ -s "${dest}" ]]; then
      chmod 0600 "${dest}"
      hasLogs=1
    else
      rm -f "${dest}" || true
    fi
    Oc exec -n "${ns}" "${pod}" -c "${container}" -- rm -f "${podTemp}" || true
  done
  if ((hasLogs)); then
    break
  fi
done

# On-disk dump extraction and EVTX conversion remain disabled; preserve the
# watcher parser result, or emit the existing offline-analysis stubs.
typeset -i parseStatus=0
if [[ -s "${outDir}/parse-dump-header.json" ]]; then
  :
elif [[ -s "${outDir}/MEMORY.DMP" ]]; then
  timeout --signal=TERM --kill-after=5 60 bash "${scriptDir}/parse-dump-header.sh" "${outDir}/MEMORY.DMP" \
    > "${outDir}/parse-dump-header.json" 2>>"${extractLog}" || parseStatus=$?
elif [[ -d "${outDir}/Minidump" ]]; then
  timeout --signal=TERM --kill-after=5 60 bash "${scriptDir}/parse-dump-header.sh" --dir "${outDir}/Minidump" \
    > "${outDir}/parse-dump-header.json" 2>>"${extractLog}" || parseStatus=$?
else
  jq -n '{"ok":true,"totalDumps":0,"dumps":[],"warnings":["no on-disk dump available; primary artifact is vm-memory.elf.tar.gz"]}' \
    > "${outDir}/parse-dump-header.json"
  chmod 0600 "${outDir}/parse-dump-header.json"
fi
if ((parseStatus != 0)) || ! jq -e '.ok == true' "${outDir}/parse-dump-header.json" >/dev/null; then
  RecordError dump-parse 'dump parser failed or reported semantic failure'
  exit 1
fi
jq -n '{"ok":true,"note":"extract-evtx.py is a developer tool — run offline against guestFS_<partition>/Windows/System32/winevt/Logs/*.evtx","events":[]}' \
  > "${outDir}/events.json"
chmod 0600 "${outDir}/events.json"

(
  cd "${outDir}"
  # Canonical relative paths; logs/errors/summaries can still change during cleanup.
  find . \( -type f -o -type l \) ! -name '*.tmp' ! -name '*.log' ! -name stage-errors.jsonl ! -name '*-summary.json' ! -name checksums.sha256 -print0 |
    sort -z | xargs -0 sha256sum | sed 's|  \./|  |' > checksums.sha256.tmp
  mv -f checksums.sha256.tmp checksums.sha256
  chmod 0600 checksums.sha256
  exit 0
)
typeset -i cleanupStatus=0 summaryStatus=0
Cleanup || cleanupStatus=$?
timeout --signal=TERM --kill-after=5 60 python3 "${scriptDir}/reliability.py" write-summary \
  --out "${outDir}" --stage-errors "${stageErrors}" --mode rhov-snapshot-recovery \
  --vm "${vm}" --namespace "${ns}" --run-id "${runId}" --filename extraction-summary.json >/dev/null || summaryStatus=$?
((cleanupStatus == 0 && summaryStatus == 0)) || exit 1
exit 0
