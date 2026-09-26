#!/usr/bin/env bats

load test-helper

@test "all data/*.json files are valid JSON" {
  for f in "$DATA_DIR"/*.json; do
    run python3 -c "import json; json.load(open('$f'))"
    [ "$status" -eq 0 ]
  done
}

@test "trigger-methods.json has required top-level keys" {
  run jq -e '.codes and ._comment' "$DATA_DIR/trigger-methods.json"
  [ "$status" -eq 0 ]
}

@test "bugcheck-codes.json has codes object" {
  run jq -e '.codes | type == "object"' "$DATA_DIR/bugcheck-codes.json"
  [ "$status" -eq 0 ]
}

@test "crash-control.json has recommended key" {
  run jq -e '.recommended' "$DATA_DIR/crash-control.json"
  [ "$status" -eq 0 ]
}

@test "event-sources.json has events array" {
  run jq -e '.events | type == "array"' "$DATA_DIR/event-sources.json"
  [ "$status" -eq 0 ]
}

@test "trigger-methods.json has exactly 19 codes" {
  count=$(jq '.codes | length' "$DATA_DIR/trigger-methods.json")
  [ "$count" -eq 19 ]
}

@test "every trigger-methods code has verified: true" {
  unverified=$(jq '[.codes[] | select(.verified != true)] | length' "$DATA_DIR/trigger-methods.json")
  [ "$unverified" -eq 0 ]
}

@test "every trigger-methods code has exactly 4 parameters" {
  bad=$(jq '[.codes[] | select(.parameters | length != 4)] | length' "$DATA_DIR/trigger-methods.json")
  [ "$bad" -eq 0 ]
}

@test "every trigger-methods code has method kebugcheckex" {
  bad=$(jq '[.codes[] | select(.method != "kebugcheckex")] | length' "$DATA_DIR/trigger-methods.json")
  [ "$bad" -eq 0 ]
}

@test "chaos-triggers.json has triggers object" {
  run jq -e '.triggers | type == "object"' "$DATA_DIR/chaos-triggers.json"
  [ "$status" -eq 0 ]
}

@test "every chaos trigger has required fields" {
  bad=$(jq '[.triggers | to_entries[] | .value | select(.name == null or .method == null or .snapshot == null or .timeoutSeconds == null or .collectionPath == null)] | length' "$DATA_DIR/chaos-triggers.json")
  [ "$bad" -eq 0 ]
}

@test "every chaos trigger tier is declared by tierSchema" {
  bad=$(jq '[. as $root | .triggers[] | select(($root.tierSchema[.tier|tostring] // null) == null)] | length' "$DATA_DIR/chaos-triggers.json")
  [ "$bad" -eq 0 ]
}

@test "tier 5 triggers are explicitly marked experimental or unsupported" {
  bad=$(jq '[. as $root | .triggers[] | select(.tier == 5) |
    select(($root.tierSchema["5"] | test("experimental|unsupported"; "i")) | not)] | length' "$DATA_DIR/chaos-triggers.json")
  [ "$bad" -eq 0 ]
}

@test "every chaos trigger collectionPath is valid" {
  bad=$(jq '[.triggers[] | select(.collectionPath != "auto" and .collectionPath != "guest" and .collectionPath != "host-offline")] | length' "$DATA_DIR/chaos-triggers.json")
  [ "$bad" -eq 0 ]
}

@test "event-sources.json entries each have source and meaning" {
  bad=$(jq '[.events[] | select(.source == null or .meaning == null)] | length' "$DATA_DIR/event-sources.json")
  [ "$bad" -eq 0 ]
}

@test "sample output collect-guest.example.json has crash.detected and crash.crashType" {
  run jq -e '.crash.detected and .crash.crashType' "$BATS_TEST_DIRNAME/../docs/sample-output/collect-guest.example.json"
  [ "$status" -eq 0 ]
}

@test "sample output crashType is a valid enum value" {
  for f in "$BATS_TEST_DIRNAME"/../docs/sample-output/collect-guest*.json; do
    type=$(jq -r '.crash.crashType' "$f")
    [[ "$type" == "bugcheck" || "$type" == "livekernelevent" || "$type" == "dirtyshutdown" ]]
  done
}
