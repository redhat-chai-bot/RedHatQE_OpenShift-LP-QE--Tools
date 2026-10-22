#!/usr/bin/env bats

load test-helper

setup() {
  setup_temp
  HOST_DIR="$REPO_ROOT/src/scripts/host"
  RELIABILITY="$HOST_DIR/reliability.py"
  FIXTURES="$REPO_ROOT/test/fixtures"
  REAL_PYTHON="$(command -v python3)"
  mkdir -p "$BATS_TMPDIR/mockbin"
}

teardown() { teardown_temp; }

make_python_and_findmnt_mocks() {
  cat > "$BATS_TMPDIR/mockbin/python3" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -c && "${2:-}" == 'import Evtx.Evtx' ]]; then exit 0; fi
exec "$REAL_PYTHON" "$@"
EOF
  cat > "$BATS_TMPDIR/mockbin/findmnt" <<'EOF'
#!/usr/bin/env bash
target="${MOUNT_TARGET:-$EVIDENCE_ROOT}"
jq -n --arg target "$target" --arg source "${MOUNT_SOURCE:-server:/evidence}" \
  '{filesystems:[{target:$target,source:$source,fstype:"xfs","maj:min":"0:99"}]}'
EOF
  chmod +x "$BATS_TMPDIR/mockbin/python3" "$BATS_TMPDIR/mockbin/findmnt"
}

make_preflight_mocks() {
  make_python_and_findmnt_mocks
  cat > "$BATS_TMPDIR/mockbin/virtctl" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *'memory-dump get --help'* || "$*" == *'memory-dump download --help'* ]] && exit 0
exit 90
EOF
  cat > "$BATS_TMPDIR/mockbin/guest-agent" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  ping) exit 0 ;;
  psfile)
    if [[ -n "${CFG_JSON:-}" ]]; then printf '%s\n' "$CFG_JSON"
    else echo '{"ok":true,"matchesRecommended":true,"current":{"AutoReboot":0},"pageFile":{"adequate":true},"rebootRequired":false}'
    fi ;;
  exec)
    if [[ "$*" == *Get-ChildItem* ]]; then echo '[]'
    else echo '{"windows":true,"dumpParent":true,"minidumpParent":true,"notMyFault":true}'
    fi ;;
  *) exit 91 ;;
esac
EOF
  cat > "$BATS_TMPDIR/mockbin/oc" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == --request-timeout=* ]] && shift
printf '%s\n' "$*" >> "$OC_LOG"
if [[ "${HANG_VM_GET:-0}" == 1 && "$1 $2" == 'get vm' ]]; then sleep 30; fi
case "$1 $2" in
  'get vm') cat "$FIXTURE_DIR/vm-manual.json" ;;
  'get vmi') cat "$FIXTURE_DIR/vmi-running.json" ;;
  'get pod')
    if [[ "$*" == *'kubevirt.io/vm='* ]]; then cat "$FIXTURE_DIR/pods-running.json"
    else printf '%s' "${PROBE_PHASE:-Succeeded}"
    fi ;;
  'get pvc')
    if [[ "$3" == fixture-memory ]]; then cat "$FIXTURE_DIR/pvc-memory-dump.json"
    elif [[ "$3" == fixture-evidence-pvc ]]; then cat "$FIXTURE_DIR/pvc-evidence.json"
    else cat "$FIXTURE_DIR/pvc-rootdisk.json"
    fi ;;
  'get storageclass') cat "$FIXTURE_DIR/storageclass.json" ;;
  'get volumesnapshotclass') cat "$FIXTURE_DIR/volumesnapshotclass.json" ;;
  'auth can-i') echo yes ;;
  'exec -n') cat "$FIXTURE_DIR/domain-rootdisk.fixture" ;;
  'apply -f') cat >/dev/null ;;
  'delete pod') exit 0 ;;
  *)
    if [[ "$1" == api-resources ]]; then echo volumesnapshots.snapshot.storage.k8s.io
    else echo "unexpected oc: $*" >&2; exit 92
    fi ;;
