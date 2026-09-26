#!/usr/bin/env bash
# Watch one RHOV VM and run a fail-closed, offline-first BSOD evidence flow.
# Requires a pre-existing VM with spec.runStrategy=Manual. The script never
# changes the VM spec and never writes evidence to an OpenShift node filesystem.
set -euo pipefail
shopt -s inherit_errexit
umask 077

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=rhov-common.sh
source "${script_dir}/rhov-common.sh"

namespace=""
vm=""
out_dir=""
interval=5
miss_limit=2
quiesce_timeout=900
stop_timeout=180
ready_timeout=600
snapshot_class=""
recovery_image="${BSOD_RECOVERY_IMAGE:-}"
requested_pvc=""
intentional_signal=""
expected_crash_token=""
intentional_signal_timeout=120
ready_file=""
run_log=""
summary_written=0
current_stage="initialization"
last_dom_state="not-queried"
detection_signal=""
vmi_uid=""

function usage() {
  echo "usage: watch-crash.sh --ns NAMESPACE --vm VM --out DIR --recovery-image IMAGE@sha256:DIGEST [options]" >&2
}

function log() {
  local line
  line="[$(date -u +%H:%M:%S)] $*"
  if [[ -n "${run_log}" ]]; then
    printf '%s\n' "${line}" | tee -a "${run_log}" >&2
  else
    printf '%s\n' "${line}" >&2
  fi
}

function write_failure() {
  local stage="$1" message="$2"
  if [[ -z "${out_dir}" ]]; then
    summary_written=1
    printf 'ERROR: %s\n' "${message}" >&2
    return 0
  fi
  mkdir -p "${out_dir}"
  chmod 0700 "${out_dir}"
  if [[ -z "${run_log}" ]]; then
    run_log="${out_dir}/watch-crash.log"
  fi
  touch "${run_log}"
  chmod 0600 "${run_log}"
  printf '[%s] writing failure summary for stage=%s\n' "$(date -u +%H:%M:%S)" "${stage}" >>"${run_log}"
  jq -n --arg vm "${vm}" --arg ns "${namespace}" --arg stage "${stage}" \
    --arg error "${message}" --arg state "${last_dom_state}" --arg signal "${detection_signal}" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{ok:false,mode:"rhov-watch",vm:$vm,namespace:$ns,failedStage:$stage,error:$error,
      detection:{signal:(if $signal=="" then null else $signal end),domState:$state},
      logs:["watch-crash.log"],reportedAt:$at}' \
    >"${out_dir}/evidence-summary.json"
  chmod 0600 "${out_dir}/evidence-summary.json"
  summary_written=1
  log "ERROR: ${message}"
}

function fail() {
  current_stage="$1"
  write_failure "$1" "$2"
  exit 1
}

function on_exit() {
  local status="$1"
  if [[ ${status} -ne 0 && ${summary_written} -eq 0 && -n "${out_dir}" ]]; then
    set +e
    write_failure "${current_stage}" "watcher exited unexpectedly with status ${status}"
  fi
}

function parse_args() {
  while (($#)); do
    case "$1" in
      --ns)
        namespace="${2:?--ns requires a value}"
        shift 2
        ;;
      --vm)
        vm="${2:?--vm requires a value}"
        shift 2
        ;;
      --out)
        out_dir="${2:?--out requires a value}"
        shift 2
        ;;
      --interval)
        interval="${2:?--interval requires a value}"
        shift 2
        ;;
      --miss)
        miss_limit="${2:?--miss requires a value}"
        shift 2
        ;;
      --quiesce-wait)
        quiesce_timeout="${2:?--quiesce-wait requires a value}"
        shift 2
        ;;
      --stop-timeout)
        stop_timeout="${2:?--stop-timeout requires a value}"
        shift 2
        ;;
      --ready-timeout)
        ready_timeout="${2:?--ready-timeout requires a value}"
        shift 2
        ;;
      --snap-class)
        snapshot_class="${2:?--snap-class requires a value}"
        shift 2
        ;;
      --recovery-image)
        recovery_image="${2:?--recovery-image requires a value}"
        shift 2
        ;;
      --pvc)
        requested_pvc="${2:?--pvc requires a value}"
        shift 2
        ;;
      --intentional-signal)
        intentional_signal="${2:?--intentional-signal requires a value}"
        shift 2
        ;;
      --expected-crash-token)
        expected_crash_token="${2:?--expected-crash-token requires a value}"
        shift 2
        ;;
      --intentional-signal-timeout)
        intentional_signal_timeout="${2:?--intentional-signal-timeout requires a value}"
        shift 2
        ;;
      --ready-file)
        ready_file="${2:?--ready-file requires a value}"
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        usage
        echo "unknown argument: $1" >&2
        exit 2
        ;;
    esac
  done
}

