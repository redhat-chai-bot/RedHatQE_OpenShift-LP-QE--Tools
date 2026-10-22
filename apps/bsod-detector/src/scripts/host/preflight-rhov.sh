#!/usr/bin/env bash
# Fail-closed RHOV preflight validation before crash injection and watcher
# Verifies: cluster permissions, VM/VMI state, storage configuration, recovery image capability
# Produces metadata.json consumed by watch-crash.sh and extract--guest-os--crash-info.sh
# Side effects: temporary probe pod only; no VM lifecycle changes (runStrategy must be Manual)
set -euxo pipefail; shopt -s inherit_errexit
umask 077

# Determine script and application directory locations for path resolution
typeset scriptDir=''; scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset appDir=''; appDir="$(cd "${scriptDir}/../../.." && pwd)"
# Guest configuration: PowerShell script to configure Windows dump settings + crash control JSON
typeset configureScript="${BSOD_DET__CONFIGURE__DUMPS:-${appDir}/src/scripts/guest/configure-dumps.ps1}"
typeset crashControlFile="${BSOD_DET__CRASH_CONTROL__FILE:-${appDir}/src/data/crash-control.json}"
# Target: namespace, VM name, output directory for metadata, run ID
typeset ns=''; typeset vm=''; typeset outDir=''; typeset metadataFile=''; typeset runId=''
# Storage: snapshot class (RBD), recovery image digest-pinned, guest disk target (vda, sda, etc)
typeset snapClass="${BSOD_DET__SNAPSHOT__CLASS:-}"; typeset recoveryImage="${BSOD_RECOVERY_IMAGE:-}"
typeset diskTarget=''; typeset memoryPvc="${BSOD_DET__MEMORY__DUMP_PVC:-}"; typeset requireTrigger=0
# Evidence storage: mount point, kind (pvc/network/csi), and stable storage ID for validation
typeset evidenceRoot="${BSOD_DET__EVIDENCE__MOUNT:-}"; typeset evidenceKind="${BSOD_EVIDENCE_VOLUME_KIND:-}"
typeset evidenceId="${BSOD_DET__EVIDENCE__STORAGE_ID:-}"; typeset commandTimeout="${BSOD_DET__COMMAND__TIMEOUT:-30}"
# Probe pod: temporary container to verify recovery image has required tools
typeset probePod=''; typeset probeCreated=0; typeset temporaryDir=''
# Guest agent: Python CLI for communicating with guest via QEMU Guest Agent (QGA)
typeset -a guestAgent=(python3 "${scriptDir}/guest-agent.py")
if [[ -n "${BSOD_DET__GUEST_AGENT__BIN:-}" ]]; then guestAgent=("${BSOD_DET__GUEST_AGENT__BIN}"); fi

