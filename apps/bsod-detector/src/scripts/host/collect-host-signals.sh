#!/usr/bin/env bash
# Capture Linux/KVM host-side crash-correlation signals invisible from the guest.
# Greps kernel log for patterns in host-signals.json and reads Hyper-V
# enlightenments from domain XML; emits one JSON object on stdout.
# Offline OpenShift/KubeVirt: pass --log-file and --domain-xml from pre-captured files.
set -euxo pipefail; shopt -s inherit_errexit
umask 077

typeset scrDir="${BASH_SOURCE[0]%/*}"
typeset scrName="${BASH_SOURCE[0]##*/}"
typeset signalsFile="${BSOD_DET__HOST_SIGNALS__FILE:-${scrDir}/../../data/host-signals.json}"
typeset vmName="${VM_NAME:-bsod-test}"
typeset since='2 hours ago'
typeset -i useDmesg=0
typeset logFile='' domainXmlFile=''
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

while (($#)); do
    case "${1}" in
      (--vm) vmName="${2:?}"; shift 2;;
      (--since) since="${2:?}"; shift 2;;
      (--dmesg) useDmesg=1; shift;;
      (--log-file) logFile="${2:?}"; shift 2;;
      (--domain-xml) domainXmlFile="${2:?}"; shift 2;;
      (-h|--help)
        echo "usage: ${scrName} --vm NAME [--since TIMESPEC] [--dmesg] [--log-file FILE] [--domain-xml FILE]"
        exit 0
        ;;
      (*)
        echo "${scrName%.sh}: unknown argument: ${1}" 1>&2
        exit 2
        ;;
    esac
done

command -v jq 1> /dev/null || {
    echo "${scrName%.sh}: jq not found" 1>&2
    exit 2
}
[ -f "${signalsFile}" ] || {
    echo "${scrName%.sh}: host-signals.json not found at ${signalsFile}" 1>&2
    exit 2
}

typeset -a warnings=()
typeset kernelLog=''

if [ -n "${logFile}" ]; then
    [ -f "${logFile}" ] || {
        echo "${scrName%.sh}: log file not found: ${logFile}" 1>&2
        exit 2
    }
    kernelLog="$(cat -- "${logFile}")"
elif ((useDmesg)); then
    if command -v dmesg 1> /dev/null; then
        kernelLog="$(dmesg 2> /dev/null || true)"
        [ -n "${kernelLog}" ] || warnings+=('dmesg returned no output (may need root)')
    else
        warnings+=('dmesg not available')
    fi
elif command -v journalctl 1> /dev/null; then
    kernelLog="$(journalctl -k --since "${since}" --no-pager 2> /dev/null || true)"
    [ -n "${kernelLog}" ] || \
        warnings+=("journalctl -k returned no output for window '${since}' (may need root or --dmesg)")
else
    warnings+=('journalctl not available; try --dmesg')
fi

typeset signalResults='[]' splitLock=false
typeset sig='' id='' pattern='' related='' matches='' line=''
typeset kvmThread='' trapAddr='' addrSpace=''
typeset -i count=0

while IFS= read -r sig; do
    id="$(jq -r '.id' <<<"${sig}")"
    pattern="$(jq -r '.pattern' <<<"${sig}")"
    related="$(jq -r '.relatedBugCheck // empty' <<<"${sig}")"
    matches='[]'
    count=0

    if [ -n "${kernelLog}" ]; then
        while IFS= read -r line; do
            [ -n "${line}" ] || continue
            kvmThread="$(grep -oPm1 'CPU\s+\d+/KVM/\d+' <<<"${line}" || true)"
            trapAddr="$(grep -oPm1 'address:\s*\K0x[0-9a-fA-F]+' <<<"${line}" || true)"
            addrSpace='unknown'
            if [ -n "${trapAddr}" ]; then
                # Windows kernel space = 0xfffff8…; anything else treated as user/other.
                if [[ "${trapAddr}" == 0xfffff8* ]]; then
                    addrSpace='kernel'
                else
                    addrSpace='user'
                fi
            fi
            matches="$(
                jq \
                    --arg raw "${line}" \
                    --arg t "${kvmThread}" \
                    --arg a "${trapAddr}" \
                    --arg s "${addrSpace}" \
                    '. + [{
                        raw: $raw,
                        kvmThread: (if $t == "" then null else $t end),
                        trapAddress: (if $a == "" then null else $a end),
                        addressSpace: $s
                    }]' \
                    <<<"${matches}"
            )"
            count=$((count + 1))
        done 0< <(grep -P "${pattern}" <<<"${kernelLog}" 2> /dev/null || true)
    fi

    if [ "${id}" = 'split-lock-trap' ] && ((count > 0)); then
        splitLock=true
    fi

    signalResults="$(
        jq \
            --arg id "${id}" \
            --argjson matches "${matches}" \
            --argjson count "${count}" \
            --arg related "${related}" \
            '. + [{
                id: $id,
                count: $count,
                relatedBugCheck: (if $related == "" then null else $related end),
                matches: $matches
            }]' \
            <<<"${signalResults}"
    )"
