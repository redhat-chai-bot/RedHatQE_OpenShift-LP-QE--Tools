#!/usr/bin/env bats
# Offline tests for src/scripts/bsod-pipeline/bsod-runner.sh. Every cluster, guest and virtctl command is a
# local mock, runs use a cleared environment (no in-cluster or kubeconfig credentials) and stdin is not a
# terminal unless a test drives a pseudo-terminal. No VM is crashed and no cluster or guest is contacted.

load test-helper

setup() {
  setup_temp
  runner="$REPO_ROOT/src/scripts/bsod-pipeline/bsod-runner.sh"
  fixtures="$REPO_ROOT/test/fixtures"
  REAL_PYTHON="$(command -v python3)"
  mockBin="$BATS_TMPDIR/mockbin"
  callLog="$BATS_TMPDIR/calls.log"
  evidenceRoot="$BATS_TMPDIR/evidence"
  runStdin=/dev/null
  defaultImage='quay.io/konveyor/oadp-vmfr-access:latest@sha256:e26c74ce8957768bd0bca7fdec01e28874c834cfdbea6fb9e8a5136ec7548cf0'
  mkdir -p "$mockBin" "$evidenceRoot"
  : > "$callLog"
  runEnvArr=()
  MakeMocks
}

teardown() { teardown_temp; }

# External commands used by the runner and the base helpers. Unexpected calls fail loudly.
MakeMocks() {
  cat > "$mockBin/oc" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == --request-timeout=* ]] && shift
printf 'oc %s\n' "$*" >> "$CALL_LOG"
[[ "${1:-}" == -n ]] && shift 2
case "$1 ${2:-}" in
  'get vm') cat "$FIXTURE_DIR/vm-manual.json" ;;
  'get vm/'*) printf '%s' "${VM_STATUS:-Stopped}" ;;
  'get vmi'|'get vmi/'*) cat "$FIXTURE_DIR/vmi-running.json" ;;
  'get pod')
    if [[ "$*" == *'kubevirt.io/vm='* ]]; then cat "$FIXTURE_DIR/pods-running.json"; else printf Succeeded; fi ;;
  'get pvc')
    case "$3" in
      fixture-memory) cat "$FIXTURE_DIR/pvc-memory-dump.json" ;;
      fixture-evidence-pvc) cat "$FIXTURE_DIR/pvc-evidence.json" ;;
      *) cat "$FIXTURE_DIR/pvc-rootdisk.json" ;;
    esac ;;
  'get storageclass') cat "$FIXTURE_DIR/storageclass.json" ;;
  'get volumesnapshotclass') cat "$FIXTURE_DIR/volumesnapshotclass.json" ;;
  'get events') exec sleep 30 ;;
  'auth can-i') echo yes ;;
  'api-resources '*) echo volumesnapshots.snapshot.storage.k8s.io ;;
  'apply -f') cat > /dev/null ;;
  'delete pod') exit 0 ;;
  'exec '*)
    if [[ "$*" == *'bash -o pipefail -xc'* ]]; then
      # The inline script reads the domain as $1, after an empty $0 placeholder.
      printf 'oc-patch-tail %q %q\n' "${@: -2:1}" "${@: -1}" >> "$CALL_LOG"
      exit "${PATCH_STATUS:-0}"
    fi
    if [[ "$*" == *'virsh dumpxml'* ]]; then cat "$FIXTURE_DIR/domain-rootdisk.fixture"; exit 0; fi
    echo "unexpected oc: $*" >&2; exit 92 ;;
  *) echo "unexpected oc: $*" >&2; exit 92 ;;
esac
EOF
  cat > "$mockBin/virtctl" <<'EOF'
#!/usr/bin/env bash
printf 'virtctl %s\n' "$*" >> "$CALL_LOG"
[[ "$*" == 'memory-dump get --help' || "$*" == 'memory-dump download --help' ]] && exit 0
echo "unexpected virtctl: $*" >&2; exit 93
EOF
  cat > "$mockBin/guest-agent" <<'EOF'