function validate_positive_integer() {
  [[ "$2" =~ ^[1-9][0-9]*$ ]] || fail preflight "$1 must be a positive integer (found '$2')"
}

launcher=""
domain=""
os_pvc=""
os_volume=""
os_target=""
memory_pvc=""

function preflight() {
  [[ -n "${namespace}" && -n "${vm}" && -n "${out_dir}" ]] || fail preflight "--ns, --vm, and --out are required"
  mkdir -p "${out_dir}"
  chmod 0700 "${out_dir}"
  run_log="${out_dir}/watch-crash.log"
  touch "${run_log}"
  chmod 0600 "${run_log}"
  rhov_valid_image_digest "${recovery_image}" ||
    fail preflight "--recovery-image must be an immutable image digest (IMAGE@sha256:<64 hex>)"
  [[ -z "${snapshot_class}" ]] || rhov_require_name VolumeSnapshotClass "${snapshot_class}" ||
    fail preflight "invalid --snap-class"
  validate_positive_integer interval "${interval}"
  validate_positive_integer miss "${miss_limit}"
  validate_positive_integer quiesce-wait "${quiesce_timeout}"
  validate_positive_integer stop-timeout "${stop_timeout}"
  validate_positive_integer ready-timeout "${ready_timeout}"
  validate_positive_integer intentional-signal-timeout "${intentional_signal_timeout}"
  if [[ -n "${intentional_signal}" || -n "${expected_crash_token}" ]]; then
    [[ -n "${intentional_signal}" && -n "${expected_crash_token}" ]] ||
      fail preflight "--intentional-signal and --expected-crash-token must be supplied together"
    [[ "${expected_crash_token}" =~ ^[0-9a-f]{64}$ ]] ||
      fail preflight "--expected-crash-token must be exactly 64 lowercase hexadecimal characters"
  fi
  rhov_require_commands oc virtctl jq python3 awk stat od timeout tr find tee ||
    fail preflight "required tooling is unavailable"
  rhov_validate_vm_contract "${namespace}" "${vm}" || fail preflight "VM contract validation failed"
  local vmi_json
  vmi_json="$(rhov_require_running_vmi "${namespace}" "${vm}")" || fail preflight "VMI is not ready for capture"
  vmi_uid="$(jq -er '.metadata.uid | select(length > 0)' <<<"${vmi_json}")" ||
    fail preflight "VMI does not expose a UID for event correlation"
  launcher="$(rhov_resolve_launcher "${namespace}" "${vm}")" || fail preflight "could not resolve exactly one launcher pod"
  domain="${namespace}_${vm}"
  local disk_identity
  disk_identity="$(rhov_resolve_os_pvc "${namespace}" "${vm}" "${requested_pvc}")" ||
    fail preflight "could not resolve exactly one OS PVC and disk target"
  IFS=$'\t' read -r os_pvc os_volume os_target <<<"${disk_identity}"
  log "resolved OS volume=${os_volume} PVC=${os_pvc} target=${os_target}"
  export GA_NS="${namespace}" GA_VM="${vm}" GA_POD="${launcher}" GA_DOM="${domain}"
  virtctl vnc screenshot --help >/dev/null 2>&1 ||
    fail preflight "installed virtctl does not support 'vnc screenshot'"
  virtctl memory-dump --help >/dev/null 2>&1 ||
    fail preflight "installed virtctl does not support the KubeVirt memory-dump API"
  local existing_dump
  existing_dump="$(oc get vm "${vm}" -n "${namespace}" -o json | jq -r '.status.memoryDumpRequest.claimName // ""')"
  [[ -z "${existing_dump}" ]] ||
    fail preflight "VM already has memory dump association '${existing_dump}'; run 'virtctl memory-dump remove ${vm} -n ${namespace}' after preserving it"
  log "preflight complete: ${namespace}/${vm}, launcher=${launcher}, OS PVC=${os_pvc}, target=${os_target}"
}