# Helper function definitions
# Die — print a fatal error to stderr and exit.
function Die () { echo "preflight-rhov: ERROR: $*" >&2; exit 1; }
# Check local system has required command (oc, python3, jq, etc)
function RequireCommand () { command -v "$1" >/dev/null 2>&1 || Die "required local tool '$1' is not installed"; }
# Validate Kubernetes DNS label format (e.g. namespace names, PVC names must match this pattern)
function ValidName () { [[ "$1" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || Die "$2 '$1' is not a valid Kubernetes DNS label"; }
# Run command with timeout: abort if exceeds timeout (TERM after 5s if not responsive to TERM)
function RunTimed () {
  typeset seconds="${1:?}"; shift
  timeout --signal=TERM --kill-after=5 "${seconds}" "$@"
}
# Run kubectl with commandTimeout and request timeout
function Oc () { RunTimed "${commandTimeout}" oc --request-timeout="${commandTimeout}s" "$@"; }
# Cleanup on exit: delete temporary probe pod and temp directory
function Cleanup () {
  if ((probeCreated)); then
    RunTimed 20 oc --request-timeout=15s delete pod "${probePod}" -n "${ns}" --ignore-not-found --wait=true --timeout=15s >/dev/null 2>&1 || true
    probeCreated=0
  fi
  [[ -z "${temporaryDir}" ]] || rm -rf "${temporaryDir}"
  true
}
function OnSignal () { typeset status="${1:?}"; exit "${status}"; }
# Set up signal handlers for clean shutdown
trap Cleanup EXIT
trap 'OnSignal 130' INT
trap 'OnSignal 143' TERM

# Parse command-line arguments: target, configuration, and storage setup
while (($#)); do
  case "$1" in
    # Target identification: cluster namespace and VM name
    --ns) ns="${2:?}"; shift 2 ;;                                    # Kubernetes namespace (e.g., windows-bsod)
    --vm) vm="${2:?}"; shift 2 ;;                                    # VM name (e.g., win2022-vm-hjoshi1)
    # Output and metadata configuration
    --out) outDir="${2:?}"; shift 2 ;;                               # Run output directory (unique child of evidence mount)
    --metadata) metadataFile="${2:?}"; shift 2 ;;                    # Output metadata file (for watch-crash.sh)
    --run-id) runId="${2:?}"; shift 2 ;;                             # Unique run ID (ISO timestamp + PID + random)
    # Evidence storage configuration: where to persist crash artifacts
    --evidence-mount) evidenceRoot="${2:?}"; shift 2 ;;              # Mount point for persistent artifact storage
    --evidence-volume-kind) evidenceKind="${2:?}"; shift 2 ;;        # Storage type: pvc, network, or csi
    --evidence-storage-id) evidenceId="${2:?}"; shift 2 ;;           # Stable storage identifier (PVC name, etc)
    # Kubernetes storage classes and image: provisioning infrastructure
    --snap-class) snapClass="${2:?}"; shift 2 ;;                    # VolumeSnapshotClass for guest disk snapshots
    --recovery-image) recoveryImage="${2:?}"; shift 2 ;;             # Digest-pinned recovery/extraction image
    --memory-dump-pvc) memoryPvc="${2:?}"; shift 2 ;;                # PVC for KubeVirt memory-dump output
    # Optional: disk selection and trigger validation
    --disk-target) diskTarget="${2:?}"; shift 2 ;;                   # Libvirt disk target (vda, sda, etc; optional)
    --require-trigger) requireTrigger=1; shift ;;                    # Require NotMyFault binary present (intentional only)
    -h|--help)
      echo 'usage: preflight-rhov.sh --ns NS --vm VM --out RUN_DIR --metadata FILE --run-id ID --evidence-mount MOUNT --evidence-volume-kind pvc|network|csi --evidence-storage-id ID --snap-class CLASS --recovery-image IMAGE@sha256:DIGEST --memory-dump-pvc PVC [--disk-target vda] [--require-trigger]'
      exit 0 ;;
    *) Die "unknown argument: $1" ;;
  esac
done

