#!/usr/bin/env bash
set -euxo pipefail; shopt -s inherit_errexit

export LIBVIRT_DEFAULT_URI=qemu:///system
typeset repoDir=''; repoDir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"  # crash-injector -> scripts -> src -> app root
cd "${repoDir}"

typeset -a codes=(
  "0x0000000A 0x0 0x0 0x0 0x0"
  "0x00000019 0x3 0x0 0x0 0x0"
  "0x0000001A 0x3F 0xF4EC 0x45C23B3D 0xEBC0C2B3"
  "0x0000001E 0x0 0x0 0x0 0x0"
  "0x0000003D 0xfffff80376bc2cc8 0xfffff80376bc2510 0x0 0x0"
  "0x0000007A 0xffff908313b69b40 0xC0000185 0x707AE860 0xffff8027d77688e8"
  "0x0000007B 0x0 0x0 0x0 0x0"
  "0x0000007E 0x0 0x0 0x0 0x0"
  "0x00000080 0x0 0x0 0x0 0x0"
  "0x0000009F 0x0 0x0 0x0 0x0"
  "0x000000C1 0x0 0x0 0x0 0x0"
  "0x000000C2 0x0 0x0 0x0 0x0"
  "0x000000F7 0x0 0x0 0x0 0x0"
  "0x00000109 0xA3A007E720C9B519 0x0 0x5229358D108F9F1A 0x101"
  "0x00000124 0x0 0x0 0x0 0x0"
  "0x00000133 0x0 0x0 0x0 0x0"
  "0x00000135 0xC0000006 0xFFFFF906CD8C4F80 0xFFFFF8030FA98A90 0xFFFFCC8D699B5920"
  "0x00000154 0xFFFF800A275D0000 0xFFFFB68B2D598F60 0x2 0x0"
  "0x00020001 0x32 0x1 0x0 0x0"
)

# Poll SSH until the guest responds or max attempts is exhausted (8s intervals).
function WaitSsh () {
  typeset max="${1:-30}"
  typeset _i=''
  while IFS= read -r _i; do
    ./src/scripts/host/guest-ssh.sh -c '"up"' 2>/dev/null | grep -q up && return 0
    sleep 8
  done < <(seq 1 "${max}")
  return 1
}

# Collect guest evidence and host signals after a CrashMe-triggered BSOD.
function CollectResult () {
  typeset codeHex="$1"
  typeset sweepDir="output/sweep-${codeHex}"
  mkdir -p "${sweepDir}"

  typeset json=''
  json=$(./src/scripts/host/guest-ssh.sh -c "& C:\\bsod-detector\\scripts\\collect-guest.ps1 -OutputDir C:\\bsod-detector\\output\\sweep-${codeHex}" 2>&1) || true
  if [[ -n "${json}" ]]; then
    echo "${json}" > "${sweepDir}/collect-guest.json"
    echo "${json}"
  else
    echo '{"ok":false,"warnings":["collect-guest.ps1 produced no output"]}' > "${sweepDir}/collect-guest.json"
    echo "EMPTY"
  fi
  true
}

: "=== CRASHME SWEEP: ${#codes[@]} codes ==="

typeset entry='' code='' p1='' p2='' p3='' p4=''
for entry in "${codes[@]}"; do
  read -r code p1 p2 p3 p4 <<< "${entry}"
  typeset codeUpper=''
  codeUpper=$(echo "${code}" | tr '[:lower:]' '[:upper:]' | sed 's/^0X/0x/')

  : "--- [${codeUpper}] REVERT ---"
  virsh snapshot-revert bsod-test crashme-installed 2>&1
  virsh start bsod-test 2>&1 || true

  : "[${codeUpper}] Waiting for SSH..."
  if ! WaitSsh 30; then
    : "[${codeUpper}] FAIL: SSH never came up after revert"
    mkdir -p "output/sweep-${codeUpper}"
    echo '{"ok":false,"warnings":["SSH never came up after snapshot revert"]}' > "output/sweep-${codeUpper}/collect-guest.json"
    continue
  fi

  : "[${codeUpper}] Starting CrashMe driver..."
  typeset scOut=''
  scOut=$(./src/scripts/host/guest-ssh.sh -c 'sc.exe start CrashMe' 2>&1) || true
  if echo "${scOut}" | grep -qi "RUNNING\|START_PENDING"; then
    : "[${codeUpper}] Driver running"
  else
    : "[${codeUpper}] WARNING: sc start output: ${scOut}"
  fi

  : "[${codeUpper}] Triggering BugCheck ${codeUpper} ${p1} ${p2} ${p3} ${p4}"
  ./src/scripts/host/guest-ssh.sh -c "C:\\Tools\\crashme-ctl.exe ${code} ${p1} ${p2} ${p3} ${p4}" 2>&1 || true

  : "[${codeUpper}] Waiting for reboot (~45s)..."
  sleep 45

  : "[${codeUpper}] Waiting for SSH after crash..."
  if ! WaitSsh 40; then
    : "[${codeUpper}] SSH not up after 320s, trying virsh reset..."
    virsh reset bsod-test 2>&1 || true
    sleep 30
    if ! WaitSsh 20; then
      : "[${codeUpper}] FAIL: VM unresponsive after reset"
      mkdir -p "output/sweep-${codeUpper}"
      echo '{"ok":false,"warnings":["VM unresponsive after BSOD + reset"]}' > "output/sweep-${codeUpper}/collect-guest.json"
      continue
    fi
  fi

  : "[${codeUpper}] Collecting evidence..."
  typeset result=''
  result=$(CollectResult "${codeUpper}")
  typeset observed=''
  typeset _bugCheckMatch=''
  _bugCheckMatch=$(grep -oP '"bugCheckCode"\s*:\s*"[^"]*"' <<< "${result}") || true
  _bugCheckMatch=$(head -1 <<< "${_bugCheckMatch}")
  observed=$(grep -oP '0x[0-9a-fA-F]+' <<< "${_bugCheckMatch}") || true
  typeset dump=''
  dump=$(grep -oP '"dumpFiles"\s*:\s*\[[^\]]*\]' <<< "${result}") || true
  dump=$(head -1 <<< "${dump}")
  : "[${codeUpper}] Observed: ${observed:-NONE} Dumps: ${dump:-NONE}"
done

: "=== SWEEP COMPLETE ==="
true
