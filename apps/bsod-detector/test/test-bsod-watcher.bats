#!/usr/bin/env bats
# bsod-watcher.sh: argument and configuration parsing, preflight metadata, watch outcomes, and the memory-dump download, export
# readiness, log sink and event-log paths. Every cluster and guest call goes to local mocks: no OpenShift, no VM.

# shellcheck disable=SC2016 # single-quoted snippets are evaluated later by the driver, inside the watcher's context.

load test-helper

setup() {
  setup_temp
  watcher="$REPO_ROOT/src/scripts/host/bsod-watcher.sh"
  fixtures="$REPO_ROOT/test/fixtures"
  export MOCK_BIN="$BATS_TMPDIR/mockbin" MOCK_DIR="$BATS_TMPDIR/mock"
  mkdir -p "$MOCK_BIN" "$MOCK_DIR/out"; : > "$MOCK_DIR/calls"
  export KUBECONFIG="$BATS_TMPDIR/no-kubeconfig"  # a client that escaped the mocks would find no cluster
  MakeMocks
  # Functions only: Main and the traps are left out, and so is xtrace (unbounded under the Bats DEBUG trap).
  export WATCHER_FUNCTIONS="$BATS_TMPDIR/watcher-functions.sh"
  sed -e 's/^set -euxo pipefail;/set -euo pipefail;/' -e '/^trap Cleanup EXIT$/,$d' "$watcher" > "$WATCHER_FUNCTIONS"
  driver="$BATS_TMPDIR/driver.sh"; MakeDriver
  # A structurally valid synthetic memory dump: a tar.gz with one *.memory.dump member holding an ELF64 ET_CORE header.
  export SYNTHETIC_MEMORY="$BATS_TMPDIR/synthetic-memory.tar.gz"
  python3 -I - "$SYNTHETIC_MEMORY" <<'EOF'
import io, struct, sys, tarfile
elf = b"\x7fELF" + bytes([2, 1, 1]) + bytes(9) + struct.pack("<HHIQQQIHHHHHH", 4, 62, 1, 0, 64, 0, 0, 64, 56, 1, 0, 0, 0) + bytes(56)
with tarfile.open(sys.argv[1], "w:gz") as tar:
    info = tarfile.TarInfo("synthetic.memory.dump"); info.size = len(elf); tar.addfile(info, io.BytesIO(elf))
EOF
}

teardown() {
  # Only a mock that still runs is stopped: a finished one has been reaped and its PID may belong to another process.
  if MockAlive; then kill -KILL "$(cat "$MOCK_DIR/download.pid")" 2>/dev/null || true; fi
  chmod -R u+rwX "$BATS_TMPDIR" 2>/dev/null || true
  teardown_temp
}

MakeMocks() {
  cat > "$MOCK_BIN/oc" <<'EOF'
#!/usr/bin/env bash
# Mock oc: answers only the calls bsod-watcher.sh makes in these tests; anything else fails loudly.
set -u
echo "oc $*" >> "$MOCK_DIR/calls"
case "$*" in
  *' create -f - -o jsonpath={.metadata.uid}'*) cat > /dev/null; printf 'uid-synthetic';;
  *' delete -f - --raw '*) cat > "$MOCK_DIR/delete-body"; echo '{}';;
  *' get virtualmachineexport '*)
    case "${MOCK_EXPORT_PROBE:-}" in
      (fail-with-ready) printf Ready; exit 1;;            # a failed probe that still printed Ready
      (late-ready) printf Ready; sleep 10; exit 0;;       # Ready printed, but the probe outlives its budget
    esac
    phase="${MOCK_EXPORT_PHASE:-Ready}"
    if [[ -f "$MOCK_DIR/export-phases" ]]; then
      phase="$(head -n 1 "$MOCK_DIR/export-phases")"
      (( $(wc -l < "$MOCK_DIR/export-phases") > 1 )) && sed -i 1d "$MOCK_DIR/export-phases"
    fi
    printf '%s' "$phase";;
  *powershell.exe*System.evtx*) [[ "${MOCK_EVTX_FAIL:-}" == System ]] && exit 1; printf "${MOCK_EVTX_SYSTEM-}";;
  *powershell.exe*Application.evtx*) [[ "${MOCK_EVTX_FAIL:-}" == Application ]] && exit 1; printf "${MOCK_EVTX_APPLICATION-}";;
  *' virsh domstate '*) printf '%s\n' "${MOCK_DOMSTATE:-crashed}";;
  *' get vmi '*) printf '%s' "${MOCK_VMI_PHASE:-Running}";;
  *' get vm '*'memoryDumpRequest.phase'*) printf Completed;;
  *' get pod '*) exit 0;;
  *) echo "mock oc: unexpected call: $*" >&2; exit 97;;
