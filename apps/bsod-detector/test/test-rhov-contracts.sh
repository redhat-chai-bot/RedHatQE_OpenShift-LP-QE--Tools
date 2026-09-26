#!/usr/bin/env bash
# Hermetic RHOV contract reproducers. No cluster is contacted.
# shellcheck disable=SC2030,SC2031,SC2034,SC2317
set -euo pipefail
shopt -s inherit_errexit

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
common="${repo_root}/src/scripts/host/rhov-common.sh"
watcher="${repo_root}/src/scripts/host/watch-crash.sh"
recovery="${repo_root}/src/scripts/host/recover-natural-crash.sh"
kubevirt_backend="${repo_root}/src/scripts/host/backends/kubevirt.sh"
dockerfile="$(cd "${repo_root}/../.." && pwd)/image/container/bsod-detector/Dockerfile"

function fail() {
  echo "FAIL: $*" >&2
  exit 1
}
function pass() { echo "PASS: $*"; }

# shellcheck disable=SC1090,SC1091
source "${common}"

manual_vm='{"metadata":{"namespace":"ns","name":"vm"},"spec":{"runStrategy":"Manual"}}'
wrong_vm='{"metadata":{"namespace":"ns","name":"other"},"spec":{"runStrategy":"Manual"}}'
always_vm='{"metadata":{"namespace":"ns","name":"vm"},"spec":{"runStrategy":"Always"}}'

function rhov_vm_json() { printf '%s\n' "${VM_FIXTURE}"; }
VM_FIXTURE="${manual_vm}"
rhov_validate_vm_contract ns vm || fail "Manual exact VM should validate"
VM_FIXTURE="${always_vm}"
if rhov_validate_vm_contract ns vm 2>/dev/null; then fail "non-Manual VM accepted"; fi
VM_FIXTURE="${wrong_vm}"
if rhov_validate_vm_contract ns vm 2>/dev/null; then fail "non-exact VM identity accepted"; fi
pass "exact Manual VM contract"

digest="$(printf 'a%.0s' {1..64})"
for image in \
  "quay.io/redhatqe/bsod-detector@sha256:${digest}" \
  "registry.example.test:5000/team/bsod-detector:v1.2.3@sha256:${digest}"; do
  rhov_valid_image_digest "${image}" || fail "valid immutable image reference was rejected: ${image}"
done
for image in \
  "bsod-detector@sha256:${digest}" \
  "https://quay.io/redhatqe/bsod-detector@sha256:${digest}" \
  "quay.io/RedHatQE/bsod-detector@sha256:${digest}" \
  "quay.io/redhatqe/bsod-detector@sha256:${digest^^}" \
  "quay.io/redhatqe/bsod-detector@@sha256:${digest}" \
  "quay.io/redhatqe/bsod detector@sha256:${digest}"; do
  if rhov_valid_image_digest "${image}"; then fail "invalid image reference was accepted: ${image}"; fi
done
pass "strict immutable recovery-image references"

single_disk_vmi='{"spec":{"domain":{"devices":{"disks":[{"name":"root","disk":{"bus":"virtio"},"bootOrder":1}]}},"volumes":[{"name":"root","dataVolume":{"name":"root-pvc"}}]},"status":{"volumeStatus":[{"name":"root","target":"vda"}]}}'
ambiguous_disk_vmi='{"spec":{"domain":{"devices":{"disks":[{"name":"root","disk":{}},{"name":"data","disk":{}}]}},"volumes":[{"name":"root","dataVolume":{"name":"root-pvc"}},{"name":"data","persistentVolumeClaim":{"claimName":"data-pvc"}}]},"status":{"volumeStatus":[{"name":"root","target":"vda"},{"name":"data","target":"vdb"}]}}'
function rhov_vmi_json() { printf '%s\n' "${VMI_FIXTURE}"; }
function oc() { return 0; }
VMI_FIXTURE="${single_disk_vmi}"
[[ "$(rhov_resolve_os_pvc ns vm)" == $'root-pvc\troot\tvda' ]] || fail "single boot OS PVC was not selected"
VMI_FIXTURE="${ambiguous_disk_vmi}"
if rhov_resolve_os_pvc ns vm >/dev/null 2>&1; then fail "ambiguous OS PVC selection succeeded"; fi
pass "exactly-one OS PVC selection"

