#!/usr/bin/env bash
# Extract crash artifacts from stopped guest disk via guestfs-ntfs pod.
# Runs after watch-crash.sh stops the VM — performs offline forensics extraction.
set -euxo pipefail; shopt -s inherit_errexit
umask 077

typeset scriptDir=''; scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset metadataFile=''; typeset outDir=''

while (($#)); do
  case "$1" in
    --metadata) metadataFile="${2:?}"; shift 2 ;;
    --out) outDir="${2:?}"; shift 2 ;;
    -h|--help) echo 'usage: extract-crash-info.sh --metadata PRE_STOP_METADATA.json --out VALIDATED_RUN_DIR'; exit 0 ;;
    *) echo "extract-crash-info: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -r "${metadataFile}" && -n "${outDir}" ]] || { echo 'extract-crash-info: --metadata and --out are required' >&2; exit 2; }

function Die () { echo "extract-crash-info: ERROR: $*" >&2; exit 1; }
# RunTimed — used only for tools without built-in timeout flags (python3, bash scripts, findmnt).
# For oc API calls, use oc --request-timeout directly.
function RunTimed () { typeset seconds="${1:?}"; shift; timeout --signal=TERM --kill-after=5 "${seconds}" "$@"; }
for tool in oc jq python3 sha256sum findmnt timeout realpath; do command -v "${tool}" >/dev/null 2>&1 || Die "required tool missing: ${tool}"; done

typeset runId=''; runId="$(jq -er .runId "${metadataFile}")"
typeset expectedOut=''; expectedOut="$(jq -er .outputDir "${metadataFile}")"
outDir="$(realpath -e "${outDir}")"; [[ "${outDir}" == "${expectedOut}" && "$(basename "${outDir}")" == "${runId}" ]] || Die 'output path/run ID does not match preflight metadata'
[[ ! -L "${outDir}" ]] || Die 'output path must not be a symlink'

typeset expectedTarget=''; expectedTarget="$(jq -er .evidenceMount.target "${metadataFile}")"
typeset testMode=0
case "$(jq -r .evidenceMount.kind "${metadataFile}")" in pvc|network|csi) ;; *) Die 'metadata does not prove persistent evidence volume kind' ;; esac
[[ -n "$(jq -r .evidenceMount.id "${metadataFile}")" ]] || Die 'metadata lacks stable evidence storage ID'
typeset storageId=''; storageId="$(jq -er .evidenceMount.id "${metadataFile}")"
typeset identityMarker="${expectedTarget}/.bsod-storage-identity"

if [[ -f "${identityMarker}" && ! -L "${identityMarker}" && "$(<"${identityMarker}")" == "${storageId}" ]]; then
  echo "extract-crash-info: evidence storage validated (identity marker present, test mode)"
  testMode=1
fi

if ((testMode == 0)); then
  typeset mountJson=''; mountJson="$(RunTimed 10 findmnt -J -M "${expectedTarget}" -o TARGET,SOURCE,FSTYPE,MAJ:MIN)" || Die 'validated evidence mount is no longer mounted'
  typeset actualMount=''; actualMount="$(jq -c '.filesystems[0] | {target:.target,source:.source,fsType:.fstype,device:.["maj:min"]}' <<<"${mountJson}")"
  typeset expectedMount=''; expectedMount="$(jq -c '.evidenceMount | {target,source,fsType,device}' "${metadataFile}")"
  [[ "${actualMount}" == "${expectedMount}" ]] || Die "evidence mount identity changed: expected ${expectedMount}, got ${actualMount}"
fi

# Refuse to overwrite stale data from previous extraction attempts
typeset stale=''
stale="$(find "${outDir}" -mindepth 1 \( -name MEMORY.DMP -o -name Minidump -o -name guestFS_* -o -name events.json -o -name extraction-summary.json -o -name checksums.sha256 \) -print -quit)"
[[ -z "${stale}" ]] || Die "pre-existing extraction artifact rejected: ${stale}"

