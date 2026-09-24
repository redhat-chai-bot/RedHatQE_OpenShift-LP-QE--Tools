#!/usr/bin/env bats

load test-helper

setup() {
  SetupTemp
}

teardown() {
  TeardownTemp
}

create_pagedu64_dump() {
  local file="$1"
  local bugcheck_code="${2:-0x000000D1}"
  local p1="${3:-0xDEADBEEF00000001}"
  local p2="${4:-0x0000000000000002}"
  local p3="${5:-0x0000000000000000}"
  local p4="${6:-0xFFFFF80000000003}"

  python3 -c "
import struct, sys

sig = b'PAGEDU64'
code = int('$bugcheck_code', 16)
params = [int('$p1', 16), int('$p2', 16), int('$p3', 16), int('$p4', 16)]

data = bytearray(0x60)
data[0:8] = sig
struct.pack_into('<I', data, 0x38, code)
for i, p in enumerate(params):
    struct.pack_into('<Q', data, 0x40 + i*8, p)

with open('$file', 'wb') as f:
    f.write(data)
"
}

@test "parse-dump-header reads correct bugcheck code" {
  local dump="$BATS_TMPDIR/test.dmp"
  create_pagedu64_dump "$dump" "0x000000D1"

  run "$REPO_ROOT/src/scripts/host/parse-dump-header.sh" "$dump"
  [ "$status" -eq 0 ]

  code=$(echo "$output" | jq -r '.dumps[0].bugCheckCode')
  [ "$code" = "0x000000D1" ]
}

@test "parse-dump-header reads 4 parameters correctly" {
  local dump="$BATS_TMPDIR/test.dmp"
  create_pagedu64_dump "$dump" "0x00000019" "0x0000000000000003" "0x0000000000000000" "0x0000000000000000" "0x0000000000000000"

  run "$REPO_ROOT/src/scripts/host/parse-dump-header.sh" "$dump"
  [ "$status" -eq 0 ]

  p1=$(echo "$output" | jq -r '.dumps[0].parameters[0]')
  [ "$p1" = "0x0000000000000003" ]
}

@test "parse-dump-header resolves known code name" {
  local dump="$BATS_TMPDIR/test.dmp"
  create_pagedu64_dump "$dump" "0x000000D1"

  run "$REPO_ROOT/src/scripts/host/parse-dump-header.sh" "$dump"
  [ "$status" -eq 0 ]

  name=$(echo "$output" | jq -r '.dumps[0].bugCheckName')
  [ "$name" = "DRIVER_IRQL_NOT_LESS_OR_EQUAL" ]
}

@test "parse-dump-header rejects invalid signature" {
  local dump="$BATS_TMPDIR/bad.dmp"
  printf 'NOTADUMP' > "$dump"
  dd if=/dev/zero bs=1 count=88 >> "$dump" 2>/dev/null

  run "$REPO_ROOT/src/scripts/host/parse-dump-header.sh" "$dump"
  [ "$status" -eq 0 ]

  valid=$(echo "$output" | jq -r '.dumps[0].valid')
  [ "$valid" = "false" ]
}

@test "parse-dump-header exits 2 on missing file" {
  run "$REPO_ROOT/src/scripts/host/parse-dump-header.sh" "/nonexistent/file.dmp"
  [ "$status" -eq 2 ]
}

@test "parse-dump-header exits 2 with no arguments" {
  run "$REPO_ROOT/src/scripts/host/parse-dump-header.sh"
  [ "$status" -eq 2 ]
}