esac
EOF
  chmod +x "$BATS_TMPDIR/mockbin/virtctl" "$BATS_TMPDIR/mockbin/guest-agent" "$BATS_TMPDIR/mockbin/oc"
}

run_preflight() {
  local run_id=fixture-run-001
  mkdir -p "$EVIDENCE_ROOT/$run_id"
  run env PATH="$BATS_TMPDIR/mockbin:$PATH" REAL_PYTHON="$REAL_PYTHON" EVIDENCE_ROOT="$EVIDENCE_ROOT" \
    FIXTURE_DIR="$FIXTURES" OC_LOG="$OC_LOG" CFG_JSON="${CFG_JSON:-}" PROBE_PHASE="${PROBE_PHASE:-}" \
    HANG_VM_GET="${HANG_VM_GET:-0}" MOUNT_TARGET="${MOUNT_TARGET:-}" MOUNT_SOURCE="${MOUNT_SOURCE:-}" \
    BSOD_DET__GUEST_AGENT__BIN="$BATS_TMPDIR/mockbin/guest-agent" BSOD_DET__COMMAND__TIMEOUT="${BSOD_COMMAND_TIMEOUT:-2}" \
    bash "$HOST_DIR/preflight-rhov.sh" --ns fixture-ns --vm fixture-vm --out "$EVIDENCE_ROOT/$run_id" \
      --metadata "$EVIDENCE_ROOT/$run_id/recovery-metadata.json" --run-id "$run_id" \
      --evidence-mount "$EVIDENCE_ROOT" --evidence-volume-kind pvc --evidence-storage-id fixture-evidence-pvc \
      --snap-class fixture-snapshot-class --recovery-image registry.test/recovery@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
      --memory-dump-pvc fixture-memory --require-trigger "${PREFLIGHT_EXTRA[@]}"
}

@test "preflight proves mount identity, image tools, pagefile, and exact disk-to-PVC mapping" {
  export EVIDENCE_ROOT="$BATS_TMPDIR/evidence" OC_LOG="$BATS_TMPDIR/oc.log"
  mkdir "$EVIDENCE_ROOT"; echo fixture-evidence-pvc > "$EVIDENCE_ROOT/.bsod-storage-identity"; make_preflight_mocks; PREFLIGHT_EXTRA=()
  run_preflight
  [ "$status" -eq 0 ]
  metadata="$EVIDENCE_ROOT/fixture-run-001/recovery-metadata.json"
  [ "$(jq -r .guestPvc "$metadata")" = fixture-rootdisk ]
  [ "$(jq -r .diskName "$metadata")" = rootdisk ]
  [ "$(jq -r .diskTarget "$metadata")" = vda ]
  [ "$(jq -r .memoryDumpPvc "$metadata")" = fixture-memory ]
  [ "$(jq -r .evidenceMount.id "$metadata")" = fixture-evidence-pvc ]
  grep -q '^apply -f -' "$OC_LOG"
}

@test "preflight rejects unmounted output, unknown pagefile, wrong disk, and bad recovery image" {
  export EVIDENCE_ROOT="$BATS_TMPDIR/evidence" OC_LOG="$BATS_TMPDIR/oc.log"
  mkdir "$EVIDENCE_ROOT"; echo fixture-evidence-pvc > "$EVIDENCE_ROOT/.bsod-storage-identity"; make_preflight_mocks; PREFLIGHT_EXTRA=()
  rm "$EVIDENCE_ROOT/.bsod-storage-identity"
  MOUNT_TARGET=/; run_preflight
  [ "$status" -ne 0 ]; [[ "$output" == *'exact target of a distinct non-root mount'* ]]
  rm -rf "$EVIDENCE_ROOT/fixture-run-001"; unset MOUNT_TARGET
  echo fixture-evidence-pvc > "$EVIDENCE_ROOT/.bsod-storage-identity"
  CFG_JSON='{"ok":true,"matchesRecommended":true,"current":{"AutoReboot":0},"pageFile":{"adequate":null},"rebootRequired":false}'; run_preflight
  [ "$status" -ne 0 ]; [[ "$output" == *'CrashControl/pagefile prerequisites failed validation'* ]]
  rm -rf "$EVIDENCE_ROOT/fixture-run-001"; unset CFG_JSON
  PREFLIGHT_EXTRA=(--disk-target vdb); run_preflight
  [ "$status" -ne 0 ]; [[ "$output" == *'does not map uniquely'* ]]
  rm -rf "$EVIDENCE_ROOT/fixture-run-001"; PREFLIGHT_EXTRA=(); PROBE_PHASE=Failed; run_preflight
  [ "$status" -ne 0 ]; [[ "$output" == *'capability probe failed'* ]]
}