#!/usr/bin/env bash
printf 'guest-agent %s\n' "$*" >> "$CALL_LOG"
printf 'guest-agent-env pod=%s domain=%s\n' "${BSOD_DET__POD__NAME:-}" "${BSOD_DET__DOMAIN__NAME:-}" >> "$CALL_LOG"
cleanState='{"memory":false,"minidumpCount":0}'
case "$1" in
  ping) echo '{}' ;;
  psfile) echo '{"ok":true,"matchesRecommended":true,"current":{"AutoReboot":0},"pageFile":{"adequate":true},"rebootRequired":false}' ;;
  exec)
    if [[ "$*" == *Remove-Item* ]]; then printf '%s\n' "${CLEAN_STATE:-$cleanState}"
    elif [[ "$*" == *notMyFault=* ]]; then
      printf '{"windows":true,"dumpParent":true,"minidumpParent":true,"notMyFault":%s}\n' "${GUEST_NMF:-true}"
    elif [[ "$*" == *Get-ChildItem* ]]; then echo '[]'
    else echo "unexpected guest-agent exec: $*" >&2; exit 91
    fi ;;
  exec-crash)
    # The real command exits 0 when the guest disconnects, 124 while NotMyFault still runs, else its exit code.
    readyArr=("$EVIDENCE_ROOT"/*/watcher-ready)
    readyState=absent
    [[ ! -s "${readyArr[0]}" ]] || readyState=present
    printf 'guest-agent crash ready-file=%s\n' "$readyState" >> "$CALL_LOG"
    status="${CRASH_STATUS:-0}"
    ((status)) || touch "$CRASH_MARKER"
    exit "$status" ;;
  *) echo "unexpected guest-agent: $*" >&2; exit 91 ;;
esac
EOF
  # Only the Python modules preflight imports are faked; every other python3 call runs the real interpreter.
  cat > "$mockBin/python3" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -c && ( "${2:-}" == 'import Evtx.Evtx' || "${2:-}" == 'import volatility3' ) ]]; then exit 0; fi
exec "$REAL_PYTHON" "$@"
EOF
  chmod +x "$mockBin/oc" "$mockBin/virtctl" "$mockBin/guest-agent" "$mockBin/python3"
}

# Copies the runner into an isolated app tree whose host helpers are recording stubs.
MakeStubTree() {
  stubRunner="$BATS_TMPDIR/app/src/scripts/bsod-pipeline/bsod-runner.sh"
  typeset stubHost="$BATS_TMPDIR/app/src/scripts/host"
  mkdir -p "${stubRunner%/*}" "$stubHost"
  cp "$runner" "$stubRunner"
  cat > "$stubHost/preflight-rhov.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'preflight %s\n' "$*" >> "$CALL_LOG"
metadata=''; run=''
while (($#)); do
  case "$1" in
    --require-trigger) shift ;;
    --metadata) metadata="$2"; shift 2 ;;
    --run-id) run="$2"; shift 2 ;;
    *) shift 2 ;;
  esac
done
sleep "${PREFLIGHT_SLEEP:-0}"
status="${PREFLIGHT_STATUS:-0}"
((status == 0)) || exit "$status"
jq -n --arg run "$run" '{runId:$run,launcherPod:"launcher-pod",domain:"fixture-ns_fixture-vm"}' > "$metadata"
EOF
  cat > "$stubHost/watch-crash.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'watcher %s\n' "$*" >> "$CALL_LOG"
printf 'watcher-env armedTimeout=%s\n' "${BSOD_DET__ARMED__TIMEOUT-<unset>}" >> "$CALL_LOG"
sleepPid=''
trap '[[ -z "$sleepPid" ]] || kill "$sleepPid"; printf "watcher TERM\n" >> "$CALL_LOG"; exit 143' TERM
function Pause () { sleep "$1" & sleepPid=$!; wait "$sleepPid"; sleepPid=''; }
out=''; run=''; ready=''; isIntentional=0
while (($#)); do
  case "$1" in
    --intentional) isIntentional=1; shift ;;
    --no-restart) shift ;;
    --out) out="$2"; shift 2 ;;
    --run-id) run="$2"; shift 2 ;;
    --ready-file) ready="$2"; shift 2 ;;
    *) shift 2 ;;
  esac
done
case "${WATCHER_MODE:-crash}" in
  exit-early) exit 3 ;;
  exit-zero) exit 0 ;;
  stale-ready) printf '%s\n' "other-run" > "$ready"; Pause 30; exit 9 ;;
esac
if ((isIntentional)); then
  # Arm late, so a crash injected without waiting for readiness is caught below.
  Pause 1
  [[ ! -e "$CRASH_MARKER" ]] || exit 8
fi
printf '%s\n' "$run" > "$ready.tmp"; mv -f "$ready.tmp" "$ready"
printf 'watcher ready\n' >> "$CALL_LOG"
if [[ "${WATCHER_MODE:-crash}" == hold ]]; then Pause 30; exit 9; fi
if ((isIntentional)); then
  for _ in {1..100}; do [[ -e "$CRASH_MARKER" ]] && break; Pause 0.2; done
  [[ -e "$CRASH_MARKER" ]] || exit 9
fi
jq -n --argjson ok "${SUMMARY_OK:-true}" --arg run "${SUMMARY_RUN:-$run}" '{ok:$ok,runId:$run}' > "$out/evidence-summary.json"
exit "${WATCHER_EXIT:-0}"
EOF
  chmod +x "$stubHost/preflight-rhov.sh" "$stubHost/watch-crash.sh"
}

# SetRunnerEnv: the cleared runner environment (mocks first on PATH, no cluster credentials) plus runEnvArr.
SetRunnerEnv() {
  runnerEnvArr=(PATH="$mockBin:$PATH" HOME="$BATS_TMPDIR" TMPDIR="$BATS_TMPDIR" KUBECONFIG="$BATS_TMPDIR/no-kubeconfig"
    REAL_PYTHON="$REAL_PYTHON" CALL_LOG="$callLog" FIXTURE_DIR="$fixtures" CRASH_MARKER="$BATS_TMPDIR/crashed"
    EVIDENCE_ROOT="$evidenceRoot" BSOD_DET__GUEST_AGENT__BIN="$mockBin/guest-agent" BSOD_DET__NAMESPACE=fixture-ns
    BSOD_DET__VM__NAME=fixture-vm BSOD_DET__EVIDENCE__DIR="$evidenceRoot" "${runEnvArr[@]}")
}

# RunRunner <runnerPath> [args...]: run with stdin from runStdin (default /dev/null, never a terminal).
RunRunner() {
  typeset runnerPath="$1"; shift
  SetRunnerEnv
  run env -i "${runnerEnvArr[@]}" bash "$runnerPath" "$@" 0< "$runStdin"
}

# RunOnTerminal <answers> <runnerPath> [args...]: run on a pseudo-terminal that receives the typed answers.
RunOnTerminal() {
  typeset answers="$1"; shift
  [ -f "$BATS_TMPDIR/pty-driver.py" ] || cat > "$BATS_TMPDIR/pty-driver.py" <<'EOF'
import os, pty, select, signal, sys, time
answers, argv = sys.argv[1].encode(), sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
os.write(fd, answers)
out, deadline = bytearray(), time.monotonic() + 60
while time.monotonic() < deadline:
    if select.select([fd], [], [], 1)[0]:
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        out += data
else:
    os.kill(pid, signal.SIGKILL)
sys.stdout.write(out.decode('utf-8', 'replace'))
sys.exit(os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]))
EOF
  SetRunnerEnv
  run "$REAL_PYTHON" -I "$BATS_TMPDIR/pty-driver.py" "$answers" env -i "${runnerEnvArr[@]}" bash "$@"
}

# ResetRun: forget the previous run's directories, crash marker and calls (keeps any storage identity marker).
ResetRun() {
  rm -rf "${evidenceRoot:?}"/*/ "$BATS_TMPDIR/crashed"
  : > "$callLog"
}