esac
EOF
  cat > "$MOCK_BIN/virtctl" <<'EOF'
#!/usr/bin/env bash
# Mock virtctl: only `vmexport download`, whose behaviour MOCK_DOWNLOAD selects.
set -u
echo "virtctl $*" >> "$MOCK_DIR/calls"
[[ "${1:-} ${2:-}" == 'memory-dump get' || "${1:-} ${2:-}" == 'memory-dump remove' ]] && exit 0
[[ "${1:-} ${2:-}" == 'vmexport download' ]] || { echo "mock virtctl: unexpected call: $*" >&2; exit 97; }
target=''; while (($#)); do [[ "$1" == --output ]] && target="$2"; shift; done
echo "$$" > "$MOCK_DIR/download.pid"
: > "$target"  # created empty at start, as virtctl does
case "${MOCK_DOWNLOAD:-complete}" in
  (complete) printf 'ELF-synthetic-dump' >> "$target"; exit 0;;
  (fail) printf 'ELF' >> "$target"; echo 'mock: transfer failed' >&2; exit 1;;
  (progress) while [[ ! -e "$MOCK_DIR/finish" ]]; do sleep 0.01; done; exit 0;;  # the test clock appends the data
  (stall) exec sleep 600;;  # no data at all
  (stall-ignore-term) trap '' TERM; while :; do sleep 0.05; done;;
  (complete-valid) cat "$SYNTHETIC_MEMORY" > "$target"; exit 0;;
  (complete-valid-lock-log) cat "$SYNTHETIC_MEMORY" > "$target"; chmod 000 "$MOCK_DIR/out/watcher.log"; exit 0;;
  (complete-valid-readonly) cat "$SYNTHETIC_MEMORY" > "$target"; chmod 0555 "$(dirname "$target")"; exit 0;;
  (interruptible)  # records whether its output still existed when it was told to stop
    trap 'if [[ -e "$target" ]]; then echo present; else echo removed; fi > "$MOCK_DIR/output-at-term"; exit 143' TERM
    while :; do sleep 0.05; done;;
esac
EOF
  cat > "$MOCK_BIN/guest-agent" <<'EOF'
#!/usr/bin/env bash
# Mock guest agent: `ping` succeeds unless MOCK_PING=fail.
echo "guest-agent $*" >> "$MOCK_DIR/calls"
[[ "${1:-}" == ping && "${MOCK_PING:-ok}" == ok ]]
EOF
  chmod +x "$MOCK_BIN/oc" "$MOCK_BIN/virtctl" "$MOCK_BIN/guest-agent"
}

MakeDriver() {
  cat > "$driver" <<'EOF'
#!/usr/bin/env bash
# Runs a snippet with the watcher functions loaded, the mocks first on PATH and a simulated clock: sleep advances SECONDS
# instantly; with GROW_STEPS it also appends one chunk per poll to the download, as a progressing transfer would.
source "$WATCHER_FUNCTIONS"
export PATH="$MOCK_BIN:$PATH"
scriptDir="$REPO_ROOT/src/scripts/host"
outDir="$MOCK_DIR/out"; runId=synthetic-run
pipelineLog="${TEST_PIPELINE_LOG:-$outDir/watcher.log}"; stageErrors="${TEST_STAGE_ERRORS:-$outDir/stage-errors.jsonl}"
cfgArr[ns]=synthetic-ns; cfgArr[vm]=synthetic-vm
metaArr=([launcherPod]=virt-launcher-synthetic-vm-abcde [domain]=synthetic-ns_synthetic-vm [memoryDumpPvc]=synthetic-memdump-pvc)
typeset -i grown=0
# The real sleep is an external command, while bash waits for it, it reaps finished children; /usr/bin/true does the same here.
sleep () {
    SECONDS=$((SECONDS + ${1%%.*})); echo "sleep $1 at=${SECONDS}" >> "$MOCK_DIR/clock"; /usr/bin/true
    [[ -z "${DELETE_TARGET_AT:-}" || -z "${target:-}" ]] || { ((SECONDS < DELETE_TARGET_AT)) || rm -f "${target}"; }
    [[ -n "${GROW_STEPS:-}" && -n "${downloadPid:-}" ]] || return 0
    if ((grown < GROW_STEPS)); then
        printf '%064d' 0 >> "${target:-$outDir/dump.tmp}"; grown=$((grown + 1)); echo "grew at=${SECONDS}" >> "$MOCK_DIR/clock"
    elif [[ "${GROW_FINISH:-yes}" == yes && ! -e "$MOCK_DIR/finish" ]]; then
        touch "$MOCK_DIR/finish"; while IsDownloadRunning; do command sleep 0.01; done
    fi
}
# Every signal the watcher sends is recorded with whether its target still existed at that moment.
kill () {
    [[ "${1:-}" == -0 ]] || echo "kill $* alive=$(ps -o pid= -p "${@: -1}" >/dev/null 2>&1 && echo yes || echo no)" >> "$MOCK_DIR/kills"
    builtin kill "$@"
}
[[ -z "${TEST_TRAPS:-}" ]] || { trap Cleanup EXIT; trap 'OnSignal 130' INT; trap 'OnSignal 143' TERM; }
snippet="$1"; shift
eval "${snippet}"
EOF
  chmod +x "$driver"
}

# MockAlive: succeeds while this test's download mock still runs. A recorded PID alone may already have been reaped and reused,
# so the process must also carry this test's MOCK_DIR in its environment (a check-then-signal window remains inherent).
MockAlive() {
  local pid='' environment=''
  pid="$(cat "$MOCK_DIR/download.pid" 2>/dev/null)" && [[ -n "$pid" ]] || return 1
  environment="$(tr '\0' '\n' 2>/dev/null < "/proc/$pid/environ")" || return 1
  grep -qxF "MOCK_DIR=$MOCK_DIR" <<<"$environment"
}

# Interrupts a progressing download with TERM after 3 s. timeout signals only its own child, the driver running the watcher's
# real traps, and kills it if it still runs 30 s later; the test itself signals no PID. $1 is the watcher.log path.
InterruptDownload() {
  rc=0
  TEST_TRAPS=1 MOCK_DOWNLOAD=interruptible GROW_STEPS=100000 GROW_FINISH=no TEST_PIPELINE_LOG="$1" \
    timeout --foreground --preserve-status -s TERM -k 30 3 "$driver" 'CaptureMemory' > "$BATS_TMPDIR/interrupted.out" 2>&1 || rc=$?
}

# Refute CMD...: fails the test when CMD succeeds (a bare `! CMD` does not fail a Bats test unless it is the last command).
Refute() { if "$@"; then echo "unexpectedly succeeded: $*" >&2; return 1; fi; }

# Virtual seconds between the start of the download and the moment it was stopped.
StoppedAfter() { awk '/^sleep/{t=$3} END{sub("at=","",t); print t}' "$MOCK_DIR/clock"; }
LastGrowth() { awk '/^grew/{t=$2} END{sub("at=","",t); print t+0}' "$MOCK_DIR/clock"; }

# ==== Arguments and configuration (the real script, run with bash; it never reaches the cluster) ====

@test "watcher --help prints the usage without contacting the cluster" {
  PATH="$MOCK_BIN:$PATH" run bash "$watcher" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *'usage: bsod-watcher.sh --ns NS --vm VM --out'* ]]
  [ ! -s "$MOCK_DIR/calls" ]
}