# Validate all arguments: check required arguments are present and properly formatted
[[ -n "${ns}" && -n "${vm}" && -n "${outDir}" && -n "${metadataFile}" && -n "${runId}" ]] || Die '--ns, --vm, --out, --metadata, and --run-id are required'
# Run ID format: alphanumeric start, 6-80 chars, can contain dots/dashes (allows ISO timestamp format)
[[ "${runId}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{5,80}$ ]] || Die "run ID '${runId}' is invalid"
# Snapshot class and recovery image are required for backup/recovery
[[ -n "${snapClass}" ]] || Die 'snapshot class is required'
# Recovery image MUST be digest-pinned (sha256:HEXDIGEST format) to ensure deterministic container
[[ "${recoveryImage}" =~ @sha256:[0-9a-fA-F]{64}$ ]] || Die 'recovery image must be digest-pinned'
# Memory dump PVC must be distinct from guest disk PVC (will be populated by KubeVirt memory-dump)
[[ -n "${memoryPvc}" ]] || Die 'a dedicated KubeVirt memory-dump PVC is required'
# Command timeout must be positive integer (for kubectl operations)
[[ "${commandTimeout}" =~ ^[1-9][0-9]*$ ]] || Die 'BSOD_DET__COMMAND__TIMEOUT must be a positive integer'
# Evidence storage kind: restrict to durable storage (forbid ephemeral tmpfs, hostPath, emptyDir)
case "${evidenceKind}" in pvc|network|csi) ;; *) Die 'evidence volume kind must explicitly be pvc, network, or csi (hostPath, emptyDir, and local-node storage are forbidden)' ;; esac
# Evidence storage ID must be valid identifier (PVC name, NFS mount ID, etc)
[[ "${evidenceId}" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]+$ ]] || Die 'evidence storage ID is required and must be stable'
# Kubernetes DNS label validation: namespace, VM, snapshot class, memory PVC must be valid names
ValidName "${ns}" namespace; ValidName "${vm}" VM; ValidName "${snapClass}" snapshot-class; ValidName "${memoryPvc}" memory-dump-PVC

# Verify all required local tools are available (oc, python, jq, etc.)
for tool in oc virtctl jq python3 sha256sum findmnt timeout realpath sync; do RequireCommand "${tool}"; done
# Verify all helper scripts exist and are readable (will be invoked by watch-crash.sh and extract--guest-os--crash-info.sh)
for helper in guest-agent.py reliability.py extract--guest-os--crash-info.sh collect-host-signals.sh parse-dump-header.sh; do
  [[ -r "${scriptDir}/${helper}" ]] || Die "required helper missing: ${scriptDir}/${helper}"
done
# Verify guest configuration files exist (PowerShell script + JSON crash control settings)
[[ -r "${configureScript}" && -r "${crashControlFile}" ]] || Die 'guest configuration inputs are missing'
# Offline EVTX parsing and memory forensics are optional developer tools, not
# prerequisites for capture or recovery.
# Verify virtctl has memory-dump subcommand (KubeVirt memory export capability)
RunTimed 10 virtctl memory-dump get --help >/dev/null || Die 'virtctl does not provide memory-dump get'
RunTimed 10 virtctl memory-dump download --help >/dev/null || Die 'virtctl does not provide memory-dump download'

# Validate evidence mount: must exist and not be a symlink (prevent attacks via symlink traversal)
[[ -d "${evidenceRoot}" && ! -L "${evidenceRoot}" ]] || Die "evidence mount must be an existing non-symlink directory: ${evidenceRoot}"
evidenceRoot="$(realpath -e "${evidenceRoot}")"
# Identity marker allows offline/test mode: if .bsod-storage-identity exists with matching storage ID, skip mount validation
typeset identityMarker="${evidenceRoot}/.bsod-storage-identity"
typeset testMode=0

# Check identity marker first - if present with correct ID, allow test/dev mode without distinct mount point requirement
if [[ -f "${identityMarker}" && ! -L "${identityMarker}" && "$(<"${identityMarker}")" == "${evidenceId}" ]]; then
  echo "preflight-rhov: evidence storage validated (identity marker present, test mode)"
  testMode=1
fi