done 0< <(jq -c '.kernelLogSignals[]' "${signalsFile}")

typeset hypervFeatures='[]' mitigationApplied=false hypervInspected=false
typeset domainXml='' feat='' name='' risk='' elem='' state=''
typeset present=false tlbState='' ipiState=''

if [ -n "${domainXmlFile}" ]; then
    [ -f "${domainXmlFile}" ] || {
        echo "${scrName%.sh}: domain XML file not found: ${domainXmlFile}" 1>&2
        exit 2
    }
    domainXml="$(cat -- "${domainXmlFile}")"
    [ -n "${domainXml}" ] || warnings+=("domain XML file '${domainXmlFile}' is empty")
elif command -v virsh 1> /dev/null; then
    domainXml="$(virsh dumpxml "${vmName}" 2> /dev/null || true)"
    [ -n "${domainXml}" ] || \
        warnings+=("could not read domain XML for '${vmName}' (is it defined? on OpenShift/KubeVirt use --domain-xml)")
else
    warnings+=('virsh not available and no --domain-xml provided; skipping Hyper-V feature extraction')
fi

if [ -n "${domainXml}" ]; then
    hypervInspected=true
    while IFS= read -r feat; do
        name="$(jq -r '.name' <<<"${feat}")"
        risk="$(jq -r '.risk' <<<"${feat}")"
        # XML element may differ from feature name (e.g. synictimer -> stimer).
        elem="$(jq -r '.element // .name' <<<"${feat}")"
        state='absent'
        present=false
        if grep -qP "<${elem}\b[^>]*state=['\"]on['\"]" <<<"${domainXml}"; then
            state='on'
            present=true
        elif grep -qP "<${elem}\b[^>]*state=['\"]off['\"]" <<<"${domainXml}"; then
            state='off'
            present=true
        fi
        hypervFeatures="$(
            jq \
                --arg n "${name}" \
                --arg s "${state}" \
                --arg r "${risk}" \
                --argjson p "${present}" \
                '. + [{name: $n, state: $s, risk: $r, present: $p}]' \
                <<<"${hypervFeatures}"
        )"
    done 0< <(jq -c '.hypervEnlightenments[]' "${signalsFile}")

    tlbState="$(jq -r '.[] | select(.name=="tlbflush") | .state' <<<"${hypervFeatures}")"
    ipiState="$(jq -r '.[] | select(.name=="ipi") | .state' <<<"${hypervFeatures}")"
    if [ "${tlbState}" != 'on' ] && [ "${ipiState}" != 'on' ]; then
        mitigationApplied=true
    fi
fi

typeset -a assessment=()
typeset kernelHits=''

if [ "${splitLock}" = true ]; then
    kernelHits="$(
        jq \
            '[.[] | select(.id=="split-lock-trap") | .matches[] | select(.addressSpace=="kernel")] | length' \
            <<<"${signalResults}"
    )"
    assessment+=(
        "Split-lock #AC traps present in host kernel log (${kernelHits} kernel-space). Consistent with HYPERVISOR_ERROR (0x20001) mechanism."
    )
    if [ "${hypervInspected}" = false ]; then
        assessment+=(
            'Could not read the guest Hyper-V config; unable to correlate the traps with tlbflush/ipi enlightenments.'
        )
    elif [ "${mitigationApplied}" = false ]; then
        assessment+=(
            'Hyper-V tlbflush/ipi enlightenments are enabled AND split-lock traps observed: matches the unmitigated HYPERVISOR_ERROR configuration.'
        )
    else
        assessment+=(
            'Split-lock traps observed but tlbflush/ipi already off; traps may originate outside the enlightened TLB-flush path.'
        )
    fi
else
    assessment+=('No split-lock #AC traps found in the examined kernel-log window.')
fi

if [ "${hypervInspected}" = true ] && [ "${mitigationApplied}" = true ]; then
    assessment+=('Mitigation appears applied: Hyper-V tlbflush and ipi are not enabled.')
fi

typeset assessJson warnJson
assessJson="$(printf '%s\n' "${assessment[@]:-}" | jq -R . | jq -s 'map(select(length > 0))')"
warnJson="$(printf '%s\n' "${warnings[@]:-}" | jq -R . | jq -s 'map(select(length > 0))')"

jq -n \
    --arg vm "${vmName}" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson signals "${signalResults}" \
    --argjson splitlock "${splitLock}" \
    --argjson features "${hypervFeatures}" \
    --argjson mitigation "${mitigationApplied}" \
    --argjson assessment "${assessJson}" \
    --argjson warnings "${warnJson}" \
    '{
        ok: true,
        vm: $vm,
        collectedAt: $at,
        kernelSignals: $signals,
        splitLockDetected: $splitlock,
        hyperv: {features: $features, mitigationApplied: $mitigation},
        assessment: $assessment,
        warnings: $warnings
    }'

true