#!/usr/bin/env bash
# Shared, side-effect-free RHOV validation and lifecycle helpers.

function rhov_die() {
  echo "ERROR: $*" >&2
  return 1
}

function rhov_valid_name() {
  local name="$1" label
  local -a labels=()
  [[ -n "${name}" && ${#name} -le 253 && "${name}" != .* && "${name}" != *. ]] || return 1
  IFS='.' read -r -a labels <<<"${name}"
  for label in "${labels[@]}"; do
    [[ -n "${label}" && ${#label} -le 63 && "${label}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || return 1
  done
}

function rhov_require_name() {
  rhov_valid_name "$2" || rhov_die "$1 must be a valid Kubernetes resource name: '$2'"
}

function rhov_valid_image_digest() {
  local value="$1" reference digest registry repository component last tag=""
  [[ "${value}" != *[[:space:]]* && "${value}" != *://* ]] || return 1
  [[ "${value}" == *@sha256:* && "${value}" != *@*@* ]] || return 1
  reference="${value%@*}"
  digest="${value##*@}"
  [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  [[ "${reference}" == */* && "${reference}" != */ && "${reference}" != *//* ]] || return 1

  registry="${reference%%/*}"
  repository="${reference#*/}"
  [[ "${registry}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$ ]] || return 1

  last="${repository##*/}"
  if [[ "${last}" == *:* ]]; then
    tag="${last##*:}"
    repository="${repository%:*}"
    [[ "${tag}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || return 1
  fi
  IFS='/' read -r -a components <<<"${repository}"
  for component in "${components[@]}"; do
    [[ "${component}" =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]] || return 1
  done
}

function rhov_require_commands() {
  local command_name
  for command_name in "$@"; do
    command -v "${command_name}" >/dev/null 2>&1 || rhov_die "required command not found: ${command_name}"
  done
}

function rhov_vm_json() {
  oc get virtualmachine.kubevirt.io "$2" -n "$1" -o json
}

function rhov_vmi_json() {
  oc get virtualmachineinstance.kubevirt.io "$2" -n "$1" -o json
}

function rhov_validate_vm_contract() {
  local namespace="$1" vm="$2" vm_json
  rhov_require_name namespace "${namespace}" || return
  rhov_require_name VM "${vm}" || return
  vm_json="$(rhov_vm_json "${namespace}" "${vm}" 2>/dev/null)" || {
    rhov_die "VirtualMachine ${namespace}/${vm} does not exist or is not readable"
    return
  }
  jq -e --arg ns "${namespace}" --arg vm "${vm}" \
    '.metadata.namespace == $ns and .metadata.name == $vm' <<<"${vm_json}" >/dev/null || {
    rhov_die "VirtualMachine lookup did not return exact identity ${namespace}/${vm}"
    return
  }
  local strategy
  strategy="$(jq -r '.spec.runStrategy // ""' <<<"${vm_json}")"
  [[ "${strategy}" == "Manual" ]] || {
    rhov_die "VirtualMachine ${namespace}/${vm} must have .spec.runStrategy exactly 'Manual' (found '${strategy:-unset}'); the detector will not mutate the VM spec"
    return
  }
}

function rhov_require_running_vmi() {
  local namespace="$1" vm="$2" vmi_json phase
  vmi_json="$(rhov_vmi_json "${namespace}" "${vm}" 2>/dev/null)" || {
    rhov_die "VirtualMachineInstance ${namespace}/${vm} does not exist; start the Manual VM before arming the detector"
    return
  }
  phase="$(jq -r '.status.phase // ""' <<<"${vmi_json}")"
  [[ "${phase}" == "Running" ]] || {
    rhov_die "VirtualMachineInstance ${namespace}/${vm} must be Running (found '${phase:-unset}')"
    return
  }
  printf '%s\n' "${vmi_json}"
}

function rhov_resolve_launcher() {
  local namespace="$1" vm="$2" vmi_json vmi_uid pods
  vmi_json="$(rhov_vmi_json "${namespace}" "${vm}")" || return
  vmi_uid="$(jq -er '.metadata.uid | select(length > 0)' <<<"${vmi_json}")" || {
    rhov_die "VMI ${namespace}/${vm} does not expose an owner UID"
    return
  }
  pods="$(oc get pods -n "${namespace}" \
    -l "kubevirt.io=virt-launcher,kubevirt.io/domain=${vm}" -o json)" || return
  jq -r --arg vm "${vm}" --arg uid "${vmi_uid}" \
    '[.items[] | select(.metadata.labels["kubevirt.io/domain"] == $vm)
      | select(any(.metadata.ownerReferences[]?;
          .kind == "VirtualMachineInstance" and .uid == $uid))
      | select(.status.phase == "Running") | .metadata.name] |
     if length == 1 then .[0] else error("expected exactly one Running launcher pod owned by the VMI, found \(length)") end' \
    <<<"${pods}"
}

# Print "PVC<TAB>volume-name<TAB>disk-target". A bootOrder=1 disk wins; when
# bootOrder is absent the VMI must expose exactly one persistent disk.
function rhov_resolve_os_pvc() {
  local namespace="$1" vm="$2" requested_pvc="${3:-}" vmi_json result
  vmi_json="$(rhov_vmi_json "${namespace}" "${vm}")" || return
  result="$(jq -er --arg requested "${requested_pvc}" '
    def persistent_volumes:
      [.spec.volumes[] | select(.persistentVolumeClaim or .dataVolume) |
       {name, pvc:(.persistentVolumeClaim.claimName // .dataVolume.name)}];
    def disk_devices:
      [.spec.domain.devices.disks[] | select(.disk != null) |
       {name, bootOrder:(.bootOrder // null)}];
    (persistent_volumes) as $vols |
    (disk_devices) as $disks |
    [$disks[] as $d | $vols[] | select(.name == $d.name) |
      . + {bootOrder:$d.bootOrder,
           target:([.name as $n | $root.status.volumeStatus[]? |
                    select(.name == $n) | .target][0] // "")}] as $all |
    (if $requested != "" then [$all[] | select(.pvc == $requested)]
     else ([$all[] | select(.bootOrder == 1)] as $boot |
           if ($boot|length) == 1 then $boot else $all end) end) as $selected |
    if ($selected|length) != 1 then
      error("expected exactly one OS PVC; set disk bootOrder=1 or pass one --pvc owned by the VMI")
    elif $selected[0].target == "" then
      error("VMI status does not expose the OS disk target for volume " + $selected[0].name)
    else $selected[0] | [.pvc,.name,.target] | @tsv end
  ' --argjson root "${vmi_json}" <<<"${vmi_json}")" || return
  local pvc
  IFS=$'\t' read -r pvc _ <<<"${result}"
  rhov_require_name PVC "${pvc}" || return
  oc get pvc "${pvc}" -n "${namespace}" -o name >/dev/null || {
    rhov_die "resolved OS PVC ${namespace}/${pvc} does not exist"
    return
  }
  printf '%s\n' "${result}"
}

# Parse one virsh domstats sample for one exact block target. Invalid, missing,
# duplicate, or non-numeric samples fail rather than becoming a stable zero.
function rhov_parse_write_bytes() {
  local target="$1"
  awk -F= -v target="${target}" '
    /^block\.[0-9]+\.name=/ {sub(/\.name$/, "", $1); prefix_by_name[$2]=$1; count_by_name[$2]++}
    /^block\.[0-9]+\.wr\.bytes=/ {key=$1; sub(/\.wr\.bytes$/, "", key); writes[key]=$2}
    END {
      p=prefix_by_name[target]
      if (p == "" || count_by_name[target] != 1 || !(p in writes) || writes[p] !~ /^[0-9]+$/) exit 1
      print writes[p]
    }'
}

function rhov_wait_absent() {
  local kind="$1" namespace="$2" name="$3" timeout_seconds="$4" elapsed=0
  while ((elapsed < timeout_seconds)); do
    if ! oc get "${kind}" "${name}" -n "${namespace}" >/dev/null 2>&1; then return 0; fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  rhov_die "timed out after ${timeout_seconds}s waiting for ${kind} ${namespace}/${name} to disappear"
}

function rhov_wait_no_launcher() {
  local namespace="$1" vm="$2" timeout_seconds="$3" elapsed=0 count
  while ((elapsed < timeout_seconds)); do
    count="$(oc get pods -n "${namespace}" -l "kubevirt.io=virt-launcher,kubevirt.io/domain=${vm}" \
      -o json 2>/dev/null | jq '[.items[] | select(.metadata.deletionTimestamp == null)] | length')" || count=-1
    [[ "${count}" == "0" ]] && return 0
    sleep 2
    elapsed=$((elapsed + 2))
  done
  rhov_die "timed out after ${timeout_seconds}s waiting for all launcher pods for ${namespace}/${vm} to disappear"
}

function rhov_wait_ready() {
  local namespace="$1" vm="$2" timeout_seconds="$3" elapsed=0 vmi_json
  while ((elapsed < timeout_seconds)); do
    if vmi_json="$(rhov_vmi_json "${namespace}" "${vm}" 2>/dev/null)" &&
      jq -e '.status.phase == "Running" and
              any(.status.conditions[]?; .type == "AgentConnected" and .status == "True")' \
        <<<"${vmi_json}" >/dev/null; then
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  rhov_die "timed out after ${timeout_seconds}s waiting for VMI Running and guest-agent AgentConnected for ${namespace}/${vm}"
}