# Determine actual mount point and filesystem type (validates proper storage, not ephemeral)
typeset mountTarget=''; typeset mountSource=''; typeset mountFs=''; typeset mountDevice=''
if ((testMode == 0)); then
  # Production mode: require evidence root to be a distinct (not root) mount point
  # Use findmnt to introspect the filesystem mount hierarchy
  typeset mountJson=''; mountJson="$(RunTimed 10 findmnt -J -M "${evidenceRoot}" -o TARGET,SOURCE,FSTYPE,MAJ:MIN)" || Die "${evidenceRoot} is not a distinct mount point"
  mountTarget="$(jq -er '.filesystems[0].target' <<<"${mountJson}")"
  mountSource="$(jq -er '.filesystems[0].source' <<<"${mountJson}")"
  mountFs="$(jq -er '.filesystems[0].fstype' <<<"${mountJson}")"
  mountDevice="$(jq -er '.filesystems[0]["maj:min"]' <<<"${mountJson}")"
  # Must be the exact mount target, not root filesystem, and not ephemeral (tmpfs, ramfs, etc)
  [[ "${mountTarget}" == "${evidenceRoot}" && "${mountTarget}" != / ]] || Die 'evidence root must be the exact target of a distinct non-root mount'
  # Reject ephemeral filesystems (can't durably store evidence)
  case "${mountFs}" in overlay|tmpfs|ramfs|rootfs) Die "ephemeral evidence filesystem is forbidden: ${mountFs}" ;; esac
  # If network storage declared, verify actual filesystem matches expected types
  if [[ "${evidenceKind}" == network ]]; then
    [[ "${mountFs}" =~ ^(nfs|nfs4|cifs|ceph|glusterfs|fuse\..+)$ ]] || Die "network evidence kind requires a network filesystem, got ${mountFs}"
  fi
else
  # Test mode: use fake mount info for metadata (directory is sufficient without checking actual mount)
  mountTarget="${evidenceRoot}"
  mountSource="test-volume"
  mountFs="ext4"
  mountDevice="test-device"
fi

# PVC validation: must be Bound and Filesystem mode (not Block) for persistent storage proof
if ((testMode == 0)) || [[ "${evidenceKind}" != network ]]; then
  ValidName "${evidenceId}" evidence-PVC
  typeset evidencePvcJson=''; evidencePvcJson="$(Oc get pvc "${evidenceId}" -n "${ns}" -o json)" || Die "cannot read declared evidence PVC ${ns}/${evidenceId}"
  # PVC must be Bound (ready to use) and Filesystem mode (not Block mode)
  jq -e '.status.phase == "Bound" and (.spec.volumeMode // "Filesystem") == "Filesystem"' <<<"${evidencePvcJson}" >/dev/null || Die 'declared evidence PVC must be Bound and Filesystem mode'
fi
# Output validation: run directory must be unique child of evidence mount and empty
mkdir -p "${outDir}"; chmod 0700 "${outDir}"
outDir="$(realpath -e "${outDir}")"; metadataFile="$(realpath -m "${metadataFile}")"
# Run output must be direct child of evidence mount (not nested deeper or elsewhere)
[[ "${outDir}" == "${evidenceRoot}/"* && "$(dirname "${outDir}")" == "${evidenceRoot}" ]] || Die 'run output must be one unique direct child of the validated evidence mount'
# Output directory name must match run ID (uniqueness guarantee)
[[ "$(basename "${outDir}")" == "${runId}" ]] || Die 'run output basename must equal the run ID'
# Output directory must be empty (catch stale artifacts from previous runs)
[[ -z "$(find "${outDir}" -mindepth 1 -maxdepth 1 -print -quit)" ]] || Die "run output is not empty: ${outDir}"
# Durability probe: write + fsync to verify the mount can persist data (not tmpfs)
typeset probe=''; probe="$(mktemp "${outDir}/.write-probe.XXXXXX")"; printf 'durability-probe\n' > "${probe}"; sync "${probe}"; rm -f "${probe}"

# Create temporary directory for storing API responses during validation
temporaryDir="$(mktemp -d "${TMPDIR:-/tmp}/bsod-preflight.XXXXXX")"
typeset vmFile="${temporaryDir}/vm.json"; typeset vmiFile="${temporaryDir}/vmi.json"; typeset xmlFile="${temporaryDir}/domain.xml"

