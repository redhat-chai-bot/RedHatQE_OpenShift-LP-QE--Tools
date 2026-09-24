#!/usr/bin/env bash
# collect-host-signals - capture Linux/KVM HOST-side crash-correlation signals
# that are invisible from inside the Windows guest.
#
# Runs on: the Linux HOST (libvirt/KVM). The HYPERVISOR_ERROR root
# cause (Intel split-lock #AC during the Hyper-V enlightened TLB-flush hypercall)
# only shows up in the host kernel log and the guest's <hyperv> domain config,
# never in the guest dump. This script greps the kernel log for the patterns in
# data/host-signals.json and extracts the VM's Hyper-V enlightenment features
# from the libvirt domain XML, then emits one JSON object to stdout (the script
# contract; diagnostics go to stderr).
#
# Usage:
#   collect-host-signals.sh --vm <name> [--since "1 hour ago"] [--dmesg]
#
#   --vm     libvirt domain name (default: $VM_NAME or bsod-test)
#   --since  journalctl --since window for kernel logs (default: "2 hours ago")
#   --dmesg  read `dmesg` instead of `journalctl -k` (use when journald has no
#            kernel log or you are parsing a captured file via --log-file)
#   --log-file <path>    parse kernel log from a file instead of the live system
#   --domain-xml <path>  read the guest domain XML from a file instead of `virsh
#                        dumpxml`. Needed on OpenShift/KubeVirt, where the node
#                        kernel log and the domain live in different execution
#                        contexts (node vs virt-launcher pod), so both signals
#                        must be captured to files and fed in offline:
#                          oc debug node/<n> -- chroot /host dmesg           > kern.log
#                          oc exec -n <ns> <virt-launcher> -- \
#                            virsh dumpxml <ns>_<vm>                         > dom.xml
#                          collect-host-signals.sh --vm <ns>_<vm> \
#                            --log-file kern.log --domain-xml dom.xml
#
# Reads: data/host-signals.json (patterns + hyperv feature list; source of truth).
#
# Output (stdout JSON):
#   { "ok": true, "vm": "...", "collectedAt": "...",
#     "kernelSignals": [ { "id","matches":[{"raw","kvmThread","trapAddress",
#                          "addressSpace"}],"count","relatedBugCheck" } ],
#     "splitLockDetected": true|false,
#     "hyperv": { "features": [ {"name","state","risk","present"} ],
#                 "mitigationApplied": true|false },
#     "assessment": [ "..." ], "warnings": [ ... ] }
exec {BASH_XTRACEFD}>/dev/null
set -euxo pipefail; shopt -s inherit_errexit

typeset here=''; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset repoRoot=''; repoRoot="$(cd "${here}/../../.." && pwd)"
typeset signalsFile="${repoRoot}/src/data/host-signals.json"

export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
typeset vmName="${VM_NAME:-bsod-test}"
typeset since="2 hours ago"
typeset useDmesg=0
typeset logFile=""
typeset domainXmlFile=""

function Warn () { echo "collect-host-signals: $*" >&2; true; }
function Die ()  { Warn "$*"; exit 2; }
function Have () { command -v "$1" >/dev/null 2>&1; }

