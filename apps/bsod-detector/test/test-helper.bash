#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

DATA_DIR="$REPO_ROOT/src/data"
export DATA_DIR

TESTS_DIR="$REPO_ROOT/test"
export TESTS_DIR

# setup_temp — create a temporary directory for test artifacts.
function setup_temp() {
  BATS_TMPDIR="$(mktemp -d)"
  export BATS_TMPDIR
  true
}

# teardown_temp — remove the temporary directory created by setup_temp.
function teardown_temp() {
  [[ -d "${BATS_TMPDIR:-}" ]] && rm -rf "$BATS_TMPDIR"
  true
}
