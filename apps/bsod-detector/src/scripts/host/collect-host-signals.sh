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
#   collect-host-signals.sh --vm <name> [--since <timespec>] [--dmesg]
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
####
# Suppress bash trace output to keep stderr clean for diagnostics
exec {BASH_XTRACEFD}>/dev/null
set -euxo pipefail; shopt -s inherit_errexit

# Determine script directory and repository root for path resolution
typeset here=''; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset repoRoot=''; repoRoot="$(cd "${here}/../../.." && pwd)"
typeset signalsFile="${BSOD_DET__HOST_SIGNALS__FILE:-${repoRoot}/src/data/host-signals.json}"

# Set default configuration values
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
typeset vmName="${VM_NAME:-bsod-test}"
typeset since="2 hours ago"
typeset useDmesg=0
typeset logFile=""
typeset domainXmlFile=""

# Helper function definitions
# warn — print a diagnostic message to stderr.
function warn () { echo "collect-host-signals: $*" >&2; true; }
# die — print a fatal error to stderr and exit.
function die ()  { warn "$*"; exit 2; }
# have — return 0 if the named command is available on PATH.
function have () { command -v "$1" >/dev/null 2>&1; }

# Verify prerequisites: jq must be available and signals data file must exist
have jq || die "jq not found"
[[ -f "${signalsFile}" ]] || die "host-signals.json not found at ${signalsFile}"