@test "preflight remote-command timeout is actionable and bounded" {
  export EVIDENCE_ROOT="$BATS_TMPDIR/evidence" OC_LOG="$BATS_TMPDIR/oc.log" HANG_VM_GET=1 BSOD_COMMAND_TIMEOUT=1
  mkdir "$EVIDENCE_ROOT"; echo fixture-evidence-pvc > "$EVIDENCE_ROOT/.bsod-storage-identity"; make_preflight_mocks; PREFLIGHT_EXTRA=()
  start=$SECONDS; run_preflight; elapsed=$((SECONDS-start))
  [ "$status" -ne 0 ]; [ "$elapsed" -lt 10 ]
  [[ "$output" == *'cannot read VirtualMachine'* ]]
}

make_recovery_mocks() {
  make_python_and_findmnt_mocks
  cat > "$BATS_TMPDIR/mockbin/oc" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == --request-timeout=* ]] && shift
printf '%s\n' "$*" >> "$OC_LOG"
if [ "${1:-}" = -n ]; then shift 2; fi
if [[ "${1:-}" == cp ]]; then
  target="$3"
  mkdir -p "$(dirname "$target")"
  "$REAL_PYTHON" -c 'import struct,sys; d=bytearray(4096); d[:8]=b"ElfFile\x00"; struct.pack_into("<I",d,0x78,len(d)); open(sys.argv[1],"wb").write(d)' "$target"
  exit 0
fi
case "$1" in
  apply) cat >/dev/null ;;
  wait) exit 0 ;;
  get)
    case "$2" in
      volumesnapshot) printf true ;;
      pvc) printf Bound ;;
      pod) printf Running ;;
      vmi) printf '{"items":[]}' ;;
      *) exit 91 ;;
    esac ;;
  exec)
    all="$*"
    if [[ "$all" == *'guestfish --ro -a /dev/vda run : list-filesystems'* ]]; then [[ "${MISSING_GUESTFISH:-0}" == 0 ]] || exit 1; printf '/dev/sda3: ntfs\n'; exit 0; fi
    if [[ "$all" == *guestfish* && "$all" == *'download /Windows/'* ]]; then exit 0; fi
    if [[ "$all" == *'/bin/bash -ceu'* ]]; then [[ "${MISSING_GUESTFISH:-0}" == 0 ]]; exit; fi
    if [[ "$all" == *' stat '* ]]; then printf 'size: 96\nmtime: 200\n'; exit 0; fi
    if [[ "$all" == *' ls /Windows/Minidump'* ]]; then exit 0; fi
    if [[ "$all" == *'download /Windows/MEMORY.DMP'* ]]; then
      "$REAL_PYTHON" -c 'import os,struct,sys; d=bytearray(8192); d[:8]=b"PAGEDU64"; struct.pack_into("<I",d,0x38,int(os.environ.get("DUMP_CODE","10"),0)); sys.stdout.buffer.write(d)'; exit 0
    fi
    if [[ "$all" == *'download /Windows/System32/winevt/Logs/System.evtx'* ]]; then
      "$REAL_PYTHON" -c 'import struct,sys; d=bytearray(4096); d[:8]=b"ElfFile\x00"; struct.pack_into("<I",d,0x78,4096); sys.stdout.buffer.write(d)'; exit 0
    fi
    if [[ "$all" == *'download /Windows/System32/winevt/Logs/Application.evtx'* ]]; then exit 1; fi
    exit 92 ;;
  delete) exit 0 ;;
  *) exit 93 ;;
