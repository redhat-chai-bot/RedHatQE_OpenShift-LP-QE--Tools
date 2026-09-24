#!/usr/bin/env bash
exec {BASH_XTRACEFD}>/dev/null
set -euxo pipefail; shopt -s inherit_errexit

export LIBVIRT_DEFAULT_URI=qemu:///system
typeset repoDir=''; repoDir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repoDir}"

typeset triggerFile="${repoDir}/src/data/chaos-triggers.json"
[[ -f "${triggerFile}" ]] || { : "chaos-triggers.json not found at ${triggerFile}"; exit 2; }

typeset vmName="${VM_NAME:-bsod-test}"
typeset mode="sweep"
typeset filterTrigger=""
typeset -i filterTier=0

while (($#)); do
  case "$1" in
    --prep-snapshots) mode="prep-snapshots"; shift ;;
    --trigger)        filterTrigger="${2:?--trigger requires an ID}"; shift 2 ;;
    --tier)           filterTier="${2:?--tier requires a number}"; shift 2 ;;
    -h|--help)        sed -n '2,30p' "$0"; exit 0 ;;
    *)                : "unknown arg: $1"; exit 2 ;;
  esac
done

typeset originalXml=""

# Poll SSH until the guest responds or maxAttempts is exhausted (8s intervals).
function WaitSsh () {
  typeset -i maxAttempts="${1:-30}"
  typeset -i i=0
  while ((i < maxAttempts)); do
    if ./host/guest-ssh.sh -c '"up"' 2>/dev/null | grep -q up; then
      return 0
    fi
    sleep 8
    ((++i))
  done
  return 1
}

# Block until pvpanic signals a crash via libvirt lifecycle event, or timeout.
# Falls back to domstate polling if virsh event is unavailable.
function DetectCrash () {
  typeset -i timeoutSec="${1:-120}"

  typeset event=""
  event=$(virsh event --domain "${vmName}" --event lifecycle \
    --timeout "${timeoutSec}" 2>/dev/null) || true

  if echo "${event}" | grep -qi "crashed"; then
    return 0
  fi

  typeset state=''
  state="$(virsh domstate "${vmName}" 2>/dev/null)" || state="unknown"
  [[ "${state}" == "crashed" || "${state}" == "shut off" ]]
}

# Wait for guest reboot; force virsh reset if SSH does not return in time.
function WaitReboot () {
  typeset -i maxAttempts="${1:-40}"
  if WaitSsh "${maxAttempts}"; then
    return 0
  fi
  virsh reset "${vmName}" 2>&1 || true
  sleep 30
  WaitSsh 20
  true
}

# Run collect-guest.ps1 via SSH and save guest-side crash evidence + host signals.
function CollectGuestEvidence () {
  typeset triggerId="${1}"
  typeset chaosDir="output/chaos-${triggerId}"
  mkdir -p "${chaosDir}"

  typeset json=""
  json=$(./host/guest-ssh.sh -c "& C:\\bsod-detector\\scripts\\collect-guest.ps1 -OutputDir C:\\bsod-detector\\output\\chaos-${triggerId}" 2>&1) || true
  if [[ -n "${json}" ]]; then
    echo "${json}" > "${chaosDir}/collect-guest.json"
  else
    echo '{"ok":false,"warnings":["collect-guest.ps1 produced no output"]}' > "${chaosDir}/collect-guest.json"
  fi

  ./src/scripts/collect-host-signals.sh --vm "${vmName}" > "${chaosDir}/host-signals.json" 2>/dev/null || true
  true
}

# Destroy the VM and extract crash evidence from the disk image offline.
function CollectHostOfflineEvidence () {
  typeset triggerId="${1}"
  typeset chaosDir="output/chaos-${triggerId}"
  mkdir -p "${chaosDir}"

  virsh destroy "${vmName}" 2>&1 || true
  sleep 5

  if [[ -x "host-tools/run.sh" ]]; then
    host-tools/run.sh --disk /var/lib/libvirt/images/bsod-test.qcow2 \
      > "${chaosDir}/host-extract.json" 2>/dev/null || true
  else
    echo '{"ok":false,"warnings":["host-tools/run.sh not found; offline extraction unavailable"]}' \
      > "${chaosDir}/host-extract.json"
  fi

  ./src/scripts/collect-host-signals.sh --vm "${vmName}" > "${chaosDir}/host-signals.json" 2>/dev/null || true
  true
}

