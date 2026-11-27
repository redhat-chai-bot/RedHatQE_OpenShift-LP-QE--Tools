#!/usr/bin/env bats
# bsod-watcher.sh event-log quiet window: WaitForEventLogs samples both event log sizes through EvtxSizes until they stay
# unchanged for over 10s, within a 600s budget. The watcher's own functions run here against a fake clock and a mocked `oc`
# probe: no cluster, VM, crash trigger or memory dump is involved. The same harness also covers the hand-off from the offline
# extractor to the evidence summary, including the 10s stabilization pause between them (StopVMAndRecover, with mocked `oc`,
# `virtctl`, extractor and summary writer), and the --help and unknown-argument handling of the script itself.

load test-helper

setup() {
  typeset watcher="${REPO_ROOT}/src/scripts/host/bsod-watcher.sh"
  typeset -g sentinelDir=''
  setup_temp
  export MOCK_BIN="${BATS_TMPDIR}/mockbin" MOCK_DIR="${BATS_TMPDIR}/mock"
  # A client that escaped the mocks would find no cluster: neither a kubeconfig nor the in-cluster settings of a pod.
  export KUBECONFIG="${BATS_TMPDIR}/no-kubeconfig"; unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
  REAL_TIMEOUT="$(command -v timeout)"; export REAL_TIMEOUT
  mkdir -p "${MOCK_BIN}" "${MOCK_DIR}"
  # The watcher ends by calling Main unconditionally, so load everything before its traps: settings and functions only. Xtrace is
  # left out to keep the output readable; the option line is the only other change.
  [ "$(grep -c '^trap Cleanup EXIT$' "${watcher}")" -eq 1 ]
  export WATCHER_FUNCTIONS="${BATS_TMPDIR}/watcher-functions.sh"
  sed -e 's/^set -euxo pipefail; shopt -s inherit_errexit$/set -euo pipefail; shopt -s inherit_errexit/' \
    -e '/^trap Cleanup EXIT$/,$d' "${watcher}" > "${WATCHER_FUNCTIONS}"
  [ "$(grep -c '^set -euo pipefail; shopt -s inherit_errexit$' "${WATCHER_FUNCTIONS}")" -eq 1 ]
  [ "$(grep -c '^Main ' "${WATCHER_FUNCTIONS}")" -eq 0 ]
  MakeMocks
  export FAKE_CLOCK="${BATS_TMPDIR}/fake-clock.sh"; MakeFakeClock "${FAKE_CLOCK}"
  typeset -g driver="${BATS_TMPDIR}/driver.sh"; MakeDriver "${driver}"
  typeset -g recoveryDriver="${BATS_TMPDIR}/recovery-driver.sh"; MakeRecoveryDriver "${recoveryDriver}"
  # The CLI tests run this exact copy, so that nothing the script does relative to its own location reaches the repository.
  typeset -g appWatcher="${BATS_TMPDIR}/app/src/scripts/host/bsod-watcher.sh"
  mkdir -p "${appWatcher%/*}"; cp "${watcher}" "${appWatcher}"
  true
}

teardown() {
  # Only the directory the CLI test created; never a path inherited from the environment.
  [[ "${sentinelDir:-}" != /tmp/bsod-watcher-sentinel.* ]] || rm -rf "${sentinelDir}"
  teardown_temp
}

MakeMocks() {
  cat > "${MOCK_BIN}/oc" <<'EOF'
#!/usr/bin/env bash
# Mock oc: answers only the single size probe for both event logs; anything else is recorded and fails.
set -euo pipefail; shopt -s inherit_errexit
printf '%s\n' "$*" >> "${MOCK_DIR}/oc-calls"
typeset probe='exec -n synthetic-ns virt-launcher-synthetic -- powershell.exe -NoProfile -Command '
if [[ "$*" != '--request-timeout='*"s ${probe}"*'\System.evtx'*'\Application.evtx'* ]]; then
    printf '%s\n' "$*" >> "${MOCK_DIR}/unexpected"; exit 97
fi
printf '%b' "${MOCK_PROBE_OUTPUT}"
exit "${MOCK_PROBE_STATUS}"
EOF
  cat > "${MOCK_BIN}/timeout" <<'EOF'
#!/usr/bin/env bash
# Recording shim: logs the arguments of each timeout(1) call, then runs the real timeout(1).
set -euo pipefail; shopt -s inherit_errexit
printf '%s\n' "$*" >> "${MOCK_DIR}/timeout-calls"
exec "${REAL_TIMEOUT}" "$@"
EOF
  chmod +x "${MOCK_BIN}/oc" "${MOCK_BIN}/timeout"
  MakeRecoveryMocks
  true
}

