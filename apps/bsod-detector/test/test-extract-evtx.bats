#!/usr/bin/env bats

load test-helper

setup() {
  SetupTemp
  EXTRACT_EVTX="$REPO_ROOT/src/scripts/host/extract-evtx.py"
}

teardown() {
  TeardownTemp
}

@test "extract-evtx.py shows help with --help" {
  run python3 "$EXTRACT_EVTX" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Parse offline .evtx files"* ]]
}

@test "extract-evtx.py exits 2 when --data-dir is missing" {
  run python3 "$EXTRACT_EVTX"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--data-dir"* ]]
}

@test "extract-evtx.py emits valid JSON with no input files" {
  run python3 "$EXTRACT_EVTX" --data-dir "$DATA_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true'
  echo "$output" | jq -e '.crash.detected == false'
  echo "$output" | jq -e '.warnings | length > 0'
}

@test "extract-evtx.py warns on nonexistent evtx file" {
  run python3 "$EXTRACT_EVTX" --data-dir "$DATA_DIR" /nonexistent.evtx
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.warnings[] | select(contains("not found"))'
}

@test "extract-evtx.py output has required top-level keys" {
  run python3 "$EXTRACT_EVTX" --data-dir "$DATA_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok and (.crash | type == "object") and (.events | type == "array") and (.warnings | type == "array")'
}