function qga_ping() {
  timeout 10 python3 "${script_dir}/guest-agent.py" ping >/dev/null 2>&1
}

function verify_guest_crash_config() {
  local probe output config
  # shellcheck disable=SC2016 # PowerShell expands $c inside the guest.
  probe='$c=Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"; [ordered]@{AutoReboot=[int]$c.AutoReboot;CrashDumpEnabled=[int]$c.CrashDumpEnabled;DumpFile=[string]$c.DumpFile} | ConvertTo-Json -Compress'
  output="$(python3 "${script_dir}/guest-agent.py" exec powershell.exe -NoProfile -NonInteractive -Command "${probe}")" || return
  config="$(sed -n '/^{.*}$/p' <<<"${output}" | tail -1)"
  jq -e '.AutoReboot == 0 and .CrashDumpEnabled == 7 and
         (.DumpFile | ascii_downcase | endswith("memory.dmp"))' <<<"${config}" >/dev/null
}

function fresh_panic_event() {
  local since="$1"
  oc get events -n "${namespace}" --field-selector reason=Panicked -o json 2>/dev/null |
    jq -e --arg vm "${vm}" --arg uid "${vmi_uid}" --argjson since "${since}" '
      any(.items[]?;
        .involvedObject.kind == "VirtualMachineInstance" and
        .involvedObject.name == $vm and
        .involvedObject.uid == $uid and
        ((.eventTime // .lastTimestamp // .metadata.creationTimestamp // "") as $when |
          $when != "" and (($when | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= $since)))' >/dev/null
}

function intentional_signal_matches() {
  local observed=""
  [[ -n "${intentional_signal}" && -n "${expected_crash_token}" ]] || return 1
  [[ -f "${intentional_signal}" && ! -L "${intentional_signal}" ]] || return 1
  observed="$(<"${intentional_signal}")" || return 1
  [[ "${observed}" == "${expected_crash_token}" ]]
}

function current_domain_state() {
  local state
  state="$(oc exec -n "${namespace}" "${launcher}" -- virsh domstate "${domain}" 2>/dev/null |
    tr -d '[:space:]')" || state="unknown"
  case "${state}" in
    running | paused | crashed | pmsuspended | shutoff) printf '%s\n' "${state}" ;;
    *) printf '%s\n' "unknown" ;;
  esac
}

function capture_screenshot() {
  local file="${out_dir}/bsod-screenshot.png" signature
  rm -f "${file}"
  virtctl vnc screenshot "${vm}" -n "${namespace}" -f "${file}" || return
  [[ -s "${file}" ]] || return 1
  signature="$(od -An -tx1 -N8 "${file}" | tr -d ' \n')"
  [[ "${signature}" == "89504e470d0a1a0a" ]] || {
    rm -f "${file}"
    echo "screenshot response was not a PNG" >&2
    return 1
  }
  chmod 0600 "${file}"
}

function capture_memory() {
  local stamp dump_file dump_size
  stamp="$(date -u +%Y%m%d%H%M%S)"
  memory_pvc="bsod-mem-${vm:0:28}-${stamp}"
  memory_pvc="${memory_pvc,,}"
  rhov_require_name memory-dump-PVC "${memory_pvc}" || return
  dump_file="${out_dir}/vm-memory.raw"
  rm -f "${dump_file}"
  # KubeVirt writes the live dump to a PVC, waits for MemoryDumpCompleted, then
  # VMExport downloads and decompresses the raw artifact to this host path.
  virtctl memory-dump get "${vm}" -n "${namespace}" \
    --claim-name="${memory_pvc}" --create-claim --format=raw --output="${dump_file}" || return
  [[ -s "${dump_file}" ]] || return 1
  dump_size="$(stat -c '%s' "${dump_file}")" || return
  ((dump_size >= 1048576)) || {
    echo "memory-dump download was implausibly small (${dump_size} bytes)" >&2
    return 1
  }
  chmod 0600 "${dump_file}"
  virtctl memory-dump remove "${vm}" -n "${namespace}" || return
  local elapsed=0
  while ((elapsed < 120)); do
    if [[ "$(oc get vm "${vm}" -n "${namespace}" -o json | jq -r '.status.memoryDumpRequest // empty')" == "" ]]; then
      oc delete pvc "${memory_pvc}" -n "${namespace}" --ignore-not-found --wait=true >/dev/null || return
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  echo "memory dump completed but its VM association did not clear" >&2
  return 1
}