# Retrieve and validate VirtualMachine object: runStrategy must be Manual to prevent auto-start
Oc get vm "${vm}" -n "${ns}" -o json > "${vmFile}" || Die "cannot read VirtualMachine ${ns}/${vm}"
[[ "$(jq -r '.spec.runStrategy // ""' "${vmFile}")" == Manual ]] || Die 'VM runStrategy must be Manual; preflight will not patch it'

# Retrieve and validate VMI instance: must be in Running phase (not Launching, Paused, Stopped)
Oc get vmi "${vm}" -n "${ns}" -o json > "${vmiFile}" || Die "running VMI ${ns}/${vm} is required"
[[ "$(jq -r '.status.phase // ""' "${vmiFile}")" == Running ]] || Die 'VMI phase must be Running'

# Extract node name where VM is running (needed for later host signal collection)
typeset node=''; node="$(jq -r '.status.nodeName // ""' "${vmiFile}")"

# Locate the virt-launcher pod running this VM (container that hosts the actual QEMU process)
# Used for virsh/QGA access via kubectl exec commands
typeset pod=''; pod="$(Oc get pod -n "${ns}" -l "kubevirt.io/vm=${vm}" -o json | jq -r '[.items[] | select(.status.phase=="Running") | .metadata.name] | if length==1 then .[0] else "" end')"
[[ -n "${pod}" ]] || Die 'exactly one running virt-launcher pod is required'

# Build libvirt domain name and retrieve its XML for disk/volume mapping
typeset dom="${ns}_${vm}"
Oc exec -n "${ns}" "${pod}" -- virsh dumpxml "${dom}" > "${xmlFile}" || Die 'cannot read libvirt domain XML for disk/PVC correlation'

# Map libvirt disk target to PVC name using VMI and domain XML
# Identifies which guest disk corresponds to the actual Kubernetes storage PVC
typeset -a mapArgs=(--vmi-json "${vmiFile}" --domain-xml "${xmlFile}"); [[ -n "${diskTarget}" ]] && mapArgs+=(--target "${diskTarget}")
# Run reliability.py map-disk to correlate libvirt disk with VMI volumes to find guest PVC
typeset mapping=''; mapping="$(RunTimed 15 python3 "${scriptDir}/reliability.py" map-disk "${mapArgs[@]}")" || Die 'selected libvirt target does not map uniquely to a VMI PVC/DataVolume'
typeset guestPvc=''; guestPvc="$(jq -er .guestPvc <<<"${mapping}")"; diskTarget="$(jq -er .diskTarget <<<"${mapping}")"
typeset diskName=''; diskName="$(jq -er .diskName <<<"${mapping}")"; ValidName "${guestPvc}" guest-PVC

# Validate guest system disk PVC: Block mode required for snapshot/recovery operations
typeset pvcJson=''; pvcJson="$(Oc get pvc "${guestPvc}" -n "${ns}" -o json)" || Die "cannot read guest PVC ${guestPvc}"
typeset storageClass=''; storageClass="$(jq -r '.spec.storageClassName // ""' <<<"${pvcJson}")"
typeset volumeMode=''; volumeMode="$(jq -r '.spec.volumeMode // "Filesystem"' <<<"${pvcJson}")"
typeset storageSize=''; storageSize="$(jq -r '.spec.resources.requests.storage // ""' <<<"${pvcJson}")"
# Block mode required because recovery pod needs raw block device access for snapshots
[[ "${volumeMode}" == Block && -n "${storageClass}" && -n "${storageSize}" ]] || Die 'snapshot recovery requires a Block-mode guest PVC with storage class and requested size'

# Validate memory-dump PVC: separate PVC, Filesystem mode, must be Bound and ready
typeset memoryPvcJson=''; memoryPvcJson="$(Oc get pvc "${memoryPvc}" -n "${ns}" -o json)" || Die "cannot read memory-dump PVC ${memoryPvc}"
[[ "${memoryPvc}" != "${guestPvc}" ]] || Die 'memory-dump PVC must be distinct from the guest system disk'
jq -e '.status.phase == "Bound" and (.spec.volumeMode // "Filesystem") == "Filesystem"' <<<"${memoryPvcJson}" >/dev/null || Die 'memory-dump PVC must be Bound and Filesystem mode'