owner_vmi='{"metadata":{"uid":"vmi-uid-1"}}'
owned_launcher='{"items":[{"metadata":{"name":"virt-launcher-vm-good","labels":{"kubevirt.io/domain":"vm"},"ownerReferences":[{"kind":"VirtualMachineInstance","uid":"vmi-uid-1"}]},"status":{"phase":"Running"}},{"metadata":{"name":"virt-launcher-vm-stale","labels":{"kubevirt.io/domain":"vm"},"ownerReferences":[{"kind":"VirtualMachineInstance","uid":"old-vmi-uid"}]},"status":{"phase":"Running"}}]}'
unowned_launcher='{"items":[{"metadata":{"name":"virt-launcher-vm-stale","labels":{"kubevirt.io/domain":"vm"},"ownerReferences":[{"kind":"VirtualMachineInstance","uid":"old-vmi-uid"}]},"status":{"phase":"Running"}}]}'
VMI_FIXTURE="${owner_vmi}"
POD_FIXTURE="${owned_launcher}"
function oc() { printf '%s\n' "${POD_FIXTURE}"; }
[[ "$(rhov_resolve_launcher ns vm)" == "virt-launcher-vm-good" ]] || fail "VMI-owned launcher was not selected"
POD_FIXTURE="${unowned_launcher}"
if rhov_resolve_launcher ns vm >/dev/null 2>&1; then fail "launcher owned by a stale VMI was accepted"; fi
pass "VMI-owner-safe launcher selection"

valid_stats=$'block.0.name=vda\nblock.0.wr.bytes=42\nblock.1.name=vdb\nblock.1.wr.bytes=999'
[[ "$(rhov_parse_write_bytes vda <<<"${valid_stats}")" == 42 ]] || fail "scoped domstats parser returned wrong value"
if rhov_parse_write_bytes vda <<<'block.0.name=vda' >/dev/null; then fail "missing counter accepted"; fi
if rhov_parse_write_bytes vda <<<$'block.0.name=vda\nblock.0.wr.bytes=bad' >/dev/null; then fail "malformed counter accepted"; fi
pass "scoped domstats validation"

function run_quiescence_case() (
  export BSOD_TEST_SOURCE_ONLY=1 BSOD_QUIESCE_POLL_SECONDS=1 BSOD_QUIESCE_IDLE_SECONDS=2
  # shellcheck disable=SC1090,SC1091,SC2034,SC2317
  source "${watcher}"
  # Consumed by wait_dump_complete from the dynamically sourced watcher.
  # shellcheck disable=SC2034
  quiesce_timeout="$1"
  sequence="$2"
  seq_file="$(mktemp)"
  trap 'rm -f "${seq_file}"' EXIT
  tr ',' '\n' <<<"${sequence}" >"${seq_file}"
  # shellcheck disable=SC2317
  function sleep() { :; }
  # shellcheck disable=SC2317
  function current_write_bytes() {
    local item
    item="$(sed -n '1p' "${seq_file}")"
    sed -i '1d' "${seq_file}"
    [[ "${item}" != ERR ]] || return 1
    printf '%s\n' "${item}"
  }
  wait_dump_complete
)

if run_quiescence_case 3 'ERR,ERR,ERR'; then fail "no-data trace counted stable"; fi
if run_quiescence_case 3 '100,100,100'; then fail "no-observed-write trace counted stable"; fi
run_quiescence_case 4 '100,110,110,110' || fail "write-then-stable trace rejected"
if run_quiescence_case 3 '100,110,120'; then fail "timeout trace returned success"; fi
pass "fail-closed dump completion traces"

function run_event_case() (
  export BSOD_TEST_SOURCE_ONLY=1
  # shellcheck disable=SC1090,SC1091
  source "${watcher}"
  namespace=ns
  vm=vm
  vmi_uid=vmi-uid-1
  event_json="$1"
  function oc() { printf '%s\n' "${event_json}"; }
  fresh_panic_event "$2"
)