esac
EOF
  cat > "$BATS_TMPDIR/mockbin/extract-evtx" <<'EOF'
#!/usr/bin/env bash
[[ "${EVTX_FAIL:-0}" == 0 ]] || { echo '{"ok":false,"error":"fixture parse failure"}'; exit 1; }
echo '{"ok":true,"crash":{"detected":true},"events":[]}'
EOF
  chmod +x "$BATS_TMPDIR/mockbin/oc" "$BATS_TMPDIR/mockbin/extract-evtx"
}

write_recovery_metadata() {
  local run_id=fixture-recovery-001 out="$EVIDENCE_ROOT/fixture-recovery-001"
  mkdir -p "$out"
  echo fixture-evidence-pvc > "$EVIDENCE_ROOT/.bsod-storage-identity"
  jq -n --arg run "$run_id" --arg out "$out" --arg target "$EVIDENCE_ROOT" \
    '{schema:2,runId:$run,outputDir:$out,namespace:"fixture-ns",vm:"fixture-vm",guestPvc:"fixture-rootdisk",
      snapshotClass:"fixture-snapshot-class",storageClass:"fixture-storage-class",storageSize:"32Gi",volumeMode:"Block",
      recoveryImage:"registry.test/recovery@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      recoveryImageContract:"bash+guestfish-v1",armedEpoch:100,preCrashInventory:[],
      evidenceMount:{target:$target,source:"server:/evidence",fsType:"xfs",device:"0:99",kind:"pvc",id:"fixture-evidence-pvc"}}' > "$BATS_TMPDIR/metadata.json"
}

run_recovery() {
  run env PATH="$BATS_TMPDIR/mockbin:$PATH" REAL_PYTHON="$REAL_PYTHON" EVIDENCE_ROOT="$EVIDENCE_ROOT" \
    OC_LOG="$OC_LOG" BSOD_EXTRACT_EVTX_BIN="$BATS_TMPDIR/mockbin/extract-evtx" \
    MISSING_GUESTFISH="${MISSING_GUESTFISH:-0}" DUMP_CODE="${DUMP_CODE:-10}" EVTX_FAIL="${EVTX_FAIL:-0}" MOUNT_SOURCE="${MOUNT_SOURCE:-}" \
    bash "$HOST_DIR/extract--guest-os--crash-info.sh" --metadata "$BATS_TMPDIR/metadata.json"
}

write_elf_memory_fixture() {
  "$REAL_PYTHON" -c 'import struct,sys; d=bytearray(124); d[:16]=b"\x7fELF\x02\x01\x01"+bytes(9); struct.pack_into("<H",d,0x10,4); struct.pack_into("<Q",d,0x20,64); struct.pack_into("<H",d,0x34,64); struct.pack_into("<HH",d,0x36,56,1); struct.pack_into("<IIQ",d,64,1,0,120); struct.pack_into("<Q",d,96,4); d[120:]=b"CORE"; open(sys.argv[1],"wb").write(d)' "$1"
}

@test "recovery reports missing memory when standalone output lacks watcher capture" {
  export EVIDENCE_ROOT="$BATS_TMPDIR/evidence" OC_LOG="$BATS_TMPDIR/oc.log"
  mkdir "$EVIDENCE_ROOT"; make_recovery_mocks; write_recovery_metadata; run_recovery
  [ "$status" -ne 0 ]
  summary="$EVIDENCE_ROOT/fixture-recovery-001/extraction-summary.json"
  [ "$(jq -r .ok "$summary")" = false ]
  jq -e '.missingRequiredArtifactTypes | index("memory") != null' "$summary"
}

