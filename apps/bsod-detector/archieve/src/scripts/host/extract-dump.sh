#!/usr/bin/env bash
# extract-dump - pull Windows crash dumps out of a guest disk image offline.
#
# Runs INSIDE the bsod-host-tools container (libguestfs). Use when the guest is
# frozen or unbootable: reads the qcow2 read-only and copies MEMORY.DMP and any
# minidumps into an output directory. Emits one JSON object to stdout describing
# what was found (the script contract; diagnostics go to stderr).
#
# Usage:
#   extract-dump --disk <imgFile> [--out <outDir>] [--windows-root <winRootDir>]
#
# Parameters:
#   --disk <imgFile>           Path to the guest disk image (qcow2) [required]
#   --out <outDir>             Output directory for recovered dumps (default: /out)
#   --windows-root <winRootDir> Windows root path in the disk (default: /Windows)
#
# Examples:
#   extract-dump --disk /images/bsod-test.qcow2
#   extract-dump --disk /images/bsod-test.qcow2 --out /out
#   extract-dump --disk /images/bsod-test.qcow2 --out /out --windows-root /Windows
#
# Output (stdout JSON):
#   { "ok": true, "disk": "...", "outputDir": "/out",
#     "dumpFiles": ["MEMORY.DMP","Minidump/..."], "warnings": [ ... ] }
####
# Enable strict mode: exit on errors (-e), print each command (-u), fail on pipe (-o pipefail)
set -euxo pipefail; shopt -s inherit_errexit
# Suppress bash trace output so only JSON is emitted to stdout
exec {BASH_XTRACEFD}>/dev/null

# Initialize variable for required disk image path (qcow2 file)
typeset disk=''
# Initialize output directory with default /out
typeset out='/out'
# Initialize Windows root path with default /Windows
typeset winRoot='/Windows'

# warn — print a diagnostic message to stderr.
function warn () { echo "extract-dump: $*" >&2; true; }

# emit — write the final JSON result object to stdout.
function emit () {
  # Format and output JSON with success status, disk path, output dir, found files array, and warnings array
  printf '{"ok":%s,"disk":%s,"outputDir":%s,"dumpFiles":%s,"warnings":%s}\n' \
    "$1" "$(jq -Rn --arg v "${disk}" '$v')" "$(jq -Rn --arg v "${out}" '$v')" \
    "${filesJson:-[]}" "${warnJson:-[]}"
  true
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    # Set disk image path (required)
    --disk) disk="$2"; shift 2 ;;
    # Set output directory for extracted dumps
    --out) out="$2"; shift 2 ;;
    # Set Windows root directory path in the disk image
    --windows-root) winRoot="$2"; shift 2 ;;
    # Display help text extracted from header comments
    -h|--help)
      sed -n '/^#!/,/^####$/{/^#!/d;/^####$/d;s/^# \{0,1\}//p;}' "$0"; exit 0 ;;
    # Reject unknown arguments
    *) warn "unknown arg: $1"; exit 2 ;;
  esac
done

# Validate that --disk argument was provided
[[ -n "${disk}" ]] || { warn "--disk is required"; exit 2; }
# Validate that the disk image file exists
[[ -f "${disk}" ]] || { warn "disk not found: ${disk}"; exit 2; }
# Create output directory if it doesn't exist
mkdir -p "${out}"

# Initialize array to store warning messages
typeset -a warns=()
# Initialize array to store found dump file paths
typeset -a found=()

# copy_out — copy a file from the guest disk image to the output directory
# Uses virt-ls to check file existence and virt-copy-out to extract (read-only)
function copy_out () {
  # Construct full path to source file in Windows filesystem
  typeset src="${winRoot}/$1"
  # Check if the file exists in the disk image
  if virt-ls -a "${disk}" "${src}" >/dev/null 2>&1; then
    # Copy file from disk image to output directory; append errors to error log
    virt-copy-out -a "${disk}" "${src}" "${out}" 2>>/tmp/err && return 0
  fi
  # Return failure if file not found or copy failed
  return 1
}

# Extract MEMORY.DMP (kernel/complete system dump)
if copy_out "MEMORY.DMP"; then
  # Add to found files list if extraction succeeded
  found+=("MEMORY.DMP")
else
  # Record warning if main dump not found
  warns+=("MEMORY.DMP not found - dump type may be misconfigured or none written")
fi

# Extract Minidump directory (small crash dumps, one per crash event)
# Variable to hold current minidump filename during iteration
typeset f=''
# Check if Minidump directory exists in disk image
if virt-ls -a "${disk}" "${winRoot}/Minidump" >/dev/null 2>&1; then
  # Copy entire Minidump directory to output (ignore errors with || true)
  virt-copy-out -a "${disk}" "${winRoot}/Minidump" "${out}" 2>>/tmp/err || true
  # List all .dmp files in Minidump directory and add each to found array with path
  while IFS= read -r f; do found+=("Minidump/${f}"); done < <(virt-ls -a "${disk}" "${winRoot}/Minidump" 2>/dev/null | sed -n '/\.dmp$/Ip')
else
  # Record warning if Minidump directory not found
  warns+=("no Minidump directory found")
fi

# Extract Event log files (.evtx) for offline crash-event analysis
# Store Windows event log directory path (for warning messages)
typeset evtxDir="${winRoot}/System32/winevt/Logs"
# Define array of target event log files to extract
typeset -a evtxTargets=("System.evtx" "Application.evtx")
# Create output directory for event logs (ignore errors)
mkdir -p "${out}/winevt" 2>/dev/null || true
# Iterate through each target event log file
for evtxName in "${evtxTargets[@]}"; do
  # Attempt to copy the event log file
  if copy_out "System32/winevt/Logs/${evtxName}"; then
    # virt-copy-out preserves directory structure; move to flat winevt/ output directory
    # Build path where virt-copy-out placed the file
    typeset srcEvtx="${out}/${evtxName}"
    # If file was extracted, move it to the winevt subdirectory
    [[ -f "${srcEvtx}" ]] && mv "${srcEvtx}" "${out}/winevt/${evtxName}" 2>/dev/null || true
    # Add to found files list with relative path
    found+=("winevt/${evtxName}")
  else
    # Record warning if event log not found
    warns+=("${evtxName} not found at ${evtxDir}")
  fi
done

# Convert found files array to JSON format
typeset filesJson=''
# Format each found file as JSON array, filtering out empty strings
filesJson="$(printf '%s\n' "${found[@]:-}" | jq -Rn '[inputs | select(length > 0)]')"
# Convert warnings array to JSON format
typeset warnJson=''
# Format each warning as JSON array, filtering out empty strings
warnJson="$(printf '%s\n' "${warns[@]:-}" | jq -Rn '[inputs | select(length > 0)]')"

# Check if any files were found; if not, emit failure JSON and exit with error code
if [[ "${#found[@]}" -eq 0 ]]; then emit false; exit 1; fi
# Emit success JSON with all found files and warnings
emit true
# Exit successfully
true