# RunId: the single run directory the runner created.
RunId() {
  typeset -a runDirArr=("$evidenceRoot"/*/)
  [ "${#runDirArr[@]}" -eq 1 ]
  [ -d "${runDirArr[0]}" ]
  basename "${runDirArr[0]}"
}

LineOf() { grep -nF -- "$1" "$callLog" | head -1 | cut -d: -f1; }

# RefuteCall <ERE>: fails when a call-log line matches, printing it; a bare `! grep` never fails a Bats test.
RefuteCall() {
  if grep -E -- "$1" "$callLog" 1>&2; then return 1; fi
  true
}

AssertNoSideEffects() {
  [ ! -s "$callLog" ]
  [ -z "$(ls -A "$evidenceRoot")" ]
}

@test 'argument validation rejects ambiguous or unsafe invocations before any helper or cluster call' {
  MakeStubTree
  typeset -a caseArr=(
    '--mode intentional|watch is required::'
    '--mode needs a value::--mode'
    "unsupported mode 'bogus'::--mode bogus"
    'a crash type is required with --mode intentional::--mode intentional'
    "unsupported NotMyFault crash type '0x0a'::--mode intentional 0x0a"
    "unsupported NotMyFault crash type '0x00'::--mode intentional 0x00"
    "unsupported NotMyFault crash type '1'::--mode intentional 1"
    'unexpected argument: 0x02::--mode intentional 0x01 0x02'
    'a crash type is only valid with --mode intentional::--mode watch 0x01'
    'unknown option: --force::--force --mode watch'
  )
  typeset item='' message=''
  typeset -a argArr=()
  for item in "${caseArr[@]}"; do
    message="${item%%::*}"
    read -ra argArr <<< "${item#*::}"
    RunRunner "$stubRunner" "${argArr[@]}"
    [ "$status" -eq 2 ]
    [[ "$output" == *"$message"* ]]
    [[ "$output" == *'Usage:'* ]]
    AssertNoSideEffects
  done
}

@test 'help prints usage and exits zero without side effects' {
  MakeStubTree
  RunRunner "$stubRunner" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *'bsod-runner.sh --mode intentional <crashType>'* ]]
  AssertNoSideEffects
}

@test 'piped input is never read as prompt answers: mode, crash type and watch deadline must be explicit' {
  MakeStubTree
  runStdin="$BATS_TMPDIR/answers"
  printf 'intentional\n0x01\n60\n' > "$runStdin"
  runEnvArr=(BSOD_DET__CONFIRM_TARGET=fixture-vm)
  RunRunner "$stubRunner"
  [ "$status" -eq 2 ]; [[ "$output" == *'--mode intentional|watch is required'* ]]
  AssertNoSideEffects

  RunRunner "$stubRunner" --mode intentional
  [ "$status" -eq 2 ]; [[ "$output" == *'a crash type is required with --mode intentional'* ]]
  AssertNoSideEffects

  RunRunner "$stubRunner" --mode watch
  [ "$status" -eq 1 ]; [[ "$output" == *'watch mode without a terminal requires BSOD_DET__ARMED__TIMEOUT'* ]]
  AssertNoSideEffects
}

@test 'target identity and intentional confirmation are required before any cluster call' {
  MakeStubTree
  typeset target=''
  for target in BSOD_DET__VM__NAME= BSOD_DET__NAMESPACE=; do
    runEnvArr=("$target" BSOD_DET__CONFIRM_TARGET=fixture-vm)
    RunRunner "$stubRunner" --mode intentional 0x01
    [ "$status" -eq 1 ]; [[ "$output" == *'BSOD_DET__VM__NAME and BSOD_DET__NAMESPACE must identify'* ]]
    AssertNoSideEffects
  done

  runEnvArr=()
  RunRunner "$stubRunner" --mode intentional 0x01
  [ "$status" -eq 1 ]
  [[ "$output" == *"BSOD_DET__CONFIRM_TARGET must be set to 'fixture-vm'"*"(got: '<unset>')"* ]]
  AssertNoSideEffects

  runEnvArr=(BSOD_DET__CONFIRM_TARGET=other-vm)
  RunRunner "$stubRunner" --mode intentional 0x01
  [ "$status" -eq 1 ]; [[ "$output" == *"(got: 'other-vm')"* ]]
  AssertNoSideEffects
}

@test 'timeouts are validated before any cluster call and unattended watch needs an explicit deadline' {
  MakeStubTree
  runEnvArr=(BSOD_DET__ARMED__TIMEOUT=60 BSOD_DET__READY__TIMEOUT=0)
  RunRunner "$stubRunner" --mode watch
  [ "$status" -eq 1 ]; [[ "$output" == *'must be positive integers'* ]]
  AssertNoSideEffects

  runEnvArr=(BSOD_DET__ARMED__TIMEOUT=60 BSOD_DET__PREFLIGHT__TIMEOUT=abc)
  RunRunner "$stubRunner" --mode watch
  [ "$status" -eq 1 ]; [[ "$output" == *'must be positive integers'* ]]
  AssertNoSideEffects

  runEnvArr=()
  RunRunner "$stubRunner" --mode watch
  [ "$status" -eq 1 ]; [[ "$output" == *'watch mode without a terminal requires BSOD_DET__ARMED__TIMEOUT'* ]]
  AssertNoSideEffects

  runEnvArr=(BSOD_DET__ARMED__TIMEOUT=1h)
  RunRunner "$stubRunner" --mode watch
  [ "$status" -eq 1 ]; [[ "$output" == *'BSOD_DET__ARMED__TIMEOUT must be a positive integer'* ]]
  AssertNoSideEffects

  runEnvArr=(BSOD_DET__CONFIRM_TARGET=fixture-vm BSOD_DET__ARMED__TIMEOUT=0)
  RunRunner "$stubRunner" --mode intentional 0x01
  [ "$status" -eq 1 ]; [[ "$output" == *'BSOD_DET__ARMED__TIMEOUT must be a positive integer'* ]]
  AssertNoSideEffects
}

@test 'intentional run requires NotMyFault, clears dumps, arms the watcher, then injects' {
  MakeStubTree
  runEnvArr=(BSOD_DET__CONFIRM_TARGET=fixture-vm)
  RunRunner "$stubRunner" --mode intentional 0x05
  [ "$status" -eq 0 ]
  [[ "$output" == *'evidence verified in'*'VM fixture-ns/fixture-vm left Stopped.'* ]]
  typeset runId=''; runId="$(RunId)"
  typeset outDir="$evidenceRoot/$runId"
  [[ "$runId" == *-intentional-* ]]
  [ "$(stat -c %a "$outDir")" = 700 ]
  typeset commonArgs="--ns fixture-ns --vm fixture-vm --out $outDir --metadata $outDir/recovery-metadata.json"
  commonArgs+=" --run-id $runId --evidence-mount $evidenceRoot --evidence-volume-kind pvc"
  commonArgs+=" --evidence-storage-id shared-bsod-evidence --snap-class ocs-storagecluster-rbdplugin-snapclass"
  commonArgs+=" --recovery-image $defaultImage --memory-dump-pvc fixture-vm-memdump"
  grep -qxF "preflight $commonArgs --require-trigger" "$callLog"
  grep -qxF "watcher $commonArgs --ready-file $outDir/watcher-ready --no-restart --intentional" "$callLog"
  grep -qxF 'watcher-env armedTimeout=<unset>' "$callLog"
  grep -qxF "oc-patch-tail '' fixture-ns_fixture-vm" "$callLog"
  grep -qxF 'guest-agent exec-crash C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x05' "$callLog"
  grep -qxF 'guest-agent crash ready-file=present' "$callLog"
  grep -qxF 'guest-agent-env pod=launcher-pod domain=fixture-ns_fixture-vm' "$callLog"
  [ -s "$outDir/pre-bsod-domain.xml" ]; [ -s "$outDir/vmi-spec.json" ]
  [ "$(LineOf 'preflight ')" -lt "$(LineOf 'bash -o pipefail -xc')" ]
  [ "$(LineOf 'bash -o pipefail -xc')" -lt "$(LineOf 'Remove-Item')" ]
  [ "$(LineOf 'Remove-Item')" -lt "$(LineOf 'watcher ')" ]
  [ "$(LineOf 'watcher ready')" -lt "$(LineOf 'exec-crash')" ]
  grep -qxF 'oc -n fixture-ns get vm/fixture-vm -o jsonpath={.status.printableStatus}' "$callLog"
  RefuteCall '^virtctl |^oc .*(delete|patch|start|stop)'
}

@test 'watch run neither requires NotMyFault nor clears dumps nor injects, and tolerates a failed domain patch' {
  MakeStubTree
  runEnvArr=(BSOD_DET__ARMED__TIMEOUT=120 PATCH_STATUS=1 BSOD_DET__RECOVERY__IMAGE='registry.test/recovery@sha256:abc')
  RunRunner "$stubRunner" --mode watch
  [ "$status" -eq 0 ]
  [[ "$output" == *'before the watcher deadline (BSOD_DET__ARMED__TIMEOUT=120s).'* ]]
  typeset runId=''; runId="$(RunId)"
  [[ "$runId" == *-watch-* ]]
  grep -q '^preflight .* --recovery-image registry.test/recovery@sha256:abc --memory-dump-pvc fixture-vm-memdump$' "$callLog"
  grep -q "^watcher .* --ready-file $evidenceRoot/$runId/watcher-ready --no-restart\$" "$callLog"
  [ "$(grep -o -- '--recovery-image' <<< "$(grep '^watcher ' "$callLog")" | wc -l)" -eq 1 ]
  grep -qxF 'watcher-env armedTimeout=120' "$callLog"
  grep -qxF "oc-patch-tail '' fixture-ns_fixture-vm" "$callLog"
  RefuteCall 'require-trigger|--intentional|Remove-Item|exec-crash|^virtctl '
}

@test 'failures before arming stop the run without starting the watcher' {
  MakeStubTree
  runEnvArr=(BSOD_DET__CONFIRM_TARGET=fixture-vm PREFLIGHT_STATUS=4)
  RunRunner "$stubRunner" --mode intentional 0x01
  [ "$status" -eq 4 ]
  grep -q '^preflight ' "$callLog"
  RefuteCall '^oc |^guest-agent |^watcher '

  ResetRun
  runEnvArr=(BSOD_DET__CONFIRM_TARGET=fixture-vm PREFLIGHT_SLEEP=20 BSOD_DET__PREFLIGHT__TIMEOUT=1)
  typeset -i started=SECONDS
  RunRunner "$stubRunner" --mode intentional 0x01
  [ "$status" -eq 124 ]; [ "$((SECONDS - started))" -lt 10 ]
  RefuteCall '^oc |^guest-agent |^watcher '

  typeset cleanState=''
  for cleanState in '{"memory":true,"minidumpCount":0}' '{"memory":false,"minidumpCount":2}' 'not-json'; do
    ResetRun
    runEnvArr=(BSOD_DET__CONFIRM_TARGET=fixture-vm CLEAN_STATE="$cleanState")
    RunRunner "$stubRunner" --mode intentional 0x01
    [ "$status" -eq 1 ]; [[ "$output" == *'guest dump cleanup could not be proven'* ]]
    RefuteCall '^watcher |exec-crash'
  done
}

@test 'watcher readiness failures stop the run and never inject' {
  MakeStubTree
  runEnvArr=(BSOD_DET__CONFIRM_TARGET=fixture-vm WATCHER_MODE=exit-early)
  RunRunner "$stubRunner" --mode intentional 0x01
  [ "$status" -eq 3 ]; [[ "$output" == *'watcher exited (status 3) before publishing readiness'* ]]
  RefuteCall 'exec-crash'

  ResetRun
  runEnvArr=(BSOD_DET__CONFIRM_TARGET=fixture-vm WATCHER_MODE=exit-zero)
  RunRunner "$stubRunner" --mode intentional 0x01
  [ "$status" -eq 1 ]; [[ "$output" == *'watcher exited (status 0) before publishing readiness'* ]]
  RefuteCall 'exec-crash'

  ResetRun
  runEnvArr=(BSOD_DET__CONFIRM_TARGET=fixture-vm WATCHER_MODE=stale-ready BSOD_DET__READY__TIMEOUT=2)
  RunRunner "$stubRunner" --mode intentional 0x01
  [ "$status" -eq 1 ]; [[ "$output" == *'watcher readiness timed out after 2s'* ]]
  grep -qx 'watcher TERM' "$callLog"
  RefuteCall 'exec-crash'
}

@test 'post-arm failures: crash command, watcher status, current-run summary and VM state are enforced' {
  MakeStubTree
  runEnvArr=(BSOD_DET__CONFIRM_TARGET=fixture-vm CRASH_STATUS=5)
  RunRunner "$stubRunner" --mode intentional 0x01
  [ "$status" -eq 5 ]; [[ "$output" == *'intentional guest crash command exited nonzero'* ]]
  grep -qx 'watcher TERM' "$callLog"

  typeset item=''
  for item in 'WATCHER_EXIT=6|6|watcher/recovery pipeline failed with status 6' \
      'SUMMARY_OK=false|1|current-run evidence summary is absent or reports failure' \
      'SUMMARY_RUN=other-run|1|current-run evidence summary is absent or reports failure' \
      "VM_STATUS=Running|1|VM fixture-ns/fixture-vm is 'Running' after extraction, expected Stopped"; do
    ResetRun
    runEnvArr=(BSOD_DET__CONFIRM_TARGET=fixture-vm "${item%%|*}")
    RunRunner "$stubRunner" --mode intentional 0x01
    item="${item#*|}"
    [ "$status" -eq "${item%%|*}" ]
    [[ "$output" == *"${item#*|}"* ]]
  done
}

@test 'TERM while the watcher is armed exits 143 and stops the watcher' {
  MakeStubTree
  runEnvArr=(BSOD_DET__ARMED__TIMEOUT=60 WATCHER_MODE=hold)
  SetRunnerEnv
  env -i "${runnerEnvArr[@]}" bash "$stubRunner" --mode watch 0< /dev/null 1> "$BATS_TMPDIR/runner.out" 2>&1 &
  typeset -i pid=$! rc=0 started=SECONDS
  for _ in {1..100}; do grep -qx 'watcher ready' "$callLog" && break; sleep 0.1; done
  grep -qx 'watcher ready' "$callLog"
  kill -TERM "$pid"
  wait "$pid" || rc=$?
  [ "$rc" -eq 143 ]; [ "$((SECONDS - started))" -lt 20 ]
  grep -qx 'watcher TERM' "$callLog"
  RefuteCall 'get vm/|exec-crash'
}

@test 'on a terminal the mode and watch deadline are prompted for, with Enter selecting 3600 seconds' {
  MakeStubTree
  RunOnTerminal $'watch\n\n' "$stubRunner"
  [ "$status" -eq 0 ]
  [[ "$output" == *'Mode (intentional|watch): '* ]]
  [[ "$output" == *'Watch timeout in seconds'* ]]
  grep -qxF 'watcher-env armedTimeout=3600' "$callLog"
  [[ "$(RunId)" == *-watch-* ]]
  RefuteCall 'Remove-Item|exec-crash'
}

@test 'on a terminal an empty crash type or an ended watch-deadline prompt stops the run' {
  MakeStubTree
  runEnvArr=(BSOD_DET__CONFIRM_TARGET=fixture-vm)
  RunOnTerminal $'\n' "$stubRunner" --mode intentional
  [ "$status" -eq 2 ]
  [[ "$output" == *'NotMyFault crash type (0x01 - 0x09): '* ]]
  [[ "$output" == *'a crash type is required with --mode intentional'* ]]
  AssertNoSideEffects

  runEnvArr=()
  RunOnTerminal $'watch\n\x04' "$stubRunner"
  [ "$status" -eq 1 ]; [[ "$output" == *'no watch timeout was entered (input ended)'* ]]
  AssertNoSideEffects
}

# The remaining tests run the runner in place against the real base preflight-rhov.sh and watch-crash.sh.
UseRealHelpers() {
  echo fixture-evidence-pvc > "$evidenceRoot/.bsod-storage-identity"
  runEnvArr=(BSOD_DET__EVIDENCE__STORAGE_ID=fixture-evidence-pvc BSOD_DET__MEMORY__DUMP_PVC=fixture-memory
    BSOD_DET__SNAPSHOT__CLASS=fixture-snapshot-class "$@")
}

@test 'real helpers: intentional run passes preflight, arms watch-crash.sh, injects and propagates the watcher result' {
  UseRealHelpers BSOD_DET__CONFIRM_TARGET=fixture-vm BSOD_DET__ARMED__TIMEOUT=3
  RunRunner "$runner" --mode intentional 0x03
  [ "$status" -eq 1 ]
  [[ "$output" == *'watcher/recovery pipeline failed with status 1'* ]]
  typeset runId=''; runId="$(RunId)"
  typeset outDir="$evidenceRoot/$runId"
  [ "$(jq -r .runId "$outDir/recovery-metadata.json")" = "$runId" ]
  [ "$(jq -r .recoveryImage "$outDir/recovery-metadata.json")" = "$defaultImage" ]
  [ "$(<"$outDir/watcher-ready")" = "$runId" ]
  grep -qxF "oc-patch-tail '' fixture-ns_fixture-vm" "$callLog"
  grep -qxF 'guest-agent exec-crash C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x03' "$callLog"
  grep -qxF 'guest-agent crash ready-file=present' "$callLog"
  [ "$(LineOf 'Remove-Item')" -lt "$(LineOf 'exec-crash')" ]
  jq -e --arg run "$runId" '.runId == $run and .mode == "intentional-rhov" and .ok == false' "$outDir/evidence-summary.json"
  grep -q 'armed observation phase exceeded 3s without a crash' "$outDir/stage-errors.jsonl"
  RefuteCall '^virtctl (stop|start)|^oc .*delete (pvc|dv|vm|vmi)'
}

@test 'real helpers: intentional preflight fails closed without NotMyFault or with an undigested image' {
  UseRealHelpers BSOD_DET__CONFIRM_TARGET=fixture-vm BSOD_DET__ARMED__TIMEOUT=3 GUEST_NMF=false
  RunRunner "$runner" --mode intentional 0x01
  [ "$status" -eq 1 ]; [[ "$output" == *'reviewed NotMyFault binary is missing'* ]]
  RefuteCall 'bash -o pipefail -xc|Remove-Item|exec-crash'
  [ ! -e "$evidenceRoot/$(RunId)/watcher.log" ]

  ResetRun
  UseRealHelpers BSOD_DET__CONFIRM_TARGET=fixture-vm BSOD_DET__RECOVERY__IMAGE='quay.io/konveyor/oadp-vmfr-access:latest'
  RunRunner "$runner" --mode intentional 0x01
  [ "$status" -eq 1 ]; [[ "$output" == *'recovery image must be digest-pinned'* ]]
  [ ! -s "$callLog" ]
}

@test 'real helpers: watch run does not require NotMyFault and arms watch-crash.sh in natural mode' {
  UseRealHelpers BSOD_DET__ARMED__TIMEOUT=3 GUEST_NMF=false
  RunRunner "$runner" --mode watch
  [ "$status" -eq 1 ]
  [[ "$output" == *'watcher/recovery pipeline failed with status 1'* ]]
  typeset runId=''; runId="$(RunId)"
  [ "$(<"$evidenceRoot/$runId/watcher-ready")" = "$runId" ]
  jq -e --arg run "$runId" '.runId == $run and .mode == "natural-rhov"' "$evidenceRoot/$runId/evidence-summary.json"
  RefuteCall 'Remove-Item|exec-crash|^virtctl (stop|start)'
}