@test "recovery validates existing memory and leaves watcher screenshot absent" {
  export EVIDENCE_ROOT="$BATS_TMPDIR/evidence" OC_LOG="$BATS_TMPDIR/oc.log"
  mkdir "$EVIDENCE_ROOT"; make_recovery_mocks; write_recovery_metadata
  write_elf_memory_fixture "$EVIDENCE_ROOT/fixture-recovery-001/vm-memory.elf"
  run_recovery
  [ "$status" -eq 0 ]
  summary="$EVIDENCE_ROOT/fixture-recovery-001/extraction-summary.json"
  [ "$(jq -r .ok "$summary")" = true ]
  [ "$(jq -r '.missingRequiredArtifactTypes|length' "$summary")" -eq 0 ]
  [ ! -e "$EVIDENCE_ROOT/fixture-recovery-001/bsod-screenshot.png" ]
  grep -q '^-n fixture-ns exec .*guestfish --ro -a /dev/vda run : list-filesystems' "$OC_LOG"
  [ "$(grep -c '^-n fixture-ns delete pod/guestfs-ntfs-.* --ignore-not-found$' "$OC_LOG")" -eq 2 ]
  [ "$(grep -c '^-n fixture-ns wait pod/guestfs-ntfs-.* --for=delete --timeout=60s$' "$OC_LOG")" -eq 2 ]
  ! grep -Eq '(^| )delete (pvc|volumesnapshot)( |/)' "$OC_LOG"
}

@test "recovery rejects stale output and unavailable guestfish without requiring storage metadata" {
  export EVIDENCE_ROOT="$BATS_TMPDIR/evidence" OC_LOG="$BATS_TMPDIR/oc.log"
  mkdir "$EVIDENCE_ROOT"; make_recovery_mocks; write_recovery_metadata
  printf stale > "$EVIDENCE_ROOT/fixture-recovery-001/MEMORY.DMP"; run_recovery
  [ "$status" -ne 0 ]; [[ "$output" == *'Pre-existing extraction artifact rejected'* ]]
  rm -rf "$EVIDENCE_ROOT/fixture-recovery-001"; write_recovery_metadata; rm "$EVIDENCE_ROOT/.bsod-storage-identity"
  jq 'del(.evidenceMount)' "$BATS_TMPDIR/metadata.json" > "$BATS_TMPDIR/metadata.tmp"
  mv "$BATS_TMPDIR/metadata.tmp" "$BATS_TMPDIR/metadata.json"
  write_elf_memory_fixture "$EVIDENCE_ROOT/fixture-recovery-001/vm-memory.elf"; run_recovery
  [ "$status" -eq 0 ]
  rm -rf "$EVIDENCE_ROOT/fixture-recovery-001"; write_recovery_metadata; MISSING_GUESTFISH=1; run_recovery
  [ "$status" -ne 0 ]
  [[ "$output" == *guestfish* ]]
  [ ! -e "$EVIDENCE_ROOT/fixture-recovery-001/stage-errors.jsonl" ]
}