# MakeRecoveryMocks: the commands StopVMAndRecover runs, each recorded in order in MOCK_DIR/calls. Only the recovery driver and
# RunCli put MOCK_BIN/recovery first on PATH; the recovery driver points the watcher's script directory at MOCK_DIR/host for the
# extractor and reliability.py.
MakeRecoveryMocks() {
  mkdir -p "${MOCK_BIN}/recovery" "${MOCK_DIR}/host"
  cat > "${MOCK_BIN}/recovery/oc" <<'EOF'
#!/usr/bin/env bash
# Mock oc: at the first probe the VM is Stopped, its launcher pod is gone and the guest PVC is Bound; anything else fails.
set -euo pipefail; shopt -s inherit_errexit
printf 'oc %s\n' "$*" >> "${MOCK_DIR}/calls"
case "$*" in
  ('--request-timeout='*'s get vm synthetic-vm -o jsonpath={.status.printableStatus} -n synthetic-ns') printf 'Stopped';;
  ('--request-timeout='*'s get pod virt-launcher-synthetic --ignore-not-found -o name -n synthetic-ns') ;;
  ('--request-timeout='*'s get pvc synthetic-pvc -o jsonpath={.status.phase}{"/"}{.metadata.deletionTimestamp} -n synthetic-ns')
    printf 'Bound/';;
  (*) printf '%s\n' "$*" >> "${MOCK_DIR}/unexpected"; exit 97;;
esac
true
EOF
  cat > "${MOCK_BIN}/recovery/virtctl" <<'EOF'
#!/usr/bin/env bash
# Mock virtctl: only the VM stop request is expected.
set -euo pipefail; shopt -s inherit_errexit
printf 'virtctl %s\n' "$*" >> "${MOCK_DIR}/calls"
[[ "$*" == 'stop synthetic-vm -n synthetic-ns' ]] || { printf '%s\n' "$*" >> "${MOCK_DIR}/unexpected"; exit 97; }
true
EOF
  cat > "${MOCK_BIN}/recovery/python3" <<'EOF'
#!/usr/bin/env bash
# Mock python3: only the evidence summary writer is expected; nothing is executed.
set -euo pipefail; shopt -s inherit_errexit
printf 'python3 %s\n' "$*" >> "${MOCK_DIR}/calls"
[[ "${1:-}" == "${MOCK_DIR}/host/reliability.py" && "${2:-}" == write-summary ]] ||
    { printf '%s\n' "$*" >> "${MOCK_DIR}/unexpected"; exit 97; }
true
EOF
  cat > "${MOCK_DIR}/host/extract--guest-os--crash-info.sh" <<'EOF'
#!/usr/bin/env bash
# Mock offline extractor: records its arguments, reports its exit status on STDERR and exits with MOCK_EXTRACT_STATUS.
set -euo pipefail; shopt -s inherit_errexit
printf 'extract %s\n' "$*" >> "${MOCK_DIR}/calls"
echo "mock extractor: exiting with status ${MOCK_EXTRACT_STATUS:?}" >&2
exit "${MOCK_EXTRACT_STATUS}"
EOF
  chmod +x "${MOCK_BIN}/recovery/oc" "${MOCK_BIN}/recovery/virtctl" "${MOCK_BIN}/recovery/python3" \
    "${MOCK_DIR}/host/extract--guest-os--crash-info.sh"
  true
}

# MakeFakeClock PATH: writes the fake clock that both drivers source at top level. Once unset, SECONDS is a plain variable that
# only the fake sleep (and, in the quiet-window driver, the probe wrapper) moves; each sleep is logged to MOCK_DIR/clock and, when
# the driver sets fakeSleepCalls to a file, also recorded there as `sleep SECONDS`.
MakeFakeClock() {
  cat > "${1:?}" <<'EOF'
unset SECONDS; typeset -i SECONDS=0
function sleep () {
    typeset fakeSeconds="${1:-}"
    [[ "${fakeSeconds}" =~ ^[1-9][0-9]*$ ]] || { echo "fake sleep: unexpected duration '${fakeSeconds}'" >&2; exit 98; }
    SECONDS=$((SECONDS + fakeSeconds))
    echo "sleep ${fakeSeconds} now=${SECONDS}" >> "${MOCK_DIR}/clock"
    [[ -z "${fakeSleepCalls:-}" ]] || echo "sleep ${fakeSeconds}" >> "${fakeSleepCalls}"
    true
}
EOF
  true
}