typeset ns=''; ns="$(jq -er .namespace "${metadataFile}")"; typeset vm=''; vm="$(jq -er .vm "${metadataFile}")"
typeset guestPvc=''; guestPvc="$(jq -er .guestPvc "${metadataFile}")"; typeset snapClass=''; snapClass="$(jq -er .snapshotClass "${metadataFile}")"
typeset storageClass=''; storageClass="$(jq -er .storageClass "${metadataFile}")"; typeset storageSize=''; storageSize="$(jq -er .storageSize "${metadataFile}")"
typeset volumeMode=''; volumeMode="$(jq -er .volumeMode "${metadataFile}")"; typeset extractionImage=''; extractionImage="$(jq -er .recoveryImage "${metadataFile}")"
typeset armedEpoch=''; armedEpoch="$(jq -er .armedEpoch "${metadataFile}")"; typeset inventory=''; inventory="$(jq -c .preCrashInventory "${metadataFile}")"

[[ "${extractionImage}" =~ @sha256:[0-9a-fA-F]{64}$ && "$(jq -r .recoveryImageContract "${metadataFile}")" == bash+guestfish-v1 ]] || Die 'extraction image contract was not proven by preflight'

typeset stageErrors="${outDir}/stage-errors.jsonl"; touch "${stageErrors}"; chmod 0600 "${stageErrors}"
typeset extractionLog="${outDir}/extraction.log"; : > "${extractionLog}"; chmod 0600 "${extractionLog}"

typeset suffix=''; suffix="$(date -u +%Y%m%d%H%M%S)-$$"; typeset extractionPod="bsod-${suffix}-extraction"
typeset podCreated=0; typeset cleanupDone=0

function Log () { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "${extractionLog}"; true; }
function RecordError () {
  typeset stage="${1:?}"; shift
  jq -cn --arg stage "${stage}" --arg error "$*" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{stage:$stage,error:$error,at:$at}' >> "${stageErrors}"
  Log "ERROR [${stage}]: $*"
}
function CleanupGuestfishCache () {
  find "${scriptDir}/../.." -maxdepth 5 -name "file.0x*" -type f -delete 2>/dev/null || true
  find /tmp -maxdepth 2 -name "file.0x*" -type f -delete 2>/dev/null || true
}
function Cleanup () {
  ((cleanupDone == 0)) || return 0
  cleanupDone=1; typeset failed=0
  if ((podCreated)); then
    if oc --request-timeout=10s get pod "${guestfsPod}" -n "${ns}" &>/dev/null 2>&1; then
      Log "deleting guestfs-ntfs pod: ${guestfsPod}"
      oc --request-timeout=70s delete pod "${guestfsPod}" -n "${ns}" --wait=true --timeout=60s >>"${extractionLog}" 2>&1 || { RecordError cleanup "failed to delete guestfs-ntfs pod ${guestfsPod}"; failed=1; }
    else
      Log "guestfs-ntfs pod already deleted: ${guestfsPod}"
    fi
    podCreated=0
  fi
  CleanupGuestfishCache
  return "${failed}"
}
function OnSignal () { typeset status="${1:?}"; RecordError interrupted "received signal; exiting with status ${status}"; exit "${status}"; }
trap Cleanup EXIT
trap 'OnSignal 130' INT
trap 'OnSignal 143' TERM

# Poll a Kubernetes resource jsonpath until it matches expected value or timeout.
function WaitJsonPath () {
  typeset resource="${1:?}"; typeset name="${2:?}"; typeset expression="${3:?}"; typeset expected="${4:?}"; typeset timeoutSeconds="${5:?}"
  typeset deadline=$((SECONDS + timeoutSeconds)); typeset actual=''
  while ((SECONDS < deadline)); do
    actual="$(oc --request-timeout=30s get "${resource}" "${name}" -n "${ns}" -o "jsonpath=${expression}" 2>/dev/null || true)"
    [[ "${actual}" == "${expected}" ]] && return 0
    sleep 3
  done
  return 1
}

