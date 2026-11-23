#!/usr/bin/env bash
set -euxo pipefail; shopt -s inherit_errexit

typeset testDir=''
testDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: '=== BSOD Detector Test Suite ==='

if ! command -v bats &>/dev/null; then
  echo 'ERROR: bats-core not installed. Install with: dnf install bats' >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo 'ERROR: jq not installed.' >&2
  exit 1
fi

# Run both suites even when the first one fails, so a unittest failure cannot hide the Bats
# results. The script exits with the unittest status if that suite failed, otherwise with the
# Bats status, as it did when it stopped at the first failing suite.
typeset -i unittestStatus=0 batsStatus=0

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v \
  "${testDir}/test_reliability.py" \
  "${testDir}/test_recovery.py" \
  "${testDir}/test_recursive_mapping.py" \
  "${testDir}/test_extractor_contract.py" \
  "${testDir}/test_guestfs_lifecycle.py" ||
unittestStatus=$?

# Keep the default suite explicit: list every active Bats file here.
bats \
  "${testDir}/test-cross-references.bats" \
  "${testDir}/test-host-signals.bats" \
  "${testDir}/test-json-validation.bats" \
  "${testDir}/test-parse-dump-header.bats" \
  "${testDir}/test-rhov-reliability.bats" ||
batsStatus=$?

: "unittest exit status: ${unittestStatus}; bats exit status: ${batsStatus}"
((unittestStatus)) && exit "${unittestStatus}"
exit "${batsStatus}"
