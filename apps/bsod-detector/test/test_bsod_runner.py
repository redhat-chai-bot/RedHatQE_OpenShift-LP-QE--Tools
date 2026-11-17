#!/usr/bin/env python3
"""Behavioural tests for src/scripts/bsod-pipeline/bsod-runner.sh with mocked helpers.

The real runner is copied into a temporary tree next to mock preflight-rhov.sh and
watch-crash.sh scripts, a mock guest agent (BSOD_DET__GUEST_AGENT__BIN) and a mock `oc` on PATH.
kubectl, virtctl and virsh are guard stubs that fail and are recorded, and KUBECONFIG points
nowhere, so no guest, VM, cluster, network or crash operation can run.
"""

import os
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


APP_DIR = Path(__file__).resolve().parents[1]
RUNNER = APP_DIR / 'src' / 'scripts' / 'bsod-pipeline' / 'bsod-runner.sh'
VALID_IMAGE = 'quay.io/konveyor/oadp-vmfr-access@sha256:' + 'e26c74ce' * 8
NMF_GUEST = 'C:\\Temp\\nmf\\notmyfaultc64.exe'

MOCK_PREFLIGHT = r'''#!/usr/bin/env bash
set -euo pipefail
echo "preflight $*" >> "${CALL_LOG}"
[ "${MOCK_PREFLIGHT_FAIL:-0}" = 0 ] || exit 7
metadata=''
while (($#)); do case "$1" in --metadata) metadata="$2"; shift 2;; *) shift;; esac; done
printf '{"launcherPod":"virt-launcher-demo","domain":"demo-ns_demo-vm"}\n' > "${metadata}"
'''

MOCK_WATCHER = r'''#!/usr/bin/env bash
set -euo pipefail
echo "watcher $*" >> "${CALL_LOG}"
echo "$$" > "${WATCHER_PID_FILE}"
ready='' runId='' outDir='' isIntentional=0
while (($#)); do
  case "$1" in
    --ready-file) ready="$2"; shift 2;;
    --run-id) runId="$2"; shift 2;;
    --out) outDir="$2"; shift 2;;
    --intentional) isIntentional=1; shift;;
    --no-restart) shift;;
    --ns|--vm|--metadata|--evidence-mount|--evidence-volume-kind|--evidence-storage-id|--snap-class|--recovery-image|--memory-dump-pvc) shift 2;;
    *) echo "mock watcher: unknown argument $1" >&2; exit 64;;
  esac
done
case "${MOCK_WATCHER:-normal}" in
  exit-early) exit 5;;
  wrong-ready) echo 'another-run' > "${ready}"; exec sleep 30;;
  hang) exec sleep 30;;
esac
echo "watcher-ready ${runId}" >> "${CALL_LOG}"
echo "${runId}" > "${ready}"
if ((isIntentional)); then
  for _ in $(seq 1 100); do [ -f "${CRASH_MARKER}" ] && break; sleep 0.1; done
fi
isOk=true; [ "${MOCK_SUMMARY:-ok}" != failed ] || isOk=false
summaryRun="${runId}"; [ "${MOCK_SUMMARY:-ok}" != other-run ] || summaryRun='another-run'
printf '{"ok":%s,"runId":"%s"}\n' "${isOk}" "${summaryRun}" > "${outDir}/evidence-summary.json"
exit "${MOCK_WATCHER_STATUS:-0}"
'''

MOCK_GUEST_AGENT = r'''#!/usr/bin/env bash
set -euo pipefail
echo "guest-agent $*" >> "${CALL_LOG}"
case "$1" in
  exec)
    command="${*: -1}"
    case "${command}" in
      *OpenRead*) printf '%s\r\n' "${MOCK_NMF_STATE:-readable}"; exit "${MOCK_NMF_EXIT:-0}";;
      *Remove-Item*) echo '{"memory":false,"minidumpCount":0}';;
      *) echo 'unexpected guest command' >&2; exit 9;;
    esac;;
  exec-crash) : > "${CRASH_MARKER}"; echo '{"disconnected":true}';;
  *) exit 9;;
esac
'''