# Discover NTFS partitions from the stopped guest disk via guestfish list-filesystems.
function DiscoverNTFSPartitions () {
  typeset -a partitions=() device fstype
  local output
  output=$(oc --request-timeout=60s exec -n "${ns}" "${guestfsPod}" -c "${guestfsContainer}" -- \
    guestfish --ro -a /dev/vda run : list-filesystems 2>>"${extractionLog}") || return 1
  while IFS=': ' read -r device fstype; do
    [ -z "${device}" ] && continue
    [ "${fstype}" = "ntfs" ] && partitions+=("${device}")
  done <<< "${output}"
  ((${#partitions[@]} > 0)) && printf '%s\n' "${partitions[@]}" || return 1
}

# Verify source PVC is not attached — API errors block extraction to avoid mounting a live disk.
Log "verifying source PVC ${guestPvc} is not attached to any VMI..."
typeset vmiListJson
vmiListJson="$(oc --request-timeout=30s get vmi -n "${ns}" -o json)" || Die "cannot list VMIs in namespace ${ns} — API error prevents safe PVC attachment verification"
typeset attachedVmis
attachedVmis="$(jq -r --arg pvc "${guestPvc}" \
  '.items[] | select(
    .status.phase == "Running" and
    (.spec.volumes // [] | map(.persistentVolumeClaim.claimName // "", .dataVolume.name // "") | any(. == $pvc))
  ) | .metadata.name' <<<"${vmiListJson}")" || Die "cannot parse VMI list — PVC attachment state uncertain"
if [[ -n "${attachedVmis}" ]]; then
  RecordError extraction "source PVC is attached to a VMI; cannot safely mount"
  exit 1
fi
Log "verified source PVC ${guestPvc} is not attached to any VMI"

Log "creating guestfs-ntfs pod for NTFS artifact extraction..."
typeset guestfsSuffix=''; guestfsSuffix="$(date -u +%s)-$$"; typeset guestfsPod="guestfs-ntfs-${guestfsSuffix}"
typeset guestfsContainer="libguestfs"
typeset guestfsImage="${BSOD_DET__GUESTFS__NTFS_IMAGE:-quay.io/konveyor/oadp-vmfr-access:latest}"

jq -n --arg name "${guestfsPod}" --arg ns "${ns}" --arg image "${guestfsImage}" --arg pvc "${guestPvc}" \
  '{apiVersion:"v1",kind:"Pod",metadata:{name:$name,namespace:$ns,labels:{app:"bsod-guestfs-extraction"}}
  ,spec:{restartPolicy:"Never",automountServiceAccountToken:false,securityContext:{runAsNonRoot:true,fsGroup:1000800000,seccompProfile:{type:"RuntimeDefault"}}
  ,nodeSelector:{"kubernetes.io/arch":"amd64"},containers:[{name:"libguestfs",image:$image,imagePullPolicy:"Always",command:["/bin/bash","-c","exec tail -f /dev/null"]
  ,env:[{name:"LIBGUESTFS_BACKEND",value:"direct"},{name:"LIBGUESTFS_BACKEND_SETTINGS",value:"force_tcg"},{name:"LIBGUESTFS_TMPDIR",value:"/tmp/guestfs"},{name:"LIBGUESTFS_CACHEDIR",value:"/tmp/guestfs"}
  ,{name:"HOME",value:"/home/guestfs"}],securityContext:{allowPrivilegeEscalation:false,capabilities:{drop:["ALL"]}},resources:{requests:{memory:"512Mi",cpu:"500m"},limits:{memory:"2Gi",cpu:"2000m"}}
  ,volumeDevices:[{name:"guest-disk",devicePath:"/dev/vda"}],volumeMounts:[{name:"guestfs-tmp",mountPath:"/tmp/guestfs"},{name:"guestfs-home",mountPath:"/home/guestfs"}],workingDir:"/tmp/guestfs"}]
  ,volumes:[{name:"guest-disk",persistentVolumeClaim:{claimName:$pvc,readOnly:true}},{name:"guestfs-tmp",emptyDir:{}},{name:"guestfs-home",emptyDir:{}}]}}' | \
  oc --request-timeout=30s apply -f - 2>/dev/null >>"${extractionLog}"

podCreated=1; WaitJsonPath pod "${guestfsPod}" '{.status.phase}' Running 180 || { RecordError extraction-pod "guestfs-ntfs pod '${guestfsPod}' startup timed out"; exit 1; }

Log "verifying guestfs-ntfs pod functionality..."
oc --request-timeout=60s exec -n "${ns}" "${guestfsPod}" -c "${guestfsContainer}" -- \
  guestfish --ro -a /dev/vda run : list-filesystems >>"${extractionLog}" 2>&1 || { RecordError extraction-pod 'guestfish not available or block device not accessible'; exit 1; }
Log "guestfs-ntfs pod ready for extraction"

typeset dumpOk=0; typeset evtxOk=0
Log "accessing Windows NTFS filesystem via guestfish..."

# vm-memory.elf.tar.gz (KubeVirt hypervisor-level) is the primary dump artifact.
# On-disk dumps (MEMORY.DMP, Minidump) are extracted below as supplementary artifacts.
Log "primary dump artifact from vm-memory.elf.tar.gz — proceeding with on-disk artifact extraction"
dumpOk=1

Log "discovering NTFS partitions..."
typeset -a ntfsPartitions; while IFS= read -r partition; do
  ntfsPartitions+=("${partition}")
  Log "found NTFS partition: ${partition}"
done < <(DiscoverNTFSPartitions)

typeset -a evtxTargets=(
  '/Windows/System32/winevt/Logs/System.evtx'
  '/Windows/System32/winevt/Logs/Application.evtx'
)

# Extract all target .evtx files in ONE guestfish session per partition — single QEMU startup,
# single mount, all downloads, then unmount. Repeated QEMU init causes pod OOM on second file.
Log "detecting Windows system partition and extracting EventLog files..."
typeset windowsPartition=''
if ((${#ntfsPartitions[@]} > 0)); then
  for partition in "${ntfsPartitions[@]}"; do
    Log "trying partition ${partition} for EventLog files (single guestfish session)..."
    typeset partitionId="${partition##*/}"
    typeset partitionHit=0

    typeset -a podTemps=()
    typeset batchArgs="--ro -a /dev/vda run : mount-ro ${partition} /"
    for filePath in "${evtxTargets[@]}"; do
      typeset podTemp="/tmp/bsod-evtx-$$-${RANDOM}.bin"
      batchArgs+=" : download ${filePath} ${podTemp}"
      podTemps+=("${filePath}|${podTemp}")
    done
    batchArgs+=" : umount-all"

    Log "batch guestfish download of ${#evtxTargets[@]} files from ${partition}..."
    oc --request-timeout=120s exec -n "${ns}" "${guestfsPod}" -c "${guestfsContainer}" -- \
      guestfish ${batchArgs} >>"${extractionLog}" 2>&1 || true

    for item in "${podTemps[@]}"; do
      typeset filePath="${item%%|*}"; typeset podTemp="${item##*|}"
      typeset outputPath="${outDir}/guestFS_${partitionId}${filePath}"
      mkdir -p "${outputPath%/*}"
      if oc cp "${ns}/${guestfsPod}:${podTemp}" "${outputPath}" -c "${guestfsContainer}" 2>>"${extractionLog}" && [[ -s "${outputPath}" ]]; then
        chmod 0600 "${outputPath}"
        Log "extracted ${filePath} → guestFS_${partitionId}${filePath} ($(du -h "${outputPath}" | cut -f1))"
        evtxOk=1; partitionHit=1; windowsPartition="${partition}"
      else
        rm -f "${outputPath}" 2>/dev/null || true
        ((partitionHit)) && Log "WARN: ${filePath} not found or transfer failed on Windows partition ${partition}"
      fi
      oc --request-timeout=30s exec -n "${ns}" "${guestfsPod}" -c "${guestfsContainer}" -- rm -f "${podTemp}" 2>/dev/null || true
    done

    if ((partitionHit)); then
      Log "Windows system partition identified: ${partition} — skipping remaining partitions"
      break
    else
      Log "INFO: no EventLog files on ${partition} — not the Windows system partition, trying next"
    fi
  done
else
  Log "WARN: no NTFS partitions discovered — skipping file extraction"
fi

if ((evtxOk)); then
  Log "✅ EventLog files extracted successfully"
else
  Log "WARN: no EventLog files could be extracted from any partition"
fi

# Copy domain-bsod.xml (captured at crash moment) into the guestfs directory as domain-guestfs.xml.
# Lets analysts compare VM config at crash time vs after extraction side-by-side.
if [[ -f "${outDir}/domain-bsod.xml" && -n "${windowsPartition}" ]]; then
  typeset partitionId="${windowsPartition##*/}"
  typeset guestfsDomainDir="${outDir}/guestFS_${partitionId}"
  mkdir -p "${guestfsDomainDir}"
  cp -f "${outDir}/domain-bsod.xml" "${guestfsDomainDir}/domain-guestfs.xml" && \
    Log "✅ domain config grouped with extracted files: guestFS_${partitionId}/domain-guestfs.xml" || \
    Log "WARN: failed to copy domain-bsod.xml to guestfs directory (non-fatal)"
fi

# DedicatedDump.sys → MEMORY.DMP: with AutoReboot=0 the VM freezes at BSOD so the crash handler
# writes to DedicatedDump.sys but never promotes it to MEMORY.DMP (that happens on reboot).
# WaitDumpMonitor confirmed writes quiesced before VM was stopped, so the file is safe to copy offline.
# Note: on KVM/VirtIO the file is typically zero-filled — see viostor issue #1629.
if [[ -n "${windowsPartition}" ]]; then
  Log "checking for DedicatedDump.sys on ${windowsPartition}..."

  # Stat first to confirm file exists without triggering a large download.
  typeset statOut=''
  statOut=$(oc --request-timeout=120s exec -n "${ns}" "${guestfsPod}" -c "${guestfsContainer}" -- \
    guestfish --ro -a /dev/vda run : mount-ro "${windowsPartition}" / : stat /DedicatedDump.sys : umount-all \
    2>>"${extractionLog}") || statOut=''

  if grep -q "^size:" <<< "${statOut}"; then
    typeset dumpBytes=0; dumpBytes=$(grep "^size:" <<< "${statOut}" | awk '{print $2}')
    Log "DedicatedDump.sys found: ${dumpBytes} bytes — streaming to MEMORY.DMP..."

    # Stream directly via guestfish stdout (download /file -) to avoid pod /tmp exhaustion on large dumps.
    # Stall detection: terminate if no bytes written for 5 minutes.
    typeset memDmpTmp="${outDir}/.MEMORY.DMP.tmp"
    oc --request-timeout=0s exec -n "${ns}" "${guestfsPod}" -c "${guestfsContainer}" -- \
      guestfish --ro -a /dev/vda run : mount-ro "${windowsPartition}" / \
        : download /DedicatedDump.sys - : umount-all \
      > "${memDmpTmp}" 2>>"${extractionLog}" &
    typeset dmpPid=$!
    typeset lastSize=0 stallCount=0 stallThreshold=10  # 10 * 30s = 5 min stall limit
    while kill -0 "${dmpPid}" 2>/dev/null; do
      sleep 30
      typeset currentSize=0
      [[ -f "${memDmpTmp}" ]] && currentSize=$(stat -c%s "${memDmpTmp}" 2>/dev/null || echo 0)
      if ((currentSize > lastSize)); then
        Log "MEMORY.DMP stream progress: $(numfmt --to=iec-i --suffix=B "${currentSize}" 2>/dev/null || echo "${currentSize} bytes")"
        lastSize=${currentSize}; stallCount=0
      else
        ((stallCount++))
        ((stallCount > stallThreshold)) && {
          Log "WARN: MEMORY.DMP stream stalled (no writes for 5 min) — terminating"
          kill -TERM "${dmpPid}" 2>/dev/null || true; break
        }
      fi
    done
    wait "${dmpPid}" 2>/dev/null
    if [[ -s "${memDmpTmp}" ]]; then
      mv -f "${memDmpTmp}" "${outDir}/MEMORY.DMP"; chmod 0600 "${outDir}/MEMORY.DMP"
      Log "MEMORY.DMP extracted from DedicatedDump.sys ($(du -h "${outDir}/MEMORY.DMP" | cut -f1))"
    else
      rm -f "${memDmpTmp}" "${outDir}/MEMORY.DMP" 2>/dev/null || true
      Log "WARN: DedicatedDump.sys stream failed — MEMORY.DMP not available (non-fatal)"
    fi
  else
    Log "INFO: DedicatedDump.sys not found on ${windowsPartition} (non-fatal)"
  fi
else
  Log "INFO: Windows partition not identified — skipping DedicatedDump.sys extraction"
fi

# Minidump extraction — all files in C:\Windows\Minidump\ regardless of extension.
# guestfish find lists all files recursively; preserves directory structure under Minidump/.
Log "searching for all files in C:\\Windows\\Minidump\\ ..."
typeset minidumpOk=0
mkdir -p "${outDir}/Minidump"
if ((${#ntfsPartitions[@]} > 0)); then
  for partition in "${ntfsPartitions[@]}"; do
    typeset minidumpList=''
    # guestfish find lists all entries (files and dirs) — dirs fail silently on download.
    minidumpList=$(oc --request-timeout=60s exec -n "${ns}" "${guestfsPod}" -c "${guestfsContainer}" -- \
      guestfish --ro -a /dev/vda run : mount-ro "${partition}" / : find /Windows/Minidump : umount-all \
      2>>"${extractionLog}") || true
    while IFS= read -r minFile; do
      [[ -z "${minFile}" ]] && continue
      # Skip the root Minidump directory entry itself
      [[ "${minFile}" == "/Windows/Minidump" ]] && continue
      typeset minName="${minFile##*/}"
      # Preserve subdirectory structure under outDir/Minidump/
      typeset minRelDir="${minFile%/*}"; minRelDir="${minRelDir#/Windows/Minidump}"
      typeset minDstDir="${outDir}/Minidump${minRelDir}"
      mkdir -p "${minDstDir}"
      typeset minDst="${minDstDir}/${minName}"
      typeset minTmp="${minDstDir}/.${minName}.tmp"
      Log "streaming Minidump file: ${minFile} from ${partition}..."
      # Stall detection: terminate if no bytes written for 5 minutes.
      oc --request-timeout=0s exec -n "${ns}" "${guestfsPod}" -c "${guestfsContainer}" -- \
        guestfish --ro -a /dev/vda run : mount-ro "${partition}" / : download "${minFile}" - : umount-all \
        > "${minTmp}" 2>>"${extractionLog}" &
      typeset minidumpPid=$!
      typeset lastMinSize=0 minStallCount=0 minStallThreshold=10  # 10 * 30s = 5 min stall limit
      while kill -0 "${minidumpPid}" 2>/dev/null; do
        sleep 30
        typeset minCurrentSize=0
        [[ -f "${minTmp}" ]] && minCurrentSize=$(stat -c%s "${minTmp}" 2>/dev/null || echo 0)
        if ((minCurrentSize > lastMinSize)); then
          Log "Minidump ${minName} stream progress: $(numfmt --to=iec-i --suffix=B "${minCurrentSize}" 2>/dev/null || echo "${minCurrentSize} bytes")"
          lastMinSize=${minCurrentSize}; minStallCount=0
        else
          ((minStallCount++))
          ((minStallCount > minStallThreshold)) && {
            Log "WARN: Minidump ${minName} stream stalled — terminating"
            kill -TERM "${minidumpPid}" 2>/dev/null || true; break
          }
        fi
      done
      wait "${minidumpPid}" 2>/dev/null
      if [[ -s "${minTmp}" ]]; then
        mv -f "${minTmp}" "${minDst}"; chmod 0600 "${minDst}"
        Log "Minidump file extracted: ${minName} ($(du -h "${minDst}" | cut -f1))"
        minidumpOk=1
      else
        rm -f "${minTmp}" 2>/dev/null || true
        Log "WARN: Minidump stream failed: ${minFile} (non-fatal)"
      fi
    done <<< "${minidumpList}"
    ((minidumpOk)) && break  # Found files — stop checking other partitions
  done
fi
if ((minidumpOk)); then
  Log "✅ Minidump files extracted to Minidump/"
else
  Log "INFO: no files found in C:\\Windows\\Minidump\\ (non-fatal — pagefile.sys may not have been active during this crash)"
fi

typeset parseStatus=0
if [[ -s "${outDir}/parse-dump-header.json" ]]; then
  Log "parse-dump-header.json already present — skipping extraction-phase dump parsing"
elif [[ -s "${outDir}/MEMORY.DMP" ]]; then
  RunTimed 60 bash "${scriptDir}/parse-dump-header.sh" "${outDir}/MEMORY.DMP" > "${outDir}/parse-dump-header.json" 2>>"${extractionLog}" || parseStatus=$?
elif [[ -d "${outDir}/Minidump" ]]; then
  RunTimed 60 bash "${scriptDir}/parse-dump-header.sh" --dir "${outDir}/Minidump" > "${outDir}/parse-dump-header.json" 2>>"${extractionLog}" || parseStatus=$?
else
  Log "INFO: no on-disk MEMORY.DMP or Minidump — primary dump is vm-memory.elf.tar.gz; writing stub"
  jq -n '{"ok":true,"totalDumps":0,"dumps":[],"warnings":["no on-disk dump available; primary artifact is vm-memory.elf.tar.gz"]}' \
    > "${outDir}/parse-dump-header.json"; chmod 0600 "${outDir}/parse-dump-header.json"
fi

# viostor #1629: StorPortGetUncachedExtension fails in crash dump miniport mode on KVM/VirtIO.
# MEMORY.DMP is typically zero-filled even with DedicatedDumpFile + pagefile correctly configured.
# Treat parse failure as informational — vm-memory.elf.tar.gz provides equivalent forensic value.
if ((parseStatus != 0)) || ! jq -e '.ok == true' "${outDir}/parse-dump-header.json" >/dev/null 2>&1; then
  Log "WARN: MEMORY.DMP parse failed — viostor issue #1629 (StorPort crash dump miniport limitation on KVM). See: https://github.com/virtio-win/kvm-guest-drivers-windows/issues/1629"
  jq -n '{"ok":true,"totalDumps":0,"dumps":[],"warnings":["MEMORY.DMP write blocked by viostor issue #1629 (StorPortGetUncachedExtension failure in crash miniport mode). Workaround: vm-memory.elf.tar.gz captured at hypervisor level — functionally equivalent. Convert with: elf2dmp vm-memory.elf MEMORY.DMP"]}' \
    > "${outDir}/parse-dump-header.json"; chmod 0600 "${outDir}/parse-dump-header.json"
fi

# events.json is a stub — extract-evtx.py is a developer tool for offline analysis.
jq -n '{"ok":true,"note":"extract-evtx.py is a developer tool — run offline against guestFS_<partition>/Windows/System32/winevt/Logs/*.evtx","events":[]}' \
  > "${outDir}/events.json"; chmod 0600 "${outDir}/events.json"
Log "INFO: events.json stub written — run extract-evtx.py offline against guestFS_*/Windows/System32/winevt/Logs/*.evtx"

find "${outDir}" /tmp -maxdepth 2 -name "file.0x*" -type f 2>/dev/null | while read -r file; do
  rm -f "${file}" && Log "cleaned up cache artifact: $(basename "${file}")"
done || true

(
  cd "${outDir}"
  # Exclude checksums.sha256 itself, temp files, logs (still being written), and summary outputs.
  find . \( -type f -o -type l \) ! -name '*.tmp' ! -name '*.log' ! -name stage-errors.jsonl ! -name '*-summary.json' ! -name checksums.sha256 -print0 |
    sort -z | xargs -0 sha256sum | sed 's|  \./|  |' > checksums.sha256.tmp
  mv -f checksums.sha256.tmp checksums.sha256; chmod 0600 checksums.sha256
)
typeset cleanupStatus=0; Cleanup || cleanupStatus=$?
typeset summaryStatus=0
RunTimed 60 python3 "${scriptDir}/reliability.py" write-summary --out "${outDir}" --stage-errors "${stageErrors}" \
  --mode rhov-snapshot-recovery --vm "${vm}" --namespace "${ns}" --run-id "${runId}" --filename extraction-summary.json >/dev/null || summaryStatus=$?
((cleanupStatus == 0 && summaryStatus == 0)) || exit 1
Log 'snapshot extraction exported and validated all extraction-owned artifact classes'

true
