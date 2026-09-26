#!/usr/bin/env bash
# Offline RHOV recovery from one stopped Manual VM's OS PVC.
set -euo pipefail
shopt -s inherit_errexit nullglob
umask 077

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=rhov-common.sh
source "${script_dir}/rhov-common.sh"

namespace=""
vm=""
out_dir=""
guest_pvc=""
snapshot_class=""
recovery_image="${BSOD_RECOVERY_IMAGE:-}"
path1_only=0
snapshot_timeout=300
pvc_timeout=300
pod_timeout=900
snapshot_name=""
restore_pvc=""
artifact_pvc=""
recovery_pod=""
offline_dir=""
current_stage="preflight"
recovery_complete=0
run_log=""

function failure_summary() {
  local status=$?
  if [[ ${status} -ne 0 && ${recovery_complete} -eq 0 && -n "${out_dir}" ]]; then
    set +e
    mkdir -p "${out_dir}" 2>/dev/null || true
    chmod 0700 "${out_dir}" 2>/dev/null || true
    if [[ -z "${run_log}" ]]; then
      run_log="${out_dir}/recovery.log"
    fi
    touch "${run_log}" 2>/dev/null || true
    chmod 0600 "${run_log}" 2>/dev/null || true
    printf '[%s] recovery failed at stage=%s with status=%s\n' \
      "$(date -u +%H:%M:%S)" "${current_stage}" "${status}" >>"${run_log}" 2>/dev/null || true
    jq -n --arg vm "${vm}" --arg ns "${namespace}" --arg stage "${current_stage}" \
      --arg snapshot "${snapshot_name}" --arg pvc "${restore_pvc}" \
      --arg artifactPvc "${artifact_pvc}" --arg pod "${recovery_pod}" \
      '{ok:false,mode:"rhov-offline-recovery",vm:$vm,namespace:$ns,failedStage:$stage,
        retainedResources:{snapshot:(if $snapshot=="" then null else $snapshot end),
          pvc:(if $pvc=="" then null else $pvc end),
          artifactPvc:(if $artifactPvc=="" then null else $artifactPvc end),
          pod:(if $pod=="" then null else $pod end)},
        logs:["recovery.log"]}' \
      >"${out_dir}/recovery-summary.json" 2>/dev/null || true
    chmod 0600 "${out_dir}/recovery-summary.json" 2>/dev/null || true
  fi
}
trap failure_summary EXIT

function log() {
  local line
  line="[$(date -u +%H:%M:%S)] $*"
  if [[ -n "${run_log}" ]]; then
    printf '%s\n' "${line}" | tee -a "${run_log}" >&2
  else
    printf '%s\n' "${line}" >&2
  fi
}
function die() {
  log "ERROR: $*"
  exit 1
}
function usage() {
  echo "usage: recover-natural-crash.sh --ns NS --vm VM --out DIR --pvc OS_PVC --recovery-image IMAGE@sha256:DIGEST [--snap-class CLASS] [--path2-only]" >&2
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
    --pvc)
      guest_pvc="${2:?--pvc requires a value}"
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
    --path1-only)
      path1_only=1
      shift
      ;;
    --path2-only) shift ;;
    --snapshot-timeout)
      snapshot_timeout="${2:?--snapshot-timeout requires a value}"
      shift 2
      ;;
    --pvc-timeout)
      pvc_timeout="${2:?--pvc-timeout requires a value}"
      shift 2
      ;;
    --pod-timeout)
      pod_timeout="${2:?--pod-timeout requires a value}"
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

[[ "${path1_only}" == 0 ]] || die "PATH 1 is unsupported on RHOV: launcher-filesystem virsh dumps violate the no-node-evidence contract; use watch-crash.sh's KubeVirt memory-dump capture before stop"
[[ -n "${namespace}" && -n "${vm}" && -n "${out_dir}" && -n "${guest_pvc}" ]] ||
  die "--ns, --vm, --out, and --pvc are required"
