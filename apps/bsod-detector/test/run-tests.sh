#!/usr/bin/env bash
set -euxo pipefail; shopt -s inherit_errexit

typeset testDir=''
testDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "=== BSOD Detector Test Suite ==="

if ! command -v bats &>/dev/null; then
  echo "ERROR: bats-core not installed. Install with: dnf install bats" >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq not installed." >&2
  exit 1
fi

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v \
  "${testDir}/test_reliability.py" \
  "${testDir}/test_recovery.py" \
  "${testDir}/test_evtx.py" \
  "${testDir}/test_container_contract.py"

# Keep the default suite explicit: archived pre-RHOV Bats files live under
# archieve/test and must not be mistaken for active workflow coverage.
bats \
  "${testDir}/test-cross-references.bats" \
  "${testDir}/test-host-signals.bats" \
  "${testDir}/test-json-validation.bats" \
  "${testDir}/test-parse-dump-header.bats" \
  "${testDir}/test-rhov-reliability.bats"