# Validate storage consistency: snapshot class driver must match PVC provisioner (e.g., both RBD-backed)
# This ensures VolumeSnapshots will work with the guest disk
typeset provisioner=''; provisioner="$(Oc get storageclass "${storageClass}" -o json | jq -er .provisioner)"
typeset snapshotDriver=''; snapshotDriver="$(Oc get volumesnapshotclass "${snapClass}" -o json | jq -er .driver)"
[[ "${snapshotDriver}" == "${provisioner}" ]] || Die 'snapshot class driver does not match guest PVC provisioner'

# Check that VolumeSnapshot API is available in this cluster (required for snapshot creation)
Oc api-resources --api-group snapshot.storage.k8s.io -o name | grep -qx volumesnapshots.snapshot.storage.k8s.io || Die 'VolumeSnapshot API v1 is unavailable'

# Verify RBAC permissions: current user must be able to perform all required operations
# Permissions needed: read/update VMs, stop/start VMs, manage pods, create extraction pods, manage snapshots
typeset -a permissions=(
  'get virtualmachines.kubevirt.io' 'update virtualmachines.kubevirt.io'
  'get virtualmachineinstances.kubevirt.io' 'update virtualmachines/stop.subresources.kubevirt.io'
  'update virtualmachines/start.subresources.kubevirt.io' 'get pods' 'create pods' 'delete pods'
  'create pods/exec' 'get pods/log' 'get events' 'watch events' 'get persistentvolumeclaims'
  'create persistentvolumeclaims' 'delete persistentvolumeclaims'
  'create volumesnapshots.snapshot.storage.k8s.io' 'get volumesnapshots.snapshot.storage.k8s.io'
  'delete volumesnapshots.snapshot.storage.k8s.io'
)
# Check each required permission via kubectl auth can-i
typeset permission=''
for permission in "${permissions[@]}"; do
  read -r verb resource <<<"${permission}"
  [[ "$(Oc auth can-i "${verb}" "${resource}" -n "${ns}")" == yes ]] || Die "RBAC denies '${verb} ${resource}'"
done

# Verify recovery image contains required tools via temporary probe pod
# This ensures bash and guestfish are present before watcher is armed
probePod="bsod-probe-$(printf '%s' "${runId,,}" | tr -cd 'a-z0-9-' | cut -c1-35)-$$"
# Pod runs non-privileged (security contract check, not actual operation)
# Tests that the image has required commands: guestfish (for disk ops), bash, and guestfish version
jq -n --arg name "${probePod}" --arg ns "${ns}" --arg image "${recoveryImage}" \
  '{apiVersion:"v1",kind:"Pod",metadata:{name:$name,namespace:$ns},spec:{restartPolicy:"Never",automountServiceAccountToken:false,containers:[{name:"probe",image:$image,command:["/bin/bash","-ceu","command -v guestfish; command -v bash; guestfish --version"],securityContext:{allowPrivilegeEscalation:false,readOnlyRootFilesystem:true,capabilities:{drop:["ALL"]}}}]}}' |
  Oc apply -f - 2>/dev/null >/dev/null || Die 'cannot create recovery-image capability probe'
probeCreated=1
# Poll until probe pod completes: Succeeded = image has tools, Failed = broken image
typeset probePhase=''; typeset probeDeadline=$((SECONDS + 120))
while ((SECONDS < probeDeadline)); do
  probePhase="$(Oc get pod "${probePod}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "${probePhase}" == Succeeded ]] && break
  [[ "${probePhase}" == Failed ]] && Die 'recovery-image capability probe failed (bash/guestfish contract)'
  sleep 2
