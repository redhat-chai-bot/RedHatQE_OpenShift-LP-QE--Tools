#!/usr/bin/env python3
"""Behavioral checks: preflight-rhov.sh runs the read-only crash-settings validator and fails closed.

The real preflight-rhov.sh runs from an isolated copy of src/ with stub commands first on PATH: oc,
virtctl and findmnt answer from test/fixtures, python3 answers the two import probes and runs every
other command with the real interpreter (reliability.py map-disk is real), and curl/wget record any
call and fail. The guest agent is a stub that records every call and answers psfile with validator
JSON. That JSON is produced by the real validate-crash-settings.ps1 (the pwsh probe of
test_validate_crash_settings_contract.py, with its system commands mocked); variants change single
fields of a real result. A staged NotMyFault record cannot come from the real script offline, so the
trigger cases add a record with the documented field names. No cluster, guest or network is used.
"""

import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import test_validate_crash_settings_contract as Contract
import validator_test_utils as Utils


PREFLIGHT_REL = Path('src') / 'scripts' / 'host' / 'preflight-rhov.sh'
FIXTURE_DIR = Utils.APP_DIR / 'test' / 'fixtures'
RUN_ID = 'fixture-run-001'
RECOVERY_IMAGE = 'registry.test/recovery@sha256:' + 'a' * 64
GUEST_DATA_FILE = 'C:\\Windows\\Temp\\crash-control.json'
STAGED_RECORD = {
    'status': 'staged', 'source': Utils.NMF_SOURCE, 'resolvedSource': Utils.NMF_SOURCE,
    'archiveSHA256': 'A' * 64, 'sha256': 'B' * 64, 'version': '4.21.0.0', 'signer': Utils.MICROSOFT_SIGNER,
    'stagedPath': Utils.NMF_PATH, 'problem': None,
}

PYTHON_STUB = '''#!/usr/bin/env bash
if [[ "${1:-}" == -c && ( "${2:-}" == 'import Evtx.Evtx' || "${2:-}" == 'import volatility3' ) ]]; then exit 0; fi
exec "$REAL_PYTHON" "$@"
'''
VIRTCTL_STUB = '''#!/usr/bin/env bash
[[ "$*" == *'memory-dump get --help'* || "$*" == *'memory-dump download --help'* ]] && exit 0
exit 90
'''
FAIL_STUB = '''#!/usr/bin/env bash
exit 93
'''
DOWNLOAD_STUB = '''#!/usr/bin/env bash
printf '%s %s\\n' "$(basename "$0")" "$*" >> "$DOWNLOAD_LOG"
exit 97
'''
OC_STUB = '''#!/usr/bin/env bash
[[ "${1:-}" == --request-timeout=* ]] && shift
printf '%s\\n' "$*" >> "$OC_LOG"
case "$1 $2" in
  'get vm') cat "$FIXTURE_DIR/vm-manual.json" ;;
  'get vmi') cat "$FIXTURE_DIR/vmi-running.json" ;;
  'get pod')
    if [[ "$*" == *'kubevirt.io/vm='* ]]; then cat "$FIXTURE_DIR/pods-running.json"; else printf 'Succeeded'; fi ;;
  'get pvc')
    if [[ "$3" == fixture-memory ]]; then cat "$FIXTURE_DIR/pvc-memory-dump.json"
    elif [[ "$3" == fixture-evidence-pvc ]]; then cat "$FIXTURE_DIR/pvc-evidence.json"
    else cat "$FIXTURE_DIR/pvc-rootdisk.json"; fi ;;
  'get storageclass') cat "$FIXTURE_DIR/storageclass.json" ;;
  'get volumesnapshotclass') cat "$FIXTURE_DIR/volumesnapshotclass.json" ;;
  'auth can-i') echo yes ;;
  'exec -n') cat "$FIXTURE_DIR/domain-rootdisk.fixture" ;;
  'apply -f') cat >/dev/null ;;
  'delete pod') exit 0 ;;
  *) if [[ "$1" == api-resources ]]; then echo volumesnapshots.snapshot.storage.k8s.io; else echo "unexpected oc: $*" >&2; exit 92; fi ;;
esac
'''
AGENT_STUB = '''#!/usr/bin/env python3
import json, os, sys
arguments = sys.argv[1:]
with open(os.environ['AGENT_LOG'], 'a', encoding='utf-8') as log:
    log.write(json.dumps(arguments) + '\\n')
command = arguments[0] if arguments else ''
if command == 'ping':
    sys.exit(1 if os.environ.get('STUB_PING_FAIL') == '1' else 0)
if command == 'psfile':
    if os.environ.get('STUB_PSFILE_FAIL') == '1':
        print('guest-agent: guest-exec failed', file=sys.stderr)
        sys.exit(125)
    sys.stdout.write(os.environ.get('STUB_VALIDATION', ''))
    sys.exit(int(os.environ.get('STUB_VALIDATION_RC', '0')))
if command == 'exec':
    print('[]' if 'MEMORY.DMP' in ' '.join(arguments) else '{"windows":true,"dumpParent":true}')
    sys.exit(0)
sys.exit(0)
'''