@test "watcher rejects an unknown argument" {
  PATH="$MOCK_BIN:$PATH" run bash "$watcher" --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *'bsod-watcher: ERROR: unknown argument: --bogus'* ]]
}

@test "watcher requires --ns, --vm and --out" {
  PATH="$MOCK_BIN:$PATH" BSOD_DET__TIMEOUT__ARMED=60 run bash "$watcher" --vm synthetic-vm
  [ "$status" -eq 1 ]
  [[ "$output" == *'--ns, --vm, and --out are required'* ]]
}

@test "watcher requires the armed timeout from its caller" {
  PATH="$MOCK_BIN:$PATH" run env -u BSOD_DET__TIMEOUT__ARMED -u BSOD_DET__ARMED__TIMEOUT bash "$watcher" --ns n --vm v --out "$BATS_TMPDIR/ev"
  [ "$status" -eq 1 ]
  [[ "$output" == *'BSOD_DET__TIMEOUT__ARMED (or legacy BSOD_DET__ARMED__TIMEOUT) must be set'* ]]
}

@test "watcher rejects a count option that is not a positive integer" {
  PATH="$MOCK_BIN:$PATH" BSOD_DET__TIMEOUT__ARMED=60 run bash "$watcher" --ns n --vm v --out "$BATS_TMPDIR/ev" --interval 0
  [ "$status" -eq 1 ]
  [[ "$output" == *"--interval must be a positive integer (got '0')"* ]]
  [ ! -s "$MOCK_DIR/calls" ]
}