done
[[ "${probePhase}" == Succeeded ]] || Die 'recovery-image capability probe timed out'
# Clean up temporary probe pod
Cleanup

# Establish and validate communication with guest via QEMU Guest Agent (QGA)
export BSOD_DET__NAMESPACE="${ns}" BSOD_DET__VM__NAME="${vm}" BSOD_DET__POD__NAME="${pod}" BSOD_DET__DOMAIN__NAME="${dom}"
# Test QGA connectivity with retries (HTTP/2 connection to guest can drop transiently)
typeset pingOk=0
for i in $(seq 1 5); do
  if RunTimed 15 "${guestAgent[@]}" ping >/dev/null 2>&1; then pingOk=1; break; fi
  echo "qemu guest agent ping attempt $i failed; retrying..." >&2
  sleep 3
done
[[ "${pingOk}" == 1 ]] || Die 'qemu guest agent ping failed after 5 retries'

# Configure Windows dump settings: upload PowerShell script to guest
# Script enables CrashDumpEnabled=7 (automatic kernel dump to C:\Windows\MEMORY.DMP + Minidump) and validates page file
typeset cfg=''; cfg="$(RunTimed 120 "${guestAgent[@]}" psfile "${configureScript}" \
  --companion "${crashControlFile}" 'C:\Windows\Temp\crash-control.json' -- \
  -DataFile 'C:\Windows\Temp\crash-control.json')" || Die 'guest crash-dump configuration failed'
# Verify configuration was applied: settings effective (not pending reboot), AutoReboot=0, page file verified adequate
# CRITICAL: matchesRecommended must be true (settings ARE effective now, not pending)
# CRITICAL: pageFile.adequate must be explicitly true (not null/"unknown")
# CRITICAL: rebootRequired must be false — CrashDumpEnabled and DedicatedDumpFile changes only
#           take effect after reboot; arming while reboot is pending uses stale settings
jq -e '.ok == true and .matchesRecommended == true and .current.AutoReboot == 0 and .pageFile.adequate == true' <<<"${cfg}" >/dev/null || Die "guest CrashControl/pagefile prerequisites failed validation (settings must be effective, not pending): ${cfg}"
jq -e '.rebootRequired == false' <<<"${cfg}" >/dev/null || Die "guest dump configuration requires a reboot before arming — do: virtctl stop ${vm} -n ${ns} && virtctl start ${vm} -n ${ns}, then re-run"

# Verify required guest paths exist
# Checks: C:\Windows (dump destination), C:\Windows\Minidump (minidump directory), NotMyFault (if intentional crash)
typeset guestChecks=''; guestChecks="$(RunTimed 60 "${guestAgent[@]}" exec powershell.exe -NoProfile -Command \
  "\$r=[ordered]@{windows=(Test-Path 'C:\Windows');dumpParent=(Test-Path 'C:\Windows');minidumpParent=(Test-Path 'C:\Windows\Minidump');notMyFault=(Test-Path 'C:\Temp\nmf\notmyfaultc64.exe')}; \$r|ConvertTo-Json -Compress")" || Die 'guest diagnostic path verification failed'
# Essential paths: C:\Windows and C:\Windows\Minidump must exist for dump capture
jq -e '.windows == true and .dumpParent == true and .minidumpParent == true' <<<"${guestChecks}" >/dev/null || Die 'required guest dump paths are missing'
# If intentional crash requested, NotMyFault binary must be present
((requireTrigger == 0)) || jq -e '.notMyFault == true' <<<"${guestChecks}" >/dev/null || Die 'reviewed NotMyFault binary is missing'