# Write a JSON result file for one trigger run (outcome, elapsed, collection method).
function RecordResult () {
  typeset triggerId="${1}"
  typeset outcome="${2}"
  typeset observedCode="${3:-null}"
  typeset -i elapsed="${4:-0}"
  typeset collectedVia="${5:-none}"

  typeset chaosDir="output/chaos-${triggerId}"
  mkdir -p "${chaosDir}"

  python3 - "${triggerId}" "${outcome}" "${observedCode}" "${elapsed}" "${collectedVia}" <<'PY' \
    > "${chaosDir}/result.json"
import json, sys, datetime
triggerId, outcome, code, elapsed, via = sys.argv[1:6]
result = {
    "trigger": triggerId,
    "outcome": outcome,
    "observedCode": None if code == "null" else code,
    "elapsedSeconds": int(elapsed),
    "collectedVia": via,
    "timestamp": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
}
print(json.dumps(result, indent=2))
PY
  true
}

# Parse the bug check code from collect-guest.json, or "null" if unavailable.
function ExtractObservedCode () {
  typeset triggerId="${1}"
  typeset chaosDir="output/chaos-${triggerId}"
  typeset jsonFile="${chaosDir}/collect-guest.json"
  if [[ -f "${jsonFile}" ]]; then
    python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    code = d.get('crash', {}).get('bugCheckCode')
    print(code if code else 'null')
except Exception:
    print('null')
" "${jsonFile}"
  else
    echo "null"
  fi
  true
}