@test "export readiness budget must be a positive integer" {
  for value in 5m 0 abc; do
    PATH="$MOCK_BIN:$PATH" BSOD_DET__TIMEOUT__ARMED=60 BSOD_DET__TIMEOUT__EXPORT_READY="$value" \
      run bash "$watcher" --ns n --vm v --out "$BATS_TMPDIR/ev"
    [ "$status" -eq 1 ]
    [[ "$output" == *"BSOD_DET__TIMEOUT__EXPORT_READY must be a positive integer (got '${value}')"* ]]
  done
}

@test "export readiness budget defaults to 300 s and takes BSOD_DET__TIMEOUT__EXPORT_READY" {
  run env -u BSOD_DET__TIMEOUT__EXPORT_READY "$driver" 'echo "budget=${cfgArr[exportReadyTimeout]}"'
  [ "$output" = 'budget=300' ]
  BSOD_DET__TIMEOUT__EXPORT_READY=45 run "$driver" 'echo "budget=${cfgArr[exportReadyTimeout]}"'
  [ "$output" = 'budget=45' ]
}

@test "suffixed preflight and capture budgets stay accepted" {
  BSOD_DET__TIMEOUT__ARMED=60 BSOD_DET__TIMEOUT__PREFLIGHT=5m BSOD_DET__TIMEOUT__CAPTURE=90s \
    run "$driver" 'ParseArgs --ns n --vm v --out /synthetic; ValidateConfig; echo valid'
  [ "$status" -eq 0 ]
  [ "$output" = valid ]
}

# ==== Preflight metadata ====

@test "metadata reader loads the preflight fields" {
  run "$driver" 'metadataFile="$1"; ReadMetadata; echo "${metaArr[runId]} ${metaArr[launcherPod]} ${metaArr[guestPvc]} ${metaArr[node]}"' \
    "$fixtures/watcher-metadata.json"
  [ "$status" -eq 0 ]
  [ "$output" = '20261125T000000Z-1-1 virt-launcher-synthetic-vm-abcde synthetic-guest-pvc synthetic-node' ]
}

@test "metadata reader names the missing field" {
  jq 'del(.launcherPod)' "$fixtures/watcher-metadata.json" > "$BATS_TMPDIR/metadata.json"
  run "$driver" 'metadataFile="$1"; ReadMetadata' "$BATS_TMPDIR/metadata.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *'missing or invalid `.launcherPod` in preflight metadata'* ]]
}

@test "metadata reader rejects several JSON documents" {
  cat "$fixtures/watcher-metadata.json" "$fixtures/watcher-metadata.json" > "$BATS_TMPDIR/metadata.json"
  run "$driver" 'metadataFile="$1"; ReadMetadata' "$BATS_TMPDIR/metadata.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *'must hold exactly one JSON document (found 2)'* ]]
}

@test "metadata reader rejects malformed trailing input" {
  { cat "$fixtures/watcher-metadata.json"; printf '{"runId":'; } > "$BATS_TMPDIR/metadata.json"
  run "$driver" 'metadataFile="$1"; ReadMetadata' "$BATS_TMPDIR/metadata.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *'cannot read preflight metadata'*'as JSON'* ]]
}

# ==== Watch outcomes ====

@test "watch phase expires while the guest agent keeps answering" {
  BSOD_DET__GUEST_AGENT__BIN="$MOCK_BIN/guest-agent" run "$driver" \
    'cfgArr[armedTimeout]=30; cfgArr[interval]=5; Watch phase crashState; echo "phase=${phase}"'
  [ "$status" -eq 0 ]
  [[ "$output" == *'phase=expired'* ]]
  Refute grep -q '^oc ' "$MOCK_DIR/calls"
}

@test "watch phase responds after the missed-ping threshold on a crashed domain" {
  BSOD_DET__GUEST_AGENT__BIN="$MOCK_BIN/guest-agent" MOCK_PING=fail MOCK_DOMSTATE=crashed run "$driver" \
    'cfgArr[armedTimeout]=300; cfgArr[interval]=5; cfgArr[miss]=2; Watch phase crashState; echo "phase=${phase} state=${crashState}"'
  [ "$status" -eq 0 ]
  [[ "$output" == *'phase=respond state=crashed'* ]]
  [ "$(grep -c 'virsh domstate' "$MOCK_DIR/calls")" -eq 2 ]
}

# ==== Memory-dump download (stall detection) ====

@test "completed download succeeds and the export is deleted by its UID" {
  MOCK_DOWNLOAD=complete run timeout 60 "$driver" 'DownloadMemoryDump "$outDir/dump.tmp"'
  [ "$status" -eq 0 ]
  grep -q '"uid":"uid-synthetic"' "$MOCK_DIR/delete-body"
  [ ! -s "$MOCK_DIR/out/stage-errors.jsonl" ]
}

