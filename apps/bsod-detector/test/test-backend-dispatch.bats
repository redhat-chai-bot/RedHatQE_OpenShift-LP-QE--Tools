#!/usr/bin/env bats

load test-helper

setup() {
  DISPATCH="$REPO_ROOT/src/scripts/host/backends/dispatch.sh"
  KVM_BACKEND="$REPO_ROOT/src/scripts/host/backends/kvm.sh"
  KUBEVIRT_BACKEND="$REPO_ROOT/src/scripts/host/backends/kubevirt.sh"
}

@test "dispatch.sh exists and is readable" {
  [ -f "$DISPATCH" ]
  [ -r "$DISPATCH" ]
}

@test "kvm.sh defines all required function signatures" {
  required=(DomainState DetectCrash StartVM StopVM KillVM Screenshot SnapshotCreate SnapshotRevert MemoryDump GuestIP GuestDisk)
  for fn in "${required[@]}"; do
    grep -qE "^function ${fn} " "$KVM_BACKEND" || { echo "MISSING: $fn"; false; }
  done
}

@test "kubevirt.sh defines all required function signatures" {
  required=(DomainState DetectCrash StartVM StopVM KillVM Screenshot SnapshotCreate SnapshotRevert MemoryDump GuestIP GuestDisk)
  for fn in "${required[@]}"; do
    grep -qE "^function ${fn} " "$KUBEVIRT_BACKEND" || { echo "MISSING: $fn"; false; }
  done
}

@test "dispatch sources kvm backend by default" {
  BSOD_DET__HYP_PROV=kvm run bash -c "source '$DISPATCH' && type DomainState"
  [ "$status" -eq 0 ]
  [[ "$output" == *"function"* ]]
}

@test "dispatch rejects invalid provider" {
  BSOD_DET__HYP_PROV=invalid run bash -c "source '$DISPATCH' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown BSOD_DET__HYP_PROV"* ]]
}

@test "kvm backend uses virsh in DomainState" {
  grep -q 'virsh domstate' "$KVM_BACKEND"
}

@test "kubevirt backend uses oc/virtctl" {
  grep -q 'oc get vmi\|virtctl' "$KUBEVIRT_BACKEND"
}

@test "kubevirt SnapshotCreate returns error (not supported)" {
  grep -q 'not supported' "$KUBEVIRT_BACKEND"
}