# Ensure the domain has <panic model='isa'/> and on_crash=preserve.
# Destroys a running domain if needed (caller must virsh start afterward).
function EnsurePvpanicConfig () {
  typeset domState=''
  domState="$(virsh domstate "${vmName}" 2>/dev/null)" || domState="unknown"

  typeset xml=''
  if [[ "${domState}" == "running" || "${domState}" == "paused" ]]; then
    xml="$(virsh dumpxml "${vmName}" 2>/dev/null)" || return 0
  else
    xml="$(virsh dumpxml --inactive "${vmName}" 2>/dev/null)" || return 0
  fi

  typeset needsDefine=false
  if ! echo "${xml}" | grep -q '<panic '; then
    needsDefine=true
  fi
  if echo "${xml}" | grep -q '<on_crash>destroy</on_crash>'; then
    needsDefine=true
  fi

  if [[ "${needsDefine}" == "true" ]]; then
    if [[ "${domState}" == "running" || "${domState}" == "paused" ]]; then
      virsh destroy "${vmName}" 2>&1 || true
      sleep 1
    fi
    typeset tmpXml=''; tmpXml="$(mktemp /tmp/chaos-pvpanic-XXXXXX.xml)"
    python3 -c "
import sys, re
xml = sys.stdin.read()
xml = re.sub(r\"<domain type='kvm' id='[0-9]+'>\", \"<domain type='kvm'>\", xml)
xml = xml.replace('<on_crash>destroy</on_crash>', '<on_crash>preserve</on_crash>')
if '<panic model=' not in xml:
    xml = xml.replace('</devices>', '    <panic model=\"isa\"/>\n  </devices>')
sys.stdout.write(xml)
" <<< "${xml}" > "${tmpXml}"
    virsh define "${tmpXml}" 2>&1 || true
    rm -f "${tmpXml}"
  fi
  true
}

# Snapshot the current domain XML so it can be restored after trigger-specific changes.
function SaveOriginalDomainXml () {
  originalXml="$(mktemp /tmp/chaos-original-XXXXXX.xml)"
  virsh dumpxml "${vmName}" > "${originalXml}" 2>&1
  true
}

# Redefine the domain from the saved XML and clean up the temp file.
function RestoreOriginalDomainXml () {
  if [[ -n "${originalXml}" && -f "${originalXml}" ]]; then
    virsh define "${originalXml}" 2>&1 || true
    rm -f "${originalXml}"
    originalXml=""
  fi
  true
}

# Disable specified Hyper-V enlightenments in the domain XML for testing.
function ApplyEnlightenmentToggles () {
  typeset triggerJson="${1}"

  SaveOriginalDomainXml

  typeset modifiedXml=''; modifiedXml="$(mktemp /tmp/chaos-modified-XXXXXX.xml)"
  cp "${originalXml}" "${modifiedXml}"

  typeset -a toDisable=()
  while IFS= read -r feat; do
    toDisable+=("${feat}")
  done < <(echo "${triggerJson}" | python3 -c "
import json, sys
t = json.load(sys.stdin)
for e in t.get('disableEnlightenments', []):
    print(e)
")

  for feat in "${toDisable[@]}"; do
    sed -i "s|<${feat} state='on'|<${feat} state='off'|g" "${modifiedXml}"
    sed -i "s|<${feat} state=\"on\"|<${feat} state=\"off\"|g" "${modifiedXml}"
  done

  virsh define "${modifiedXml}" 2>&1
  rm -f "${modifiedXml}"
  true
}

# Inject a non-maskable interrupt into the guest.
function ExecuteNmiInject () {
  virsh inject-nmi "${vmName}" 2>&1
  true
}

# Reduce guest memory via virtio-balloon to targetMemoryKiB.
function ExecuteBalloonSqueeze () {
  typeset triggerJson="${1}"
  typeset -i targetKiB=0; targetKiB=$(echo "${triggerJson}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('targetMemoryKiB', 1048576))")
  virsh setmem "${vmName}" "${targetKiB}" 2>&1
  true
}

# Live-detach a disk device from the guest.
function ExecuteDeviceHotremove () {
  typeset triggerJson="${1}"
  typeset deviceTarget=''; deviceTarget=$(echo "${triggerJson}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('deviceTarget', 'vda'))")
  virsh detach-disk "${vmName}" "${deviceTarget}" --live 2>&1 || true
  true
}

# Bring the guest NIC down for 10 seconds, then back up.
function ExecuteNetworkToggle () {
  typeset iface=""
  if ! iface=$(virsh domiflist "${vmName}" 2>/dev/null | awk 'NR>2 && NF{print $1; exit}'); then
    iface=""
  fi
  if [[ -z "${iface}" ]]; then
    : "no network interface found; skipping"
    return 1
  fi
  virsh domif-setlink "${vmName}" "${iface}" down 2>&1 || true
  sleep 10
  virsh domif-setlink "${vmName}" "${iface}" up 2>&1 || true
  true
}

# Reduce live vCPU count to targetVcpus.
function ExecuteVcpuHotremove () {
  typeset triggerJson="${1}"
  typeset -i targetVcpus=0; targetVcpus=$(echo "${triggerJson}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('targetVcpus', 1))")
  virsh setvcpus "${vmName}" "${targetVcpus}" --live 2>&1 || true
  true
}

# Inject EIO errors on all block I/O via QMP blkdebug interposition.
function ExecuteBlkdebugConfig () {
  virsh qemu-monitor-command "${vmName}" '{
    "execute": "blockdev-add",
    "arguments": {
      "driver": "blkdebug",
      "node-name": "blkdebug-chaos",
      "inject-error": [
        {"event": "read_aio", "errno": 5, "once": false, "immediately": true, "sector": -1},
        {"event": "write_aio", "errno": 5, "once": false, "immediately": true, "sector": -1},
        {"event": "flush_to_disk", "errno": 5, "once": false, "immediately": true, "sector": -1}
      ],
      "image": "libvirt-3-storage"
    }
  }' 2>&1

  virsh qemu-monitor-command "${vmName}" '{
    "execute": "blockdev-reopen",
    "arguments": {
      "options": [{
        "driver": "qcow2",
        "node-name": "libvirt-3-format",
        "file": "blkdebug-chaos"
      }]
    }
  }' 2>&1
  true
}

# Throttle block I/O to near-zero IOPS/bandwidth via blkdeviotune.
function ExecuteBlkdeviotune () {
  typeset triggerJson="${1}"
  typeset deviceTarget=''; deviceTarget=$(echo "${triggerJson}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('deviceTarget', 'vda'))")
  typeset -i iops=0; iops=$(echo "${triggerJson}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('throttleTotalIopsSec', 1))")
  typeset -i bps=0; bps=$(echo "${triggerJson}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('throttleTotalBytesSec', 512))")
  virsh blkdeviotune "${vmName}" "${deviceTarget}" \
    --total-iops-sec "${iops}" --total-bytes-sec "${bps}" 2>&1
  true
}

