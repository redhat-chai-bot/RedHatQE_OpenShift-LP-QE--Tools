#!/usr/bin/env bats

load test-helper

setup() {
  SetupTemp
  COLLECT_OFFLINE="$REPO_ROOT/src/scripts/host/collect-offline.sh"
}

teardown() {
  TeardownTemp
}

@test "collect-offline exits 2 when --vm is missing" {
  run bash "$COLLECT_OFFLINE" --out "$BATS_TMPDIR/out"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--vm required"* ]]
}

@test "collect-offline exits 2 when --out is missing" {
  run bash "$COLLECT_OFFLINE" --vm test-vm
  [ "$status" -eq 2 ]
  [[ "$output" == *"--out required"* ]]
}

@test "collect-offline exits 2 on unknown argument" {
  run bash "$COLLECT_OFFLINE" --vm test-vm --out "$BATS_TMPDIR/out" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown arg"* ]]
}

@test "collect-offline shows help with --help" {
  run bash "$COLLECT_OFFLINE" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"offline evidence collection"* ]]
}
