#!/usr/bin/env bash
# Arm the RHOV watcher and trigger one whitelisted NotMyFault crash type.
set -euo pipefail
shopt -s inherit_errexit
umask 077

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
host_dir="$(cd "${script_dir}/../host" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../host/rhov-common.sh
source "${host_dir}/rhov-common.sh"

namespace=""
vm=""
out_dir=""
crash_type="0x01"
recovery_image="${BSOD_RECOVERY_IMAGE:-}"
snapshot_class=""
watch_timeout=1800
run_log=""
summary_written=0
current_stage="argument-validation"
watch_status="null"
trigger_status="null"
correlation_token=""
notmyfault_path='C:\Temp\nmf\notmyfaultc64.exe'

function usage() {
  echo "usage: trigger-bsod-intentional.sh --ns NS --vm VM --out DIR --recovery-image IMAGE@sha256:DIGEST [--crash-type 0x01..0x09]" >&2
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
function write_intentional_summary() {
  local ok="$1" stage="$2" error="$3" logs
  [[ -n "${out_dir}" ]] || return 0
  mkdir -p "${out_dir}"
  chmod 0700 "${out_dir}"
  if [[ -z "${run_log}" ]]; then
    run_log="${out_dir}/intentional-trigger.log"
  fi
  touch "${run_log}"
  chmod 0600 "${run_log}"
  printf '[%s] writing intentional summary for stage=%s\n' "$(date -u +%H:%M:%S)" "${stage:-complete}" >>"${run_log}"
  logs="$(for name in intentional-trigger.log trigger.log watch-crash.log; do
    [[ -s "${out_dir}/${name}" ]] && printf '%s\n' "${name}"
  done | jq -Rn '[inputs]')"
  jq -n --argjson ok "${ok}" --arg vm "${vm}" --arg ns "${namespace}" \
    --arg crashType "${crash_type}" --arg token "${correlation_token}" \
    --arg stage "${stage}" --arg error "${error}" --argjson watchStatus "${watch_status}" \
    --argjson triggerStatus "${trigger_status}" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson logs "${logs}" \
    '{ok:$ok,mode:"intentional-trigger",vm:$vm,namespace:$ns,crashType:$crashType,
      correlationToken:(if $token=="" then null else $token end),
      failedStage:(if $ok then null else $stage end),error:(if $ok then null else $error end),
      watcherExit:$watchStatus,triggerProcessExit:$triggerStatus,
      logs:$logs,reportedAt:$at}' \
    >"${out_dir}/intentional-summary.json"
  chmod 0600 "${out_dir}/intentional-summary.json"
  summary_written=1
}
function die() {
  write_intentional_summary false "${current_stage}" "$*" || true
  log "ERROR: $*"
  exit 1
}

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
    --crash-type)
      crash_type="${2:?--crash-type requires a value}"
      shift 2
      ;;
    --recovery-image)
      recovery_image="${2:?--recovery-image requires a value}"
      shift 2
      ;;
    --snap-class)
      snapshot_class="${2:?--snap-class requires a value}"
      shift 2
      ;;
    --watch-timeout)
      watch_timeout="${2:?--watch-timeout requires a value}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "${namespace}" && -n "${vm}" && -n "${out_dir}" ]] || die "--ns, --vm, and --out are required"
mkdir -p "${out_dir}"
chmod 0700 "${out_dir}"
run_log="${out_dir}/intentional-trigger.log"
touch "${run_log}"
chmod 0600 "${run_log}"
work_dir=""
watch_pid=""
trigger_pid=""
function cleanup() {
  if [[ -n "${trigger_pid}" ]]; then
    kill "${trigger_pid}" 2>/dev/null || true
    wait "${trigger_pid}" 2>/dev/null || true
  fi
  if [[ -n "${watch_pid}" ]]; then
    kill "${watch_pid}" 2>/dev/null || true
    wait "${watch_pid}" 2>/dev/null || true
  fi
  [[ -z "${work_dir}" ]] || rm -rf "${work_dir}"
}
function on_exit() {
  local status="$1"
  if [[ ${status} -ne 0 && ${summary_written} -eq 0 ]]; then
    set +e
    write_intentional_summary false "${current_stage}" "intentional trigger exited unexpectedly with status ${status}"
  fi
  cleanup
}
trap 'on_exit $?' EXIT
trap 'exit 130' INT TERM

case "${crash_type}" in
  0x01 | 0x02 | 0x03 | 0x04 | 0x05 | 0x06 | 0x07 | 0x08 | 0x09) ;;
  *) die "unsupported crash type '${crash_type}'; allowed NotMyFault enum: 0x01..0x09" ;;