# Inject a Machine Check Exception into vCPU 0 via QMP HMP passthrough.
function ExecuteMceInject () {
  typeset triggerJson="${1}"
  typeset mceCmd=''
  mceCmd=$(echo "${triggerJson}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('mceCommandLine','mce 0 9 0xbd80000000000164 0xb200000000000000 0 0 0'))")
  virsh qemu-monitor-command "${vmName}" \
    "{\"execute\":\"human-monitor-command\",\"arguments\":{\"command-line\":\"${mceCmd}\"}}" 2>&1
  true
}

# Pause the VM for pauseSeconds, then resume to test clock desync handling.
function ExecutePauseResume () {
  typeset triggerJson="${1}"
  typeset -i pauseSec=0
  pauseSec=$(echo "${triggerJson}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('pauseSeconds', 20))")
  virsh qemu-monitor-command "${vmName}" '{"execute":"stop"}' 2>&1
  sleep "${pauseSec}"
  virsh qemu-monitor-command "${vmName}" '{"execute":"cont"}' 2>&1
  true
}

# Suspend the guest via ACPI (requires QEMU guest agent) and wake after delay.
function ExecuteAcpiSuspend () {
  typeset triggerJson="${1}"
  typeset suspendType=''
  suspendType=$(echo "${triggerJson}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('suspendType', 'mem'))")
  typeset -i delaySec=0
  delaySec=$(echo "${triggerJson}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('suspendDelaySec', 5))")
  virsh dompmsuspend "${vmName}" "${suspendType}" 2>&1 || true
  sleep "${delaySec}"
  virsh dompmwakeup "${vmName}" 2>&1 || true
  true
}