Have jq || Die "jq not found"
[[ -f "${signalsFile}" ]] || Die "host-signals.json not found at ${signalsFile}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm) [[ $# -ge 2 ]] || Die "--vm requires a value"; vmName="$2"; shift 2 ;;
    --since) [[ $# -ge 2 ]] || Die "--since requires a value"; since="$2"; shift 2 ;;
    --dmesg) useDmesg=1; shift ;;
    --log-file) [[ $# -ge 2 ]] || Die "--log-file requires a value"; logFile="$2"; shift 2 ;;
    --domain-xml) [[ $# -ge 2 ]] || Die "--domain-xml requires a value"; domainXmlFile="$2"; shift 2 ;;
    -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
    *) Die "unknown arg: $1" ;;
  esac
done

typeset -a warnings=()

typeset kernelLog=""
if [[ -n "${logFile}" ]]; then
  [[ -f "${logFile}" ]] || Die "log file not found: ${logFile}"
  kernelLog="$(cat "${logFile}")"
elif [[ "${useDmesg}" -eq 1 ]]; then
  if Have dmesg; then
    kernelLog="$(dmesg 2>/dev/null || true)"
    [[ -n "${kernelLog}" ]] || warnings+=("dmesg returned no output (may need root)")
  else
    warnings+=("dmesg not available")
  fi
else
  if Have journalctl; then
    kernelLog="$(journalctl -k --since "${since}" --no-pager 2>/dev/null || true)"
    [[ -n "${kernelLog}" ]] || warnings+=("journalctl -k returned no output for window '${since}' (may need root or --dmesg)")
  else
    warnings+=("journalctl not available; try --dmesg")
  fi
fi

typeset signalResults="[]"
typeset splitLock=false
while IFS= read -r sig; do
  typeset id=''; id="$(echo "${sig}" | jq -r '.id')"
  typeset pattern=''; pattern="$(echo "${sig}" | jq -r '.pattern')"
  typeset related=''; related="$(echo "${sig}" | jq -r '.relatedBugCheck // empty')"

  typeset matches="[]"
  typeset count=0
  if [[ -n "${kernelLog}" ]]; then
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      typeset kvmThread=''; kvmThread="$(echo "${line}" | { grep -oP 'CPU\s+\d+/KVM/\d+' || true; } | head -n1)"
      typeset trapAddr=''; trapAddr="$(echo "${line}" | { grep -oP 'address:\s*\K0x[0-9a-fA-F]+' || true; } | head -n1)"
      typeset addrSpace="unknown"
      if [[ -n "${trapAddr}" ]]; then
        # Windows kernel space = 0xfffff8xx...; anything else treated as user/other.
        if [[ "${trapAddr}" == 0xfffff8* ]]; then addrSpace="kernel"; else addrSpace="user"; fi
      fi
      matches="$(echo "${matches}" | jq \
        --arg raw "${line}" --arg t "${kvmThread}" --arg a "${trapAddr}" --arg s "${addrSpace}" \
        '. + [{raw:$raw, kvmThread:(if $t=="" then null else $t end), trapAddress:(if $a=="" then null else $a end), addressSpace:$s}]')"
      count=$((count+1))
    done < <(grep -P "${pattern}" <<<"${kernelLog}" 2>/dev/null || true)
  fi

  [[ "${id}" == "split-lock-trap" && "${count}" -gt 0 ]] && splitLock=true

  signalResults="$(echo "${signalResults}" | jq \
    --arg id "${id}" --argjson matches "${matches}" --argjson count "${count}" \
    --arg related "${related}" \
    '. + [{id:$id, count:$count, relatedBugCheck:(if $related=="" then null else $related end), matches:$matches}]')"
done < <(jq -c '.kernelLogSignals[]' "${signalsFile}")

typeset hypervFeatures="[]"
typeset mitigationApplied=false
typeset hypervInspected=false
typeset domainXml=""
if [[ -n "${domainXmlFile}" ]]; then
  [[ -f "${domainXmlFile}" ]] || Die "domain XML file not found: ${domainXmlFile}"
  domainXml="$(cat "${domainXmlFile}")"
  [[ -n "${domainXml}" ]] || warnings+=("domain XML file '${domainXmlFile}' is empty")
elif Have virsh; then
  domainXml="$(virsh dumpxml "${vmName}" 2>/dev/null || true)"
  [[ -n "${domainXml}" ]] || warnings+=("could not read domain XML for '${vmName}' (is it defined? on OpenShift/KubeVirt use --domain-xml with 'oc exec <virt-launcher> -- virsh dumpxml <ns>_<vm>')")
else
  warnings+=("virsh not available and no --domain-xml provided; skipping Hyper-V feature extraction")
fi

if [[ -n "${domainXml}" ]]; then
  hypervInspected=true
  while IFS= read -r feat; do
    typeset name=''; name="$(echo "${feat}" | jq -r '.name')"
    typeset risk=''; risk="$(echo "${feat}" | jq -r '.risk')"
    # (e.g. synictimer -> <stimer>); fall back to name when .element absent.
    typeset elem=''; elem="$(echo "${feat}" | jq -r '.element // .name')"
    typeset state="absent"; typeset present=false
    if grep -qP "<${elem}\b[^>]*state=['\"]on['\"]" <<<"${domainXml}"; then
      state="on"; present=true
    elif grep -qP "<${elem}\b[^>]*state=['\"]off['\"]" <<<"${domainXml}"; then
      state="off"; present=true
    fi
    hypervFeatures="$(echo "${hypervFeatures}" | jq \
      --arg n "${name}" --arg s "${state}" --arg r "${risk}" --argjson p "${present}" \
      '. + [{name:$n, state:$s, risk:$r, present:$p}]')"
  done < <(jq -c '.hypervEnlightenments[]' "${signalsFile}")

  typeset tlbState=''; tlbState="$(echo "${hypervFeatures}" | jq -r '.[] | select(.name=="tlbflush") | .state')"
  typeset ipiState=''; ipiState="$(echo "${hypervFeatures}"  | jq -r '.[] | select(.name=="ipi") | .state')"
  if [[ "${tlbState}" != "on" && "${ipiState}" != "on" ]]; then mitigationApplied=true; fi
fi

typeset -a assessment=()
if [[ "${splitLock}" == true ]]; then
  typeset kernelHits=''; kernelHits="$(echo "${signalResults}" | jq '[.[] | select(.id=="split-lock-trap") | .matches[] | select(.addressSpace=="kernel")] | length')"
  assessment+=("Split-lock #AC traps present in host kernel log (${kernelHits} kernel-space). Consistent with HYPERVISOR_ERROR (0x20001) mechanism.")
  if [[ "${hypervInspected}" == false ]]; then
    assessment+=("Could not read the guest Hyper-V config; unable to correlate the traps with tlbflush/ipi enlightenments.")
  elif [[ "${mitigationApplied}" == false ]]; then
    assessment+=("Hyper-V tlbflush/ipi enlightenments are enabled AND split-lock traps observed: matches the unmitigated HYPERVISOR_ERROR configuration.")
  else
    assessment+=("Split-lock traps observed but tlbflush/ipi already off; traps may originate outside the enlightened TLB-flush path.")
  fi
else
  assessment+=("No split-lock #AC traps found in the examined kernel-log window.")
fi
if [[ "${hypervInspected}" == true && "${mitigationApplied}" == true ]]; then
  assessment+=("Mitigation appears applied: Hyper-V tlbflush and ipi are not enabled.")
fi

typeset assessJson=''; assessJson="$(printf '%s\n' "${assessment[@]:-}" | jq -R . | jq -s 'map(select(length>0))')"
typeset warnsJson=''; warnsJson="$(printf '%s\n' "${warnings[@]:-}"   | jq -R . | jq -s 'map(select(length>0))')"

jq -n \
  --arg vm "${vmName}" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson signals "${signalResults}" \
  --argjson splitlock "${splitLock}" \
  --argjson features "${hypervFeatures}" \
  --argjson mitigation "${mitigationApplied}" \
  --argjson assessment "${assessJson}" \
  --argjson warnings "${warnsJson}" \
  '{ok:true, vm:$vm, collectedAt:$at,
    kernelSignals:$signals, splitLockDetected:$splitlock,
    hyperv:{features:$features, mitigationApplied:$mitigation},
    assessment:$assessment, warnings:$warnings}'

true