function capture_live_metadata() {
  oc exec -n "${namespace}" "${launcher}" -- virsh dumpxml "${domain}" >"${out_dir}/dom.xml" || return
  [[ -s "${out_dir}/dom.xml" ]] || return 1
  chmod 0600 "${out_dir}/dom.xml"
  bash "${script_dir}/collect-host-signals.sh" --vm "${domain}" \
    --domain-xml "${out_dir}/dom.xml" >"${out_dir}/host-signals.json" || return
  jq -e '.ok == true' "${out_dir}/host-signals.json" >/dev/null
}

function current_write_bytes() {
  oc exec -n "${namespace}" "${launcher}" -- virsh domstats --block "${domain}" 2>/dev/null |
    rhov_parse_write_bytes "${os_target}"
}

# Success requires a valid baseline, at least one positive write delta after the
# crash signal, and a valid unchanged plateau. Invalid samples reset the idle
# window and never count as stable. Timeout is a hard failure.
function wait_dump_complete() {
  local poll="${BSOD_QUIESCE_POLL_SECONDS:-10}"
  local idle_required="${BSOD_QUIESCE_IDLE_SECONDS:-30}"
  local elapsed=0 idle=0 previous="${1:-}" current="" observed_write=0
  while ((elapsed < quiesce_timeout)); do
    if current="$(current_write_bytes)" && [[ "${current}" =~ ^[0-9]+$ ]]; then
      if [[ -n "${previous}" ]]; then
        if ((current > previous)); then
          observed_write=1
          idle=0
        elif ((current == previous)) && ((observed_write == 1)); then
          idle=$((idle + poll))
          if ((idle >= idle_required)); then return 0; fi
        else
          idle=0
        fi
      fi
      previous="${current}"
    else
      previous=""
      idle=0
      log "invalid/no domstats sample for ${os_target}; stability window reset"
    fi
    sleep "${poll}"
    elapsed=$((elapsed + poll))
  done
  echo "no proven write-then-idle transition within ${quiesce_timeout}s; VM remains running" >&2
  return 1
}

function stop_vm() {
  virtctl stop "${vm}" -n "${namespace}" || return
  rhov_wait_absent virtualmachineinstance.kubevirt.io "${namespace}" "${vm}" "${stop_timeout}" || return
  rhov_wait_no_launcher "${namespace}" "${vm}" "${stop_timeout}"
}

function recover_offline() {
  local -a args=(--ns "${namespace}" --vm "${vm}" --out "${out_dir}" --path2-only
    --pvc "${os_pvc}" --recovery-image "${recovery_image}")
  [[ -n "${snapshot_class}" ]] && args+=(--snap-class "${snapshot_class}")
  bash "${script_dir}/recover-natural-crash.sh" "${args[@]}"
  jq -e '.ok == true and .recovery.path2Snapshot == true' "${out_dir}/recovery-summary.json" >/dev/null
}

function restart_and_wait() {
  rhov_validate_vm_contract "${namespace}" "${vm}" || return
  virtctl start "${vm}" -n "${namespace}" || return
  rhov_wait_ready "${namespace}" "${vm}" "${ready_timeout}"
}