@test "slowly progressing download is never cut off" {
  MOCK_DOWNLOAD=progress GROW_STEPS=20 run timeout 60 "$driver" 'DownloadMemoryDump "$outDir/dump.tmp"'
  [ "$status" -eq 0 ]
  [ "$(StoppedAfter)" -ge 600 ]
  Refute grep -q 'stalled\|stopping it' "$MOCK_DIR/out/watcher.log"
  [ ! -s "$MOCK_DIR/out/stage-errors.jsonl" ]
}

@test "stalled download is stopped after 300 s without data" {
  MOCK_DOWNLOAD=stall run timeout 60 "$driver" 'DownloadMemoryDump "$outDir/dump.tmp"'
  [ "$status" -eq 1 ]
  [ "$(StoppedAfter)" -ge 300 ] && [ "$(StoppedAfter)" -le 311 ]  # limit reached at 300 s, then at most 10 s of TERM grace
  grep -q 'download stalled (no data for 300s) and was stopped' "$MOCK_DIR/out/stage-errors.jsonl"
  Refute grep -q 'download failed' "$MOCK_DIR/out/stage-errors.jsonl"
  Refute MockAlive
  grep -q '"uid":"uid-synthetic"' "$MOCK_DIR/delete-body"
}

@test "download that stops growing is stopped 300 s after its last data" {
  MOCK_DOWNLOAD=progress GROW_STEPS=3 GROW_FINISH=no run timeout 60 "$driver" 'DownloadMemoryDump "$outDir/dump.tmp"'
  [ "$status" -eq 1 ]
  last="$(LastGrowth)"; stopped="$(StoppedAfter)"
  [ "$((stopped - last))" -ge 300 ] && [ "$((stopped - last))" -le 345 ]
  grep -q 'stalled' "$MOCK_DIR/out/stage-errors.jsonl"
}

@test "stalled download that ignores TERM is killed" {
  MOCK_DOWNLOAD=stall-ignore-term run timeout 60 "$driver" 'DownloadMemoryDump "$outDir/dump.tmp"'
  [ "$status" -eq 1 ]
  Refute MockAlive
  grep -q 'stalled' "$MOCK_DIR/out/stage-errors.jsonl"
}

@test "failing download is reported as failed and the export is deleted" {
  MOCK_DOWNLOAD=fail run timeout 60 "$driver" 'DownloadMemoryDump "$outDir/dump.tmp"'
  [ "$status" -eq 1 ]
  grep -q 'virtctl vmexport download failed' "$MOCK_DIR/out/stage-errors.jsonl"
  Refute grep -q 'stalled' "$MOCK_DIR/out/stage-errors.jsonl"
  grep -q '"uid":"uid-synthetic"' "$MOCK_DIR/delete-body"
}

# ==== Log sink ====

@test "failed watcher.log writes do not stop the watcher and are reported once" {
  TEST_PIPELINE_LOG=/dev/full run "$driver" 'Log first; Log second; echo continued'
  [ "$status" -eq 0 ]
  [[ "$output" == *'] first'*'] second'*'continued'* ]]
  [ "$(grep -c 'cannot append to /dev/full' <<<"$output")" -eq 1 ]
}

@test "failed stage-error writes do not stop the watcher or mask the caller status" {
  TEST_STAGE_ERRORS=/dev/full run "$driver" 'Fail () { RecordError memory synthetic failure; return 3; }; Fail || echo "status=$?"'
  [ "$status" -eq 0 ]
  [[ "$output" == *'cannot append to /dev/full: [memory] synthetic failure'* ]]
  [[ "$output" == *'status=3'* ]]
}

# ==== Export readiness ====

@test "export readiness succeeds on a later probe" {
  printf 'Pending\nPending\nReady\n' > "$MOCK_DIR/export-phases"
  run "$driver" 'WaitForExportReady synthetic-export'
  [ "$status" -eq 0 ]
  [ "$(grep -c 'get virtualmachineexport' "$MOCK_DIR/calls")" -eq 3 ]
}

@test "export readiness gives up after the default 300 s with bounded probes" {
  MOCK_EXPORT_PHASE=Pending run env -u BSOD_DET__TIMEOUT__EXPORT_READY "$driver" 'WaitForExportReady synthetic-export'
  [ "$status" -eq 1 ]
  [ "$(StoppedAfter)" -le 300 ]
  grep -q 'not Ready within 300s (last phase: Pending)' "$MOCK_DIR/out/watcher.log"
  awk -F'--request-timeout=' '/get virtualmachineexport/ {n++; split($2, t, "s"); if (t[1] < 1 || t[1] > 30) bad++}
    END {exit !(n >= 10 && bad == 0)}' "$MOCK_DIR/calls"  # every probe bounded to 1..30 s
}

