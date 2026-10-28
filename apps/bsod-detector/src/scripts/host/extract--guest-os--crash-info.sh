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
            echo "usage: ${scrName} --metadata METADATA.json"
            exit 0
            ;;
        (*) echo "${scrName%.sh}: unknown argument: ${1}" 1>&2; exit 2;;
    esac
done
[ -r "${metadataFile}" ] || {
    echo "${scrName%.sh}: \`--metadata\` is required and must be readable" 1>&2
    exit 2
}

typeset tool=''
for tool in oc jq; do
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
mkdir -p "${outDir}" || {
    : "Cannot create output directory: ${outDir}"
    false
}

function FindNTFS () {
    typeset podName="${1:?}"; (($#)) && shift
    typeset ctrName="${1:?}"; (($#)) && shift

    typeset blkDev='' fsType=''
    typeset -a partArr=()

    while IFS=': ' read -r blkDev fsType; do
        if { [ -n "${blkDev}" ] && [ "${fsType}" = ntfs ]; } then
            partArr+=("${blkDev}")
        fi
    done 0< <(
        oc -n "${ns}" exec \
            "${podName}" \
            -c "${ctrName}" \
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

function Cleanup () {
    typeset podName="${1:?}"; (($#)) && shift
    [ -z "${podName}" ] || {
        oc -n "${ns}" delete "pod/${podName}" \
            --ignore-not-found
        oc -n "${ns}" wait "pod/${podName}" \
            --for=delete \
            --timeout=60s
    }
    true
}

typeset helperPod="guest-fs--ntfs--$(date -u +'%s')-$$"
typeset helperPodCtr='libguestfs'
trap 'Cleanup "${helperPod}"' EXIT

jq -es '
    ((length == 1) and (.[0].status.printableStatus == "Stopped"))
' 0< <(
    oc -n "${ns}" get vm/"${vm}" -o json
) 1> /dev/null

{
    oc create -f - --dry-run=client -o json --save-config |
    jq -c \
        --arg name "${helperPod}" \
        --arg ns "${ns}" \
        --arg ctrName "${helperPodCtr}" \
        --arg ctrImg "${BSOD_DET__GUEST_FS__CTR_IMG:-quay.io/konveyor/oadp-vmfr-access:latest}" \
        --arg pvc "${guestPVC}" \
        '
            .metadata|=(
                .name=$name |
                .namespace=$ns
            ) |
            .spec|=(
                .containers[0]|=(
                    .name=$ctrName |
                    .image=$ctrImg
                ) |
                .volumes[0].persistentVolumeClaim.claimName=$pvc
            )
        '
} 0<<'ocEOF' | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  labels:
    app: bsod--guest-fs--extraction
  name: guest-fs--ntfs
  namespace: ''
spec:
  automountServiceAccountToken: false
  containers:
    - name: ''
      image: ''
      imagePullPolicy: Always
      command:
        - /bin/bash
        - -c
      args:
        - exec tail -f /dev/null
      workingDir: /tmp/guestfs
      env:
        - name: LIBGUESTFS_BACKEND
          value: direct
        - name: LIBGUESTFS_BACKEND_SETTINGS
          value: force_kvm
        - name: LIBGUESTFS_TMPDIR
          value: /tmp/guestfs
        - name: LIBGUESTFS_CACHEDIR
          value: /tmp/guestfs
        - name: HOME
          value: /home/guestfs
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop:
            - ALL
      resources:
        requests:
          memory: 512Mi
          cpu: 500m
          devices.kubevirt.io/kvm: "1"
        limits:
          memory: 2Gi
          cpu: 2000m
          devices.kubevirt.io/kvm: "1"
      volumeDevices:
        - name: vm-disk
          devicePath: /dev/vda
      volumeMounts:
        - name: guest-fs--tmp
          mountPath: /tmp/guestfs
        - name: guest-fs--home
          mountPath: /home/guestfs
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  volumes:
    - name: vm-disk
      persistentVolumeClaim:
        claimName: ''
        readOnly: true
    - name: guest-fs--tmp
      emptyDir: {}
    - name: guest-fs--home
      emptyDir: {}
ocEOF

oc -n "${ns}" wait "pod/${helperPod}" \
    --for=condition=Ready \
    --timeout=180s 1> /dev/null

typeset -A fileArr=(
    [/pagefile.sys]='/MEMORY.DMP'
    [/Windows/System32/winevt/Logs/System.evtx]=''
    [/Windows/System32/winevt/Logs/Application.evtx]=''
)
typeset ntfsPart=''
while IFS= read -r ntfsPart; do
    # ntfsPart: /dev/sda<N>
    # Copy file independently.
    typeset podTmp="/tmp/bsod--guest-files--$(date -u +'%s')"
    typeset src='' dst=''

    {
        oc -n "${ns}" exec "pod/${helperPod}" \
            -c "${helperPodCtr}" \
            -- \
            guestfish \
            -ra /dev/vda \
            set-program virt-sh \
            : run \
            : mount-ro "${ntfsPart}" / \
            : ls /Windows \
            : umount-all ||
        continue
    }
    for src in "${!fileArr[@]}"; do
        dst="${fileArr[${src}]:-${src}}"
        src="/${src#/}"
        while [[ "${src}" == */ ]]; do src="${src%/}"; done
        dst="${podTmp}/${dst#/}"
        while [[ "${dst}" == */ ]]; do dst="${dst%/}"; done
        {
            oc -n "${ns}" exec "pod/${helperPod}" \
                -c "${helperPodCtr}" \
                -- \
                bash -o pipefail -O inherit_errexit -euxc '
                    typeset ntfsPart="${1:?}"; (($#)) && shift
                    typeset src="${1:?}"; (($#)) && shift
                    typeset dst="${1:?}"; (($#)) && shift

                    mkdir -p "${dst%/*}"
                    (
                        exec -a virt-sh guestfish \
                            -ra /dev/vda \
                            run \
                            : mount-ro "${ntfsPart}" / \
                            : copy-out "${src}" "${dst%/*}" \
                            : umount-all
                    )
                    [ "${src##*/}" = "${dst##*/}" ] ||
                    mv -T -- "${dst%/*}/${src##*/}" "${dst}"

                    true
                ' '' "${ntfsPart}" "${src}" "${dst}" ||
            continue
        }
    done
    {
        oc -n "${ns}" exec \
            "pod/${helperPod}" \
            -c "${helperPodCtr}" \
            -- \
            test -d "${podTmp}/" &&
        {
            oc -n "${ns}" exec "pod/${helperPod}" \
                -c "${helperPodCtr}" \
                -- \
                tar zc -C "${podTmp}/" ./ \
                1> "${outDir}/guest-fs--crash-info--${ntfsPart##*/}.tgz"
            break
        }
    }
done 0< <(FindNTFS "${helperPod}" "${helperPodCtr}")

# Python Code to parse MEMORY.DMP
# Revisit summary validation when reliability.py is refactored.
# timeout --signal=TERM --kill-after=5 60 python3 "${scrDir}/reliability.py" write-summary \
#     --out "${outDir}" --stage-errors "${outDir}/stage-errors.jsonl" --mode rhov-snapshot-recovery \
#     --vm "${vm}" --namespace "${ns}" --run-id "${runId}" --filename extraction-summary.json 1> /dev/null || exit 1

true
