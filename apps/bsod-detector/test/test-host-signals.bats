#!/usr/bin/env bats

load test-helper

setup() {
  SetupTemp
  SCRIPT="$REPO_ROOT/src/scripts/host/collect-host-signals.sh"
  SPLIT_LOCK_LOG="$BATS_TMPDIR/dmesg-splitlock.txt"
  cat > "$SPLIT_LOCK_LOG" <<'EOF'
[12345.678] x86/split lock detection: #AC: CPU 8/KVM/3051128 took a split_lock trap at address: 0xfffff801c684e9be
[12346.111] x86/split lock detection: #AC: CPU 4/KVM/2799267 took a split_lock trap at address: 0xfffff80275535ed3
[12347.222] x86/split lock detection: #AC: CPU 7/KVM/2823994 took a split_lock trap at address: 0x2143e8a2b36
[12348.333] some unrelated kernel line
EOF
  CLEAN_LOG="$BATS_TMPDIR/clean-dmesg.txt"
  printf '[1] boot line\n[2] nothing interesting\n' > "$CLEAN_LOG"
}

teardown() {
  TeardownTemp
}

@test "host-signals detects split-lock traps" {
  run bash "$SCRIPT" --log-file "$SPLIT_LOCK_LOG" --vm no-such-vm
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.splitLockDetected')" = "true" ]
  [ "$(echo "$output" | jq -r '.kernelSignals[] | select(.id=="split-lock-trap") | .count')" -eq 3 ]
}

@test "host-signals classifies kernel vs user trap addresses" {
  run bash "$SCRIPT" --log-file "$SPLIT_LOCK_LOG" --vm no-such-vm
  [ "$status" -eq 0 ]
  kernel=$(echo "$output" | jq '[.kernelSignals[] | select(.id=="split-lock-trap") | .matches[] | select(.addressSpace=="kernel")] | length')
  user=$(echo "$output" | jq '[.kernelSignals[] | select(.id=="split-lock-trap") | .matches[] | select(.addressSpace=="user")] | length')
  [ "$kernel" -eq 2 ]
  [ "$user" -eq 1 ]
}

@test "host-signals extracts kvm thread and trap address" {
  run bash "$SCRIPT" --log-file "$SPLIT_LOCK_LOG" --vm no-such-vm
  [ "$status" -eq 0 ]
  thread=$(echo "$output" | jq -r '.kernelSignals[] | select(.id=="split-lock-trap") | .matches[0].kvmThread')
  addr=$(echo "$output" | jq -r '.kernelSignals[] | select(.id=="split-lock-trap") | .matches[0].trapAddress')
  [ "$thread" = "CPU 8/KVM/3051128" ]
  [ "$addr" = "0xfffff801c684e9be" ]
}

@test "host-signals reports no split-lock on a clean log" {
  run bash "$SCRIPT" --log-file "$CLEAN_LOG" --vm no-such-vm
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.splitLockDetected')" = "false" ]
}

@test "host-signals links split-lock signal to bugcheck 0x00020001" {
  run bash "$SCRIPT" --log-file "$SPLIT_LOCK_LOG" --vm no-such-vm
  [ "$status" -eq 0 ]
  related=$(echo "$output" | jq -r '.kernelSignals[] | select(.id=="split-lock-trap") | .relatedBugCheck')
  [ "$related" = "0x00020001" ]
}

@test "host-signals emits valid JSON with required top-level keys" {
  run bash "$SCRIPT" --log-file "$SPLIT_LOCK_LOG" --vm no-such-vm
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok and (.kernelSignals|type=="array") and (.hyperv|type=="object") and (.assessment|type=="array")'
}

@test "host-signals does not claim enlightenments enabled when XML is unreadable" {
  run bash "$SCRIPT" --log-file "$SPLIT_LOCK_LOG" --vm no-such-vm
  [ "$status" -eq 0 ]
  # With no domain XML, must not assert the unmitigated-config claim.
  matched=$(echo "$output" | jq '[.assessment[] | select(contains("enlightenments are enabled"))] | length')
  [ "$matched" -eq 0 ]
}

@test "host-signals exits non-zero on missing log file" {
  run bash "$SCRIPT" --log-file "/nonexistent/log.txt" --vm no-such-vm
  [ "$status" -eq 2 ]
}