@test "export readiness honours BSOD_DET__TIMEOUT__EXPORT_READY" {
  MOCK_EXPORT_PHASE=Pending BSOD_DET__TIMEOUT__EXPORT_READY=45 run "$driver" 'WaitForExportReady synthetic-export'
  [ "$status" -eq 1 ]
  [ "$(StoppedAfter)" -le 45 ]
  grep -q 'not Ready within 45s' "$MOCK_DIR/out/watcher.log"
}

# ==== Event-log sizes ====

@test "CRLF-terminated byte counts are read as sizes" {
  run "$driver" 'printf "[%s]" "$(MOCK_EVTX_SYSTEM="00123\r\n" EvtxSize System)" "$(MOCK_EVTX_SYSTEM=" 77 \r\n" EvtxSize System)"'
  [ "$output" = '[123][77]' ]
  run "$driver" 'MOCK_EVTX_SYSTEM="12 34\r\n" EvtxSize System || echo "status=$?"'
  [ "$output" = 'status=2' ]
}

@test "event logs with positive CRLF sizes become stable" {
  MOCK_EVTX_SYSTEM='1024\r\n' MOCK_EVTX_APPLICATION='2048\r\n' run "$driver" 'WaitForEventLogs'
  [ "$status" -eq 0 ]
  grep -q 'event logs stable (System: 1024 bytes, Application: 2048 bytes)' "$MOCK_DIR/out/watcher.log"
}

@test "zero, malformed, empty and failed event-log probes never signal readiness" {
  for case in 'size is 0|0\r\n|2048\r\n|' 'answer is not a byte count|Get-Item : denied\r\n|2048\r\n|' \
              'answer is not a byte count||2048\r\n|' 'probe failed|1024\r\n|2048\r\n|System'; do
    IFS='|' read -r want system application failing <<<"$case"
    : > "$MOCK_DIR/out/watcher.log"
    MOCK_EVTX_SYSTEM="$system" MOCK_EVTX_APPLICATION="$application" MOCK_EVTX_FAIL="$failing" run "$driver" 'WaitForEventLogs'
    [ "$status" -eq 0 ]
    Refute grep -q 'event logs stable' "$MOCK_DIR/out/watcher.log"
    grep -q "not confirmed stable within 600s (System ${want})" "$MOCK_DIR/out/watcher.log"
  done
}

# ==== Human review: execution, side effects, owned temporaries, finalization ====

@test "watcher runs directly as an executable" {
  [ -x "$watcher" ]
  PATH="$MOCK_BIN:$PATH" run "$watcher" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *'usage: bsod-watcher.sh'* ]]
}