# Write MSRs to vCPU 0 via kvm-msr-write.py while the VM is paused.
function ExecuteMsrWrite () {
  typeset triggerJson="${1}"
  virsh qemu-monitor-command "${vmName}" '{"execute":"stop"}' 2>&1
  sleep 1
  while IFS= read -r line; do
    typeset reg=''; reg=$(echo "${line}" | python3 -c "import json,sys; print(json.load(sys.stdin)['register'])")
    typeset val=''; val=$(echo "${line}" | python3 -c "import json,sys; print(json.load(sys.stdin)['value'])")
    sudo python3 "${repoDir}/vm/kvm-msr-write.py" \
      --vm "${vmName}" --vcpu 0 --msr "${reg}" --value "${val}" 2>&1
  done < <(echo "${triggerJson}" | python3 -c "
import json, sys
for w in json.load(sys.stdin).get('msrWrites', []):
    print(json.dumps(w))
")
  virsh qemu-monitor-command "${vmName}" '{"execute":"cont"}' 2>&1
  true
}

# Enable ACPI suspend-to-mem in domain XML (required for dompmsuspend).
function ApplyAcpiSuspendXml () {
  SaveOriginalDomainXml
  typeset modifiedXml=''; modifiedXml="$(mktemp /tmp/chaos-modified-XXXXXX.xml)"

  python3 -c "
import re, sys
with open(sys.argv[1]) as f:
    xml = f.read()
if '<suspend-to-mem' not in xml:
    xml = xml.replace('</domain>', '  <pm>\n    <suspend-to-mem enabled=\"yes\"/>\n  </pm>\n</domain>')
else:
    xml = re.sub(r'<suspend-to-mem enabled=[\"'\"'\"']no[\"'\"'\"']', '<suspend-to-mem enabled=\"yes\"', xml)
with open(sys.argv[2], 'w') as f:
    f.write(xml)
" "${originalXml}" "${modifiedXml}"

  virsh define "${modifiedXml}" 2>&1
  rm -f "${modifiedXml}"
  true
}

# Execute one chaos trigger: revert snapshot, apply XML, run trigger, detect crash, collect evidence.
function RunTrigger () {
  typeset triggerId="${1}"
  typeset triggerJson="${2}"

  typeset name=''; name=$(echo "${triggerJson}" | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")
  typeset method=''; method=$(echo "${triggerJson}" | python3 -c "import json,sys; print(json.load(sys.stdin)['method'])")
  typeset snapshot=''; snapshot=$(echo "${triggerJson}" | python3 -c "import json,sys; print(json.load(sys.stdin)['snapshot'])")
  typeset collectionPath=''; collectionPath=$(echo "${triggerJson}" | python3 -c "import json,sys; print(json.load(sys.stdin)['collectionPath'])")
  typeset -i timeoutSec=0; timeoutSec=$(echo "${triggerJson}" | python3 -c "import json,sys; print(json.load(sys.stdin)['timeoutSeconds'])")
  typeset -i crashExpected=0; crashExpected=$(echo "${triggerJson}" | python3 -c "import json,sys; print(1 if json.load(sys.stdin)['crashExpected'] else 0)")
  typeset guestWorkload=''; guestWorkload=$(echo "${triggerJson}" | python3 -c "import json,sys; w=json.load(sys.stdin).get('guestWorkload'); print(w if w else '')")
  typeset -i requiresManual=0; requiresManual=$(echo "${triggerJson}" | python3 -c "import json,sys; print(1 if json.load(sys.stdin).get('requiresManualSetup', False) else 0)")

  : "=== [${triggerId}] ${name} ==="

  if ((requiresManual)); then
    : "[${triggerId}] SKIP: requires manual domain XML setup"
    RecordResult "${triggerId}" "skipped" "null" 0 "none"
    return 0
  fi

  # --- Revert to snapshot ---
  : "[${triggerId}] reverting to ${snapshot}"
  if ! virsh snapshot-revert "${vmName}" "${snapshot}" 2>&1; then
    : "[${triggerId}] FAIL: snapshot ${snapshot} not found"
    RecordResult "${triggerId}" "error" "null" 0 "none"
    RestoreOriginalDomainXml
    return 0
  fi

  # --- Apply domain XML changes (after revert restores snapshot config, before start) ---
  EnsurePvpanicConfig
  if [[ "${method}" == "enlightenment-toggle" ]]; then
    ApplyEnlightenmentToggles "${triggerJson}"
  fi
  if [[ "${method}" == "acpi-suspend" ]]; then
    ApplyAcpiSuspendXml
  fi

  virsh start "${vmName}" 2>&1 || true

  # --- Wait for SSH ---
  : "[${triggerId}] waiting for SSH"
  if ! WaitSsh 30; then
    : "[${triggerId}] FAIL: SSH never came up after revert"
    RecordResult "${triggerId}" "error" "null" 0 "none"
    RestoreOriginalDomainXml
    return 0
  fi

  # --- Start guest workload (async) ---
  typeset -i workloadPid=0
  if [[ -n "${guestWorkload}" ]]; then
    : "[${triggerId}] starting guest workload"
    ./host/guest-ssh.sh -c "${guestWorkload}" 2>/dev/null &
    workloadPid=$!
    sleep 5
  fi

  # --- Execute trigger ---
  SECONDS=0
  : "[${triggerId}] executing trigger (method=${method})"
  case "${method}" in
    nmi-inject)          ExecuteNmiInject ;;
    balloon-squeeze)     ExecuteBalloonSqueeze "${triggerJson}" ;;
    device-hotremove)    ExecuteDeviceHotremove "${triggerJson}" ;;
    network-toggle)      ExecuteNetworkToggle ;;
    vcpu-hotremove)      ExecuteVcpuHotremove "${triggerJson}" ;;
    verifier-stress)     : "no host trigger; crash comes from verifier + workload" ;;
    blkdeviotune)        ExecuteBlkdeviotune "${triggerJson}" ;;
    blkdebug-config)     ExecuteBlkdebugConfig ;;
    enlightenment-toggle) : "enlightenment applied at define time; workload is the trigger" ;;
    mce-inject)          ExecuteMceInject "${triggerJson}" ;;
    guest-only)          : "no host trigger; guest workload is the trigger" ;;
    pause-resume)        ExecutePauseResume "${triggerJson}" ;;
    acpi-suspend)        ExecuteAcpiSuspend "${triggerJson}" ;;
    msr-write)           ExecuteMsrWrite "${triggerJson}" ;;
    *) : "[${triggerId}] WARN: unknown method ${method}" ;;
  esac

  if [[ "${method}" == "pause-resume" || "${method}" == "acpi-suspend" ]]; then
    : "[${triggerId}] waiting for guest to stabilize after ${method}"
    sleep 30
  fi

  # --- Detect crash ---
  : "[${triggerId}] watching for crash (timeout=${timeoutSec}s)"
  typeset outcome="no-crash"
  if DetectCrash "${timeoutSec}"; then
    outcome="crashed"
    : "[${triggerId}] crash detected at ${SECONDS}s"
  else
    : "[${triggerId}] no crash within ${timeoutSec}s"
  fi
  typeset -i elapsed="${SECONDS}"

  # --- Clean up workload process ---
  if ((workloadPid > 0)); then
    kill "${workloadPid}" 2>/dev/null || true
    wait "${workloadPid}" 2>/dev/null || true
  fi

  # --- Post-crash cleanup (remove I/O throttle so VM can reboot) ---
  if [[ "${outcome}" == "crashed" && "${method}" == "blkdeviotune" ]]; then
    typeset cleanupDev=''; cleanupDev=$(echo "${triggerJson}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('deviceTarget', 'vda'))")
    : "[${triggerId}] removing I/O throttle before reboot"
    virsh blkdeviotune "${vmName}" "${cleanupDev}" --total-iops-sec 0 --total-bytes-sec 0 2>&1 || true
  fi

  # --- Collect evidence ---
  typeset collectedVia="none"
  if [[ "${outcome}" == "crashed" ]]; then
    typeset domState=''
    domState="$(virsh domstate "${vmName}" 2>/dev/null)" || domState="unknown"

    if [[ "${domState}" == "crashed" || "${domState}" == "paused" ]]; then
      : "[${triggerId}] domain preserved; attempting host-side raw memory capture"
      typeset chaosDir="output/chaos-${triggerId}"
      mkdir -p "${chaosDir}"
      "${repoDir}/src/scripts/capture-host-dump.sh" --vm "${vmName}" --out "${chaosDir}" \
        > "${chaosDir}/capture-host-dump.json" 2>&1 || true

      : "[${triggerId}] destroying and restarting domain"
      virsh destroy "${vmName}" 2>&1 || true
      sleep 2
      virsh start "${vmName}" 2>&1 || true
    fi

    if [[ "${collectionPath}" == "host-offline" ]]; then
      : "[${triggerId}] collecting via host-offline extraction"
      CollectHostOfflineEvidence "${triggerId}"
      collectedVia="host-offline"
    else
      : "[${triggerId}] waiting for reboot to collect guest evidence"
      if WaitReboot 40; then
        CollectGuestEvidence "${triggerId}"
        collectedVia="guest"
      else
        : "[${triggerId}] guest did not reboot; falling back to host-offline"
        CollectHostOfflineEvidence "${triggerId}"
        collectedVia="host-offline"
      fi
    fi
  elif [[ "${outcome}" == "no-crash" ]]; then
    if ((crashExpected)); then
      : "[${triggerId}] expected crash did not occur"
    fi
    CollectGuestEvidence "${triggerId}"
    collectedVia="guest"
  fi

  # --- Extract observed code ---
  typeset observedCode=''; observedCode=$(ExtractObservedCode "${triggerId}")

  # --- Record result ---
  typeset resultJson=''; resultJson=$(RecordResult "${triggerId}" "${outcome}" "${observedCode}" "${elapsed}" "${collectedVia}")
  : "[${triggerId}] result: ${outcome} code=${observedCode} elapsed=${elapsed}s via=${collectedVia}"
  echo "${resultJson}"

  # --- Restore domain XML if modified ---
  RestoreOriginalDomainXml
  true
}

