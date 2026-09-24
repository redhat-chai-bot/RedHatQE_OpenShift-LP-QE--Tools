#!/usr/bin/env bats

load test-helper

setup() {
  SCRIPT="$REPO_ROOT/src/scripts/host/capture-host-dump.sh"
}

# These tests validate the script's content (static analysis) rather than
# running it, because the script requires virsh which is not available in CI.

@test "capture-host-dump does NOT require elf2dmp as a prerequisite" {
  # elf2dmp may be mentioned in comments (offline conversion guidance) but
  # must NOT be a prerequisite check or a called command.
  ! grep -q 'Have elf2dmp' "$SCRIPT"
}

@test "capture-host-dump preserves raw ELF (no rm -f elfFile)" {
  ! grep -q 'rm -f.*elfFile' "$SCRIPT"
}

@test "capture-host-dump output references guest-memory.elf not host-crash.dmp" {
  grep -q 'guest-memory.elf' "$SCRIPT"
  ! grep -q 'host-crash.dmp' "$SCRIPT"
}

@test "capture-host-dump uses virsh-memory-only method" {
  grep -q 'virsh-memory-only' "$SCRIPT"
}

@test "capture-host-dump requires --vm and --out arguments" {
  grep -q '\-\-vm required' "$SCRIPT"
  grep -q '\-\-out required' "$SCRIPT"
}