make_watcher_mocks() {
  cat > "$BATS_TMPDIR/mockbin/guest-agent" <<'EOF'
#!/usr/bin/env bash
count=0; [[ ! -f "$PING_COUNT" ]] || count="$(<"$PING_COUNT")"; count=$((count+1)); echo "$count" > "$PING_COUNT"
if ((count == 1)); then sleep "${FIRST_PING_DELAY:-0}"; exit 0; fi
exit 1
EOF
  cat > "$BATS_TMPDIR/mockbin/virtctl" <<'EOF'
#!/usr/bin/env bash
printf 'virtctl %s\n' "$*" >> "$CALL_LOG"
if [[ "$1 $2" == 'vnc screenshot' ]]; then
  for arg in "$@"; do [[ "$arg" == --file=* ]] && file="${arg#--file=}"; done
  "$REAL_PYTHON" -c 'import struct,sys,zlib; c=lambda k,p:struct.pack(">I",len(p))+k+p+struct.pack(">I",zlib.crc32(k+p)&0xffffffff); open(sys.argv[1],"wb").write(b"\x89PNG\r\n\x1a\n"+c(b"IHDR",struct.pack(">II5B",1,1,8,2,0,0,0))+c(b"IEND",b""))' "$file"; exit 0
fi
if [[ "$1 $2" == 'memory-dump download' ]]; then
  for arg in "$@"; do [[ "$arg" == --output=* ]] && file="${arg#--output=}"; done
  "$REAL_PYTHON" -c 'import struct,sys; d=bytearray(124); d[:16]=b"\x7fELF\x02\x01\x01"+bytes(9); struct.pack_into("<H",d,0x10,4); struct.pack_into("<Q",d,0x20,64); struct.pack_into("<H",d,0x34,64); struct.pack_into("<HH",d,0x36,56,1); struct.pack_into("<IIQ",d,64,1,0,120); struct.pack_into("<Q",d,96,4); d[120:]=b"CORE"; open(sys.argv[1],"wb").write(d)' "$file"; exit 0
fi
if [[ "$1" == stop ]]; then touch "$STOPPED"; fi
exit 0
EOF
  cat > "$BATS_TMPDIR/mockbin/oc" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == --request-timeout=* ]] && shift
printf 'oc %s\n' "$*" >> "$CALL_LOG"
if [[ "$1 $2" == 'get events' ]]; then sleep 60; exit 0; fi
if [[ "$1 $2" == 'exec -n' && "$*" == *'virsh domstate'* ]]; then [[ "${BLOCK_DOMSTATE:-0}" == 1 ]] && sleep 30; echo paused; exit 0; fi
if [[ "$1 $2" == 'exec -n' && "$*" == *'virsh domstats'* ]]; then
  count=0; [[ ! -f "$STAT_COUNT" ]] || count="$(<"$STAT_COUNT")"; count=$((count+1)); echo "$count" > "$STAT_COUNT"
  value=100; ((count >= 2)) && value=200; printf 'block.0.name=vda\nblock.0.wr.bytes=%s\n' "$value"; exit 0
fi
if [[ "$1 $2" == 'exec -n' && "$*" == *'virsh dumpxml'* ]]; then echo '<domain><devices/></domain>'; exit 0; fi
if [[ "$1 $2" == 'logs -n' ]]; then echo 'fixture compute log'; exit 0; fi
if [[ "$1 $2" == 'get vm' ]]; then printf Completed; exit 0; fi
if [[ "$1 $2" == 'get vmi' ]]; then [[ -f "$STOPPED" ]] || printf Running; exit 0; fi
if [[ "$1 $2" == 'get pod' ]]; then exit 0; fi
exit 92
EOF
  cat > "$BATS_TMPDIR/mockbin/host-signals" <<'EOF'
#!/usr/bin/env bash
echo '{"ok":true}'
EOF
  cat > "$BATS_TMPDIR/mockbin/recovery" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == --metadata && "$#" == 2 ]] || exit 2
out="$(jq -er .outputDir "$2")"
"$REAL_PYTHON" -c 'import struct,sys,pathlib; p=pathlib.Path(sys.argv[1]); d=bytearray(8192); d[:8]=b"PAGEDU64"; struct.pack_into("<I",d,0x38,10); (p/"MEMORY.DMP").write_bytes(d); e=bytearray(4096); e[:8]=b"ElfFile\x00"; struct.pack_into("<I",e,0x78,4096); (p/"System.evtx").write_bytes(e)' "$out"
echo '{"ok":true}' > "$out/parse-dump-header.json"
echo '{"ok":true}' > "$out/events.json"
echo fixture > "$out/recovery.log"
echo fixture > "$out/checksums.sha256"
EOF
  chmod +x "$BATS_TMPDIR/mockbin/guest-agent" "$BATS_TMPDIR/mockbin/virtctl" "$BATS_TMPDIR/mockbin/oc" "$BATS_TMPDIR/mockbin/host-signals" "$BATS_TMPDIR/mockbin/recovery"
}

