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
for tool in oc jq virtctl; do
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
    typeset -i es="${1?}"; (($#)) && shift
    typeset -i hlprPodPid="${1?}"; (($#)) && shift
    typeset -i hlprPodStdIn="${1?}"; (($#)) && shift
    typeset hlprPodName="${1?}"; (($#)) && shift
    typeset -i hlprPodDelES=0 hlprPodES=0

    # Delete only while this run's virtctl still runs; liveness is not proof
    # that the same-name Pod is this run's helper.
    ((hlprPodPid)) && kill -0 "${hlprPodPid}" || hlprPodName=''
    # EOF ends the virtctl attach session; virtctl then deletes its helper.
    ((hlprPodStdIn)) && exec {hlprPodStdIn}>&-
    # Clean exit: the helper is Running, so virtctl attaches, reads EOF and
    # exits; reap it before deleting.
    ((es)) || ((! hlprPodPid)) || wait "${hlprPodPid}" || hlprPodES=$?
    [ -z "${hlprPodName}" ] || {
        oc -n "${ns}" delete "pod/${hlprPodName}" \
            --ignore-not-found \
            --timeout=60s \
            --wait=true ||
        hlprPodDelES=$?
    }
    # Failure: delete first, which also ends a virtctl wait on a Pending Pod,
    # then reap.
    ((! es)) || ((! hlprPodPid)) || wait "${hlprPodPid}" || hlprPodES=$?

    ((hlprPodDelES)) && return "${hlprPodDelES}"
    ((hlprPodES)) && return "${hlprPodES}"
    return "${es}"
}

typeset hlprPod="libguestfs-tools-${guestPVC}"
typeset helperPodCtr='libguestfs'
typeset dfltCtrImg='quay.io/kubevirt/libguestfs-tools:20261112_5c3989e66e'
typeset -i guestfsPid=0 guestfsIn=0
typeset podRef=''
trap 'Cleanup "$?" "${guestfsPid}" "${guestfsIn}" "${hlprPod}"' EXIT

jq -es '
    ((length == 1) and (.[0].status.printableStatus == "Stopped"))
' 0< <(
    oc -n "${ns}" get vm/"${vm}" -o json
) 1> /dev/null

# virtctl names its helper libguestfs-tools-<pvc>; never adopt or delete a
# same-name Pod that existed before this run.
podRef="$(oc -n "${ns}" get "pod/${hlprPod}" --ignore-not-found -o name)"
[ -z "${podRef}" ] || {
    : "Pre-existing helper Pod: ${podRef}"
    false
}
coproc guestfsProc {
    exec virtctl -n "${ns}" guestfs \
        --vm "${vm}" \
        --image "${BSOD_DET__GUEST_FS__CTR_IMG:-${dfltCtrImg}}" \
        "${guestPVC}" \
        1>&2
}
# shellcheck disable=SC2154  # Set by the coproc builtin.
guestfsPid="${guestfsProc_PID}"
# Bash opens a new unused descriptor (>=10), stores its number in guestfsIn
# and, through the trailing '-', closes the original coproc write end. A
# plain number assignment would not keep the descriptor alive: Bash closes
# coproc descriptors itself once it reaps the coprocess.
exec {guestfsIn}>&"${guestfsProc[1]}"-

oc -n "${ns}" wait "pod/${hlprPod}" \
    --for=create \
    --timeout=60s 1> /dev/null
oc -n "${ns}" wait "pod/${hlprPod}" \
    --for=condition=Ready \
    --timeout=180s 1> /dev/null
# An exited virtctl has already requested deletion of its helper.
kill -0 "${guestfsPid}"

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
        oc -n "${ns}" exec "pod/${hlprPod}" \
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
        [[ "${dst}" == /* ]] || dst="/${dst#/}"
        dst="${podTmp}${dst}"
        while [[ "${dst}" == */ ]]; do dst="${dst%/}"; done
        {
            oc -n "${ns}" exec "pod/${hlprPod}" \
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
            "pod/${hlprPod}" \
            -c "${helperPodCtr}" \
            -- \
            test -d "${podTmp}/" &&
        {
            oc -n "${ns}" exec "pod/${hlprPod}" \
                -c "${helperPodCtr}" \
                -- \
                tar zc -C "${podTmp}/" ./ \
                1> "${outDir}/guest-fs--crash-info--${ntfsPart##*/}.tgz"
            break
        }
    }
done 0< <(FindNTFS "${hlprPod}" "${helperPodCtr}")
# A virtctl that exited during extraction has also deleted its helper.
kill -0 "${guestfsPid}"

# Python Code to parse MEMORY.DMP
# Revisit summary validation when reliability.py is refactored.
# timeout --signal=TERM --kill-after=5 60 python3 "${scrDir}/reliability.py" write-summary \
#     --out "${outDir}" --stage-errors "${outDir}/stage-errors.jsonl" --mode rhov-snapshot-recovery \
#     --vm "${vm}" --namespace "${ns}" --run-id "${runId}" --filename extraction-summary.json 1> /dev/null || exit 1

true