fresh_event='{"items":[{"involvedObject":{"kind":"VirtualMachineInstance","name":"vm","uid":"vmi-uid-1"},"eventTime":"2026-09-26T08:00:00.123456Z"}]}'
wrong_uid_event='{"items":[{"involvedObject":{"kind":"VirtualMachineInstance","name":"vm","uid":"old-vmi-uid"},"eventTime":"2026-09-26T08:00:00Z"}]}'
stale_event='{"items":[{"involvedObject":{"kind":"VirtualMachineInstance","name":"vm","uid":"vmi-uid-1"},"lastTimestamp":"2020-01-01T00:00:00Z"}]}'
run_event_case "${fresh_event}" 1700000000 || fail "fresh fractional Panicked event was rejected"
if run_event_case "${wrong_uid_event}" 1700000000; then fail "Panicked event for an old VMI UID was accepted"; fi
if run_event_case "${stale_event}" 1700000000; then fail "stale Panicked event was accepted"; fi
pass "fresh exact-VMI Panicked event detection"

function run_unknown_state_case() (
  local marker_mode="$1"
  export BSOD_TEST_SOURCE_ONLY=1
  # shellcheck disable=SC1090,SC1091,SC2317
  source "${watcher}"
  out_dir="$(mktemp -d)"
  trap 'rm -rf "${out_dir}"' RETURN
  namespace=ns
  vm=vm
  interval=1
  miss_limit=2
  expected_crash_token="$(printf 'b%.0s' {1..64})"
  intentional_signal="${out_dir}/expected-crash-token"
  ready_file="${out_dir}/ready"
  detection_signal=""
  last_dom_state="not-queried"
  printf '%s\n' "$([[ "${marker_mode}" == match ]] && printf '%s' "${expected_crash_token}" || printf 'wrong-token')" >"${intentional_signal}"
  ping_count=0
  sleep_count=0
  function parse_args() { :; }
  function preflight() {
    run_log="${out_dir}/watch-crash.log"
    touch "${run_log}"
  }
  function qga_ping() {
    ping_count=$((ping_count + 1))
    printf '%s\n' "${ping_count}" >"${out_dir}/ping-count"
    ((ping_count == 1))
  }
  function verify_guest_crash_config() { return 0; }
  function fresh_panic_event() { return 1; }
  function current_domain_state() { printf 'unknown\n'; }
  function sleep() {
    sleep_count=$((sleep_count + 1))
    ((sleep_count < 5)) || exit 97
  }
  function handle_crash() {
    printf '%s|%s\n' "${detection_signal}" "${last_dom_state}" >"${out_dir}/handled"
    jq -n '{ok:true}' >"${out_dir}/evidence-summary.json"
    summary_written=1
  }

  set +e
  (main)
  status=$?
  set -e
  [[ "$(<"${out_dir}/ping-count")" == "3" ]] || return 1
  if [[ "${marker_mode}" == match ]]; then
    [[ ${status} -eq 0 ]] || return 1
    [[ "$(<"${out_dir}/handled")" == "intentional-token-and-qga-loss|unknown" ]] || return 1
    [[ -s "${out_dir}/evidence-summary.json" && -s "${out_dir}/watch-crash.log" ]] || return 1
  else
    [[ ${status} -ne 0 && ! -e "${out_dir}/handled" ]] || return 1
    jq -e '.ok == false and .failedStage == "signal-correlation" and
      (.error | contains("domstate=unknown"))' "${out_dir}/evidence-summary.json" >/dev/null || return 1
    [[ -s "${out_dir}/watch-crash.log" ]] || return 1
  fi
)

run_unknown_state_case match || fail "intentional token + QGA down + domstate unknown did not enter evidence flow"
run_unknown_state_case mismatch || fail "uncorrelated QGA down + domstate unknown was not failed explicitly"
grep -Fq -- '--expected-crash-token' "${repo_root}/src/scripts/crash-injector/trigger-bsod-intentional.sh" ||
  fail "intentional trigger does not pass an expected-crash token to the watcher"