mkdir -p "${out_dir}"
chmod 0700 "${out_dir}"
run_log="${out_dir}/recovery.log"
touch "${run_log}"
chmod 0600 "${run_log}"
rhov_valid_image_digest "${recovery_image}" ||
  die "--recovery-image must be an immutable digest containing extract-dump (IMAGE@sha256:<64 hex>)"
rhov_require_commands oc jq python3 tee find od tr || die "required tooling is unavailable"
rhov_require_name namespace "${namespace}" || exit 1
rhov_require_name VM "${vm}" || exit 1
rhov_require_name PVC "${guest_pvc}" || exit 1
rhov_validate_vm_contract "${namespace}" "${vm}" || exit 1
for timeout_value in "${snapshot_timeout}" "${pvc_timeout}" "${pod_timeout}"; do
  [[ "${timeout_value}" =~ ^[1-9][0-9]*$ ]] || die "all timeout values must be positive integers"
done

# Recovery is deliberately pod-independent and only operates after complete VMI
# and launcher disappearance. It never resolves or needs virt-launcher.
if oc get vmi "${vm}" -n "${namespace}" >/dev/null 2>&1; then
  die "VMI ${namespace}/${vm} still exists; refuse to snapshot a live OS disk"
fi
launcher_count="$(oc get pods -n "${namespace}" -l "kubevirt.io=virt-launcher,kubevirt.io/domain=${vm}" \
  -o json | jq '[.items[] | select(.metadata.deletionTimestamp == null)] | length')"
[[ "${launcher_count}" == "0" ]] || die "launcher pod for ${namespace}/${vm} still exists; wait for disappearance before recovery"

offline_dir="${out_dir}/offline"
if [[ -d "${offline_dir}" && -n "$(find "${offline_dir}" -mindepth 1 -print -quit)" ]]; then
  die "offline artifact directory ${offline_dir} is not empty; use a fresh output directory to avoid stale evidence"
fi
mkdir -p "${offline_dir}"
chmod 0700 "${offline_dir}"

