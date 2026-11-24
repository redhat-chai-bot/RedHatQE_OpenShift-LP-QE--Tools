#!/usr/bin/env bats

load test-helper

setup() {
  setup_temp
  EXTRACT_EVTX="$REPO_ROOT/src/scripts/host/extract-evtx.py"
}

teardown() {
  teardown_temp
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

@test "extract-evtx.py fails closed with valid JSON when no input files are provided" {
  run python3 "$EXTRACT_EVTX" --data-dir "$DATA_DIR"
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.ok == false'
  echo "$output" | jq -e '.crash.detected == false'
  echo "$output" | jq -e '.error | contains("no .evtx files")'
}

@test "extract-evtx.py fails on nonexistent evtx file" {
  run python3 "$EXTRACT_EVTX" --data-dir "$DATA_DIR" /nonexistent.evtx
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.ok == false and (.error | contains("not found"))'
}

@test "extract-evtx.py output has required top-level keys" {
  run python3 "$EXTRACT_EVTX" --data-dir "$DATA_DIR"
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '(.ok == false) and (.crash | type == "object") and (.events | type == "array") and (.warnings | type == "array")'
}
