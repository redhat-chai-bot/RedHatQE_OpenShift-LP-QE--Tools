#!/usr/bin/env bats

load test-helper

setup() {
  SetupTemp
  CAPTURE_SCRIPT="$REPO_ROOT/src/scripts/host/capture-vm-screen.sh"
  COLLECT_ALL="$REPO_ROOT/src/scripts/host/collect-all.sh"
}

teardown() {
  TeardownTemp
}

# --- capture-vm-screen.sh tests ---

@test "capture-vm-screen exits 2 when --vm is missing" {
  run bash "$CAPTURE_SCRIPT" --out "$BATS_TMPDIR/frames"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--vm required"* ]]
}

@test "capture-vm-screen exits 2 when --out is missing" {
  run bash "$CAPTURE_SCRIPT" --vm test-vm
  [ "$status" -eq 2 ]
  [[ "$output" == *"--out required"* ]]
}

@test "capture-vm-screen creates output directory" {
  # Mock virsh by prepending a fake virsh that does nothing
  mkdir -p "$BATS_TMPDIR/bin"
  cat > "$BATS_TMPDIR/bin/virsh" <<'MOCK'
#!/bin/bash
touch "$4"
MOCK
  chmod +x "$BATS_TMPDIR/bin/virsh"

  PATH="$BATS_TMPDIR/bin:$PATH" run bash "$CAPTURE_SCRIPT" \
    --vm fake-vm --out "$BATS_TMPDIR/frames" --frames 3 --interval 0.1
  [ "$status" -eq 0 ]
  [ -d "$BATS_TMPDIR/frames" ]
}

@test "capture-vm-screen produces numbered frame files" {
  mkdir -p "$BATS_TMPDIR/bin"
  cat > "$BATS_TMPDIR/bin/virsh" <<'MOCK'
#!/bin/bash
# Create a minimal file at the path given by --file (4th arg)
printf 'PNG' > "$4"
MOCK
  chmod +x "$BATS_TMPDIR/bin/virsh"

  PATH="$BATS_TMPDIR/bin:$PATH" run bash "$CAPTURE_SCRIPT" \
    --vm fake-vm --out "$BATS_TMPDIR/frames" --frames 5 --interval 0.1
  [ "$status" -eq 0 ]
  [ -f "$BATS_TMPDIR/frames/bsod-frame-1.png" ]
  [ -f "$BATS_TMPDIR/frames/bsod-frame-5.png" ]
}

@test "capture-vm-screen tolerates virsh failures gracefully" {
  mkdir -p "$BATS_TMPDIR/bin"
  cat > "$BATS_TMPDIR/bin/virsh" <<'MOCK'
#!/bin/bash
exit 1
MOCK
  chmod +x "$BATS_TMPDIR/bin/virsh"

  PATH="$BATS_TMPDIR/bin:$PATH" run bash "$CAPTURE_SCRIPT" \
    --vm fake-vm --out "$BATS_TMPDIR/frames" --frames 2 --interval 0.1
  [ "$status" -eq 0 ]
}

# --- collect-all.sh tests ---

@test "collect-all exits 2 when --vm is missing" {
  run bash "$COLLECT_ALL" --out "$BATS_TMPDIR/out" --ssh /bin/true
  [ "$status" -eq 2 ]
  [[ "$output" == *"--vm required"* ]]
}

@test "collect-all exits 2 when --out is missing" {
  run bash "$COLLECT_ALL" --vm test-vm --ssh /bin/true
  [ "$status" -eq 2 ]
  [[ "$output" == *"--out required"* ]]
}

@test "collect-all exits 2 when --ssh is missing" {
  run bash "$COLLECT_ALL" --vm test-vm --out "$BATS_TMPDIR/out"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--ssh required"* ]]
}