pvc_json="$(oc get pvc "${guest_pvc}" -n "${namespace}" -o json)" || die "OS PVC ${namespace}/${guest_pvc} not found"
storage_class="$(jq -r '.spec.storageClassName // ""' <<<"${pvc_json}")"
volume_mode="$(jq -r '.spec.volumeMode // "Filesystem"' <<<"${pvc_json}")"
size="$(jq -r '.spec.resources.requests.storage // ""' <<<"${pvc_json}")"
mapfile -t access_modes < <(jq -r '.spec.accessModes[]' <<<"${pvc_json}")
[[ -n "${storage_class}" && -n "${size}" && ${#access_modes[@]} -gt 0 ]] ||
  die "PVC ${namespace}/${guest_pvc} lacks storageClass, requested size, or accessModes"
[[ "${volume_mode}" == "Block" ]] ||
  die "OS PVC ${namespace}/${guest_pvc} uses volumeMode=${volume_mode}; only the verified Block-mode recovery contract is supported"

if [[ -z "${snapshot_class}" ]]; then
  provisioner="$(oc get storageclass "${storage_class}" -o jsonpath='{.provisioner}')" ||
    die "cannot read StorageClass ${storage_class}"
  mapfile -t snapshot_classes < <(oc get volumesnapshotclass -o json |
    jq -r --arg driver "${provisioner}" '.items[] | select(.driver == $driver) | .metadata.name')
  [[ ${#snapshot_classes[@]} -eq 1 ]] ||
    die "expected exactly one VolumeSnapshotClass for CSI driver ${provisioner}, found ${#snapshot_classes[@]}; pass --snap-class explicitly"
  snapshot_class="${snapshot_classes[0]}"
fi
rhov_require_name VolumeSnapshotClass "${snapshot_class}" || exit 1

suffix="$(date -u +%Y%m%d%H%M%S)-$$"
snapshot_name="bsod-${vm:0:28}-${suffix}"
restore_pvc="${snapshot_name}-pvc"
artifact_pvc="${snapshot_name}-artifacts"
recovery_pod="${snapshot_name}-extract"

function apply_snapshot() {
  jq -n --arg name "${snapshot_name}" --arg ns "${namespace}" --arg vm "${vm}" \
    --arg class "${snapshot_class}" --arg pvc "${guest_pvc}" \
    '{apiVersion:"snapshot.storage.k8s.io/v1",kind:"VolumeSnapshot",
      metadata:{name:$name,namespace:$ns,labels:{"app.kubernetes.io/name":"bsod-detector"},annotations:{"bsod-detector/target-vm":$vm}},
      spec:{volumeSnapshotClassName:$class,source:{persistentVolumeClaimName:$pvc}}}' |
    oc apply -f - >/dev/null
}

function wait_snapshot() {
  local elapsed=0 json ready error
  while ((elapsed < snapshot_timeout)); do
    json="$(oc get volumesnapshot "${snapshot_name}" -n "${namespace}" -o json 2>/dev/null)" || true
    [[ -n "${json}" ]] || json='{}'
    ready="$(jq -r '.status.readyToUse // false' <<<"${json}")"
    error="$(jq -r '.status.error.message // ""' <<<"${json}")"
    [[ -z "${error}" ]] || die "VolumeSnapshot failed: ${error}"
    [[ "${ready}" == "true" ]] && return 0
    sleep 5
    elapsed=$((elapsed + 5))
  done
  die "VolumeSnapshot ${namespace}/${snapshot_name} was not ready within ${snapshot_timeout}s"
}

function apply_restore_pvc() {
  access_json="$(printf '%s\n' "${access_modes[@]}" | jq -R . | jq -s .)"
  jq -n --arg name "${restore_pvc}" --arg ns "${namespace}" --arg vm "${vm}" \
    --arg sc "${storage_class}" --arg mode "${volume_mode}" --arg size "${size}" \
    --arg snap "${snapshot_name}" --argjson modes "${access_json}" \
    '{apiVersion:"v1",kind:"PersistentVolumeClaim",
      metadata:{name:$name,namespace:$ns,labels:{"app.kubernetes.io/name":"bsod-detector"},annotations:{"bsod-detector/target-vm":$vm}},
      spec:{accessModes:$modes,volumeMode:$mode,storageClassName:$sc,
        resources:{requests:{storage:$size}},
        dataSource:{apiGroup:"snapshot.storage.k8s.io",kind:"VolumeSnapshot",name:$snap}}}' |
    oc apply -f - >/dev/null
}

function apply_artifact_pvc() {
  access_json="$(printf '%s\n' "${access_modes[@]}" | jq -R . | jq -s .)"
  jq -n --arg name "${artifact_pvc}" --arg ns "${namespace}" --arg vm "${vm}" \
    --arg sc "${storage_class}" --arg size "${size}" --argjson modes "${access_json}" \
    '{apiVersion:"v1",kind:"PersistentVolumeClaim",
      metadata:{name:$name,namespace:$ns,labels:{"app.kubernetes.io/name":"bsod-detector"},annotations:{"bsod-detector/target-vm":$vm}},
      spec:{accessModes:$modes,volumeMode:"Filesystem",storageClassName:$sc,
        resources:{requests:{storage:$size}}}}' |
    oc apply -f - >/dev/null
}

function wait_pvc() {
  local pvc_name="$1" elapsed=0 phase
  while ((elapsed < pvc_timeout)); do
    phase="$(oc get pvc "${pvc_name}" -n "${namespace}" -o jsonpath='{.status.phase}' 2>/dev/null)" || true
    [[ "${phase}" == "Bound" ]] && return 0
    sleep 5
    elapsed=$((elapsed + 5))
  done
  die "PVC ${namespace}/${pvc_name} was not Bound within ${pvc_timeout}s"
}

function apply_recovery_pod() {
  jq -n --arg name "${recovery_pod}" --arg ns "${namespace}" --arg vm "${vm}" \
    --arg image "${recovery_image}" --arg pvc "${restore_pvc}" \
    --arg artifactPvc "${artifact_pvc}" --arg mode "${volume_mode}" '
    {apiVersion:"v1",kind:"Pod",
     metadata:{name:$name,namespace:$ns,labels:{"app.kubernetes.io/name":"bsod-detector"},annotations:{"bsod-detector/target-vm":$vm}},
     spec:{restartPolicy:"Never",automountServiceAccountToken:false,
       securityContext:{seccompProfile:{type:"RuntimeDefault"}},
       containers:[{name:"extractor",image:$image,imagePullPolicy:"IfNotPresent",
         command:["/bin/bash","-ceu"],
         args:["mkdir -p /work/tmp /work/cache /work/home /work/out; chmod 0700 /work/tmp /work/cache /work/home /work/out; exec /usr/local/bin/extract-dump --disk /dev/os-disk --out /work/out"],
         env:[
           {name:"LIBGUESTFS_BACKEND",value:"direct"},
           {name:"LIBGUESTFS_CACHEDIR",value:"/work/cache"},
           {name:"TMPDIR",value:"/work/tmp"},
           {name:"HOME",value:"/work/home"}],
         securityContext:{allowPrivilegeEscalation:false,runAsNonRoot:false,runAsUser:0,
           readOnlyRootFilesystem:true,capabilities:{drop:["ALL"]}},
         resources:{requests:{cpu:"250m",memory:"512Mi"},limits:{cpu:"2",memory:"4Gi"}},
         volumeDevices:[{name:"os-disk",devicePath:"/dev/os-disk"}],
         volumeMounts:[{name:"artifacts",mountPath:"/work"}]}],
       volumes:[
         {name:"os-disk",persistentVolumeClaim:{claimName:$pvc,readOnly:true}},
         {name:"artifacts",persistentVolumeClaim:{claimName:$artifactPvc}}]}}
    | if $mode != "Block" then error("recovery currently requires a Block-mode OS PVC; refusing an unverified filesystem mount mechanism") else . end' |
    oc apply -f - >/dev/null
}

function wait_pod() {
  local elapsed=0 phase reason
  while ((elapsed < pod_timeout)); do
    phase="$(oc get pod "${recovery_pod}" -n "${namespace}" -o jsonpath='{.status.phase}' 2>/dev/null)" || true
    case "${phase}" in
      Succeeded) return 0 ;;
      Failed)
        reason="$(oc get pod "${recovery_pod}" -n "${namespace}" -o jsonpath='{.status.containerStatuses[0].state.terminated.message}' 2>/dev/null)"
        die "recovery pod failed: ${reason:-see pod logs}"
        ;;
    esac
    sleep 5
    elapsed=$((elapsed + 5))
  done
  die "recovery pod ${namespace}/${recovery_pod} did not complete within ${pod_timeout}s"
}

function copy_and_validate() {
  oc cp "${namespace}/${recovery_pod}:/work/out/." "${offline_dir}" || die "artifact transfer from recovery pod failed; resources retained"
  local -a dump_files=() evtx_files=()
  local file signature
  if [[ -s "${offline_dir}/MEMORY.DMP" ]]; then
    signature="$(od -An -tx1 -N8 "${offline_dir}/MEMORY.DMP" | tr -d ' \n')"
    [[ "${signature}" == "5041474544553634" ]] && dump_files+=("${offline_dir}/MEMORY.DMP")
  fi
  while IFS= read -r file; do
    signature="$(od -An -tx1 -N4 "${file}" | tr -d ' \n')"
    [[ "${signature}" == "4d444d50" ]] && dump_files+=("${file}")
  done < <(find "${offline_dir}/Minidump" -type f -iname '*.dmp' -size +0c 2>/dev/null | sort)
  while IFS= read -r file; do
    signature="$(od -An -tx1 -N8 "${file}" | tr -d ' \n')"
    [[ "${signature}" == "456c6646696c6500" ]] && evtx_files+=("${file}")
  done < <(find "${offline_dir}/winevt" -type f -iname '*.evtx' -size +0c 2>/dev/null | sort)
  [[ ${#dump_files[@]} -gt 0 ]] || die "offline extraction produced no nonempty MEMORY.DMP or minidump; resources retained"

  dump_parse_status="unavailable"
  evtx_parse_status="unavailable"
  if [[ -x "${script_dir}/parse-dump-header.sh" ]]; then
    if bash "${script_dir}/parse-dump-header.sh" "${dump_files[@]}" >"${out_dir}/parse-dump-header.json" &&
      jq -e '.ok == true' "${out_dir}/parse-dump-header.json" >/dev/null; then
      dump_parse_status="parsed"
    else
      dump_parse_status="failed"
    fi
  fi
  if [[ ${#evtx_files[@]} -gt 0 && -x "${script_dir}/extract-evtx.py" ]]; then
    data_dir="${BSOD_DATA_DIR:-${script_dir}/../../data}"
    if python3 "${script_dir}/extract-evtx.py" --data-dir "${data_dir}" "${evtx_files[@]}" >"${out_dir}/evtx-events.json" &&
      jq -e '.ok == true' "${out_dir}/evtx-events.json" >/dev/null; then
      evtx_parse_status="parsed"
    else
      evtx_parse_status="failed"
    fi
  fi

  dump_paths="$(for file in "${dump_files[@]}"; do printf '%s\n' "${file#"${out_dir}/"}"; done | jq -R . | jq -s .)"
  evtx_paths="$(for file in "${evtx_files[@]:-}"; do printf '%s\n' "${file#"${out_dir}/"}"; done | jq -R . | jq -s 'map(select(length>0))')"
}

function cleanup_success() {
  oc delete pod "${recovery_pod}" -n "${namespace}" --ignore-not-found --wait=true >/dev/null
  oc delete pvc "${artifact_pvc}" -n "${namespace}" --ignore-not-found --wait=true >/dev/null
  oc delete pvc "${restore_pvc}" -n "${namespace}" --ignore-not-found --wait=true >/dev/null
  oc delete volumesnapshot "${snapshot_name}" -n "${namespace}" --ignore-not-found --wait=true >/dev/null
}

log "creating offline snapshot of ${namespace}/${guest_pvc} for ${namespace}/${vm}"
current_stage="snapshot-create"
apply_snapshot
current_stage="snapshot-ready"
wait_snapshot
current_stage="restore-pvc-create"
apply_restore_pvc
current_stage="restore-pvc-ready"
wait_pvc "${restore_pvc}"
current_stage="artifact-pvc-create"
apply_artifact_pvc
current_stage="artifact-pvc-ready"
wait_pvc "${artifact_pvc}"
current_stage="extractor-pod-create"
apply_recovery_pod
current_stage="extractor-pod-complete"
wait_pod
current_stage="artifact-transfer-and-parse"
copy_and_validate

current_stage="resource-cleanup"
cleanup_success

jq -n --arg vm "${vm}" --arg ns "${namespace}" --arg pvc "${guest_pvc}" \
  --arg snapshot "${snapshot_name}" --arg dumpStatus "${dump_parse_status}" \
  --arg evtxStatus "${evtx_parse_status}" --argjson dumps "${dump_paths}" \
  --argjson evtx "${evtx_paths}" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{ok:true,mode:"rhov-offline-recovery",vm:$vm,namespace:$ns,osPvc:$pvc,
    recoveredAt:$at,recovery:{path1MemoryDump:false,path2Snapshot:true,snapshot:$snapshot},
    artifacts:{dumps:$dumps,evtx:$evtx},parsing:{dump:$dumpStatus,evtx:$evtxStatus},
    logs:["recovery.log"]}' \
  >"${out_dir}/recovery-summary.json"
chmod 0600 "${out_dir}/recovery-summary.json"

recovery_complete=1
log "offline recovery succeeded; artifacts copied and validated in ${out_dir}"
