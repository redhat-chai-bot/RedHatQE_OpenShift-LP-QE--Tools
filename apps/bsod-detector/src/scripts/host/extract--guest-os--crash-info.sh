#!/usr/bin/env bash
# Read offline Windows event logs after watch-crash.sh stops the VM.
set -euxo pipefail; shopt -s inherit_errexit
umask 077

typeset scrDir="${BASH_SOURCE[0]%/*}"
typeset scrName="${BASH_SOURCE[0]##*/}"
typeset metadataFile='' outDir=''

while (($#)); do
    case "${1}" in
        (--metadata)    metadataFile="${2:?}"; shift 2;;
        (-h|--help)
            echo "usage: ${scrName} --metadata PRE_STOP_METADATA.json"
            exit 0
            ;;
        (*) echo "${scrName%.sh}: unknown argument: ${1}" 1>&2; exit 2;;
    esac
done
[ -r "${metadataFile}" ] || {
    echo "${scrName%.sh}: --metadata is required and must be readable" 1>&2
    exit 2
}

typeset tool=''
for tool in oc jq python3 sha256sum timeout; do
    command -v "${tool}" 1> /dev/null || {
        : "Required tool missing: ${tool}"
        false
        exit 1
    }
done

typeset runId='' ns='' vm='' guestPVC='' field=''
typeset -A fieldArr=([runId]=runId [outDir]=outputDir [ns]=namespace [vm]=vm [guestPVC]=guestPvc)
for field in "${!fieldArr[@]}"; do
    typeset -n fieldRef="${field}"
    fieldRef="$(jq -er --arg key "${fieldArr[${field}]}" \
        '.[$key] | select((type == "string") and (length > 0))' "${metadataFile}")" ||
        { : "Metadata lacks a non-empty string: ${fieldArr[${!fieldRef}]}"; false; exit 1; }
done
unset -n fieldRef
mkdir -p "${outDir}" || { : "Cannot create output directory: ${outDir}"; false; exit 1; }

# Watcher-owned captures may exist, but extraction must not overwrite stale data.
typeset stale=''
stale="$(find -H "${outDir}" -mindepth 1 \( -name MEMORY.DMP -o -name Minidump -o -name 'guestFS_*' -o -name events.json -o -name extraction-summary.json -o -name checksums.sha256 \) -print -quit)"
[ -z "${stale}" ] || { : "Pre-existing extraction artifact rejected: ${stale}"; false; exit 1; }

typeset stageErrors="${outDir}/stage-errors.jsonl"
touch "${stageErrors}"
chmod 0600 "${stageErrors}"
typeset extractLog="${outDir}/extraction.log"
: 1> "${extractLog}"
chmod 0600 "${extractLog}"
typeset -i hasPod=0 isClean=0
typeset helperPod='' container='libguestfs'

function RecordError () {
    typeset stage="${1:?}" at=''
    shift
    at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq -cn --arg stage "${stage}" --arg error "$*" --arg at "${at}" \
        '{stage:$stage,error:$error,at:$at}' 1>> "${stageErrors}"
    echo "${scrName%.sh}: ERROR [${stage}]: $*" 1>&2
    return 0
}

function Cleanup () {
    ((isClean == 0)) || return 0
    isClean=1
    typeset -i status=0
    if ((hasPod)); then
        timeout --signal=TERM --kill-after=5 70 oc --request-timeout=65s \
            delete pod "${helperPod}" -n "${ns}" --ignore-not-found --wait=false 1>> "${extractLog}" 2>&1 || {
            RecordError cleanup "failed to delete guestfs-ntfs pod ${helperPod}"
            status=1
        }
        timeout --signal=TERM --kill-after=5 70 oc --request-timeout=65s \
            wait pod "${helperPod}" -n "${ns}" --for=delete --timeout=60s 1>> "${extractLog}" 2>&1 || {
            RecordError cleanup "failed waiting for guestfs-ntfs pod ${helperPod} deletion"
            status=1
        }
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
    output="$()" || return 1
    typeset -a partArr=()

    while IFS=': ' read -r device fsType; do
        if [ -n "${device}" ] && [ "${fsType}" = ntfs ]; then
            partArr+=("${device}")
        fi
    done 0< <(
        oc -n "${ns}" exec \
            "${helperPod}" \
            -c "${container}" \
            -- \
            guestfish \
            --ro \
            -a /dev/vda \
            run : list-filesystems
    )
    ((${#partArr[@]}))
    printf '%s\n' "${partArr[@]}"

    true
}

# Uncertain attachment state must block extraction, including DataVolume references.
typeset vmiJson='' attachedVmis=''
vmiJson="$(oc get vmi -n "${ns}" -o json)" || {
    : "Cannot list VMIs in namespace ${ns} — API error prevents safe PVC attachment verification."
    false
    exit 1
}
attachedVmis="$(jq -r --arg pvc "${guestPVC}" '
  .items[] | select(
    (.status.phase == "Running") and
    (.spec.volumes // [] | map(.persistentVolumeClaim.claimName // "", .dataVolume.name // "") | any(. == $pvc))
  ) | .metadata.name' 0<<<"${vmiJson}")" || {
    : 'Cannot parse VMI list — PVC attachment state uncertain.'
    false
    exit 1
}
if [ -n "${attachedVmis}" ]; then
    RecordError extraction 'source PVC is attached to a VMI (direct or DataVolume); cannot safely mount'
    exit 1
fi

typeset suffix=''
suffix="$(date -u +%s)-$$"
helperPod="guestfs-ntfs-${suffix}"
typeset guestfsImage="${BSOD_DET__GUESTFS__NTFS_IMAGE:-quay.io/konveyor/oadp-vmfr-access:latest}"
hasPod=1
jq -n --arg name "${helperPod}" --arg ns "${ns}" --arg image "${guestfsImage}" --arg pvc "${guestPVC}" '
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
  }' | oc apply -f - 1>> "${extractLog}"

oc --request-timeout=185s wait pod "${helperPod}" -n "${ns}" --for=jsonpath='{.status.phase}'=Running --timeout=180s 1>> "${extractLog}" 2>&1 || {
    RecordError extraction-pod "guestfs-ntfs pod '${helperPod}' startup timed out"
    exit 1
}
oc exec -n "${ns}" "${helperPod}" -c "${container}" -- \
    guestfish --ro -a /dev/vda run : list-filesystems 1>> "${extractLog}" 2>&1 || {
    RecordError extraction-pod 'guestfish not available or block device not accessible'
    exit 1
}

typeset -a ntfsArr=() evtxArr=(
    '/Windows/System32/winevt/Logs/System.evtx'
    '/Windows/System32/winevt/Logs/Application.evtx'
)
typeset ntfsPart='' ntfsOutput=''
ntfsOutput="$(FindNTFS)" || {
    RecordError extraction 'NTFS discovery failed or found no NTFS partitions'
    exit 1
}
while IFS= read -r ntfsPart; do
    ntfsArr+=("${ntfsPart}")
done 0<<< "${ntfsOutput}"

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
    oc exec -n "${ns}" "${helperPod}" -c "${container}" -- \
        guestfish "${batchArr[@]}" 1>> "${extractLog}" 2>&1 || true

    typeset -i index=0
    for filePath in "${evtxArr[@]}"; do
        podTemp="${tempArr[${index}]}"
        index+=1
        typeset dest="${outDir}/guestFS_${partId}${filePath}"
        mkdir -p "${dest%/*}"
        if oc cp "${ns}/${helperPod}:${podTemp}" "${dest}" -c "${container}" 2>> "${extractLog}" && [ -s "${dest}" ]; then
            chmod 0600 "${dest}"
            hasLogs=1
        else
            rm -f "${dest}" || true
        fi
        oc exec -n "${ns}" "${helperPod}" -c "${container}" -- rm -f "${podTemp}" || true
    done
    if ((hasLogs)); then
        break
    fi
done

# On-disk dump extraction and EVTX conversion remain disabled; preserve the
# watcher parser result, or emit the existing offline-analysis stubs.
typeset -i parseStatus=0
if [ -s "${outDir}/parse-dump-header.json" ]; then
    :
elif [ -s "${outDir}/MEMORY.DMP" ]; then
    timeout --signal=TERM --kill-after=5 60 bash "${scrDir}/parse-dump-header.sh" "${outDir}/MEMORY.DMP" \
        1> "${outDir}/parse-dump-header.json" 2>> "${extractLog}" || parseStatus=$?
elif [ -d "${outDir}/Minidump" ]; then
    timeout --signal=TERM --kill-after=5 60 bash "${scrDir}/parse-dump-header.sh" --dir "${outDir}/Minidump" \
        1> "${outDir}/parse-dump-header.json" 2>> "${extractLog}" || parseStatus=$?
else
    jq -n '{"ok":true,"totalDumps":0,"dumps":[],"warnings":["no on-disk dump available; primary artifact is vm-memory.elf.tar.gz"]}' \
        1> "${outDir}/parse-dump-header.json"
    chmod 0600 "${outDir}/parse-dump-header.json"
fi
if ((parseStatus != 0)) || ! jq -e '.ok == true' "${outDir}/parse-dump-header.json" 1> /dev/null; then
    RecordError dump-parse 'dump parser failed or reported semantic failure'
    exit 1
fi
jq -n '{"ok":true,"note":"extract-evtx.py is a developer tool — run offline against guestFS_<partition>/Windows/System32/winevt/Logs/*.evtx","events":[]}' \
    1> "${outDir}/events.json"
chmod 0600 "${outDir}/events.json"

(
    cd "${outDir}"
    # Canonical relative paths; logs/errors/summaries can still change during cleanup.
    find . \( -type f -o -type l \) ! -name '*.tmp' ! -name '*.log' ! -name stage-errors.jsonl ! -name '*-summary.json' ! -name checksums.sha256 -print0 |
        sort -z | xargs -0 sha256sum | sed 's|  \./|  |' 1> checksums.sha256.tmp
    mv -f checksums.sha256.tmp checksums.sha256
    chmod 0600 checksums.sha256
    exit 0
)
typeset -i cleanupStatus=0 summaryStatus=0
Cleanup || cleanupStatus=$?
timeout --signal=TERM --kill-after=5 60 python3 "${scrDir}/reliability.py" write-summary \
    --out "${outDir}" --stage-errors "${stageErrors}" --mode rhov-snapshot-recovery \
    --vm "${vm}" --namespace "${ns}" --run-id "${runId}" --filename extraction-summary.json 1> /dev/null || summaryStatus=$?
((cleanupStatus == 0 && summaryStatus == 0)) || exit 1
exit 0