# shellcheck disable=SC2016 # Assert the literal wait contract in the source.
grep -Fq 'wait "${watch_pid}"' "${repo_root}/src/scripts/crash-injector/trigger-bsod-intentional.sh" ||
  fail "intentional trigger does not preserve the watcher exit status with wait"
pass "uploaded unknown-state regression: correlated intentional run captures; uncorrelated run fails explicitly"

function run_handle_case() (
  export BSOD_TEST_SOURCE_ONLY=1
  # shellcheck disable=SC1090,SC1091
  source "${watcher}"
  out_dir="$(mktemp -d)"
  trap 'rm -rf "${out_dir}"' EXIT
  order_file="${out_dir}/order"
  function capture_screenshot() { echo screenshot >>"${order_file}"; }
  function capture_memory() { echo memory >>"${order_file}"; }
  function capture_live_metadata() { echo metadata >>"${order_file}"; }
  function current_write_bytes() { echo 100; }
  function wait_dump_complete() { echo quiescence >>"${order_file}"; }
  function stop_vm() { echo stop >>"${order_file}"; }
  function recover_offline() { echo recovery >>"${order_file}"; }
  function restart_and_wait() { echo restart >>"${order_file}"; }
  function write_success() { echo summary >>"${order_file}"; }
  if [[ "$1" == fail ]]; then
    function recover_offline() {
      echo recovery >>"${order_file}"
      return 1
    }
    if (handle_crash >/dev/null 2>&1); then return 1; fi
    if grep -q '^restart$' "${order_file}"; then return 1; fi
  else
    handle_crash
    [[ "$(paste -sd, "${order_file}")" == "screenshot,memory,metadata,quiescence,stop,recovery,restart,summary" ]]
  fi
)

run_handle_case success || fail "required lifecycle order changed"
run_handle_case fail || fail "restart occurred after failed extraction"
pass "lifecycle ordering and no restart after extraction failure"

grep -q 'virtctl vnc screenshot.*-f' "${watcher}" || fail "validated screenshot command missing"
grep -q 'virtctl memory-dump get' "${watcher}" || fail "KubeVirt memory-dump command missing"
if grep -Eq 'virsh dump .*/tmp|virsh dump .*/dev/stdout' "${watcher}" "${recovery}" "${kubevirt_backend}"; then
  fail "launcher filesystem/stdout memory dumping reintroduced"
fi
grep -q 'virtctl memory-dump get' "${kubevirt_backend}" || fail "generic KubeVirt backend does not use memory-dump API"
grep -q 'oc delete pvc.*claim' "${kubevirt_backend}" || fail "generic KubeVirt backend leaks its memory-dump PVC"
if grep -Eq 'rhov_resolve_launcher|pod=.*virt-launcher|oc exec.*launcher' "${recovery}"; then
  fail "post-stop recovery depends on virt-launcher"
fi
grep -q 'automountServiceAccountToken:false' "${recovery}" || fail "recovery pod token hardening missing"
grep -q 'allowPrivilegeEscalation:false' "${recovery}" || fail "recovery pod privilege hardening missing"
grep -q 'readOnlyRootFilesystem:true' "${recovery}" || fail "recovery pod writable root filesystem reintroduced"
if grep -q 'emptyDir' "${recovery}"; then fail "recovery uses node-local emptyDir for evidence"; fi
grep -q 'offline artifact directory.*is not empty' "${recovery}" || fail "stale offline artifact rejection missing"
pass "supported capture and pod-independent recovery contracts"

