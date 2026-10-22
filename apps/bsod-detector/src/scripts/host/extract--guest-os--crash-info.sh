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
    }
done

typeset k=''
typeset -A fldChk=(
    [runId]=.runId
    [outDir]=.outputDir
    [ns]=.namespace
    [vm]=.vm
    [guestPVC]=.guestPvc
)
for k in "${!fldChk[@]}"; do
    eval "typeset ${k}=''"
    typeset -n varRef="${k}"
    varRef="$(
        jq -er \
            "
                ${fldChk[${k}]}"' |
                select((type == "string") and (length > 0))
            ' \
            "${metadataFile}"
    )" || {
        : "Missing \`${fldChk[${k}]}\` in metadata."
        false
    }
done
unset -n varRef
mkdir -p "${outDir}" || { : "Cannot create output directory: ${outDir}"; false; }

# Watcher-owned captures may exist, but extraction must not overwrite stale data.
typeset stale=''
stale="$(find -H "${outDir}" -mindepth 1 \( -name MEMORY.DMP -o -name Minidump -o -name 'guestFS_*' -o -name events.json -o -name extraction-summary.json -o -name checksums.sha256 \) -print -quit)"
[ -z "${stale}" ] || { : "Pre-existing extraction artifact rejected: ${stale}"; false; }

typeset helperPod='' container='libguestfs'

function Cleanup () {
    [ -z "${helperPod}" ] || {
        oc -n "${ns}" delete "pod/${helperPod}" \
            --ignore-not-found
        oc -n "${ns}" wait "pod/${helperPod}" \
            --for=delete \
            --timeout=60s
    }
    true
}

trap Cleanup EXIT

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
}
attachedVmis="$(jq -r --arg pvc "${guestPVC}" '
  .items[] | select(
    (.status.phase == "Running") and
    (.spec.volumes // [] | map(.persistentVolumeClaim.claimName // "", .dataVolume.name // "") | any(. == $pvc))
  ) | .metadata.name' 0<<<"${vmiJson}")" || {
    : 'Cannot parse VMI list — PVC attachment state uncertain.'
    false
}
[ -z "${attachedVmis}" ]

helperPod="guestfs-ntfs-$(date -u +%s)-$$"
typeset guestfsImage="${BSOD_DET__GUESTFS__NTFS_IMAGE:-quay.io/konveyor/oadp-vmfr-access:latest}"
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
  }' | oc apply -f -

oc --request-timeout=185s wait pod "${helperPod}" -n "${ns}" --for=jsonpath='{.status.phase}'=Running --timeout=180s
oc exec -n "${ns}" "${helperPod}" -c "${container}" -- \
    guestfish --ro -a /dev/vda run : list-filesystems

typeset -a evtxArr=(
    '/Windows/System32/winevt/Logs/System.evtx'
    '/Windows/System32/winevt/Logs/Application.evtx'
)
typeset ntfsPart='' ntfsOutput=''
ntfsOutput="$(FindNTFS)"
# One QEMU session per partition avoids repeated startup OOMs. Copy each result
# independently: a missing Application.evtx must not discard a valid System.evtx.
while IFS= read -r ntfsPart; do
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
        guestfish "${batchArr[@]}" || true

    typeset -i index=0
    for filePath in "${evtxArr[@]}"; do
        podTemp="${tempArr[${index}]}"
        index+=1
        typeset dest="${outDir}/guestFS_${partId}${filePath}"
        mkdir -p "${dest%/*}"
        if oc cp "${ns}/${helperPod}:${podTemp}" "${dest}" -c "${container}" && [ -s "${dest}" ]; then
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
done 0<<< "${ntfsOutput}"

if [ ! -s "${outDir}/parse-dump-header.json" ]; then
    jq -n '{"ok":true,"totalDumps":0,"dumps":[],"warnings":["no on-disk dump available; primary artifact is vm-memory.elf.tar.gz"]}' \
        1> "${outDir}/parse-dump-header.json"
    chmod 0600 "${outDir}/parse-dump-header.json"
fi
jq -e '.ok == true' "${outDir}/parse-dump-header.json" 1> /dev/null
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
Cleanup
timeout --signal=TERM --kill-after=5 60 python3 "${scrDir}/reliability.py" write-summary \
    --out "${outDir}" --stage-errors "${outDir}/stage-errors.jsonl" --mode rhov-snapshot-recovery \
    --vm "${vm}" --namespace "${ns}" --run-id "${runId}" --filename extraction-summary.json 1> /dev/null || exit 1
exit 0
