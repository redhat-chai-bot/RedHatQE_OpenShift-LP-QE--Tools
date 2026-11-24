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
# Requires: Bash 4.4+, jq, python3
####
# Validate Bash version is 4.4 or higher for proper typeset and string handling
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'parse-dump-header: requires Bash >= 4.4 (found %s)\n' "${BASH_VERSION}" >&2; exit 2
fi
# Suppress bash trace output to keep stderr clean
exec {BASH_XTRACEFD}>/dev/null
set -euxo pipefail; shopt -s inherit_errexit

# Determine script and repository root paths for file resolution
typeset scriptDir; scriptDir="$(cd "$(dirname "$0")" && pwd)"
typeset repoRoot; repoRoot="$(cd "${scriptDir}/../../.." && pwd)"
typeset codesFile="${BSOD_DET__CODES__FILE:-${repoRoot}/src/data/bugcheck-codes.json}"

# Helper function definitions
# Die — print a fatal error to stderr and exit.
function Die () { echo "parse-dump-header: $*" >&2; exit 2; }
typeset -a warnList=()

# Verify bugcheck-codes.json data file exists
[[ -f "${codesFile}" ]] || Die "bugcheck-codes.json not found at ${codesFile}"

# Parse command-line arguments to gather dump files
typeset -a files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)
      # Batch mode: find all .DMP files in a directory and add to processing list
      [[ $# -ge 2 ]] || Die "--dir requires a value"
      [[ -d "$2" ]] || Die "directory not found: $2"
      while IFS= read -r f; do files+=("${f}"); done < <(find "$2" -maxdepth 1 -iname '*.dmp' -type f | sort)
      shift 2 ;;
    -h|--help)
      # Display help text extracted from script header
      sed -n '/^#!/,/^####$/{/^#!/d;/^####$/d;s/^# \{0,1\}//p;}' "$0"; exit 0 ;;
    *)
      # Single file mode: add individual dump files
      [[ -f "$1" ]] || Die "file not found: $1"
      files+=("$1"); shift ;;
  esac
done

# Ensure at least one dump file was provided
[[ ${#files[@]} -gt 0 ]] || Die "no dump files specified"

# PAGEDU64 header layout (64-bit kernel dump):
#   Offset  Size  Field
#   0x00    8     Signature ("PAGEDU64")
#   0x38    4     BugCheckCode (uint32 LE)
#   0x40    8     BugCheckParameter1 (uint64 LE)
#   0x48    8     BugCheckParameter2 (uint64 LE)
#   0x50    8     BugCheckParameter3 (uint64 LE)
#   0x58    8     BugCheckParameter4 (uint64 LE)
typeset -r pagedu64Sig="5041474544553634"

# Binary data extraction functions using Python (Bash has no native binary read)
# ReadU32Le — read a little-endian uint32 at the given offset from a binary file.
function ReadU32Le () {
  python3 -c '
import struct, sys
with open(sys.argv[1], "rb") as stream:
    stream.seek(int(sys.argv[2], 0))
    data = stream.read(4)
    if len(data) != 4:
        raise SystemExit("short dump header")
    print("0x" + format(struct.unpack("<I", data)[0], "08X"))
' "$1" "$2"
  true
}

# ReadU64Le — read a little-endian uint64 at the given offset from a binary file.
function ReadU64Le () {
  python3 -c '
import struct, sys
with open(sys.argv[1], "rb") as stream:
    stream.seek(int(sys.argv[2], 0))
    data = stream.read(8)
    if len(data) != 8:
        raise SystemExit("short dump header")
    print("0x" + format(struct.unpack("<Q", data)[0], "016X"))
' "$1" "$2"
  true
}

# Process each dump file: extract header fields and resolve bug check code
typeset -a results=()
for dump in "${files[@]}"; do
  typeset baseName; baseName="$(basename "${dump}")"

  # Verify dump file starts with PAGEDU64 signature (8 bytes: "PAGEDU64" in ASCII hex)
  typeset sig
  sig="$(python3 -c 'import sys; print(open(sys.argv[1], "rb").read(8).hex())' "${dump}" 2>/dev/null || true)"
  if [[ "${sig}" != "${pagedu64Sig}" ]]; then
    warnList+=("${baseName}: not a PAGEDU64 dump (sig=${sig}), skipped")
    results+=("$(jq -n --arg f "${baseName}" '{file:$f, bugCheckCode:null, bugCheckName:null, parameters:[], valid:false, error:"not a PAGEDU64 dump"}')")
    continue
  fi

  # Extract BugCheckCode (uint32 @ 0x38) and Parameters 1-4 (uint64 each @ 0x40, 0x48, 0x50, 0x58)
  typeset code; code=$(ReadU32Le "${dump}" 0x38)
  typeset p1; p1=$(ReadU64Le "${dump}" 0x40)
  typeset p2; p2=$(ReadU64Le "${dump}" 0x48)
  typeset p3; p3=$(ReadU64Le "${dump}" 0x50)
  typeset p4; p4=$(ReadU64Le "${dump}" 0x58)

  # Resolve bug check code to human-readable name via bugcheck-codes.json lookup
  typeset name; name=$(jq -r --arg c "${code}" '.codes[$c].name // empty' "${codesFile}")
  if [[ -z "${name}" ]]; then
    warnList+=("${baseName}: code ${code} not in bugcheck-codes.json")
    name="null"
  else
    name="\"${name}\""
  fi

  # Accumulate result for this dump with all extracted fields
  results+=("$(jq -n \
    --arg f "${baseName}" \
    --arg code "${code}" \
    --argjson name "${name}" \
    --arg p1 "${p1}" --arg p2 "${p2}" --arg p3 "${p3}" --arg p4 "${p4}" \
    '{file:$f, bugCheckCode:$code, bugCheckName:$name, parameters:[$p1,$p2,$p3,$p4], valid:true}')")
done

# Format results and warnings as JSON arrays
typeset dumpsJson; dumpsJson=$(printf '%s\n' "${results[@]}" | jq -s .)
typeset warnsJson; warnsJson=$(printf '%s\n' "${warnList[@]:-}" | jq -R . | jq -s 'map(select(length>0))')

# Check overall success: true if all dumps are valid and have known bug check codes
typeset ok=true
for r in "${results[@]}"; do
  if echo "${r}" | jq -e '.valid == false or .bugCheckName == null' >/dev/null 2>&1; then
    ok=false; break
  fi
done

# Emit the final JSON report with all dump analysis results and warnings
jq -n --argjson ok "${ok}" --argjson dumps "${dumpsJson}" --argjson warns "${warnsJson}" \
  '{ok:$ok, totalDumps:($dumps|length), dumps:$dumps, warnings:$warns}'
# Exit with success only if all dumps were valid and resolved
[[ "${ok}" == true ]]