tmp_recovery="$(mktemp -d)"
mkdir -p "${tmp_recovery}/bin" "${tmp_recovery}/out"
fake_oc_log="${tmp_recovery}/oc.log"
cat >"${tmp_recovery}/bin/oc" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_OC_LOG}"
case "$1" in
  get)
    case "$2" in
      virtualmachine.kubevirt.io)
        printf '%s\n' '{"metadata":{"namespace":"ns","name":"vm"},"spec":{"runStrategy":"Manual"}}'
        ;;
      vmi) exit 1 ;;
      pods) printf '%s\n' '{"items":[]}' ;;
      pvc)
        if [[ "$3" == "os-pvc" ]]; then
          printf '%s\n' '{"spec":{"storageClassName":"sc","volumeMode":"Block","resources":{"requests":{"storage":"20Gi"}},"accessModes":["ReadWriteOnce"]}}'
        else
          printf 'Bound'
        fi
        ;;
      storageclass) printf 'csi.example.test' ;;
      volumesnapshotclass) printf '%s\n' '{"items":[{"metadata":{"name":"snap-class"},"driver":"csi.example.test"}]}' ;;
      volumesnapshot) printf '%s\n' '{"status":{"readyToUse":true}}' ;;
      pod) printf 'Succeeded' ;;
      *) exit 1 ;;
    esac
    ;;
  apply)
    manifest="$(cat)"
    printf 'manifest %s\n' "$(jq -c . <<<"${manifest}")" >>"${FAKE_OC_LOG}"
    ;;
  cp)
    destination="${@: -1}"
    mkdir -p "${destination}/winevt" "${destination}/Minidump"
    printf 'PAGEDU64' >"${destination}/MEMORY.DMP"
    truncate -s 96 "${destination}/MEMORY.DMP"
    printf 'MDMP' >"${destination}/Minidump/one.dmp"
    printf 'ElfFile\0' >"${destination}/winevt/System.evtx"
    ;;
  delete) ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "${tmp_recovery}/bin/oc"
recovery_image='example.invalid/bsod@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
FAKE_OC_LOG="${fake_oc_log}" PATH="${tmp_recovery}/bin:${PATH}" \
  bash "${recovery}" --ns ns --vm vm --out "${tmp_recovery}/out" --pvc os-pvc \
  --path2-only --recovery-image "${recovery_image}" >/dev/null
jq -e '.ok == true and .recovery.path2Snapshot == true and
  (.artifacts.dumps | index("offline/MEMORY.DMP")) != null and
  (.artifacts.dumps | index("offline/Minidump/one.dmp")) != null and
  (.artifacts.evtx | index("offline/winevt/System.evtx")) != null' \
  "${tmp_recovery}/out/recovery-summary.json" >/dev/null ||
  fail "mocked recovery did not report transferred nonempty artifacts"
[[ -s "${tmp_recovery}/out/offline/MEMORY.DMP" && -s "${tmp_recovery}/out/offline/winevt/System.evtx" ]] ||
  fail "mocked recovery did not preserve raw artifacts"
grep '^manifest ' "${fake_oc_log}" | sed 's/^manifest //' |
  jq -s -e 'any(.[]; .kind == "Pod" and
    any(.spec.containers[0].volumeMounts[]?; .name == "artifacts" and .mountPath == "/work") and
    any(.spec.containers[0].env[]?; .name == "TMPDIR" and .value == "/work/tmp") and
    any(.spec.volumes[]?; .name == "artifacts" and .persistentVolumeClaim.claimName != null)) and
    any(.[]; .kind == "PersistentVolumeClaim" and .spec.volumeMode == "Filesystem")' >/dev/null ||
  fail "recovery pod output was not backed by a Filesystem PVC"
cp_line="$(grep -n '^cp ' "${fake_oc_log}" | cut -d: -f1)"
first_delete_line="$(grep -n '^delete ' "${fake_oc_log}" | head -1 | cut -d: -f1)"
[[ -n "${cp_line}" && -n "${first_delete_line}" && ${cp_line} -lt ${first_delete_line} ]] ||
  fail "recovery resources were cleaned before artifact transfer"
rm -rf "${tmp_recovery}"
pass "mocked offline snapshot, transfer, validation, and cleanup ordering"

grep -q 'ARG OCP_VERSION=4.18.23' "${dockerfile}" || fail "oc client version is not pinned"
grep -q 'ARG VIRTCTL_VERSION=v1.6.6' "${dockerfile}" || fail "virtctl version is not pinned"
grep -q 'VIRTCTL_SHA256=' "${dockerfile}" || fail "virtctl checksum is not pinned"
make -C "$(dirname "${dockerfile}")" validate-layout >/dev/null
pass "container build context and entrypoint layout"

