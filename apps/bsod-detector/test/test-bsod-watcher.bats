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
}

teardown() {
  [[ ! -s "$MOCK_DIR/download.pid" ]] || kill -KILL "$(cat "$MOCK_DIR/download.pid")" 2>/dev/null || true
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
  *' get pod '*) exit 0;;
  *) echo "mock oc: unexpected call: $*" >&2; exit 97;;
esac
EOF
  cat > "$MOCK_BIN/virtctl" <<'EOF'
#!/usr/bin/env bash
# Mock virtctl: only `vmexport download`, whose behaviour MOCK_DOWNLOAD selects.
set -u
echo "virtctl $*" >> "$MOCK_DIR/calls"
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
sleep () {
    SECONDS=$((SECONDS + ${1%%.*})); echo "sleep $1 at=${SECONDS}" >> "$MOCK_DIR/clock"
    [[ -n "${GROW_STEPS:-}" && -n "${downloadPid:-}" ]] || return 0
    if ((grown < GROW_STEPS)); then
        printf '%064d' 0 >> "$outDir/dump.tmp"; grown=$((grown + 1)); echo "grew at=${SECONDS}" >> "$MOCK_DIR/clock"
    elif [[ "${GROW_FINISH:-yes}" == yes && ! -e "$MOCK_DIR/finish" ]]; then
        touch "$MOCK_DIR/finish"; while kill -0 "${downloadPid}" 2>/dev/null; do command sleep 0.01; done
    fi
}
snippet="$1"; shift
eval "${snippet}"
EOF
  chmod +x "$driver"
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
  Refute kill -0 "$(cat "$MOCK_DIR/download.pid")" 2>/dev/null
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
  Refute kill -0 "$(cat "$MOCK_DIR/download.pid")" 2>/dev/null
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

# ==== Test isolation ====

@test "mocks shadow the cluster clients and refuse unexpected calls" {
  run "$driver" 'command -v oc virtctl; oc get nodes || echo "status=$?"'
  [[ "$output" == *"$MOCK_BIN/oc"*"$MOCK_BIN/virtctl"* ]]
  [[ "$output" == *'mock oc: unexpected call: get nodes'*'status=97'* ]]
}