MOCK_OC = r'''#!/usr/bin/env bash
echo "oc $*" >> "${CALL_LOG}"
case "$*" in
  *"device_add pvpanic"*) [ "${MOCK_DOMAIN_PATCH_FAIL:-0}" = 0 ] || exit 1;;
  *"get vm/"*) echo "${MOCK_VM_STATUS:-Stopped}";;
  *"get vmi/"*) echo '{}';;
  *"virsh dumpxml"*) echo '<domain/>';;
esac
exit 0
'''

GUARD = '#!/bin/sh\necho "GUARD $0 $*" >> "${CALL_LOG}"\nexit 99\n'


def WriteExecutable(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding='utf-8')
    path.chmod(0o755)


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.tmpDir = Path(tempfile.mkdtemp(prefix='bsod-runner-test-'))
        self.addCleanup(shutil.rmtree, self.tmpDir, ignore_errors=True)
        scripts = self.tmpDir / 'src' / 'scripts'
        self.runner = scripts / 'bsod-pipeline' / 'bsod-runner.sh'
        WriteExecutable(self.runner, RUNNER.read_text(encoding='utf-8'))
        WriteExecutable(scripts / 'host' / 'preflight-rhov.sh', MOCK_PREFLIGHT)
        WriteExecutable(scripts / 'host' / 'watch-crash.sh', MOCK_WATCHER)
        self.guestAgent = self.tmpDir / 'mock' / 'guest-agent'
        WriteExecutable(self.guestAgent, MOCK_GUEST_AGENT)
        mockBin = self.tmpDir / 'mockbin'
        WriteExecutable(mockBin / 'oc', MOCK_OC)
        for tool in ('kubectl', 'virtctl', 'virsh'):
            WriteExecutable(mockBin / tool, GUARD)
        self.evidence = self.tmpDir / 'evidence'
        self.evidence.mkdir()
        self.callLog = self.tmpDir / 'calls.log'
        self.crashMarker = self.tmpDir / 'crash.marker'
        self.watcherPidFile = self.tmpDir / 'watcher.pid'
        self.env = {
            'PATH': f'{mockBin}:/usr/bin:/bin', 'HOME': str(self.tmpDir), 'KUBECONFIG': '/nonexistent/kubeconfig',
            'BSOD_DET__NAMESPACE': 'demo-ns', 'BSOD_DET__VM__NAME': 'demo-vm', 'BSOD_DET__RECOVERY__IMAGE': VALID_IMAGE,
            'BSOD_DET__EVIDENCE__DIR': str(self.evidence), 'BSOD_DET__GUEST_AGENT__BIN': str(self.guestAgent),
            'BSOD_DET__READY__TIMEOUT': '10', 'BSOD_DET__PREFLIGHT__TIMEOUT': '30',
            'CALL_LOG': str(self.callLog), 'CRASH_MARKER': str(self.crashMarker), 'WATCHER_PID_FILE': str(self.watcherPidFile),
        }

    def Run(self, *args, timeout=60, **overrides):
        env = dict(self.env)
        for key, value in overrides.items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = value
        result = subprocess.run(['bash', str(self.runner), *args], env=env, stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, timeout=timeout, check=False)
        return result, self.Calls()

    def Calls(self):
        calls = self.callLog.read_text(encoding='utf-8').splitlines() if self.callLog.exists() else []
        self.assertFalse([call for call in calls if call.startswith('GUARD')], calls)
        return calls

    def RunDirs(self):
        return [path for path in self.evidence.iterdir() if path.is_dir()]

    def Index(self, calls, prefix):
        return next(index for index, call in enumerate(calls) if call.startswith(prefix))

    def test_missing_or_mutable_recovery_image_fails_before_side_effects(self):
        for image in (None, '', 'quay.io/konveyor/oadp-vmfr-access:latest', 'quay.io/konveyor/oadp-vmfr-access@sha256:abc'):
            with self.subTest(image=image):
                result, calls = self.Run('--mode', 'watch', BSOD_DET__RECOVERY__IMAGE=image)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn('BSOD_DET__RECOVERY__IMAGE must be a digest-pinned image', result.stderr)
                self.assertEqual(calls, [])
                self.assertEqual(self.RunDirs(), [])

    def test_mode_crash_type_and_confirmation_gates_fail_before_side_effects(self):
        cases = [
            ((), {}, 2, '--mode intentional|watch is required'),
            (('--mode', 'intentional'), {'BSOD_DET__CONFIRM_TARGET': 'demo-vm'}, 2, 'a crash type is required'),
            (('--mode', 'intentional', '0x10'), {'BSOD_DET__CONFIRM_TARGET': 'demo-vm'}, 2, "unsupported NotMyFault crash type '0x10'"),
            (('--mode', 'watch', '0x01'), {}, 2, 'a crash type is only valid with --mode intentional'),
            (('--mode', 'intentional', '0x01'), {}, 1, "BSOD_DET__CONFIRM_TARGET must be set to 'demo-vm'"),
            (('--mode', 'intentional', '0x01'), {'BSOD_DET__CONFIRM_TARGET': 'other-vm'}, 1, "BSOD_DET__CONFIRM_TARGET must be set to 'demo-vm'"),
        ]
        for args, env, status, message in cases:
            with self.subTest(args=args, env=env):
                result, calls = self.Run(*args, **env)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertIn(message, result.stderr)
                self.assertEqual(calls, [])
                self.assertEqual(self.RunDirs(), [])

    def test_watch_mode_never_stages_injects_or_deletes_guest_dumps(self):
        result, calls = self.Run('--mode', 'watch')
        self.assertEqual(result.returncode, 0, result.stderr)
        preflight = calls[self.Index(calls, 'preflight ')]
        self.assertNotIn('--require-trigger', preflight)
        self.assertIn(f'--recovery-image {VALID_IMAGE}', preflight)
        self.assertFalse([call for call in calls if call.startswith('guest-agent')])
        watcher = calls[self.Index(calls, 'watcher ')]
        self.assertIn('--no-restart', watcher)
        self.assertNotIn('--intentional', watcher)
        self.assertTrue(any('get vm/demo-vm' in call for call in calls))
        self.assertFalse(self.crashMarker.exists())

    def test_intentional_requests_trigger_and_injects_only_after_matching_readiness(self):
        result, calls = self.Run('--mode', 'intentional', '0x01', BSOD_DET__CONFIRM_TARGET='demo-vm')
        self.assertEqual(result.returncode, 0, result.stderr)
        preflightAt = self.Index(calls, 'preflight ')
        self.assertIn('--require-trigger', calls[preflightAt])
        nmfAt = next(i for i, call in enumerate(calls) if call.startswith('guest-agent exec') and 'OpenRead' in call)
        cleanupAt = next(i for i, call in enumerate(calls) if call.startswith('guest-agent exec') and 'Remove-Item' in call)
        watcherAt = self.Index(calls, 'watcher ')
        runDir = self.RunDirs()[0]
        readyAt = calls.index(f'watcher-ready {runDir.name}')
        crashAt = self.Index(calls, 'guest-agent exec-crash')
        self.assertLess(preflightAt, nmfAt)
        self.assertLess(nmfAt, cleanupAt)
        self.assertLess(cleanupAt, watcherAt)
        self.assertLess(readyAt, crashAt)
        self.assertEqual(calls[crashAt], f'guest-agent exec-crash {NMF_GUEST} /accepteula /crash 0x01')
        self.assertIn('--intentional', calls[watcherAt])
        self.assertIn('--no-restart', calls[watcherAt])
        self.assertNotIn('--require-trigger', calls[watcherAt])

    def test_unreadable_notmyfault_stops_before_dump_cleanup_and_watcher(self):
        cases = [{'MOCK_NMF_STATE': 'unavailable'}, {'MOCK_NMF_STATE': 'readable', 'MOCK_NMF_EXIT': '124'}]
        for env in cases:
            with self.subTest(env=env):
                shutil.rmtree(self.evidence)
                self.evidence.mkdir()
                self.callLog.unlink(missing_ok=True)
                result, calls = self.Run('--mode', 'intentional', '0x01', BSOD_DET__CONFIRM_TARGET='demo-vm', **env)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn('is not available and readable on the guest', result.stderr)
                self.assertFalse([call for call in calls if 'Remove-Item' in call or call.startswith(('watcher', 'guest-agent exec-crash'))])
                self.assertEqual(len(self.RunDirs()), 1)

    def test_mismatched_readiness_times_out_without_injection(self):
        result, calls = self.Run('--mode', 'intentional', '0x01', BSOD_DET__CONFIRM_TARGET='demo-vm',
                                 MOCK_WATCHER='wrong-ready', BSOD_DET__READY__TIMEOUT='2')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('watcher readiness timed out after 2s', result.stderr)
        self.assertFalse([call for call in calls if call.startswith('guest-agent exec-crash')])
        self.AssertWatcherStopped()
        self.assertEqual(len(self.RunDirs()), 1)

    def test_early_watcher_exit_is_reported_with_its_status(self):
        result, calls = self.Run('--mode', 'intentional', '0x01', BSOD_DET__CONFIRM_TARGET='demo-vm', MOCK_WATCHER='exit-early')
        self.assertEqual(result.returncode, 5, result.stderr)
        self.assertIn('watcher exited (status 5) before publishing readiness', result.stderr)
        self.assertFalse([call for call in calls if call.startswith('guest-agent exec-crash')])

    def test_failure_status_summary_and_vm_state_are_errors_and_keep_evidence(self):
        cases = [
            ({'MOCK_WATCHER_STATUS': '3'}, 3, 'watcher/recovery pipeline failed with status 3'),
            ({'MOCK_SUMMARY': 'failed'}, 1, 'current-run evidence summary is absent or reports failure'),
            ({'MOCK_SUMMARY': 'other-run'}, 1, 'current-run evidence summary is absent or reports failure'),
            ({'MOCK_VM_STATUS': 'Running'}, 1, "is 'Running' after extraction, expected Stopped"),
            ({'MOCK_PREFLIGHT_FAIL': '1'}, 7, None),
        ]
        for env, status, message in cases:
            with self.subTest(env=env):
                shutil.rmtree(self.evidence)
                self.evidence.mkdir()
                self.callLog.unlink(missing_ok=True)
                result, calls = self.Run('--mode', 'watch', **env)
                self.assertEqual(result.returncode, status, result.stderr)
                if message is None:
                    self.assertFalse([call for call in calls if call.startswith('watcher')])
                else:
                    self.assertIn(message, result.stderr)
                self.assertEqual(len(self.RunDirs()), 1)

    def test_sigterm_stops_the_watcher_and_keeps_the_run_directory(self):
        env = dict(self.env, MOCK_WATCHER='hang', BSOD_DET__READY__TIMEOUT='60')
        process = subprocess.Popen(['bash', str(self.runner), '--mode', 'watch'], env=env, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 20
        while not self.watcherPidFile.exists() and time.monotonic() < deadline:
            time.sleep(0.1)
        self.assertTrue(self.watcherPidFile.exists())
        time.sleep(0.5)
        process.send_signal(signal.SIGTERM)
        self.assertEqual(process.wait(timeout=20), 143)
        self.AssertWatcherStopped()
        self.assertEqual(len(self.RunDirs()), 1)
        self.Calls()

    def test_domain_patch_failure_is_a_stderr_warning(self):
        result, _ = self.Run('--mode', 'watch', MOCK_DOMAIN_PATCH_FAIL='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('bsod-runner: WARN: domain crash-behaviour patch failed', result.stderr)

    def AssertWatcherStopped(self):
        watcherPid = int(self.watcherPidFile.read_text(encoding='utf-8').strip())
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                os.kill(watcherPid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.1)
        self.fail(f'watcher process {watcherPid} is still running')


if __name__ == '__main__':
    unittest.main()