tmp_wrapper="$(mktemp -d)"
trap 'rm -rf "${tmp_wrapper}"' EXIT
touch "${tmp_wrapper}/disk.qcow2"
mkdir -p "${tmp_wrapper}/bin" "${tmp_wrapper}/out"
cat >"${tmp_wrapper}/bin/podman" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@"
MOCK
chmod +x "${tmp_wrapper}/bin/podman"
wrapper_output="$(PATH="${tmp_wrapper}/bin:${PATH}" BSOD_HOST_IMAGE=test/image:tag \
  bash "${repo_root}/host-tools/run.sh" --disk "${tmp_wrapper}/disk.qcow2" --out "${tmp_wrapper}/out")"
grep -qx 'MODE=extract' <<<"${wrapper_output}" || fail "wrapper did not select extract mode"
grep -qx -- '--disk' <<<"${wrapper_output}" || fail "wrapper did not forward --disk"
if grep -qx -- '--' <<<"${wrapper_output}"; then fail "wrapper forwarded a stray --"; fi
entrypoint="$(dirname "${dockerfile}")/entrypoint.sh"
awk '/^[[:space:]]*watch\)/,/^[[:space:]]*;;/' "${entrypoint}" | grep -Fq '"$@"' ||
  fail "container watch mode does not forward optional arguments"
pass "offline wrapper argument forwarding"

function run_small_memory_case() (
  export BSOD_TEST_SOURCE_ONLY=1
  # shellcheck disable=SC1090,SC1091
  source "${watcher}"
  out_dir="$(mktemp -d)"
  trap 'rm -rf "${out_dir}"' EXIT
  namespace=ns
  vm=vm
  function virtctl() {
    local argument
    for argument in "$@"; do
      if [[ "${argument}" == --output=* ]]; then
        printf 'not-a-memory-dump' >"${argument#--output=}"
      fi
    done
  }
  function rhov_require_name() { return 0; }
  capture_memory
)
if run_small_memory_case; then fail "implausibly small live-memory artifact was accepted"; fi
pass "live-memory capture rejects nonempty but implausibly small artifacts"

tmp_extract="$(mktemp -d)"
mkdir -p "${tmp_extract}/bin" "${tmp_extract}/out"
touch "${tmp_extract}/disk.qcow2"
cat >"${tmp_extract}/bin/virt-ls" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
cat >"${tmp_extract}/bin/virt-copy-out" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
source_path="$3"
destination="$4"
if [[ "${source_path}" == */Minidump ]]; then
  mkdir -p "${destination}/Minidump"
else
  : >"${destination}/${source_path##*/}"
fi
MOCK
chmod +x "${tmp_extract}/bin/virt-ls" "${tmp_extract}/bin/virt-copy-out"
set +e
PATH="${tmp_extract}/bin:${PATH}" bash "${repo_root}/host-tools/extract-dump.sh" \
  --disk "${tmp_extract}/disk.qcow2" --out "${tmp_extract}/out" >"${tmp_extract}/result.json"
extract_status=$?
set -e
[[ ${extract_status} -ne 0 ]] || fail "empty offline artifacts produced extraction success"
jq -e '.ok == false and (.dumpFiles | length) == 0' "${tmp_extract}/result.json" >/dev/null ||
  fail "empty offline artifacts were reported as real files"
rm -rf "${tmp_extract}"
pass "offline extractor rejects empty copied artifacts"

quoted_dump="${tmp_wrapper}/quoted'name.dmp"
python3 - "${quoted_dump}" <<'PY'
import struct
import sys

data = bytearray(0x60)
data[:8] = b"PAGEDU64"
struct.pack_into("<I", data, 0x38, 0xD1)
with open(sys.argv[1], "wb") as dump:
    dump.write(data)
PY
BSOD_CODES_FILE="${repo_root}/src/data/bugcheck-codes.json" \
  bash "${repo_root}/src/scripts/host/parse-dump-header.sh" "${quoted_dump}" |
  jq -e '.ok == true and .dumps[0].bugCheckCode == "0x000000D1"' >/dev/null ||
  fail "dump parser did not safely handle a quoted file path"
pass "dump parser path argument safety"