class PreflightCrashSettingsTests(unittest.TestCase):
    """Runs the real preflight entry point and checks its exit status, messages, guest calls and metadata."""

    realResults: dict = {}
    PROBE = Contract.ValidatorJSONContractTests.PROBE
    RunValidator = Contract.ValidatorJSONContractTests.RunValidator

    def RealResult(self, scenario: str, arguments: dict) -> tuple[int, dict]:
        """Exit code and JSON of the real validator (cached per scenario and arguments)."""
        key = (scenario, json.dumps(arguments, sort_keys=True))
        if key not in self.realResults:
            type(self).realResults[key] = self.RunValidator(scenario, arguments)
        exitCode, output = type(self).realResults[key]
        return exitCode, copy.deepcopy(output)

    def Golden(self) -> dict:
        exitCode, output = self.RealResult('golden', {'dataFile': 'DATA_FILE'})
        self.assertEqual(exitCode, 0)
        return output

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix='bsod-preflight-test.'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.app = self.tmp / 'app'
        shutil.copytree(Utils.APP_DIR / 'src', self.app / 'src')
        self.bin = self.tmp / 'bin'
        self.bin.mkdir()
        for name, body in (('python3', PYTHON_STUB), ('virtctl', VIRTCTL_STUB), ('oc', OC_STUB), ('curl', DOWNLOAD_STUB),
                           ('wget', DOWNLOAD_STUB), ('findmnt', FAIL_STUB), ('guest-agent', AGENT_STUB)):
            stub = self.bin / name
            stub.write_text(body, encoding='utf-8')
            stub.chmod(0o755)
        self.evidence = self.tmp / 'evidence'
        (self.evidence / RUN_ID).mkdir(parents=True)
        (self.evidence / '.bsod-storage-identity').write_text('fixture-evidence-pvc', encoding='utf-8')
        self.logs = {name: self.tmp / f'{name}.log' for name in ('agent', 'oc', 'download')}
        for log in self.logs.values():
            log.touch()
        self.metadata = self.evidence / RUN_ID / 'recovery-metadata.json'

    def RunPreflight(self, validation: dict | str | None, *, requireTrigger: bool = False, validationExitCode: int = 0,
                     recoveryImage: str = RECOVERY_IMAGE, extraEnv: dict | None = None) -> subprocess.CompletedProcess:
        env = {key: value for key, value in os.environ.items() if not key.startswith('BSOD_')}
        env.update({
            'PATH': f'{self.bin}:{os.environ["PATH"]}', 'REAL_PYTHON': sys.executable, 'FIXTURE_DIR': str(FIXTURE_DIR),
            'AGENT_LOG': str(self.logs['agent']), 'OC_LOG': str(self.logs['oc']), 'DOWNLOAD_LOG': str(self.logs['download']),
            'BSOD_DET__GUEST_AGENT__BIN': str(self.bin / 'guest-agent'), 'STUB_VALIDATION_RC': str(validationExitCode),
            'STUB_VALIDATION': validation if isinstance(validation, str) else json.dumps(validation),
            'TMPDIR': str(self.tmp),
        })
        env.update(extraEnv or {})
        command = ['bash', str(self.app / PREFLIGHT_REL), '--ns', 'fixture-ns', '--vm', 'fixture-vm',
                   '--out', str(self.evidence / RUN_ID), '--metadata', str(self.metadata), '--run-id', RUN_ID,
                   '--evidence-mount', str(self.evidence), '--evidence-volume-kind', 'pvc',
                   '--evidence-storage-id', 'fixture-evidence-pvc', '--snap-class', 'fixture-snapshot-class',
                   '--recovery-image', recoveryImage, '--memory-dump-pvc', 'fixture-memory']
        if requireTrigger:
            command.append('--require-trigger')
        return subprocess.run(command, env=env, capture_output=True, text=True, timeout=180, check=False)

    def AgentCalls(self) -> list[list[str]]:
        return [json.loads(line) for line in self.logs['agent'].read_text(encoding='utf-8').splitlines()]

    def PsfileCalls(self) -> list[list[str]]:
        return [call for call in self.AgentCalls() if call[0] == 'psfile']

    def AssertNoGuestChangesOrDownloads(self) -> None:
        """Only ping, psfile (validator) and read-only exec calls; no upload of other files, installer or reboot."""
        for call in self.AgentCalls():
            self.assertIn(call[0], ('ping', 'psfile', 'exec'), call)
            text = ' '.join(call)
            for forbidden in ('msiexec', '.msi', 'Restart-Computer', 'Set-ItemProperty', 'Remove-Item', 'Minidump', 'configure-dumps'):
                self.assertNotIn(forbidden, text)
        for call in self.PsfileCalls():
            self.assertEqual(Path(call[1]).name, 'validate-crash-settings.ps1')
        self.assertEqual(self.logs['download'].read_text(encoding='utf-8'), '')

    def AssertStopped(self, result: subprocess.CompletedProcess, message: str) -> None:
        self.assertEqual(result.returncode, 1, result.stderr[-3000:])
        self.assertIn(message, result.stderr)
        self.assertFalse(self.metadata.exists())

    def test_Preflight_AcceptsTheRealValidatorResultAndNeverStagesInNormalMode(self) -> None:
        result = self.RunPreflight(self.Golden())
        self.assertEqual(result.returncode, 0, result.stderr[-3000:])
        psfileCalls = self.PsfileCalls()
        self.assertEqual(len(psfileCalls), 1)
        self.assertEqual(psfileCalls[0][1], str(self.app / 'src' / 'scripts' / 'guest' / 'validate-crash-settings.ps1'))
        self.assertEqual(psfileCalls[0][2:], ['--companion', str(self.app / 'src' / 'data' / 'crash-control.json'), GUEST_DATA_FILE,
                                              '--', '-dataFile', GUEST_DATA_FILE])
        self.AssertNoGuestChangesOrDownloads()
        metadata = json.loads(self.metadata.read_text(encoding='utf-8'))
        self.assertIsNone(metadata['artifacts']['notMyFault'])
        self.assertEqual(metadata['preCrashInventory'], [])
        self.assertEqual((metadata['recoveryImage'], metadata['recoveryImageContract']), (RECOVERY_IMAGE, 'bash+guestfish-v1'))
        self.assertEqual((metadata['guestPvc'], metadata['diskTarget'], metadata['memoryDumpPvc']), ('fixture-rootdisk', 'vda', 'fixture-memory'))
        self.assertIn('apply -f -', self.logs['oc'].read_text(encoding='utf-8'))  # the recovery-image probe still runs

    def test_Preflight_ForwardsStageNotMyFaultOnlyWithRequireTriggerAndRecordsTheStagedRecord(self) -> None:
        validation = self.Golden()
        validation['notMyFault'] = dict(STAGED_RECORD)
        result = self.RunPreflight(validation, requireTrigger=True)
        self.assertEqual(result.returncode, 0, result.stderr[-3000:])
        self.assertEqual(self.PsfileCalls()[0][-3:], ['-dataFile', GUEST_DATA_FILE, '-stageNotMyFault'])
        self.AssertNoGuestChangesOrDownloads()
        record = json.loads(self.metadata.read_text(encoding='utf-8'))['artifacts']['notMyFault']
        self.assertEqual((record['status'], record['sha256'], record['archiveSHA256'], record['stagedPath']),
                         ('staged', 'b' * 64, 'a' * 64, Utils.NMF_PATH))

    def test_Preflight_StopsOnTheRealMismatchResultWithoutChangingAnything(self) -> None:
        exitCode, validation = self.RealResult('mismatch', {'dataFile': 'DATA_FILE'})
        self.assertEqual(exitCode, 0)
        result = self.RunPreflight(validation)
        self.AssertStopped(result, 'guest crash settings do not match the golden image (nothing was changed')
        self.assertIn('AutoReboot', result.stderr)
        self.AssertNoGuestChangesOrDownloads()

    def test_Preflight_StopsOnTheRealStagingFailureAndPrintsTheResult(self) -> None:
        exitCode, validation = self.RealResult('mismatch', {'dataFile': 'DATA_FILE', 'stageNotMyFault': True})
        self.assertEqual(exitCode, 4)
        result = self.RunPreflight(validation, requireTrigger=True, validationExitCode=4)
        self.AssertStopped(result, 'guest crash-setting validation failed: ')
        self.assertIn('NotMyFault could not be staged', result.stderr)
        self.AssertNoGuestChangesOrDownloads()

    def test_Preflight_RejectsResultsThatAreNotATypedMatchingValidatorResult(self) -> None:
        golden = self.Golden()
        def Changed(path: tuple, value) -> dict:
            changed = copy.deepcopy(golden)
            target = changed
            for key in path[:-1]:
                target = target[key]
            if value is KeyError:
                del target[path[-1]]
            else:
                target[path[-1]] = value
            return changed
        cases = {
            'AutoReboot as a string': Changed(('current', 'AutoReboot'), '0'),
            'AutoReboot 1': Changed(('current', 'AutoReboot'), 1),
            'ok as a string': Changed(('ok',), 'true'),
            'ok false': Changed(('ok',), False),
            'page file not adequate': Changed(('pageFile', 'adequate'), False),
            'matchesRecommended missing': Changed(('matchesRecommended',), KeyError),
            'script missing': Changed(('script',), KeyError),
            'other action': Changed(('action',), 'applied'),
            'former configuration output': {'ok': True, 'matchesRecommended': True, 'current': {'AutoReboot': 0},
                                            'pageFile': {'adequate': True}, 'rebootRequired': False},
            'invalid JSON': 'not json',
            'empty output': '',
        }
        for name, validation in cases.items():
            with self.subTest(name):
                self.logs['agent'].write_text('', encoding='utf-8')
                result = self.RunPreflight(validation)
                self.AssertStopped(result, 'guest crash settings do not match the golden image')
                self.AssertNoGuestChangesOrDownloads()

    def test_Preflight_DoesNotDependOnRebootRequired(self) -> None:
        validation = self.Golden()
        validation['rebootRequired'] = True
        result = self.RunPreflight(validation)
        self.assertEqual(result.returncode, 0, result.stderr[-3000:])
        self.assertTrue(self.metadata.exists())
        self.assertNotIn('rebootRequired', (self.app / PREFLIGHT_REL).read_text(encoding='utf-8'))

    def test_Preflight_TriggerRunRejectsMissingOrIncompleteStagedRecords(self) -> None:
        cases = {
            'not requested': {'status': 'not requested'},
            'plain HTTP source': dict(STAGED_RECORD, resolvedSource='http://download.sysinternals.com/files/NotMyFault.zip'),
            'other host': dict(STAGED_RECORD, resolvedSource='https://example.com/NotMyFault.zip'),
            'missing executable hash': dict(STAGED_RECORD, sha256=None),
            'other staging path': dict(STAGED_RECORD, stagedPath='C:\\Users\\Public\\notmyfaultc64.exe'),
        }
        for name, record in cases.items():
            with self.subTest(name):
                validation = self.Golden()
                validation['notMyFault'] = record
                result = self.RunPreflight(validation, requireTrigger=True)
                self.AssertStopped(result, 'the latest NotMyFault was not staged')
                self.AssertNoGuestChangesOrDownloads()

    def test_Preflight_StopsWithAGoldenImageMessageWhenTheGuestAgentDoesNotAnswer(self) -> None:
        result = self.RunPreflight(self.Golden(), extraEnv={'STUB_PING_FAIL': '1'})
        self.AssertStopped(result, 'the VM must run a golden image with the QEMU-GA service installed and running')
        self.assertEqual({call[0] for call in self.AgentCalls()}, {'ping'})  # no upload, installer or validator run
        self.AssertNoGuestChangesOrDownloads()

    def test_Preflight_StopsWhenTheValidatorCannotRunInTheGuest(self) -> None:
        result = self.RunPreflight(self.Golden(), extraEnv={'STUB_PSFILE_FAIL': '1'})
        self.AssertStopped(result, 'guest crash-setting validation failed')

    def test_Preflight_StillRequiresEveryListedHelperAndADigestPinnedRecoveryImage(self) -> None:
        (self.app / 'src' / 'scripts' / 'host' / 'collect-host-signals.sh').unlink()
        self.AssertStopped(self.RunPreflight(self.Golden()), 'required helper missing')
        self.assertEqual(self.AgentCalls(), [])
        shutil.copy2(Utils.HOST_DIR / 'collect-host-signals.sh', self.app / 'src' / 'scripts' / 'host' / 'collect-host-signals.sh')
        self.AssertStopped(self.RunPreflight(self.Golden(), recoveryImage='registry.test/recovery:latest'), 'recovery image must be digest-pinned')
        self.assertEqual(self.AgentCalls(), [])

    def test_Preflight_DeprecatedAliasMustNameTheValidator(self) -> None:
        guestDir = self.app / 'src' / 'scripts' / 'guest'
        former = guestDir / 'configure-dumps.ps1'
        shutil.copy2(guestDir / 'validate-crash-settings.ps1', former)
        result = self.RunPreflight(self.Golden(), extraEnv={'BSOD_DET__CONFIGURE__DUMPS': str(former)})
        self.AssertStopped(result, 'the guest validator must be validate-crash-settings.ps1')
        self.assertEqual(self.AgentCalls(), [])
        aliasCopy = self.tmp / 'ci' / 'validate-crash-settings.ps1'
        aliasCopy.parent.mkdir()
        shutil.copy2(guestDir / 'validate-crash-settings.ps1', aliasCopy)
        result = self.RunPreflight(self.Golden(), extraEnv={'BSOD_DET__CONFIGURE__DUMPS': str(aliasCopy)})
        self.assertEqual(result.returncode, 0, result.stderr[-3000:])
        self.assertIn('BSOD_DET__CONFIGURE__DUMPS is deprecated', result.stderr)
        self.assertEqual(self.PsfileCalls()[0][1], str(aliasCopy))


if __name__ == '__main__':
    unittest.main()