# MakeDriver PATH: writes the script that runs WaitForEventLogs once.
MakeDriver() {
  cat > "${1:?}" <<'EOF'
#!/usr/bin/env bash
# Runs the watcher's WaitForEventLogs once. MOCK_DIR/steps scripts one probe per line: DURATION STATUS OUTPUT, where DURATION
# is in seconds or `timeout` (the probe's whole budget); OUTPUT is printf %b text, possibly empty.
set -euo pipefail; shopt -s inherit_errexit
source "${WATCHER_FUNCTIONS}"
declare -F WaitForEventLogs EvtxSizes Log >/dev/null
# The watcher's EvtxSizes, renamed, so that the wrapper below can move the fake clock by each probe's duration.
eval "Real$(declare -f EvtxSizes)"
export PATH="${MOCK_BIN}:${PATH}"
[[ "$(command -v oc)" == "${MOCK_BIN}/oc" && "$(command -v timeout)" == "${MOCK_BIN}/timeout" ]] ||
    { echo 'driver: oc or timeout is not the mock' >&2; exit 96; }
cfgArr[ns]=synthetic-ns
metaArr[launcherPod]=virt-launcher-synthetic
pipelineLog="${MOCK_DIR}/watcher.log"; : > "${pipelineLog}"
: > "${MOCK_DIR}/clock"; : > "${MOCK_DIR}/oc-calls"; : > "${MOCK_DIR}/timeout-calls"
typeset -a stepArr=()
mapfile -t stepArr < "${MOCK_DIR}/steps"
typeset -i stepIndex=0
# Fake clock (see MakeFakeClock): only the fake sleep and the probe wrapper below move SECONDS.
source "${FAKE_CLOCK}"
# Its locals are prefixed so that they never capture the caller's result variable, which the real EvtxSizes binds by name.
function EvtxSizes () {
    typeset -i fakeBudget="${1:?}" fakeGrace="${2:?}"
    typeset fakeDuration='' fakeStatus='' fakeOutput=''
    ((stepIndex < ${#stepArr[@]})) || { echo "fake probe: script exhausted after ${stepIndex} probes" >&2; exit 97; }
    read -r fakeDuration fakeStatus fakeOutput <<<"${stepArr[stepIndex]}"
    stepIndex=$((stepIndex + 1))
    [[ "${fakeDuration}" != timeout ]] || fakeDuration="${fakeBudget}"
    ((fakeDuration <= fakeBudget + fakeGrace)) ||
        { echo "fake probe: ${fakeDuration}s outlives its ${fakeBudget}s budget and ${fakeGrace}s kill grace" >&2; exit 95; }
    echo "probe start=${SECONDS} seconds=${fakeBudget} grace=${fakeGrace} duration=${fakeDuration}" >> "${MOCK_DIR}/clock"
    export MOCK_PROBE_STATUS="${fakeStatus}" MOCK_PROBE_OUTPUT="${fakeOutput}"
    SECONDS=$((SECONDS + fakeDuration))
    RealEvtxSizes "$@"
}
WaitForEventLogs
echo "end=${SECONDS} probes=${stepIndex}" > "${MOCK_DIR}/result"
true
EOF
  true
}

# MakeRecoveryDriver PATH: writes the script that runs StopVMAndRecover once against the recovery mocks.
MakeRecoveryDriver() {
  cat > "${1:?}" <<'EOF'
#!/usr/bin/env bash
# Runs the watcher's StopVMAndRecover once with the fake clock and writes `status=EXIT_STATUS end=FAKE_TIME` to MOCK_DIR/result.
set -euo pipefail; shopt -s inherit_errexit
source "${WATCHER_FUNCTIONS}"
declare -F StopVMAndRecover ReleaseProbe WriteSummary Fatal >/dev/null
export PATH="${MOCK_BIN}/recovery:${MOCK_BIN}:${PATH}"
[[ "$(command -v oc)" == "${MOCK_BIN}/recovery/oc" && "$(command -v virtctl)" == "${MOCK_BIN}/recovery/virtctl" &&
    "$(command -v python3)" == "${MOCK_BIN}/recovery/python3" && "$(command -v timeout)" == "${MOCK_BIN}/timeout" ]] ||
    { echo 'recovery driver: a command is not the mock' >&2; exit 96; }
scriptDir="${MOCK_DIR}/host"
cfgArr[ns]=synthetic-ns; cfgArr[vm]=synthetic-vm
metaArr[launcherPod]=virt-launcher-synthetic; metaArr[guestPvc]=synthetic-pvc
runId=synthetic-run; outDir="${MOCK_DIR}/out"; metadataFile="${outDir}/recovery-metadata.json"
stageErrors="${outDir}/stage-errors.jsonl"; pipelineLog="${outDir}/watcher.log"
mkdir -p "${outDir}"; : > "${stageErrors}"; : > "${pipelineLog}"
: > "${MOCK_DIR}/calls"; : > "${MOCK_DIR}/clock"; : > "${MOCK_DIR}/timeout-calls"
# Fake clock (see MakeFakeClock): only the fake sleep moves SECONDS. Each sleep is also recorded in MOCK_DIR/calls, so that the
# tests see where a pause falls between the mocked commands.
typeset fakeSleepCalls="${MOCK_DIR}/calls"
source "${FAKE_CLOCK}"
trap 'printf "status=%s end=%s\n" "$?" "${SECONDS}" > "${MOCK_DIR}/result"' EXIT
StopVMAndRecover
true
EOF
  true
}

# RunRecovery EXTRACT_STATUS: runs the recovery driver with that extractor exit status; its output is printed so that a failing
# test shows the watcher log.
RunRecovery() {
  rm -f "${MOCK_DIR}/result" "${MOCK_DIR}/unexpected"
  run env MOCK_EXTRACT_STATUS="${1:?}" bash "${recoveryDriver}"
  printf '%s\n' "${output}"
  true
}

# RunCli [VAR=VALUE...] COMMAND ARG...: runs the command with those variables and the mocks first on PATH, so that a command the
# watcher script ran would be recorded (see AssertNoMockCalls) instead of reaching a real client; its output is printed so that
# a failing test shows it.
RunCli() {
  run env PATH="${MOCK_BIN}/recovery:${MOCK_BIN}:${PATH}" "$@"
  printf '%s\n' "${output}"
  true
}

# AssertNoMockCalls: no mocked command (oc, virtctl, python3 or timeout) was run.
AssertNoMockCalls() {
  [ ! -e "${MOCK_DIR}/calls" ]
  [ ! -e "${MOCK_DIR}/oc-calls" ]
  [ ! -e "${MOCK_DIR}/timeout-calls" ]
  [ ! -e "${MOCK_DIR}/unexpected" ]
  true
}

# WriteSteps COUNT LINE...: the probe script (see MakeDriver), COUNT copies of each LINE in order.
WriteSteps() {
  typeset -i count=0
  : > "${MOCK_DIR}/steps"
  while (($#)); do
    for ((count = ${1:?}; count > 0; count--)); do printf '%s\n' "${2?}" >> "${MOCK_DIR}/steps"; done
    shift 2
  done
  true
}

# RunQuietWindow: runs the driver; its output is printed so that a failing test shows the watcher log and driver diagnostics.
RunQuietWindow() {
  rm -f "${MOCK_DIR}/result" "${MOCK_DIR}/unexpected"
  run bash "${driver}"
  printf '%s\n' "${output}"
  true
}

# AssertRun END PROBES: the wait returned normally at fake time END after PROBES probes, all answered by the mock. Each probe's
# timeout(1) call carried the budget and kill grace WaitForEventLogs chose, its request timeout matched the budget, and budget plus
# kill grace ended by the 600 s deadline (fake time 0 is the start).
AssertRun() {
  typeset -i end="${1:?}" probes="${2:?}"
  typeset badProbes=''
  [ "${status}" -eq 0 ]
  [ "$(<"${MOCK_DIR}/result")" = "end=${end} probes=${probes}" ]
  [ "$(grep -c '^probe ' "${MOCK_DIR}/clock")" -eq "${probes}" ]
  [ "$(wc -l < "${MOCK_DIR}/oc-calls")" -eq "${probes}" ]
  [ "$(wc -l < "${MOCK_DIR}/timeout-calls")" -eq "${probes}" ]
  [ ! -e "${MOCK_DIR}/unexpected" ]
  # An assignment, so that a failing awk fails the test instead of reading as no mismatches; mismatching probes are printed.
  badProbes="$(paste -d ' ' <(grep '^probe ' "${MOCK_DIR}/clock") "${MOCK_DIR}/timeout-calls" | awk '
    { split($2, start, "="); split($3, budget, "="); split($4, grace, "=") }
    !($6 == "--signal=TERM" && $7 == "--kill-after=" grace[2] && $8 == budget[2] && $9 == "oc" &&
      $10 == "--request-timeout=" budget[2] "s" && start[2] + budget[2] + grace[2] <= 600)')"
  [ -z "${badProbes}" ] || { printf 'probe/timeout mismatch: %s\n' "${badProbes}"; false; }
  true
}

@test 'watcher quiet window: stable sizes end the wait only once unchanged for more than 10 s' {
  WriteSteps 6 '0 0 4096 8192\r\n'
  RunQuietWindow
  # Probes at 0, 5, 10 and 15 s: the sample exactly 10 s after the baseline is not enough.
  AssertRun 15 4
  [ "$(grep -c '^sleep 5 ' "${MOCK_DIR}/clock")" -eq 3 ]
  [ "$(grep -c 'event logs: new baseline System 4096 bytes, Application 8192 bytes$' "${MOCK_DIR}/watcher.log")" -eq 1 ]
  grep -q 'event log sizes unchanged for over 10s (System: 4096 bytes, Application: 8192 bytes) — not proof that the logs were flushed$' \
    "${MOCK_DIR}/watcher.log"
  [ "$(grep -c 'WARN' "${MOCK_DIR}/watcher.log")" -eq 0 ]
  # One probe reads both logs, bounded by the 30 s cap while plenty of budget is left.
  [ "$(grep -c '^--request-timeout=30s exec .*System\.evtx.*Application\.evtx' "${MOCK_DIR}/oc-calls")" -eq 4 ]
}

@test 'watcher quiet window: the duration of the baseline probe never counts as quiet time' {
  WriteSteps 5 '12 0 4096 8192'
  RunQuietWindow
  # The baseline is set when its probe ends (12 s); the probe that starts then sees 0 s of quiet, the next one 12 s.
  AssertRun 36 3
  [ "$(grep -c '^sleep ' "${MOCK_DIR}/clock")" -eq 0 ]
  grep -q 'event log sizes unchanged for over 10s (System: 4096 bytes, Application: 8192 bytes)' "${MOCK_DIR}/watcher.log"
}

@test 'watcher quiet window: a size change in either event log restarts the window' {
  WriteSteps 2 '0 0 100 200' 2 '0 0 150 200' 6 '0 0 150 250'
  RunQuietWindow
  # Baselines at 0 s (initial), 10 s (System grew) and 20 s (Application grew); the window then completes at 35 s.
  AssertRun 35 8
  [ "$(grep -c 'event logs: .*new baseline' "${MOCK_DIR}/watcher.log")" -eq 3 ]
  grep -q 'event logs: new baseline System 100 bytes, Application 200 bytes$' "${MOCK_DIR}/watcher.log"
  grep -q 'event logs: sizes changed; new baseline System 150 bytes, Application 200 bytes$' "${MOCK_DIR}/watcher.log"
  grep -q 'event logs: sizes changed; new baseline System 150 bytes, Application 250 bytes$' "${MOCK_DIR}/watcher.log"
  grep -q 'event log sizes unchanged for over 10s (System: 150 bytes, Application: 250 bytes)' "${MOCK_DIR}/watcher.log"
}

@test 'watcher quiet window: a failed or invalid sample discards the baseline' {
  typeset invalid='' reason=''
  typeset -a caseArr=(
    '0 1 4096 8192|size probe failed or timed out (exit 1)'
    '0 0 0 8192|size probe did not print two positive integer lengths'
    '0 0 4096 0|size probe did not print two positive integer lengths'
    '0 0 4096|size probe did not print two positive integer lengths'
    '0 0 4096 8192 512|size probe did not print two positive integer lengths'
    '0 0|size probe did not print two positive integer lengths'
  )
  for invalid in "${caseArr[@]}"; do
    reason="${invalid#*|}"; invalid="${invalid%%|*}"
    echo "case: '${invalid}'"
    WriteSteps 2 '0 0 4096 8192' 1 "${invalid}" 5 '0 0 4096 8192'
    RunQuietWindow
    # Without the reset the probe at 15 s would end the wait; the baseline is re-established there instead.
    AssertRun 30 7
    [ "$(grep -c "event logs: invalid sample — ${reason}\$" "${MOCK_DIR}/watcher.log")" -eq 1 ]
    [ "$(grep -c 'event logs: new baseline System 4096 bytes, Application 8192 bytes$' "${MOCK_DIR}/watcher.log")" -eq 2 ]
    grep -q 'event log sizes unchanged for over 10s' "${MOCK_DIR}/watcher.log"
  done
}

@test 'watcher quiet window: sizes that keep changing end the wait before the 600 s deadline' {
  typeset -i i=0
  typeset -a lineArr=()
  for ((i = 0; i < 130; i++)); do lineArr+=(1 "0 0 $((1000 + i)) 2048"); done
  WriteSteps "${lineArr[@]}"
  RunQuietWindow
  # Probes every 5 s from 0 to 590 s; at 595 s only the kill grace is left, so no further probe starts.
  AssertRun 595 119
  [ "$(grep -c 'event log sizes unchanged for over' "${MOCK_DIR}/watcher.log")" -eq 0 ]
  grep -q 'WARN: event log sizes did not stay unchanged for over 10s within 600s (119 valid, 0 failed or invalid samples) — proceeding to stop the VM$' \
    "${MOCK_DIR}/watcher.log"
  # Probe budgets shrink with the time left: 30 s at the start, 5 s for the probe at 590 s.
  [ "$(head -n 1 "${MOCK_DIR}/oc-calls" | cut -d' ' -f1)" = '--request-timeout=30s' ]
  [ "$(tail -n 1 "${MOCK_DIR}/oc-calls" | cut -d' ' -f1)" = '--request-timeout=5s' ]
}

@test 'watcher quiet window: the last probe before the deadline can still complete the window' {
  typeset -i i=0
  typeset -a lineArr=()
  for ((i = 0; i < 116; i++)); do lineArr+=(1 "0 0 $((1000 + i)) 2048"); done
  WriteSteps "${lineArr[@]}" 5 '0 0 1115 2048'
  RunQuietWindow
  # The last change is seen at 575 s; the samples at 580 and 585 s are too early and the one at 590 s, with a 5 s budget, ends it.
  AssertRun 590 119
  grep -q 'event log sizes unchanged for over 10s (System: 1115 bytes, Application: 2048 bytes)' "${MOCK_DIR}/watcher.log"
  [ "$(grep -c 'WARN' "${MOCK_DIR}/watcher.log")" -eq 0 ]
  [ "$(tail -n 1 "${MOCK_DIR}/oc-calls" | cut -d' ' -f1)" = '--request-timeout=5s' ]
}

@test 'watcher quiet window: probes that time out are clamped to the time left and the wait ends by the deadline' {
  WriteSteps 30 'timeout 124'
  RunQuietWindow
  # Each probe uses its whole budget: 30 s from 0 to 570 s, then the 25 s left before the 5 s kill grace.
  AssertRun 595 20
  [ "$(grep -c '^sleep ' "${MOCK_DIR}/clock")" -eq 0 ]
  [ "$(tail -n 1 "${MOCK_DIR}/oc-calls" | cut -d' ' -f1)" = '--request-timeout=25s' ]
  # Consecutive identical failures are logged once.
  [ "$(grep -c 'event logs: invalid sample — size probe failed or timed out (exit 124)$' "${MOCK_DIR}/watcher.log")" -eq 1 ]
  grep -q 'WARN: no valid event log size sample within 600s (20 failed or invalid; last: size probe failed or timed out (exit 124)) — proceeding to stop the VM$' \
    "${MOCK_DIR}/watcher.log"
}

@test 'watcher recovery: the evidence summary follows a successful extraction after the 10 s stabilization pause' {
  RunRecovery 0
  [ "${status}" -eq 0 ]
  [ ! -e "${MOCK_DIR}/unexpected" ]
  # Ready at the first probe, so the only pause is the 10 s stabilization wait after the extraction.
  [ "$(<"${MOCK_DIR}/result")" = 'status=0 end=10' ]
  [ "$(<"${MOCK_DIR}/clock")" = 'sleep 10 now=10' ]
  [ "$(head -n 1 "${MOCK_DIR}/calls")" = 'virtctl stop synthetic-vm -n synthetic-ns' ]
  [ "$(grep -c '^oc ' "${MOCK_DIR}/calls")" -eq 3 ]
  # The extractor gets the run metadata; after the pause, the summary writer runs with the summary contract arguments.
  typeset -a summaryArgArr=(--out "${MOCK_DIR}/out" --stage-errors "${MOCK_DIR}/out/stage-errors.jsonl" --mode natural-rhov
    --vm synthetic-vm --namespace synthetic-ns --run-id synthetic-run --filename evidence-summary.json)
  [ "$(tail -n 3 "${MOCK_DIR}/calls")" = "$(printf '%s\n' "extract --metadata ${MOCK_DIR}/out/recovery-metadata.json" \
    'sleep 10' "python3 ${MOCK_DIR}/host/reliability.py write-summary ${summaryArgArr[*]}")" ]
  [ ! -s "${MOCK_DIR}/out/stage-errors.jsonl" ]
  grep -q 'guest PVC synthetic-pvc Bound; starting the offline extraction$' "${MOCK_DIR}/out/watcher.log"
  grep -q 'waiting for recovery artifacts to stabilize\.\.\.$' "${MOCK_DIR}/out/watcher.log"
}

@test 'watcher recovery: a failed extractor skips the pause, still gets the evidence summary and the watcher exits 1' {
  RunRecovery 3
  [ "${status}" -eq 1 ]
  [ ! -e "${MOCK_DIR}/unexpected" ]
  [ "$(<"${MOCK_DIR}/result")" = 'status=1 end=0' ]
  [ ! -s "${MOCK_DIR}/clock" ]
  [ "$(grep -c '^sleep ' "${MOCK_DIR}/calls")" -eq 0 ]
  [ "$(grep -c '^extract ' "${MOCK_DIR}/calls")" -eq 1 ]
  [ "$(grep -c '^python3 ' "${MOCK_DIR}/calls")" -eq 1 ]
  [ "$(tail -n 1 "${MOCK_DIR}/calls" | cut -d ' ' -f 1-3)" = "python3 ${MOCK_DIR}/host/reliability.py write-summary" ]
  # Current behaviour, unchanged here: the extractor's own output in watcher.log explains the failure and the watcher adds no stage
  # error of its own.
  grep -q '^mock extractor: exiting with status 3$' "${MOCK_DIR}/out/watcher.log"
  [ ! -s "${MOCK_DIR}/out/stage-errors.jsonl" ]
}

@test 'watcher CLI: --help prints the usage, accepts --no-restart and leaves unrelated file.0x files alone' {
  # An exit-time scan for guestfish caches (file.0x*) would reach either sentinel: one directly under /tmp, where TMPDIR points too
  # (--help itself exits before the watcher creates any temporary directory), and one in the source tree of the watcher copy (see
  # setup), which a scan relative to the script would cover.
  typeset -a sentinelArr=()
  sentinelDir="$(mktemp -d /tmp/bsod-watcher-sentinel.XXXXXX)"
  sentinelArr=("${sentinelDir}/file.0x-unrelated" "${BATS_TMPDIR}/app/src/x/file.0x-unrelated")
  mkdir -p "${sentinelArr[1]%/*}"
  printf 'keep this unrelated file\n' | tee "${sentinelArr[@]}" >/dev/null
  RunCli TMPDIR="${sentinelDir}" bash "${appWatcher}" --no-restart --help
  [ "${status}" -eq 0 ]
  [ "$(grep -c '^usage: bsod-watcher\.sh --ns NS --vm VM --out EVIDENCE_MOUNT_OR_RUN_DIR ' <<<"${output}")" -eq 1 ]
  grep -q '^bsod-watcher: WARN: --no-restart is deprecated and has no effect' <<<"${output}"
  [ "$(<"${sentinelArr[0]}")" = 'keep this unrelated file' ]
  [ "$(<"${sentinelArr[1]}")" = 'keep this unrelated file' ]
  AssertNoMockCalls
}

@test 'watcher CLI: an unknown argument fails with status 1' {
  RunCli bash "${appWatcher}" --no-such-option
  [ "${status}" -eq 1 ]
  grep -q '^bsod-watcher: ERROR: unknown argument: --no-such-option$' <<<"${output}"
  AssertNoMockCalls
}