invalid_trigger_output="$(bash "${repo_root}/src/scripts/crash-injector/trigger-bsod-intentional.sh" \
  --ns ns --vm vm --out "${tmp_wrapper}/out" --crash-type '0x01&whoami' \
  --recovery-image 'example.invalid/image@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' 2>&1 || true)"
grep -q 'unsupported crash type' <<<"${invalid_trigger_output}" || fail "unsafe crash type was not rejected before cluster access"
jq -e '.ok == false and .failedStage == "argument-validation" and
  (.logs | index("intentional-trigger.log")) != null' \
  "${tmp_wrapper}/out/intentional-summary.json" >/dev/null ||
  fail "early intentional-trigger failure did not leave a truthful summary"
[[ -s "${tmp_wrapper}/out/intentional-trigger.log" ]] || fail "early intentional-trigger failure did not leave a nonempty log"
pass "intentional crash enum validation"

early_watch_out="${tmp_wrapper}/early-watch"
if bash "${watcher}" --out "${early_watch_out}" --invalid-option >/dev/null 2>&1; then
  fail "invalid watcher option unexpectedly succeeded"
fi
jq -e '.ok == false and .failedStage == "initialization"' \
  "${early_watch_out}/evidence-summary.json" >/dev/null || fail "early watcher failure summary missing"
[[ -s "${early_watch_out}/watch-crash.log" ]] || fail "early watcher failure log missing"

early_recovery_out="${tmp_wrapper}/early-recovery"
if bash "${recovery}" --out "${early_recovery_out}" --path1-only >/dev/null 2>&1; then
  fail "unsupported recovery path unexpectedly succeeded"
fi
jq -e '.ok == false and .failedStage == "preflight"' \
  "${early_recovery_out}/recovery-summary.json" >/dev/null || fail "early recovery failure summary missing"
[[ -s "${early_recovery_out}/recovery.log" ]] || fail "early recovery failure log missing"
pass "early failures leave private nonempty logs and summaries"

python3 - "${repo_root}/src/scripts/host/guest-agent.py" <<'PY'
import importlib.util
import sys

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("guest_agent", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.guest_exec = lambda *args, **kwargs: {"exitcode": 7, "stdout": "", "stderr": "failed"}
sys.argv = [path, "exec", "cmd.exe"]
try:
    module.main()
except SystemExit as exc:
    assert exc.code == 7, exc.code
else:
    raise AssertionError("guest exit code was swallowed")
PY
pass "guest-agent exit propagation"

data_dir="${repo_root}/src/data"
jq -e '[.codes | to_entries[] | select(.key | test("^0x[0-9A-F]{8}$") | not)] | length == 0' \
  "${data_dir}/bugcheck-codes.json" >/dev/null || fail "bugcheck keys are not canonical 8-digit uppercase hexadecimal"
jq -e --slurpfile codes "${data_dir}/bugcheck-codes.json" '
  [.triggers[] | .expectedCodes[]? | select($codes[0].codes[.] == null)] | length == 0' \
  "${data_dir}/chaos-triggers.json" >/dev/null || fail "chaos expectedCodes contain unknown bugchecks"
jq -e '[. as $root | .triggers[] |
  select(($root.tierSchema[.tier | tostring] // null) == null)] | length == 0' \
  "${data_dir}/chaos-triggers.json" >/dev/null || fail "chaos trigger uses an undeclared tier"
jq -e '(.tierSchema["5"] | test("experimental|unsupported"; "i")) and
  ([.triggers[] | select(.tier == 5)] | length > 0)' \
  "${data_dir}/chaos-triggers.json" >/dev/null || fail "tier 5 is not explicitly experimental/unsupported"
pass "bugcheck cross-references and five-tier chaos schema"

if command -v shfmt >/dev/null 2>&1; then
  while IFS= read -r bats_file; do
    shfmt -ln bats -tojson <"${bats_file}" >/dev/null || fail "Bats parser rejected ${bats_file}"
  done < <(find "${repo_root}/test" -maxdepth 1 -type f -name '*.bats' -print | sort)
  pass "Bats syntax parser invocation via stdin"
fi

echo "RHOV contract reproducers passed"