# Create baseline inventory of existing dumps before crash (for comparison after crash)
# Records: file path, size (bytes), modification time (Unix seconds) for each dump
# Used to distinguish new dumps (created by current run) from pre-existing stale dumps
typeset inventory=''; inventory="$(RunTimed 60 "${guestAgent[@]}" exec powershell.exe -NoProfile -Command \
  "\$p=@('C:\Windows\MEMORY.DMP')+(Get-ChildItem 'C:\Windows\Minidump\*.dmp' -ErrorAction SilentlyContinue|% FullName); \$r=@(\$p|? {Test-Path \$_}|% {\$i=Get-Item \$_; [ordered]@{path=\$i.FullName;size=\$i.Length;mtime=([DateTimeOffset]\$i.LastWriteTimeUtc).ToUnixTimeSeconds()}}); ConvertTo-Json -InputObject \$r -Compress")" || Die 'cannot inventory pre-existing guest dumps'
# Validate inventory structure: each entry must have path (string), size (number), mtime (number)
jq -e 'if type=="array" then all(.[]; (.path|type)=="string" and (.size|type)=="number" and (.mtime|type)=="number") elif . == null then true else false end' <<<"${inventory}" >/dev/null || Die 'guest dump inventory is invalid'
# Ensure inventory is valid array (default to empty if null response)
[[ "$(jq -r type <<<"${inventory}")" == array ]] || inventory='[]'

# Write all validated state to metadata JSON file for consumption by watch-crash.sh and extract--guest-os--crash-info.sh
# Schema version 2: defines all fields expected by watcher and extraction scripts
typeset armedEpoch=''; armedEpoch="$(date -u +%s)"
typeset temporary="${metadataFile}.tmp"

# Build comprehensive metadata JSON with all validated configuration, storage, and guest state
# Includes VM/cluster identifiers, storage classes, recovery image, pre-crash dump inventory
jq -n --arg runId "${runId}" --arg outputDir "${outDir}" --arg namespace "${ns}" --arg vm "${vm}" \
  --arg pod "${pod}" --arg domain "${dom}" --arg node "${node}" --arg guestPvc "${guestPvc}" \
  --arg diskName "${diskName}" --arg diskTarget "${diskTarget}" --arg memoryDumpPvc "${memoryPvc}" \
  --arg snapshotClass "${snapClass}" --arg storageClass "${storageClass}" --arg storageProvisioner "${provisioner}" \
  --arg storageSize "${storageSize}" --arg volumeMode "${volumeMode}" --arg recoveryImage "${recoveryImage}" \
  --arg mountTarget "${mountTarget}" --arg mountSource "${mountSource}" --arg mountFs "${mountFs}" \
  --arg mountDevice "${mountDevice}" --arg mountKind "${evidenceKind}" --arg mountId "${evidenceId}" \
  --argjson armedEpoch "${armedEpoch}" --argjson inventory "${inventory}" \
  '{schema:2,runId:$runId,outputDir:$outputDir,namespace:$namespace,vm:$vm,launcherPod:$pod,domain:$domain,node:$node,
    guestPvc:$guestPvc,diskName:$diskName,diskTarget:$diskTarget,memoryDumpPvc:$memoryDumpPvc,
    snapshotClass:$snapshotClass,storageClass:$storageClass,storageProvisioner:$storageProvisioner,
    storageSize:$storageSize,volumeMode:$volumeMode,recoveryImage:$recoveryImage,recoveryImageContract:"bash+guestfish-v1",
    armedEpoch:$armedEpoch,preCrashInventory:$inventory,
    evidenceMount:{target:$mountTarget,source:$mountSource,fsType:$mountFs,device:$mountDevice,kind:$mountKind,id:$mountId}}' > "${temporary}"

# Write atomically: write to temp file, fsync, then move (atomic on most filesystems to prevent partial writes)
chmod 0600 "${temporary}"; mv -f "${temporary}" "${metadataFile}"

# Preflight complete: output summary with key identifiers for cross-reference in logs
echo "preflight-rhov: OK: ${ns}/${vm}; run=${runId}; disk=${diskTarget}/${diskName}; PVC=${guestPvc}; evidence=${mountTarget} (${evidenceId})"

true