write_watcher_metadata() {
  mkdir -p "$BATS_TMPDIR/evidence/fixture-watch-001"
  jq -n --arg out "$BATS_TMPDIR/evidence/fixture-watch-001" \
    '{runId:"fixture-watch-001",outputDir:$out,namespace:"fixture-ns",vm:"fixture-vm",launcherPod:"launcher",domain:"fixture-ns_fixture-vm",node:"node",diskTarget:"vda",memoryDumpPvc:"memory-pvc"}' > "$BATS_TMPDIR/metadata.json"
}

run_watcher() {
  run env PATH="$BATS_TMPDIR/mockbin:$PATH" REAL_PYTHON="$REAL_PYTHON" CALL_LOG="$BATS_TMPDIR/calls.log" PING_COUNT="$BATS_TMPDIR/pings" STAT_COUNT="$BATS_TMPDIR/stats" STOPPED="$BATS_TMPDIR/stopped" \
    BLOCK_DOMSTATE="${BLOCK_DOMSTATE:-0}" BSOD_DET__GUEST_AGENT__BIN="$BATS_TMPDIR/mockbin/guest-agent" BSOD_DET__HOST_SIGNALS__BIN="$BATS_TMPDIR/mockbin/host-signals" \
    BSOD_COMMAND_TIMEOUT=1 BSOD_CAPTURE_TIMEOUT=5 BSOD_MEMORY_CAPTURE_TIMEOUT=5 BSOD_RECOVERY_TIMEOUT=10 BSOD_ARMED_TIMEOUT=20 \
    bash "$HOST_DIR/watch-crash.sh" --ns fixture-ns --vm fixture-vm --out "$BATS_TMPDIR/evidence/fixture-watch-001" \
      --metadata "$BATS_TMPDIR/metadata.json" --run-id fixture-watch-001 --ready-file "$BATS_TMPDIR/evidence/fixture-watch-001/ready" --interval 1 --miss 1 --idle-samples 2 --quiesce-wait 10
}

@test "ARCHIVED: watcher arms, samples before capture, and completes fixture recovery" {
  skip "legacy end-to-end fixture assumes old timing/recovery mocks; current watcher integration simulation is not implemented"
  make_watcher_mocks; write_watcher_metadata; run_watcher
  [ "$status" -eq 0 ]
  [ "$(<"$BATS_TMPDIR/evidence/fixture-watch-001/ready")" = fixture-watch-001 ]
  [ "$(jq -r .ok "$BATS_TMPDIR/evidence/fixture-watch-001/evidence-summary.json")" = true ]
  stat_line="$(grep -n 'virsh domstats' "$BATS_TMPDIR/calls.log" | head -1 | cut -d: -f1)"
  shot_line="$(grep -n 'virtctl vnc screenshot' "$BATS_TMPDIR/calls.log" | head -1 | cut -d: -f1)"
  [ "$stat_line" -lt "$shot_line" ]
  grep -q 'virtctl memory-dump get' "$BATS_TMPDIR/calls.log"
  grep -q 'virtctl memory-dump download' "$BATS_TMPDIR/calls.log"
  ! grep -q '/dev/stdout' "$BATS_TMPDIR/calls.log"
}

@test "ARCHIVED: blocked remote state call times out and never stops the VM" {
  skip "legacy end-to-end fixture assumes old timing/recovery mocks; current watcher integration simulation is not implemented"
  make_watcher_mocks; write_watcher_metadata; BLOCK_DOMSTATE=1; run_watcher
  [ "$status" -ne 0 ]
  ! grep -q 'virtctl stop' "$BATS_TMPDIR/calls.log"
  grep -q 'ambiguous or unavailable crash evidence' "$BATS_TMPDIR/evidence/fixture-watch-001/stage-errors.jsonl"
}

