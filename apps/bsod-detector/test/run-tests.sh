#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

typeset testDir=''
testDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "=== BSOD Detector Test Suite ==="

bash "${testDir}/test-rhov-contracts.sh"

if ! command -v bats &>/dev/null; then
  echo "NOTICE: bats-core not installed; hermetic RHOV contract reproducers passed, Bats suite skipped." >&2
  exit 0
fi

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq not installed." >&2
  exit 1
fi

bats "${testDir}/"
true
