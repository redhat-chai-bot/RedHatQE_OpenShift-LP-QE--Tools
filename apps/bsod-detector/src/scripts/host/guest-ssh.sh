#!/usr/bin/env bash
# guest-ssh.sh - run PowerShell in the test guest over SSH, robustly.
#
# Runs on the HOST. Used for CRASH TRIGGERING ONLY (crash-injector scripts),
# NOT for evidence collection. Evidence is collected offline via guestfs after
# the VM is stopped.
#
# Wraps sshpass + OpenSSH to execute PowerShell in the guest
# using -EncodedCommand (base64/UTF-16LE) so quoting is never an issue, and
# filters out PowerShell's CLIXML/progress noise so stdout is clean.
#
# Config via env (with defaults for the local bsod-test VM):
#   GUEST_IP    (default: auto-detected from libvirt DHCP lease for bsod-test)
#   GUEST_USER  (default: Administrator)
#   GUEST_KEY   (default: <repo>/.ssh/bsod-test if present) - SSH private key
#   GUEST_PASS  (fallback if no key; e.g. export GUEST_PASS=... )
#
# Auth: uses the SSH key when available (no password needed); otherwise falls
# back to GUEST_PASS via sshpass.
#
# Usage:
#   src/scripts/guest-ssh.sh -c 'Get-Date; $env:COMPUTERNAME'     # inline PowerShell
#   src/scripts/guest-ssh.sh -f path/to/script.ps1 [-- -Arg val]  # run a .ps1 file
#   echo '<ps>' | src/scripts/guest-ssh.sh                        # PowerShell on stdin
set -euxo pipefail; shopt -s inherit_errexit

export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
typeset GUEST_USER="${GUEST_USER:-Administrator}"
typeset VM_NAME="${VM_NAME:-bsod-test}"
typeset scriptDir=""; scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
typeset GUEST_KEY="${GUEST_KEY:-${scriptDir}/../../../.ssh/bsod-test}"   # src/scripts/host -> src/scripts -> src -> app root/.ssh

function Die () { echo "guest-ssh: $*" >&2; exit 1; }

typeset GUEST_IP="${GUEST_IP:-}"
if [[ -z "${GUEST_IP}" ]]; then
  GUEST_IP="$(virsh -q domifaddr "${VM_NAME}" 2>/dev/null | awk 'NR==1{print $4}' | cut -d/ -f1)"
  [[ -z "${GUEST_IP}" ]] && GUEST_IP="$(virsh -q net-dhcp-leases default 2>/dev/null \
      | awk -v m="$(virsh -q domiflist "${VM_NAME}" | awk 'NR==1{print $5}')" '$3==m{print $5}' | cut -d/ -f1)"
fi
[[ -n "${GUEST_IP}" ]] || Die "could not resolve guest IP (set GUEST_IP)"

# ServerAlive* ensures a session that dies mid-command (e.g. the guest
# bugchecking during a crash trigger) is torn down within ~15s instead of hanging
# indefinitely on a half-open TCP connection.
typeset -a sshOpts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
         -o ConnectTimeout=15 -o LogLevel=ERROR
         -o ServerAliveInterval=5 -o ServerAliveCountMax=3)

typeset -a sshCmd=() scpCmd=()
if [[ -f "${GUEST_KEY}" ]]; then
  sshOpts+=(-i "${GUEST_KEY}" -o IdentitiesOnly=yes)
  sshCmd=(ssh);  scpCmd=(scp)
elif [[ -n "${GUEST_PASS:-}" ]]; then
  export SSHPASS="${GUEST_PASS}"
  sshCmd=(sshpass -e ssh);  scpCmd=(sshpass -e scp)
else
  Die "no auth: set GUEST_KEY to an SSH key (${GUEST_KEY}) or GUEST_PASS"
fi

typeset ps="" args="" file=""
case "${1:-}" in
  -c) ps="$2"; shift 2 ;;
  -f) file="$2"; shift 2
      [[ -f "${file}" ]] || Die "no such file: ${file}"
      ps="$(cat "${file}")"
      [[ "${1:-}" == "--" ]] && { shift; args="$*"; } ;;
  "") ps="$(cat)" ;;
  *)  Die "usage: -c <ps> | -f <file> [-- args] | (stdin)" ;;
esac

typeset payload="${ps}"
[[ -n "${args}" ]] && payload="& { ${ps} } ${args}"

typeset b64=""; b64="$(printf '%s' "${payload}" | iconv -t UTF-16LE | base64 -w0)"
if [[ ${#b64} -lt 6000 ]]; then
  "${sshCmd[@]}" "${sshOpts[@]}" "${GUEST_USER}@${GUEST_IP}" \
    "powershell -NoProfile -NonInteractive -EncodedCommand ${b64}" 2>&1 \
    | sed -e '/^#< CLIXML/d' -e '/<Objs /d' -e '/Permanently added/d'
else
  typeset tmp="" remote="" rwin=""
  tmp="$(mktemp --suffix=.ps1)"; printf '%s' "${ps}" > "${tmp}"
  remote="C:/Windows/Temp/gssh-$$.ps1"
  "${scpCmd[@]}" "${sshOpts[@]}" "${tmp}" "${GUEST_USER}@${GUEST_IP}:${remote}" 2>&1 \
    | sed -e '/Permanently added/d'
  rm -f "${tmp}"
  rwin="${remote//\//\\}"
  "${sshCmd[@]}" "${sshOpts[@]}" "${GUEST_USER}@${GUEST_IP}" \
    "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ${rwin} ${args}" 2>&1 \
    | sed -e '/^#< CLIXML/d' -e '/<Objs /d' -e '/Permanently added/d'
  "${sshCmd[@]}" "${sshOpts[@]}" "${GUEST_USER}@${GUEST_IP}" \
    "powershell -NoProfile -Command \"Remove-Item '${rwin}' -Force -EA SilentlyContinue\"" >/dev/null 2>&1 || true
fi

true