@test "ARCHIVED: readiness waits for ping/event arming and TERM exits instead of resuming" {
  skip "legacy end-to-end fixture assumes old timing/recovery mocks; current watcher integration simulation is not implemented"
  make_watcher_mocks; write_watcher_metadata
  env PATH="$BATS_TMPDIR/mockbin:$PATH" REAL_PYTHON="$REAL_PYTHON" CALL_LOG="$BATS_TMPDIR/calls.log" PING_COUNT="$BATS_TMPDIR/pings" STAT_COUNT="$BATS_TMPDIR/stats" STOPPED="$BATS_TMPDIR/stopped" FIRST_PING_DELAY=2 \
    BSOD_DET__GUEST_AGENT__BIN="$BATS_TMPDIR/mockbin/guest-agent" BSOD_DET__HOST_SIGNALS__BIN="$BATS_TMPDIR/mockbin/host-signals" BSOD_ARMED_TIMEOUT=30 \
    bash "$HOST_DIR/watch-crash.sh" --ns fixture-ns --vm fixture-vm --out "$BATS_TMPDIR/evidence/fixture-watch-001" --metadata "$BATS_TMPDIR/metadata.json" --run-id fixture-watch-001 --ready-file "$BATS_TMPDIR/evidence/fixture-watch-001/ready" --interval 5 --miss 2 >"$BATS_TMPDIR/watcher.out" 2>&1 &
  pid=$!
  sleep 1; [ ! -e "$BATS_TMPDIR/evidence/fixture-watch-001/ready" ]
  for _ in {1..10}; do [[ -e "$BATS_TMPDIR/evidence/fixture-watch-001/ready" ]] && break; sleep 1; done
  [ -e "$BATS_TMPDIR/evidence/fixture-watch-001/ready" ]
  kill -TERM "$pid"; result=0; wait "$pid" || result=$?
  [ "$result" -eq 143 ]
  ! kill -0 "$pid" 2>/dev/null
}

@test "watcher help preserves an unrelated file.0x sentinel in TMPDIR" {
  local sentinel="$BATS_TMPDIR/file.0x-unrelated"
  printf 'keep this unrelated file\n' > "$sentinel"

  run env TMPDIR="$BATS_TMPDIR" bash "$HOST_DIR/watch-crash.sh" --help

  [ "$status" -eq 0 ]
  [ -f "$sentinel" ]
  [ "$(<"$sentinel")" = 'keep this unrelated file' ]
}

@test "dump parser handles quoted paths and returns semantic failures nonzero" {
  weird="$BATS_TMPDIR/a' [fixture] --dump.dmp"
  "$REAL_PYTHON" -c 'import struct,sys; d=bytearray(96); d[:8]=b"PAGEDU64"; struct.pack_into("<I",d,0x38,10); open(sys.argv[1],"wb").write(d)' "$weird"
  run bash "$HOST_DIR/parse-dump-header.sh" "$weird"
  [ "$status" -eq 0 ]; [ "$(jq -r .ok <<<"$output")" = true ]
  "$REAL_PYTHON" -c 'import struct,sys; d=bytearray(96); d[:8]=b"PAGEDU64"; struct.pack_into("<I",d,0x38,57005); open(sys.argv[1],"wb").write(d)' "$weird"
  run bash "$HOST_DIR/parse-dump-header.sh" "$weird"
  [ "$status" -ne 0 ]; [ "$(jq -r .ok <<<"$output")" = false ]
}

@test "source contracts use bounded file capture and the current trigger entry point" {
  ! grep -q 'memory-dump .*\/dev\/stdout' "$HOST_DIR/watch-crash.sh"
  grep -q 'virtctl vnc screenshot' "$HOST_DIR/watch-crash.sh"
  grep -q 'virtctl memory-dump get' "$HOST_DIR/watch-crash.sh"
  grep -q 'extract--guest-os--crash-info.sh' "$HOST_DIR/watch-crash.sh"
  grep -q 'exec-crash' "$REPO_ROOT/src/scripts/crash-injector/trigger-bsod-intentional.sh"
}