@test "help, invalid arguments and early failures leave caches and other files untouched" {
  app="$BATS_TMPDIR/app"; mkdir -p "$app/src/scripts/host" "$BATS_TMPDIR/ev"; cp "$watcher" "$app/src/scripts/host/"
  echo app > "$app/src/file.0xSENTINEL.img"; echo tmp > "$BATS_TMPDIR/file.0xSENTINEL.img"  # where the old sweeps looked
  before="$(find "$BATS_TMPDIR" -path "$MOCK_DIR" -prune -o -print | sort | sha256sum)"
  for case in '0|--help' '1|--bogus' '1|--vm v' "1|--ns n --vm v --out $BATS_TMPDIR/ev --interval 0"; do
    # shellcheck disable=SC2086 # the argument lists are split on purpose
    PATH="$MOCK_BIN:$PATH" BSOD_DET__TIMEOUT__ARMED=60 run bash "$app/src/scripts/host/bsod-watcher.sh" ${case#*|}
    [ "$status" -eq "${case%%|*}" ]
    [ "$(find "$BATS_TMPDIR" -path "$MOCK_DIR" -prune -o -print | sort | sha256sum)" = "$before" ]
  done
  [ ! -s "$MOCK_DIR/calls" ]
}

@test "a reused run ID never touches the existing run directory" {
  run_dir="$BATS_TMPDIR/ev/reused-run-01"; mkdir -p "$run_dir"
  for name in .vm-memory.elf.tmp .domain-bsod.xml.tmp .vm-memory.elf.OTHER1 vm-memory.elf.tar.gz; do echo other > "$run_dir/$name"; done
  PATH="$MOCK_BIN:$PATH" BSOD_DET__TIMEOUT__ARMED=60 run "$watcher" --ns n --vm v --out "$BATS_TMPDIR/ev" \
    --evidence-mount "$BATS_TMPDIR/ev" --run-id reused-run-01
  [ "$status" -eq 1 ]
  [[ "$output" == *'cannot create unique run directory'* ]]
  [ "$(cat "$run_dir"/.vm-memory.elf.tmp "$run_dir"/.domain-bsod.xml.tmp "$run_dir"/.vm-memory.elf.OTHER1 "$run_dir"/vm-memory.elf.tar.gz | tr '\n' ' ')" = 'other other other other ' ]
  [ ! -s "$MOCK_DIR/calls" ]
}

@test "named diagnostics identify each invalid integer setting" {
  PATH="$MOCK_BIN:$PATH" BSOD_DET__TIMEOUT__ARMED=10m run "$watcher" --ns n --vm v --out "$BATS_TMPDIR/ev"
  [[ "$output" == *"BSOD_DET__TIMEOUT__ARMED (or BSOD_DET__ARMED__TIMEOUT) must be a positive integer (got '10m')"* ]]
  PATH="$MOCK_BIN:$PATH" BSOD_DET__TIMEOUT__ARMED=60 run "$watcher" --ns n --vm v --out "$BATS_TMPDIR/ev" --quiesce-wait -5
  [[ "$output" == *"--quiesce-wait must be a positive integer (got '-5')"* ]]
}

@test "a completed memory dump is finalized and its download is never signalled" {
  MOCK_DOWNLOAD=complete-valid run timeout 60 "$driver" 'CaptureMemory; echo "assoc=${isMemoryAssociated} temp=[${memoryTemporary}]"'
  [ "$status" -eq 0 ]
  [[ "$output" == *'validated KubeVirt memory dump: vm-memory.elf.tar.gz'*'assoc=0 temp=[]'* ]]
  cmp "$SYNTHETIC_MEMORY" "$MOCK_DIR/out/vm-memory.elf.tar.gz"
  [ -z "$(find "$MOCK_DIR/out" -name '.vm-memory.elf.*')" ]
  [ ! -s "$MOCK_DIR/kills" ]
  grep -q 'virtctl memory-dump remove' "$MOCK_DIR/calls"
}

@test "a failed download removes only its own temporary and keeps a finalized dump" {
  echo final > "$MOCK_DIR/out/vm-memory.elf.tar.gz"; echo other > "$MOCK_DIR/out/.vm-memory.elf.OTHER1"
  MOCK_DOWNLOAD=fail run timeout 60 "$driver" 'CaptureMemory || echo "capture failed temp=[${memoryTemporary}]"'
  [[ "$output" == *'capture failed temp=[]'* ]]
  [ "$(cat "$MOCK_DIR/out/vm-memory.elf.tar.gz") $(cat "$MOCK_DIR/out/.vm-memory.elf.OTHER1")" = 'final other' ]
  [ "$(find "$MOCK_DIR/out" -name '.vm-memory.elf.*' | wc -l)" -eq 1 ]
  grep -q 'virtctl vmexport download failed' "$MOCK_DIR/out/stage-errors.jsonl"
}

@test "a stalled download is stopped before its temporary is removed, without signalling a finished process" {
  MOCK_DOWNLOAD=stall run timeout 60 "$driver" 'CaptureMemory || echo "capture failed temp=[${memoryTemporary}]"'
  [[ "$output" == *'capture failed temp=[]'* ]]
  Refute MockAlive
  [ -z "$(find "$MOCK_DIR/out" -name '.vm-memory.elf.*')" ]
  grep -q 'stalled' "$MOCK_DIR/out/stage-errors.jsonl"
  grep -q '^kill -TERM .* alive=yes' "$MOCK_DIR/kills"
  Refute grep -q 'alive=no' "$MOCK_DIR/kills"
}

@test "an interrupted download is stopped before its temporary output is removed" {
  InterruptDownload "$MOCK_DIR/out/watcher.log"
  [ "$rc" -eq 143 ]
  grep -q '"stage":"interrupted"' "$MOCK_DIR/out/stage-errors.jsonl"
  [ "$(cat "$MOCK_DIR/output-at-term")" = present ]
  Refute MockAlive
  [ -z "$(find "$MOCK_DIR/out" -name '.vm-memory.elf.*')" ]
  grep -q '"uid":"uid-synthetic"' "$MOCK_DIR/delete-body"
  grep -q '^kill -TERM .* alive=yes' "$MOCK_DIR/kills"
}

@test "a failed log sink neither skips the interrupt cleanup nor changes its status" {
  InterruptDownload /dev/full
  [ "$rc" -eq 143 ]
  [ "$(grep -c 'cannot append to /dev/full' "$BATS_TMPDIR/interrupted.out")" -eq 1 ]
  grep -q '"stage":"interrupted"' "$MOCK_DIR/out/stage-errors.jsonl"
  [ "$(cat "$MOCK_DIR/output-at-term")" = present ]
  Refute MockAlive
  [ -z "$(find "$MOCK_DIR/out" -name '.vm-memory.elf.*')" ]
  grep -q '"uid":"uid-synthetic"' "$MOCK_DIR/delete-body"
}

@test "a download that already finished is not signalled when stopped" {
  run "$driver" '/usr/bin/true & downloadPid=$!; /usr/bin/sleep 0.2; StopDownload; echo "status=${downloadStatus} pid=[${downloadPid}]"'
  [ "$status" -eq 0 ]
  [ "$output" = 'status=0 pid=[]' ]
  [ ! -s "$MOCK_DIR/kills" ]
}

@test "a failed finalization is a memory-stage failure that keeps the association for Cleanup" {
  mkdir "$MOCK_DIR/out/vm-memory.elf.tar.gz"
  MOCK_DOWNLOAD=complete-valid run timeout 60 "$driver" 'CaptureMemory || echo "capture failed assoc=${isMemoryAssociated}"'
  [[ "$output" == *'capture failed assoc=1'* ]]
  Refute grep -q 'validated KubeVirt memory dump' <<<"$output"
  grep -q 'cannot finalize the memory dump as vm-memory.elf.tar.gz' "$MOCK_DIR/out/stage-errors.jsonl"
  [ -z "$(ls -A "$MOCK_DIR/out/vm-memory.elf.tar.gz")" ]
  [ -z "$(find "$MOCK_DIR/out" -name '.vm-memory.elf.*')" ]
}

@test "finalization does not depend on watcher.log being writable" {
  # The later association step still redirects to watcher.log (as other steps do), so it is skipped and reported; the
  # association then stays recorded for Cleanup. The finalized dump itself must not depend on the log.
  MOCK_DOWNLOAD=complete-valid-lock-log run timeout 60 "$driver" 'CaptureMemory || echo "capture status=$? assoc=${isMemoryAssociated}"'
  cmp "$SYNTHETIC_MEMORY" "$MOCK_DIR/out/vm-memory.elf.tar.gz"
  [ -z "$(find "$MOCK_DIR/out" -name '.vm-memory.elf.*')" ]
  Refute grep -q 'cannot finalize' "$MOCK_DIR/out/stage-errors.jsonl"
  [[ "$output" == *'capture status=1 assoc=1'* ]]
  [ "$(jq -r .error "$MOCK_DIR/out/stage-errors.jsonl")" = 'memory-dump association cleanup failed' ]
}

@test "an unreadable download size is reported distinctly and counts as no progress" {
  MOCK_DOWNLOAD=stall DELETE_TARGET_AT=90 run timeout 60 "$driver" 'DownloadMemoryDump "$outDir/dump.tmp"'
  [ "$status" -eq 1 ]
  grep -q 'cannot read the size of' "$MOCK_DIR/out/watcher.log"
  grep -q 'stalled' "$MOCK_DIR/out/stage-errors.jsonl"
}

@test "a failed export probe that printed Ready is not readiness" {
  MOCK_EXPORT_PROBE=fail-with-ready BSOD_DET__TIMEOUT__EXPORT_READY=20 run "$driver" 'WaitForExportReady synthetic-export'
  [ "$status" -eq 1 ]
  grep -q 'not Ready within 20s' "$MOCK_DIR/out/watcher.log"
}

@test "a Ready answer from a probe that outlived the deadline is not readiness" {
  MOCK_EXPORT_PROBE=late-ready BSOD_DET__TIMEOUT__EXPORT_READY=2 run timeout 30 "$driver" 'WaitForExportReady synthetic-export'
  [ "$status" -eq 1 ]
  grep -q 'not Ready within 2s' "$MOCK_DIR/out/watcher.log"
}

# ==== Test isolation ====

@test "mocks shadow the cluster clients and refuse unexpected calls" {
  run "$driver" 'command -v oc virtctl; oc get nodes || echo "status=$?"'
  [[ "$output" == *"$MOCK_BIN/oc"*"$MOCK_BIN/virtctl"* ]]
  [[ "$output" == *'mock oc: unexpected call: get nodes'*'status=97'* ]]
}