esac
rhov_valid_image_digest "${recovery_image}" ||
  die "--recovery-image must be an immutable digest (IMAGE@sha256:<64 hex>)"
[[ "${watch_timeout}" =~ ^[1-9][0-9]*$ ]] || die "--watch-timeout must be a positive integer"
rhov_require_commands oc virtctl jq python3 timeout tee || die "required tooling is unavailable"

# This check is intentionally repeated here and in the watcher: no guest cleanup,
# configuration, or crash command occurs unless the exact VM exists and is Manual.
current_stage="vm-preflight"
rhov_validate_vm_contract "${namespace}" "${vm}" || exit 1
rhov_require_running_vmi "${namespace}" "${vm}" >/dev/null || exit 1
launcher="$(rhov_resolve_launcher "${namespace}" "${vm}")" || die "could not resolve exactly one launcher pod"

work_dir="$(mktemp -d "${out_dir}/.intentional.XXXXXX")"
ready_file="${work_dir}/watcher-ready"
signal_file="${work_dir}/expected-crash-token"
watch_log="${out_dir}/watch-crash.log"
trigger_log="${out_dir}/trigger.log"
touch "${trigger_log}"
chmod 0600 "${trigger_log}"

export GA_NS="${namespace}" GA_VM="${vm}" GA_POD="${launcher}" GA_DOM="${namespace}_${vm}"

# Require the executable crash settings before arming. Automatic dumps do not
# independently guarantee minidumps, so only MEMORY.DMP is required here.
current_stage="guest-crash-config"
# shellcheck disable=SC2016 # PowerShell expands $c inside the guest, not Bash.
config_probe='$c=Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"; [ordered]@{AutoReboot=[int]$c.AutoReboot;CrashDumpEnabled=[int]$c.CrashDumpEnabled;DumpFile=[string]$c.DumpFile} | ConvertTo-Json -Compress'
config_output="$(python3 "${host_dir}/guest-agent.py" exec powershell.exe -NoProfile -NonInteractive -Command "${config_probe}")" ||
  die "guest CrashControl probe failed"
config_json="$(sed -n '/^{.*}$/p' <<<"${config_output}" | tail -1)"
jq -e '.AutoReboot == 0 and .CrashDumpEnabled == 7 and (.DumpFile | ascii_downcase | endswith("memory.dmp"))' \
  <<<"${config_json}" >/dev/null ||
  die "guest CrashControl must have AutoReboot=0, CrashDumpEnabled=7, and a MEMORY.DMP path before triggering; observed: ${config_json:-no JSON}"

correlation_token="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
watch_args=(--ns "${namespace}" --vm "${vm}" --out "${out_dir}"
  --recovery-image "${recovery_image}" --intentional-signal "${signal_file}"
  --expected-crash-token "${correlation_token}"
  --ready-file "${ready_file}")
[[ -n "${snapshot_class}" ]] && watch_args+=(--snap-class "${snapshot_class}")

current_stage="watcher-preflight"
log "starting watcher for correlated intentional run"
timeout "${watch_timeout}" bash "${host_dir}/watch-crash.sh" "${watch_args[@]}" >/dev/null 2>&1 &
watch_pid=$!

elapsed=0
while [[ ! -f "${ready_file}" && ${elapsed} -lt 120 ]]; do
  kill -0 "${watch_pid}" 2>/dev/null || {
    wait "${watch_pid}" || true
    die "watcher exited during preflight; see ${watch_log}"
  }
  sleep 2
  elapsed=$((elapsed + 2))
done
[[ -f "${ready_file}" ]] || die "watcher did not become ready within 120s"

current_stage="crash-trigger"
printf '%s\n' "${correlation_token}" >"${signal_file}"
chmod 0600 "${signal_file}"
log "watcher ready; expected-crash token issued before NotMyFault invocation"
python3 "${host_dir}/guest-agent.py" exec "${notmyfault_path}" /crash "${crash_type}" >"${trigger_log}" 2>&1 &
trigger_pid=$!

current_stage="watcher-wait"
set +e
wait "${watch_pid}"
watch_status=$?
set -e
watch_pid=""
kill "${trigger_pid}" 2>/dev/null || true
set +e
wait "${trigger_pid}" 2>/dev/null
trigger_status=$?
set -e
trigger_pid=""

[[ ${watch_status} -eq 0 ]] || die "watch/evidence pipeline failed with exit ${watch_status}; see ${watch_log} and evidence-summary.json"
jq -e '.ok == true and .lifecycle.guestAgentReady == true' "${out_dir}/evidence-summary.json" >/dev/null ||
  die "watcher exited without a truthful successful evidence summary"
current_stage="complete"
write_intentional_summary true "" ""
log "intentional BSOD evidence pipeline completed: ${out_dir}"
