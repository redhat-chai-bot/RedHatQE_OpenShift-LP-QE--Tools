#!/usr/bin/env bats

load test-helper

@test "make builds crashme-ctl.exe" {
  run make -C "$REPO_ROOT/src/scripts/crash-injector/test-driver" clean
  run make -C "$REPO_ROOT/src/scripts/crash-injector/test-driver" crashme-ctl.exe
  [ "$status" -eq 0 ]
  [ -f "$REPO_ROOT/src/scripts/crash-injector/test-driver/crashme-ctl.exe" ]
}

@test "make builds crashme.sys" {
  run make -C "$REPO_ROOT/src/scripts/crash-injector/test-driver" crashme.sys
  [ "$status" -eq 0 ]
  [ -f "$REPO_ROOT/src/scripts/crash-injector/test-driver/crashme.sys" ]
}

@test "crashme-ctl.exe is a PE executable" {
  make -C "$REPO_ROOT/src/scripts/crash-injector/test-driver" crashme-ctl.exe >/dev/null 2>&1
  filetype=$(file "$REPO_ROOT/src/scripts/crash-injector/test-driver/crashme-ctl.exe")
  [[ "$filetype" == *"PE32+"* ]] || [[ "$filetype" == *"Windows"* ]]
}

@test "crashme.sys is a PE executable" {
  make -C "$REPO_ROOT/src/scripts/crash-injector/test-driver" crashme.sys >/dev/null 2>&1
  filetype=$(file "$REPO_ROOT/src/scripts/crash-injector/test-driver/crashme.sys")
  [[ "$filetype" == *"PE32+"* ]] || [[ "$filetype" == *"Windows"* ]]
}

@test "make clean removes build artifacts" {
  make -C "$REPO_ROOT/src/scripts/crash-injector/test-driver" >/dev/null 2>&1
  make -C "$REPO_ROOT/src/scripts/crash-injector/test-driver" clean >/dev/null 2>&1
  [ ! -f "$REPO_ROOT/src/scripts/crash-injector/test-driver/crashme-ctl.exe" ]
  [ ! -f "$REPO_ROOT/src/scripts/crash-injector/test-driver/crashme.sys" ]
}