# Parse command-line arguments to override defaults
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm) [[ $# -ge 2 ]] || die "--vm requires a value"; vmName="$2"; shift 2 ;;
    --since) [[ $# -ge 2 ]] || die "--since requires a value"; since="$2"; shift 2 ;;
    --dmesg) useDmesg=1; shift ;;
    --log-file) [[ $# -ge 2 ]] || die "--log-file requires a value"; logFile="$2"; shift 2 ;;
    --domain-xml) [[ $# -ge 2 ]] || die "--domain-xml requires a value"; domainXmlFile="$2"; shift 2 ;;
    -h|--help) sed -n '/^#!/,/^####$/{/^#!/d;/^####$/d;s/^# \{0,1\}//p;}' "$0"; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

# Initialize warnings array to track issues encountered during collection
typeset -a warnings=()

# Retrieve kernel log from the specified source (file, dmesg, or journalctl)
# Priority: explicit log file > --dmesg flag > journalctl (default) with time window
typeset kernelLog=""
if [[ -n "${logFile}" ]]; then
  # Load kernel log from a pre-captured file (for offline analysis or OpenShift scenarios)
  [[ -f "${logFile}" ]] || die "log file not found: ${logFile}"
  kernelLog="$(cat "${logFile}")"
elif [[ "${useDmesg}" -eq 1 ]]; then
  # Read current in-memory kernel buffer via dmesg (fallback when journald is unavailable)
  if have dmesg; then
    kernelLog="$(dmesg 2>/dev/null || true)"
    [[ -n "${kernelLog}" ]] || warnings+=("dmesg returned no output (may need root)")
  else
    warnings+=("dmesg not available")
  fi
else
  # Query journalctl for kernel logs within the specified time window (default: "2 hours ago")
  if have journalctl; then
    kernelLog="$(journalctl -k --since "${since}" --no-pager 2>/dev/null || true)"
    [[ -n "${kernelLog}" ]] || warnings+=("journalctl -k returned no output for window '${since}' (may need root or --dmesg)")
  else
    warnings+=("journalctl not available; try --dmesg")
  fi
fi

# Scan kernel log for crash-correlation signals defined in host-signals.json
# For each signal pattern, extract matches and collect context (KVM thread, trap address, address space)
typeset signalResults="[]"
typeset splitLock=false
while IFS= read -r sig; do
  # Extract signal metadata from data source
  typeset id=''; id="$(echo "${sig}" | jq -r '.id')"
  typeset pattern=''; pattern="$(echo "${sig}" | jq -r '.pattern')"
  typeset related=''; related="$(echo "${sig}" | jq -r '.relatedBugCheck // empty')"

  # Initialize match array and count for this signal pattern
  typeset matches="[]"
  typeset count=0
  if [[ -n "${kernelLog}" ]]; then
    # Search kernel log for lines matching the signal pattern
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      # Extract KVM thread identifier (CPU/KVM/thread format) from matched line
      typeset kvmThread=''; kvmThread="$(echo "${line}" | { grep -oP 'CPU\s+\d+/KVM/\d+' || true; } | head -n1)"
      # Extract trap address (e.g., 0x1234567890) from matched line
      typeset trapAddr=''; trapAddr="$(echo "${line}" | { grep -oP 'address:\s*\K0x[0-9a-fA-F]+' || true; } | head -n1)"
      # Classify address space (kernel vs user) based on Windows address ranges
      typeset addrSpace="unknown"
      if [[ -n "${trapAddr}" ]]; then
        # Windows kernel space = 0xfffff8xx...; anything else treated as user/other.
        if [[ "${trapAddr}" == 0xfffff8* ]]; then addrSpace="kernel"; else addrSpace="user"; fi
      fi
      # Accumulate this match with extracted context
      matches="$(echo "${matches}" | jq \
        --arg raw "${line}" --arg t "${kvmThread}" --arg a "${trapAddr}" --arg s "${addrSpace}" \
        '. + [{raw:$raw, kvmThread:(if $t=="" then null else $t end), trapAddress:(if $a=="" then null else $a end), addressSpace:$s}]')"
      count=$((count+1))
    done < <(grep -P "${pattern}" <<<"${kernelLog}" 2>/dev/null || true)
  fi

  # Flag split-lock traps if this signal matches split-lock-trap and has hits
  [[ "${id}" == "split-lock-trap" && "${count}" -gt 0 ]] && splitLock=true

  # Append this signal's results to the overall signal results
  signalResults="$(echo "${signalResults}" | jq \
    --arg id "${id}" --argjson matches "${matches}" --argjson count "${count}" \
    --arg related "${related}" \
    '. + [{id:$id, count:$count, relatedBugCheck:(if $related=="" then null else $related end), matches:$matches}]')"
done < <(jq -c '.kernelLogSignals[]' "${signalsFile}")

# Extract Hyper-V enlightenment configuration from the guest domain XML
# This reveals which performance features are enabled (and their risk profiles)
typeset hypervFeatures="[]"
typeset mitigationApplied=false
typeset hypervInspected=false
typeset domainXml=""
if [[ -n "${domainXmlFile}" ]]; then
  # Load domain XML from a file (needed for OpenShift/KubeVirt where kernel log and domain config are in separate pods)
  [[ -f "${domainXmlFile}" ]] || die "domain XML file not found: ${domainXmlFile}"
  domainXml="$(cat "${domainXmlFile}")"
  [[ -n "${domainXml}" ]] || warnings+=("domain XML file '${domainXmlFile}' is empty")
elif have virsh; then
  # Retrieve domain XML directly from libvirt using virsh (standard KVM setup)
  domainXml="$(virsh dumpxml "${vmName}" 2>/dev/null || true)"
  [[ -n "${domainXml}" ]] || warnings+=("could not read domain XML for '${vmName}' (is it defined? on OpenShift/KubeVirt use --domain-xml with 'oc exec <virt-launcher> -- virsh dumpxml <ns>_<vm>')")
else
  warnings+=("virsh not available and no --domain-xml provided; skipping Hyper-V feature extraction")
fi

# Parse Hyper-V enlightenments from domain XML
if [[ -n "${domainXml}" ]]; then
  hypervInspected=true
  # Iterate through each enlightenment feature defined in host-signals.json
  while IFS= read -r feat; do
    # Extract feature metadata (name, risk level, and XML element to search for)
    typeset name=''; name="$(echo "${feat}" | jq -r '.name')"
    typeset risk=''; risk="$(echo "${feat}" | jq -r '.risk')"
    # XML element name may differ from feature name (e.g. synictimer -> <stimer>); fall back to name when .element absent.
    typeset elem=''; elem="$(echo "${feat}" | jq -r '.element // .name')"
    # Search domain XML for the feature element and its state attribute
    typeset state="absent"; typeset present=false
    if grep -qP "<${elem}\b[^>]*state=['\"]on['\"]" <<<"${domainXml}"; then
      state="on"; present=true
    elif grep -qP "<${elem}\b[^>]*state=['\"]off['\"]" <<<"${domainXml}"; then
      state="off"; present=true
    fi
    # Accumulate this feature's configuration into the results
    hypervFeatures="$(echo "${hypervFeatures}" | jq \
      --arg n "${name}" --arg s "${state}" --arg r "${risk}" --argjson p "${present}" \
      '. + [{name:$n, state:$s, risk:$r, present:$p}]')"
  done < <(jq -c '.hypervEnlightenments[]' "${signalsFile}")

  # Check if split-lock mitigation is applied (tlbflush and ipi are both disabled)
  typeset tlbState=''; tlbState="$(echo "${hypervFeatures}" | jq -r '.[] | select(.name=="tlbflush") | .state')"
  typeset ipiState=''; ipiState="$(echo "${hypervFeatures}"  | jq -r '.[] | select(.name=="ipi") | .state')"
  if [[ "${tlbState}" != "on" && "${ipiState}" != "on" ]]; then mitigationApplied=true; fi
fi

# Generate assessment and recommendations based on collected signals and configuration
typeset -a assessment=()
if [[ "${splitLock}" == true ]]; then
  # Count kernel-space split-lock traps for the assessment message
  typeset kernelHits=''; kernelHits="$(echo "${signalResults}" | jq '[.[] | select(.id=="split-lock-trap") | .matches[] | select(.addressSpace=="kernel")] | length')"
  assessment+=("Split-lock #AC traps present in host kernel log (${kernelHits} kernel-space). Consistent with HYPERVISOR_ERROR (0x20001) mechanism.")
  # Correlate traps with Hyper-V configuration to assess root cause
  if [[ "${hypervInspected}" == false ]]; then
    assessment+=("Could not read the guest Hyper-V config; unable to correlate the traps with tlbflush/ipi enlightenments.")
  elif [[ "${mitigationApplied}" == false ]]; then
    assessment+=("Hyper-V tlbflush/ipi enlightenments are enabled AND split-lock traps observed: matches the unmitigated HYPERVISOR_ERROR configuration.")
  else
    assessment+=("Split-lock traps observed but tlbflush/ipi already off; traps may originate outside the enlightened TLB-flush path.")
  fi
else
  # No split-lock traps found; note that no HYPERVISOR_ERROR signals were present
  assessment+=("No split-lock #AC traps found in the examined kernel-log window.")
fi
# If mitigation was applied, explicitly document that in the assessment
if [[ "${hypervInspected}" == true && "${mitigationApplied}" == true ]]; then
  assessment+=("Mitigation appears applied: Hyper-V tlbflush and ipi are not enabled.")
fi

# Convert assessment and warnings arrays into JSON format for output
typeset assessJson=''; assessJson="$(printf '%s\n' "${assessment[@]:-}" | jq -R . | jq -s 'map(select(length>0))')"
typeset warnsJson=''; warnsJson="$(printf '%s\n' "${warnings[@]:-}"   | jq -R . | jq -s 'map(select(length>0))')"

# Emit the final JSON report containing all collected signals and analysis
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

# Ensure script exits successfully
true