function write_success() {
  local artifacts required
  for required in bsod-screenshot.png vm-memory.raw dom.xml host-signals.json recovery-summary.json; do
    [[ -s "${out_dir}/${required}" ]] ||
      fail reporting "required artifact ${required} was missing or empty after its stage reported success"
  done
  artifacts="$(find "${out_dir}" -maxdepth 3 -type f -size +0c -printf '%P\n' | sort |
    jq -Rn '[inputs | select(length > 0)]')"
  jq -n --arg vm "${vm}" --arg ns "${namespace}" --arg pvc "${os_pvc}" \
    --arg memoryPvc "${memory_pvc}" --arg state "${last_dom_state}" \
    --arg signal "${detection_signal}" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson artifacts "${artifacts}" \
    '{ok:true,mode:"rhov-watch",vm:$vm,namespace:$ns,osPvc:$pvc,
      detection:{signal:$signal,domState:$state},
      memoryDumpPvc:$memoryPvc,completedAt:$at,lifecycle:{stopped:true,restarted:true,
      vmiRunning:true,guestAgentReady:true},logs:["watch-crash.log"],artifacts:$artifacts}' \
    >"${out_dir}/evidence-summary.json"
  chmod 0600 "${out_dir}/evidence-summary.json"
  summary_written=1
  log "evidence flow succeeded; summary=${out_dir}/evidence-summary.json"
}

function handle_crash() {
  log "correlated crash signal '${detection_signal}' confirmed (domstate=${last_dom_state}); completing all live-VMI captures before stop"
  local crash_write_baseline
  crash_write_baseline="$(current_write_bytes)" ||
    fail dump-completion "OS-disk statistics were invalid at the crash signal; VM was not stopped"
  capture_screenshot || fail screenshot "virtctl vnc screenshot failed or did not produce a valid nonempty PNG; VM was not stopped"
  capture_memory || fail memory-dump "supported KubeVirt memory-dump capture/download failed; VM was not stopped and no launcher filesystem fallback was attempted"
  capture_live_metadata || fail live-metadata "launcher-dependent domain metadata capture failed; VM was not stopped"
  wait_dump_complete "${crash_write_baseline}" || fail dump-completion "OS-disk dump completion was not proven; VM was not stopped"
  stop_vm || fail stop "VM/VMI/launcher did not stop cleanly; offline extraction was not started"
  recover_offline || fail offline-extraction "snapshot/offline artifact extraction failed; VM remains stopped and recovery resources are retained"
  restart_and_wait || fail restart-readiness "offline extraction succeeded but VM/VMI/guest-agent readiness was not proven"
  write_success
}

function main() {
  trap 'on_exit $?' EXIT
  parse_args "$@"
  preflight
  local armed_at misses=0 intentional_seen_at=0 now=0
  armed_at="$(date -u +%s)"
  qga_ping || fail preflight "guest agent is not reachable before arming"
  verify_guest_crash_config ||
    fail preflight "guest CrashControl must have AutoReboot=0, CrashDumpEnabled=7, and a MEMORY.DMP path"
  if [[ -n "${ready_file}" ]]; then
    mkdir -p "$(dirname "${ready_file}")"
    : >"${ready_file}"
    chmod 0600 "${ready_file}"
  fi
  log "armed for fresh Panicked event on ${namespace}/${vm} at epoch ${armed_at}"
  while true; do
    if fresh_panic_event "${armed_at}"; then
      detection_signal="fresh-panicked-event"
      last_dom_state="$(current_domain_state)"
      handle_crash
      return 0
    fi
    if qga_ping; then
      misses=0
      if intentional_signal_matches; then
        now="$(date -u +%s)"
        if ((intentional_seen_at == 0)); then
          intentional_seen_at="${now}"
          log "matching intentional crash token observed; waiting for QGA loss"
        elif ((now - intentional_seen_at >= intentional_signal_timeout)); then
          fail signal-correlation "intentional crash token was issued but QGA remained healthy for ${intentional_signal_timeout}s"
        fi
      fi
    else
      misses=$((misses + 1))
      last_dom_state="$(current_domain_state)"
      log "guest-agent miss ${misses}/${miss_limit} (domstate=${last_dom_state}); QGA loss alone is not a natural-crash signal"
      if ((misses >= miss_limit)); then
        if intentional_signal_matches; then
          detection_signal="intentional-token-and-qga-loss"
          handle_crash
          return 0
        fi
        fail signal-correlation \
          "QGA was unavailable for ${misses} consecutive checks with domstate=${last_dom_state}, but neither a fresh Panicked event nor the expected intentional crash token was present; refusing to classify this as a crash"
      fi
    fi
    sleep "${interval}"
  done
}

if [[ "${BSOD_TEST_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
