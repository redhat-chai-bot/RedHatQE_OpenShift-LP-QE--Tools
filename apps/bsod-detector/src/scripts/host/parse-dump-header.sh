#!/usr/bin/env bash
# parse-dump-header - read bug-check code and parameters from a Windows kernel
# crash dump header, then resolve via bugcheck-codes.json.
#
# Works on PAGEDU64 (64-bit full/kernel dump) files. Reads the fixed-offset
# fields from the dump header without needing a Windows debugger.
#
# Usage:
#   parse-dump-header <dump-file> [<dump-file> ...]
#   parse-dump-header --dir <directory>   # all *.DMP files in the directory
#
# Output (stdout JSON):
#   { "ok": true, "dumps": [ { "file": "...", "bugCheckCode": "0x...",
#     "bugCheckName": "...", "parameters": [...], "valid": true } ], "warnings": [] }
#
# Requires: Bash 4.4+, od, jq, python3 (for struct unpacking on 64-bit params)
####
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  printf 'parse-dump-header: requires Bash >= 4.4 (found %s)\n' "${BASH_VERSION}" >&2
  exit 2
fi
exec {BASH_XTRACEFD}>/dev/null
set -euxo pipefail
shopt -s inherit_errexit

typeset scriptDir
scriptDir="$(cd "$(dirname "$0")" && pwd)"
typeset repoRoot
repoRoot="$(cd "${scriptDir}/../../.." && pwd)"
typeset codesFile="${BSOD_CODES_FILE:-${repoRoot}/src/data/bugcheck-codes.json}"

# die — print a fatal error to stderr and exit.
function die() {
  echo "parse-dump-header: $*" >&2
  exit 2
}
typeset -a warnList=()

[[ -f "${codesFile}" ]] || die "bugcheck-codes.json not found at ${codesFile}"

typeset -a files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)
      [[ $# -ge 2 ]] || die "--dir requires a value"
      [[ -d "$2" ]] || die "directory not found: $2"
      while IFS= read -r f; do files+=("${f}"); done < <(find "$2" -maxdepth 1 -iname '*.dmp' -type f | sort)
      shift 2
      ;;
    -h | --help)
      sed -n '/^#!/,/^####$/{/^#!/d;/^####$/d;s/^# \{0,1\}//p;}' "$0"
      exit 0
      ;;
    *)
      [[ -f "$1" ]] || die "file not found: $1"
      files+=("$1")
      shift
      ;;
  esac
done

[[ ${#files[@]} -gt 0 ]] || die "no dump files specified"

# PAGEDU64 header layout (64-bit kernel dump):
#   Offset  Size  Field
#   0x00    8     Signature ("PAGEDU64")
#   0x38    4     BugCheckCode (uint32 LE)
#   0x40    8     BugCheckParameter1 (uint64 LE)
#   0x48    8     BugCheckParameter2 (uint64 LE)
#   0x50    8     BugCheckParameter3 (uint64 LE)
#   0x58    8     BugCheckParameter4 (uint64 LE)
typeset -r pagedu64Sig="5041474544553634"

# read_uint_le — read a little-endian uint32/uint64 without embedding the
# caller-controlled file path in Python source.
function read_uint_le() {
  python3 - "$1" "$2" "$3" <<'PY'
import struct
import sys

path, offset_text, bits_text = sys.argv[1:]
bits = int(bits_text)
formats = {32: ("<I", 4, 8), 64: ("<Q", 8, 16)}
fmt, size, width = formats[bits]
with open(path, "rb") as dump:
    dump.seek(int(offset_text, 0))
    value = struct.unpack(fmt, dump.read(size))[0]
print("0x" + format(value, f"0{width}X"))
PY
}

typeset -a results=()
for dump in "${files[@]}"; do
  typeset baseName
  baseName="$(basename "${dump}")"

  typeset sig
  sig=$(od -An -tx1 -N8 -- "${dump}" 2>/dev/null | tr -d ' \n' || echo "")
  if [[ "${sig}" != "${pagedu64Sig}" ]]; then
    warnList+=("${baseName}: not a PAGEDU64 dump (sig=${sig}), skipped")
    results+=("$(jq -n --arg f "${baseName}" '{file:$f, bugCheckCode:null, bugCheckName:null, parameters:[], valid:false, error:"not a PAGEDU64 dump"}')")
    continue
  fi

  typeset code
  code=$(read_uint_le "${dump}" 0x38 32)
  typeset p1
  p1=$(read_uint_le "${dump}" 0x40 64)
  typeset p2
  p2=$(read_uint_le "${dump}" 0x48 64)
  typeset p3
  p3=$(read_uint_le "${dump}" 0x50 64)
  typeset p4
  p4=$(read_uint_le "${dump}" 0x58 64)

  typeset name
  name=$(jq -r --arg c "${code}" '.codes[$c].name // empty' "${codesFile}")
  if [[ -z "${name}" ]]; then
    warnList+=("${baseName}: code ${code} not in bugcheck-codes.json")
    name="null"
  else
    name="\"${name}\""
  fi

  results+=("$(jq -n \
    --arg f "${baseName}" \
    --arg code "${code}" \
    --argjson name "${name}" \
    --arg p1 "${p1}" --arg p2 "${p2}" --arg p3 "${p3}" --arg p4 "${p4}" \
    '{file:$f, bugCheckCode:$code, bugCheckName:$name, parameters:[$p1,$p2,$p3,$p4], valid:true}')")
done

typeset dumpsJson
dumpsJson=$(printf '%s\n' "${results[@]}" | jq -s .)
typeset warnsJson
warnsJson=$(printf '%s\n' "${warnList[@]:-}" | jq -R . | jq -s 'map(select(length>0))')
typeset ok=true
for r in "${results[@]}"; do
  if echo "${r}" | jq -e '.valid == false or .bugCheckName == null' >/dev/null 2>&1; then
    ok=false
    break
  fi
done

jq -n --argjson ok "${ok}" --argjson dumps "${dumpsJson}" --argjson warns "${warnsJson}" \
  '{ok:$ok, totalDumps:($dumps|length), dumps:$dumps, warnings:$warns}'
true
