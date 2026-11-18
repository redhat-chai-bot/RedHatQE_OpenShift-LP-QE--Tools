#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test-helper

setup() {
  setup_temp
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
  DOMAIN_XML_UNMITIGATED="$BATS_TMPDIR/domain-unmitigated.xml"
  cat > "$DOMAIN_XML_UNMITIGATED" <<'EOF'
<domain>
  <features>
    <hyperv>
      <tlbflush state='on'/>
      <ipi state='on'/>
      <vapic state='on'/>
      <spinlocks state='on'/>
      <stimer state='on'/>
    </hyperv>
  </features>
</domain>
EOF
  DOMAIN_XML_MITIGATED="$BATS_TMPDIR/domain-mitigated.xml"
  cat > "$DOMAIN_XML_MITIGATED" <<'EOF'
<domain>
  <features>
    <hyperv>
      <tlbflush state='off'/>
      <ipi state='off'/>
      <vapic state='on'/>
    </hyperv>
  </features>
</domain>
EOF
}

teardown() {
  teardown_temp
}

# xtrace goes to stderr; keep $output as clean JSON for jq assertions.
run_host_signals() {
  run --separate-stderr bash "$SCRIPT" "$@"
}

@test "host-signals detects split-lock traps" {
  run_host_signals --log-file "$SPLIT_LOCK_LOG" --vm no-such-vm
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.splitLockDetected')" = "true" ]
  [ "$(echo "$output" | jq -r '.kernelSignals[] | select(.id=="split-lock-trap") | .count')" -eq 3 ]
}

@test "host-signals classifies kernel vs user trap addresses" {
  run_host_signals --log-file "$SPLIT_LOCK_LOG" --vm no-such-vm
  [ "$status" -eq 0 ]
  kernel=$(echo "$output" | jq '[.kernelSignals[] | select(.id=="split-lock-trap") | .matches[] | select(.addressSpace=="kernel")] | length')
  user=$(echo "$output" | jq '[.kernelSignals[] | select(.id=="split-lock-trap") | .matches[] | select(.addressSpace=="user")] | length')
  [ "$kernel" -eq 2 ]
  [ "$user" -eq 1 ]
}

@test "host-signals extracts kvm thread and trap address" {
  run_host_signals --log-file "$SPLIT_LOCK_LOG" --vm no-such-vm
  [ "$status" -eq 0 ]
  thread=$(echo "$output" | jq -r '.kernelSignals[] | select(.id=="split-lock-trap") | .matches[0].kvmThread')
  addr=$(echo "$output" | jq -r '.kernelSignals[] | select(.id=="split-lock-trap") | .matches[0].trapAddress')
  [ "$thread" = "CPU 8/KVM/3051128" ]
  [ "$addr" = "0xfffff801c684e9be" ]
}

@test "host-signals reports no split-lock on a clean log" {
  run_host_signals --log-file "$CLEAN_LOG" --vm no-such-vm
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.splitLockDetected')" = "false" ]
}

@test "host-signals links split-lock signal to bugcheck 0x00020001" {
  run_host_signals --log-file "$SPLIT_LOCK_LOG" --vm no-such-vm
  [ "$status" -eq 0 ]
  related=$(echo "$output" | jq -r '.kernelSignals[] | select(.id=="split-lock-trap") | .relatedBugCheck')
  [ "$related" = "0x00020001" ]
}

@test "host-signals emits valid JSON with required top-level keys" {
  run_host_signals --log-file "$SPLIT_LOCK_LOG" --vm no-such-vm
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok and (.kernelSignals|type=="array") and (.hyperv|type=="object") and (.assessment|type=="array")'
}

@test "host-signals does not claim enlightenments enabled when XML is unreadable" {
  run_host_signals --log-file "$SPLIT_LOCK_LOG" --vm no-such-vm
  [ "$status" -eq 0 ]
  # With no domain XML, must not assert the unmitigated-config claim.
  matched=$(echo "$output" | jq '[.assessment[] | select(contains("enlightenments are enabled"))] | length')
  [ "$matched" -eq 0 ]
}

@test "host-signals exits non-zero on missing log file" {
  run_host_signals --log-file "/nonexistent/log.txt" --vm no-such-vm
  [ "$status" -eq 2 ]
}

@test "host-signals reads Hyper-V features from --domain-xml" {
  run_host_signals --log-file "$SPLIT_LOCK_LOG" --vm no-such-vm --domain-xml "$DOMAIN_XML_UNMITIGATED"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.hyperv.features[] | select(.name=="tlbflush") | .state')" = "on" ]
  [ "$(echo "$output" | jq -r '.hyperv.features[] | select(.name=="ipi") | .state')" = "on" ]
  [ "$(echo "$output" | jq -r '.hyperv.features[] | select(.name=="synictimer") | .state')" = "on" ]
  [ "$(echo "$output" | jq -r '.hyperv.mitigationApplied')" = "false" ]
}

@test "host-signals reports mitigation when tlbflush and ipi are off" {
  run_host_signals --log-file "$CLEAN_LOG" --vm no-such-vm --domain-xml "$DOMAIN_XML_MITIGATED"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.hyperv.mitigationApplied')" = "true" ]
  matched=$(echo "$output" | jq '[.assessment[] | select(contains("Mitigation appears applied"))] | length')
  [ "$matched" -eq 1 ]
}

@test "host-signals correlates unmitigated Hyper-V with split-lock traps" {
  run_host_signals --log-file "$SPLIT_LOCK_LOG" --vm no-such-vm --domain-xml "$DOMAIN_XML_UNMITIGATED"
  [ "$status" -eq 0 ]
  matched=$(echo "$output" | jq '[.assessment[] | select(contains("enlightenments are enabled"))] | length')
  [ "$matched" -eq 1 ]
}

@test "host-signals exits non-zero on missing domain XML" {
  run_host_signals --log-file "$SPLIT_LOCK_LOG" --vm no-such-vm --domain-xml "/nonexistent/domain.xml"
  [ "$status" -eq 2 ]
}

@test "host-signals help prints usage" {
  run_host_signals --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage:"* ]]
  [[ "$output" == *"--log-file"* ]]
  [[ "$output" == *"--domain-xml"* ]]
}