# Create Driver Verifier snapshots by enabling verifier flags and rebooting from crashme-installed.
function PrepSnapshots () {
  : "=== PREPARING CHAOS SNAPSHOTS ==="

  while IFS= read -r entry; do
    typeset snapName=''; snapName=$(echo "${entry}" | python3 -c "import json,sys; print(json.load(sys.stdin)['snapshot'])")
    typeset flags=''; flags=$(echo "${entry}" | python3 -c "import json,sys; print(json.load(sys.stdin)['verifierFlags'])")
    typeset triggerName=''; triggerName=$(echo "${entry}" | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")

    if virsh snapshot-info "${vmName}" "${snapName}" 2>/dev/null | grep -q "Name"; then
      : "[prep] snapshot ${snapName} already exists; skipping"
      continue
    fi

    : "[prep] creating snapshot ${snapName} for ${triggerName}"
    : "[prep] reverting to clean-baseline"
    virsh snapshot-revert "${vmName}" clean-baseline 2>&1
    virsh start "${vmName}" 2>&1 || true

    : "[prep] waiting for SSH"
    if ! WaitSsh 30; then
      : "[prep] FAIL: SSH never came up"
      continue
    fi

    : "[prep] setting verifier flags to ${flags}"
    ./host/guest-ssh.sh -c "verifier /flags ${flags} /all" 2>&1 || true

    : "[prep] rebooting guest to activate verifier"
    ./host/guest-ssh.sh -c "Restart-Computer -Force" 2>&1 || true
    sleep 30

    if ! WaitSsh 30; then
      : "[prep] FAIL: guest did not come back after verifier reboot"
      continue
    fi

    : "[prep] shutting down guest"
    virsh shutdown "${vmName}" 2>&1 || true
    sleep 15
    virsh destroy "${vmName}" 2>&1 || true

    : "[prep] creating snapshot ${snapName}"
    virsh snapshot-create-as "${vmName}" "${snapName}" \
      "clean-baseline + Driver Verifier flags ${flags}" --atomic 2>&1
    : "[prep] snapshot ${snapName} created"
  done < <(python3 - "${triggerFile}" <<'PY'
import json, sys
triggers = json.load(open(sys.argv[1]))['triggers']
for tid, t in triggers.items():
    if t['method'] == 'verifier-stress':
        print(json.dumps({
            'id': tid,
            'snapshot': t['snapshot'],
            'verifierFlags': t['verifierFlags'],
            'name': t['name'],
        }))
PY
  )

  : "=== SNAPSHOT PREPARATION COMPLETE ==="
  virsh snapshot-list "${vmName}" 2>&1
  true
}

# Main entry: iterate all chaos triggers (optionally filtered by --trigger or --tier).
function SweepChaos () {
  typeset -a triggerIds=()
  while IFS= read -r tid; do
    triggerIds+=("${tid}")
  done < <(python3 - "${triggerFile}" "${filterTrigger}" "${filterTier}" <<'PY'
import json, sys
triggers = json.load(open(sys.argv[1]))['triggers']
filterTrigger = sys.argv[2] if len(sys.argv) > 2 else ''
filterTier = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] != '0' else 0
for tid in sorted(triggers.keys()):
    if filterTrigger and tid != filterTrigger:
        continue
    if filterTier and triggers[tid]['tier'] != filterTier:
        continue
    print(tid)
PY
  )

  : "=== CHAOS SWEEP: ${#triggerIds[@]} triggers ==="
  mkdir -p output

  for triggerId in "${triggerIds[@]}"; do
    typeset triggerJson=''; triggerJson=$(python3 -c "
import json, sys
triggers = json.load(open(sys.argv[1]))['triggers']
print(json.dumps(triggers[sys.argv[2]]))
" "${triggerFile}" "${triggerId}")

    RunTrigger "${triggerId}" "${triggerJson}"
  done

  : "=== CHAOS SWEEP COMPLETE ==="

  # --- Summary ---
  python3 - <<'PY'
import json, os, glob
results = []
for f in sorted(glob.glob('output/chaos-*/result.json')):
    try:
        results.append(json.load(open(f)))
    except (json.JSONDecodeError, FileNotFoundError):
        pass
if not results:
    print('No results found.')
else:
    print(f'\n{"Trigger":<35} {"Outcome":<12} {"Code":<14} {"Time":>5}  Via')
    print('-' * 80)
    for r in results:
        code = r.get('observedCode') or '-'
        print(f'{r["trigger"]:<35} {r["outcome"]:<12} {code:<14} {r["elapsedSeconds"]:>4}s  {r["collectedVia"]}')
PY
  true
}

if [[ "${mode}" == "prep-snapshots" ]]; then
  PrepSnapshots
else
  SweepChaos
fi
true
