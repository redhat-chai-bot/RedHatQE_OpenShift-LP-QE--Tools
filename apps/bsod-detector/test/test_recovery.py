#!/usr/bin/env python3
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest


hostDir = Path(__file__).resolve().parents[1] / 'src/scripts/host'
recovery = hostDir / 'extract--guest-os--crash-info.sh'

mockOC = r'''
import json, os, signal, sys, time
from pathlib import Path
root = Path(os.environ['MOCK_ROOT'])
args = sys.argv[1:]
with (root / 'oc-argv.jsonl').open('a') as calls:
    calls.write(json.dumps(args) + '\n')
if args[0].startswith('--request-timeout='):
    args.pop(0)
with (root / 'calls.jsonl').open('a') as calls:
    calls.write(json.dumps(args) + '\n')
scenario = os.environ.get('SCENARIO', '')
if args[0] == 'get':
    if args[1] == 'vmi':
        if scenario == 'api-error':
            print('mock API unavailable', file=sys.stderr)
            sys.exit(17)
        if scenario == 'bad-json':
            print('{')
        elif scenario in ('attached-pvc', 'attached-dv'):
            volume = {'persistentVolumeClaim': {'claimName': 'rootdisk'}}
            if scenario == 'attached-dv':
                volume = {'dataVolume': {'name': 'rootdisk'}}
            print(json.dumps({'items': [{'metadata': {'name': 'fixture-vmi'},
                  'status': {'phase': 'Running'}, 'spec': {'volumes': [volume]}}]}))
        else:
            print('{"items":[]}')
    elif args[1] == 'pod':
        print('Running')
    else:
        sys.exit(91)
elif args[0] == 'apply':
    (root / 'pod.json').write_text(sys.stdin.read())
    if scenario == 'apply-error':
        sys.exit(18)
elif args[0] == 'wait':
    if scenario == 'signal':
        os.kill(os.getppid(), signal.SIGTERM)
        time.sleep(0.1)
    if scenario == 'wait-error':
        print('mock startup timeout', file=sys.stderr)
        sys.exit(19)
elif args[0] == 'exec':
    command = args[args.index('--') + 1:]
    if command[0] == 'guestfish':
        if scenario == 'exec-error':
            print('mock guestfish exec failure', file=sys.stderr)
            sys.exit(27)
        if scenario == 'no-guestfish':
            print('mock guestfish unavailable', file=sys.stderr)
            sys.exit(20)
        if 'list-filesystems' in command:
            probe = root / 'probe-done'
            if scenario == 'discovery-error' and probe.exists():
                print('mock discovery failure', file=sys.stderr)
                sys.exit(26)
            probe.touch()
            if scenario != 'no-ntfs':
                print('/dev/sda1: vfat\n/dev/sda2: ntfs\n/dev/sda3: ntfs\n/dev/sda4: ntfs')
        else:
            part = command[command.index('mount-ro') + 1]
            if part != '/dev/sda3':
                sys.exit(21)
            for index, arg in enumerate(command):
                if arg == 'download':
                    src, dest = command[index + 1:index + 3]
                    if scenario == 'partial-batch' and src.endswith('Application.evtx'):
                        sys.exit(22)
                    (root / Path(dest).name).write_bytes((root / 'fixture.evtx').read_bytes())
    elif command[:2] == ['rm', '-f']:
        (root / Path(command[2]).name).unlink(missing_ok=True)
    else:
        sys.exit(92)
elif args[0] == 'cp':
    src = root / Path(args[1].split(':', 1)[1]).name
    dest = Path(args[2])
    if scenario == 'copy-error':
        dest.write_bytes(b'partial')
        sys.exit(23)
    if not src.exists():
        print('mock missing guest file', file=sys.stderr)
        sys.exit(24)
    dest.write_bytes(b'' if scenario == 'empty-copy' else src.read_bytes())
elif args[0] == 'delete':
    if scenario == 'cleanup-error':
        print('mock delete failure', file=sys.stderr)
        sys.exit(25)
else:
    sys.exit(93)
'''


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='recovery test ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.out = self.root / 'run-001'
        self.out.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        mock = self.bin / 'oc'
        mock.write_text(f'#!{sys.executable}\n' + mockOC)
        mock.chmod(0o755)
        mountMock = self.bin / 'findmnt'
        mountMock.write_text(f'#!{sys.executable}\nimport json, os\n'
                            'print(json.dumps({"filesystems": [{"target": os.environ["MOCK_ROOT"], '
                            '"source": "server:/evidence", "fstype": "xfs", "maj:min": "0:99"}]}))\n')
        mountMock.chmod(0o755)
        self.metadata = {
            'schema': 2, 'runId': self.out.name, 'outputDir': str(self.out),
            'namespace': 'fixture-ns', 'vm': 'fixture-vm', 'guestPvc': 'rootdisk',
            'snapshotClass': 'snapshot', 'storageClass': 'storage', 'storageSize': '32Gi',
            'volumeMode': 'Block', 'recoveryImage': 'registry.test/recovery@sha256:' + 'a' * 64,
            'recoveryImageContract': 'bash+guestfish-v1', 'armedEpoch': 100, 'preCrashInventory': [],
            'evidenceMount': {'target': str(self.root), 'source': 'server:/evidence',
                              'fsType': 'xfs', 'device': '0:99', 'kind': 'pvc', 'id': 'evidence'},
        }
        self.meta = self.root / 'metadata.json'
        self.marker = self.root / '.bsod-storage-identity'
        self.marker.write_text('evidence\n')
        evtx = bytearray(4096)
        evtx[:8] = b'ElfFile\x00'
        struct.pack_into('<I', evtx, 0x78, len(evtx))
        (self.root / 'fixture.evtx').write_bytes(evtx)
        memory = bytearray(124)
        memory[:16] = b'\x7fELF\x02\x01\x01' + bytes(9)
        struct.pack_into('<H', memory, 0x10, 4)
        struct.pack_into('<Q', memory, 0x20, 64)
        struct.pack_into('<H', memory, 0x34, 64)
        struct.pack_into('<HH', memory, 0x36, 56, 1)
        struct.pack_into('<IIQ', memory, 64, 1, 0, 120)
        struct.pack_into('<Q', memory, 96, 4)
        memory[120:] = b'CORE'
        (self.out / 'vm-memory.elf').write_bytes(memory)
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                        MOCK_ROOT=str(self.root),
                        BSOD_DET__GUESTFS__NTFS_IMAGE='registry.test/guestfs:fixture')

    def RunRecovery(self, scenario='', *args, script=recovery, cwd=None):
        self.meta.write_text(json.dumps(self.metadata))
        return subprocess.run([str(script), *(args or ('--metadata', str(self.meta)))],
                              cwd=cwd, env=dict(self.env, SCENARIO=scenario), text=True, capture_output=True, timeout=10)

    def Calls(self):
        path = self.root / 'calls.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def AssertDeleted(self):
        deletes = [call for call in self.Calls() if call[0] == 'delete']
        self.assertEqual(len(deletes), 1)
        self.assertIn('--timeout=60s', deletes[0])

    def test_success_contract(self):
        result = self.RunRecovery()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.AssertDeleted()
        self.assertFalse(list(self.root.glob('bsod-evtx-*')))
        pod = json.loads((self.root / 'pod.json').read_text())
        spec = pod['spec']
        self.assertFalse(spec['automountServiceAccountToken'])
        self.assertTrue(spec['volumes'][0]['persistentVolumeClaim']['readOnly'])
        self.assertTrue(spec['securityContext']['runAsNonRoot'])
        container = spec['containers'][0]
        self.assertEqual(container['image'], self.env['BSOD_DET__GUESTFS__NTFS_IMAGE'])
        self.assertFalse(container['securityContext']['allowPrivilegeEscalation'])
        self.assertIn('inherit_errexit', container['command'][2])
        self.assertIn('set -euxo pipefail', container['command'][2])
        batches = [call for call in self.Calls() if 'mount-ro' in call]
        self.assertEqual(len(batches), 2)
        self.assertTrue(all('--ro' in call for call in batches))
        self.assertTrue(all(call.count('download') == 2 for call in batches))
        self.assertEqual(batches[-1][batches[-1].index('mount-ro') + 1], '/dev/sda3')
        logs = list(self.out.glob('guestFS_sda3/**/*.evtx'))
        self.assertEqual(len(logs), 2)
        for path in logs + [self.out / 'events.json', self.out / 'checksums.sha256']:
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads((self.out / 'events.json').read_text())['events'], [])
        summary = json.loads((self.out / 'extraction-summary.json').read_text())
        self.assertTrue(summary['ok'], summary)
        check = subprocess.run(['sha256sum', '-c', 'checksums.sha256'], cwd=self.out,
                               text=True, capture_output=True, timeout=5)
        self.assertEqual(check.returncode, 0, check.stderr)

    def test_partial_batch_keeps_system_log(self):
        result = self.RunRecovery('partial-batch')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(list(self.out.glob('guestFS_sda3/**/*.evtx'))), 1)
        self.AssertDeleted()

    def test_direct_oc_preserves_only_scoped_deadlines(self):
        realTimeout = shutil.which('timeout', path=os.environ['PATH'])
        self.assertIsNotNone(realTimeout)
        timeoutMock = self.bin / 'timeout'
        timeoutMock.write_text(f'#!{sys.executable}\nimport json, os, sys\n'
                              'from pathlib import Path\n'
                              'with (Path(os.environ["MOCK_ROOT"]) / "timeouts.jsonl").open("a") as calls:\n'
                              '    calls.write(json.dumps(sys.argv[1:]) + "\\n")\n'
                              f'os.execv({realTimeout!r}, [{realTimeout!r}, *sys.argv[1:]])\n')
        timeoutMock.chmod(0o755)
        self.env['BSOD_DET__COMMAND__TIMEOUT'] = 'not-a-timeout'
        result = self.RunRecovery()
        self.assertEqual(result.returncode, 0, result.stderr)
        rawCalls = [json.loads(line) for line in (self.root / 'oc-argv.jsonl').read_text().splitlines()]
        requests = [call for call in rawCalls if call[0].startswith('--request-timeout=')]
        self.assertEqual(len(requests), 2)
        wait, delete = requests
        self.assertEqual(wait[:2], ['--request-timeout=185s', 'wait'])
        self.assertIn('--timeout=180s', wait)
        self.assertEqual(delete[:2], ['--request-timeout=65s', 'delete'])
        self.assertIn('--timeout=60s', delete)
        self.assertTrue(all(call[0] in ('get', 'apply', 'exec', 'cp') for call in rawCalls if call not in requests))
        deadlines = [json.loads(line) for line in (self.root / 'timeouts.jsonl').read_text().splitlines()]
        self.assertEqual(len(deadlines), 2)
        self.assertEqual(deadlines[0][:5], ['--signal=TERM', '--kill-after=5', '70', 'oc', '--request-timeout=65s'])
        self.assertEqual(deadlines[1][:4], ['--signal=TERM', '--kill-after=5', '60', 'python3'])
        source = recovery.read_text()
        self.assertNotRegex(source, r'\bOc\b')
        self.assertNotIn('cmdTimeout', source)
        self.assertNotIn('BSOD_DET__COMMAND__TIMEOUT', source)
        self.AssertDeleted()

    def test_all_die_messages_have_consistent_grammar(self):
        source = recovery.read_text()
        messages = re.findall(r'\bDie ([\'"])(.*?)\1', source)
        self.assertEqual(len(messages), 10)
        self.assertEqual(len(re.findall(r'\bDie\b', source)), len(messages) + 1)
        for quote, message in messages:
            with self.subTest(message=message):
                self.assertTrue(message[0].isupper())
                if ': ' not in message:
                    self.assertTrue(message.endswith('.'))
        self.assertIn(('"', 'Required tool missing: ${tool}'), messages)
        self.assertIn(("'", 'Metadata lacks a non-empty guest PVC.'), messages)

    def test_relative_host_path_resolves_helpers(self):
        result = self.RunRecovery(script=f'./{recovery.name}', cwd=hostDir)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads((self.out / 'extraction-summary.json').read_text())['ok'])
        self.AssertDeleted()

    def test_metadata_only_output_contract(self):
        source = recovery.read_text()
        self.assertNotIn('--out', source[:source.index('function Die')])
        self.assertNotIn('expectedOut', source)
        self.assertNotIn('realpath', source)
        self.assertNotIn('${outDir##*/}', source)
        self.assertNotIn('[ ! -L "${outDir}" ]', source)
        for removed in ('evidenceMount', 'storageId', 'marker', 'findmnt', 'recoveryImage',
                        'snapshotClass', 'storageClass', 'storageSize', 'volumeMode',
                        'armedEpoch', 'preCrashInventory'):
            self.assertNotIn(removed, source)
        result = self.RunRecovery()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.out / 'checksums.sha256').is_file())
        self.AssertDeleted()

    def test_metadata_output_spelling_and_independent_run_id(self):
        for pathKind in ('parent-alias', 'leaf-alias', 'relative-alias', 'arbitrary-directory'):
            with self.subTest(pathKind=pathKind):
                case = RecoveryTests('test_success_contract')
                case.setUp()
                self.addCleanup(case.doCleanups)
                alias = case.root / 'different alias'
                if pathKind == 'arbitrary-directory':
                    case.out = case.out.rename(case.root / 'arbitrary capture directory')
                    providedOut = str(case.out)
                else:
                    alias.symlink_to(case.root if pathKind == 'parent-alias' else case.out, target_is_directory=True)
                    providedOut = (str(alias / case.out.name) if pathKind == 'parent-alias' else
                                   './different alias' if pathKind == 'relative-alias' else str(alias) + '/.')
                case.metadata['outputDir'] = providedOut
                case.metadata['runId'] = 'summary-run-id'
                pythonMock = case.bin / 'python3'
                pythonMock.write_text(f'#!{sys.executable}\nimport json, os, sys\n'
                                      'from pathlib import Path\n'
                                      'with (Path(os.environ["MOCK_ROOT"]) / "python-argv.jsonl").open("a") as calls:\n'
                                      '    calls.write(json.dumps(sys.argv[1:]) + "\\n")\n'
                                      f'os.execv({sys.executable!r}, [{sys.executable!r}, *sys.argv[1:]])\n')
                pythonMock.chmod(0o755)
                result = case.RunRecovery(cwd=case.root)
                self.assertEqual(result.returncode, 0, result.stderr)
                summary = json.loads((case.out / 'extraction-summary.json').read_text())
                self.assertTrue(summary['ok'])
                self.assertEqual(summary['runId'], 'summary-run-id')
                self.assertTrue((case.out / 'checksums.sha256').is_file())
                copies = [call for call in case.Calls() if call[0] == 'cp']
                self.assertTrue(copies)
                self.assertTrue(all(call[2].startswith(providedOut + '/guestFS_') for call in copies))
                pythonCalls = [json.loads(line) for line in (case.root / 'python-argv.jsonl').read_text().splitlines()]
                summaryCall, = [call for call in pythonCalls if 'write-summary' in call]
                self.assertEqual(summaryCall[summaryCall.index('--out') + 1], providedOut)
                case.AssertDeleted()

    def test_directory_alias_stale_outputs_rejected_before_writes(self):
        for staleName in ('MEMORY.DMP', 'Minidump', 'guestFS_sda3', 'events.json',
                          'extraction-summary.json', 'checksums.sha256'):
            with self.subTest(staleName=staleName):
                case = RecoveryTests('test_success_contract')
                case.setUp()
                self.addCleanup(case.doCleanups)
                alias = case.root / 'directory alias'
                alias.symlink_to(case.out, target_is_directory=True)
                case.metadata['outputDir'] = str(alias)
                stale = case.out / staleName
                stale.mkdir() if staleName in ('Minidump', 'guestFS_sda3') else stale.write_text('preserve-stale')
                before = sorted(path.name for path in case.out.iterdir())
                result = case.RunRecovery()
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn('Pre-existing extraction artifact rejected:', result.stderr)
                self.assertFalse(case.Calls())
                self.assertEqual(sorted(path.name for path in case.out.iterdir()), before)
                if stale.is_file():
                    self.assertEqual(stale.read_text(), 'preserve-stale')
                self.assertFalse((case.out / 'extraction.log').exists())

    def test_stale_scan_does_not_follow_descendant_directory_alias(self):
        external = self.root / 'external'
        external.mkdir()
        (external / 'events.json').write_text('external-stale')
        (self.out / 'nested alias').symlink_to(external, target_is_directory=True)
        result = self.RunRecovery('api-error')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('Cannot list VMIs', result.stderr)
        self.assertNotIn('Pre-existing extraction artifact rejected:', result.stderr)
        self.assertEqual([call[0] for call in self.Calls()], ['get'])
        self.assertEqual((external / 'events.json').read_text(), 'external-stale')

    def test_invalid_metadata_output_rejected_before_oc_or_writes(self):
        for scenario in ('missing', 'null', 'empty', 'non-string', 'missing-target', 'file'):
            with self.subTest(scenario=scenario):
                case = RecoveryTests('test_success_contract')
                case.setUp()
                self.addCleanup(case.doCleanups)
                if scenario == 'missing':
                    del case.metadata['outputDir']
                elif scenario in ('null', 'empty', 'non-string'):
                    case.metadata['outputDir'] = {'null': None, 'empty': '', 'non-string': 42}[scenario]
                elif scenario == 'missing-target':
                    case.metadata['outputDir'] = str(case.root / 'missing')
                elif scenario == 'file':
                    case.metadata['outputDir'] = str(case.root / 'fixture.evtx')
                before = {path.name: path.read_bytes() for path in case.out.iterdir()}
                result = case.RunRecovery()
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn('ERROR:', result.stderr)
                self.assertFalse(case.Calls())
                self.assertEqual({path.name: path.read_bytes() for path in case.out.iterdir()}, before)

    def test_obsolete_storage_and_image_policy_is_not_consulted(self):
        identity = self.root / 'identity'
        self.marker.rename(identity)
        self.marker.symlink_to(identity)
        self.metadata['evidenceMount']['source'] = 'other:/mount'
        self.metadata['evidenceMount']['kind'] = 'temporary'
        self.metadata['evidenceMount']['id'] = ''
        self.metadata['recoveryImage'] = 'unused-unpinned-image'
        self.metadata['recoveryImageContract'] = 'unused-contract'
        (self.bin / 'findmnt').write_text('#!/bin/sh\nexit 99\n')
        result = self.RunRecovery()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.AssertDeleted()

    def test_watcher_recovery_uses_metadata_only(self):
        watcher = (hostDir / 'watch-crash.sh').read_text()
        runTimed = re.search(r'^function RunTimed \(\) \{.*\}$', watcher, re.MULTILINE).group()
        recover = re.search(r'^function Recover \(\) \{\n.*?^\}', watcher, re.MULTILINE | re.DOTALL).group()
        self.meta.write_text(json.dumps(self.metadata))
        command = ('set -euxo pipefail; shopt -s inherit_errexit\n'
                   'typeset scriptDir="${1}" metadataFile="${2}" pipelineLog="${3}"\n'
                   + runTimed + '\n' + recover + '\nRecover\n')
        result = subprocess.run(['bash', '-c', command, 'watcher-fixture', str(hostDir),
                                 str(self.meta), str(self.root / 'pipeline.log')],
                                cwd=self.root, env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr + (self.root / 'pipeline.log').read_text())
        self.assertTrue(json.loads((self.out / 'extraction-summary.json').read_text())['ok'])
        self.assertNotIn('--out', recover)
        self.AssertDeleted()

    def test_relative_repository_path_resolves_helpers(self):
        repoRoot = Path(__file__).resolve().parents[3]
        result = self.RunRecovery(script=os.path.relpath(recovery, repoRoot), cwd=repoRoot)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads((self.out / 'extraction-summary.json').read_text())['ok'])
        self.AssertDeleted()

    def test_absolute_path_from_unrelated_directory_resolves_helpers(self):
        result = self.RunRecovery(cwd=self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads((self.out / 'extraction-summary.json').read_text())['ok'])
        self.AssertDeleted()

    def test_container_recover_dispatch(self):
        entrypoint = Path(__file__).resolve().parents[3] / 'image/container/bsod-detector/entrypoint.sh'
        self.meta.write_text(json.dumps(self.metadata))
        command = '''set -euxo pipefail; shopt -s inherit_errexit
function exec () {
    [ "$1" = "/usr/local/bin/${MOCK_EXTRACTOR_NAME}" ] || return 99
    shift
    command "${MOCK_EXTRACTOR}" "$@"
}
source "$1" "${@:2}"
'''
        result = subprocess.run(['bash', '-c', command, 'container-fixture', str(entrypoint),
                                 '--metadata', str(self.meta)], cwd=self.root,
                                env=dict(self.env, MODE='recover', EVIDENCE_DIR=str(self.root),
                                         MOCK_EXTRACTOR=str(recovery), MOCK_EXTRACTOR_NAME=recovery.name),
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads((self.out / 'extraction-summary.json').read_text())['ok'])
        self.AssertDeleted()

    def test_diagnostics_follow_invoked_name(self):
        alias = self.root / 'fixture-extractor.sh'
        alias.symlink_to(recovery)
        for args, expected, message in (
                (('--help',), 0, f'usage: {alias.name} '),
                (('--unknown',), 2, f'{alias.stem}: unknown argument:'),
                (('--metadata', str(self.root / 'missing.json')), 2, f'{alias.stem}: --metadata is required and must be readable')):
            with self.subTest(args=args):
                result = self.RunRecovery('', *args, script=alias)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertIn(message, result.stdout if expected == 0 else result.stderr)
        self.metadata['guestPvc'] = ''
        result = self.RunRecovery(script=alias)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f'{alias.stem}: ERROR:', result.stderr)
        self.assertFalse(self.Calls())

    def test_metadata_guard_rejects_missing_or_unreadable_inputs(self):
        for args in ((),
                     ('--metadata', str(self.root / 'missing.json'))):
            with self.subTest(args=args):
                result = (self.RunRecovery('', *args) if args else
                          subprocess.run([str(recovery)], env=self.env, text=True, capture_output=True, timeout=10))
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn('--metadata is required and must be readable', result.stderr)
        self.assertFalse(self.Calls())

    def test_preserves_watcher_parser(self):
        parser = self.out / 'parse-dump-header.json'
        content = '{"ok":true,"totalDumps":0,"dumps":[],"fixture":"watcher"}\n'
        parser.write_text(content)
        result = self.RunRecovery()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(parser.read_text(), content)

    def test_invalid_parser_fails_and_cleans(self):
        (self.out / 'parse-dump-header.json').write_text('{"ok":false}')
        result = self.RunRecovery()
        self.assertEqual(result.returncode, 1)
        self.AssertDeleted()
        self.assertIn('dump-parse', (self.out / 'stage-errors.jsonl').read_text())

    def test_failure_stages(self):
        for scenario in ('wait-error', 'no-guestfish', 'discovery-error', 'exec-error', 'copy-error',
                         'empty-copy', 'no-ntfs', 'cleanup-error'):
            with self.subTest(scenario=scenario):
                case = RecoveryTests('test_success_contract')
                case.setUp()
                self.addCleanup(case.doCleanups)
                result = case.RunRecovery(scenario)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                case.AssertDeleted()
                if scenario != 'cleanup-error':
                    self.assertFalse(list(case.out.glob('**/*.evtx')))

    def test_failed_apply_stops_before_extraction(self):
        result = self.RunRecovery('apply-error')
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[0] for call in self.Calls()], ['get', 'apply'])

    def test_unsafe_inputs_never_apply(self):
        for scenario in ('api-error', 'bad-json', 'attached-pvc', 'attached-dv', 'stale'):
            with self.subTest(scenario=scenario):
                case = RecoveryTests('test_success_contract')
                case.setUp()
                self.addCleanup(case.doCleanups)
                if scenario == 'stale':
                    (case.out / 'events.json').write_text('stale')
                result = case.RunRecovery(scenario)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertFalse(any(call[0] == 'apply' for call in case.Calls()))
                if scenario == 'api-error':
                    self.assertIn('Cannot list VMIs in namespace fixture-ns — API error prevents safe PVC attachment verification.', result.stderr)
                    self.assertIn('mock API unavailable', result.stderr)
                if scenario == 'bad-json':
                    self.assertIn('Cannot parse VMI list — PVC attachment state uncertain.', result.stderr)

    def test_only_consumed_metadata_fields_are_required(self):
        self.metadata = {key: self.metadata[key] for key in
                         ('runId', 'outputDir', 'namespace', 'vm', 'guestPvc')}
        self.marker.unlink()
        (self.bin / 'findmnt').unlink()
        result = self.RunRecovery()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.AssertDeleted()

    def test_malformed_required_fields_fail_before_mutation(self):
        for field, label in (('runId', 'run ID'), ('namespace', 'namespace'),
                             ('vm', 'VM name'), ('guestPvc', 'guest PVC')):
            for value in ('missing', None, '', 42, [], {}):
                with self.subTest(field=field, value=value):
                    case = RecoveryTests('test_success_contract')
                    case.setUp()
                    self.addCleanup(case.doCleanups)
                    if value == 'missing':
                        del case.metadata[field]
                    else:
                        case.metadata[field] = value
                    before = {path.name: path.read_bytes() for path in case.out.iterdir()}
                    result = case.RunRecovery()
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn(f'Metadata lacks a non-empty {label}.', result.stderr)
                    self.assertFalse(case.Calls())
                    self.assertEqual({path.name: path.read_bytes() for path in case.out.iterdir()}, before)

    def test_signal_cleans_once(self):
        result = self.RunRecovery('signal')
        self.assertEqual(result.returncode, 143, result.stderr)
        self.AssertDeleted()
        self.assertIn('interrupted', (self.out / 'stage-errors.jsonl').read_text())

    def test_cli_statuses(self):
        for args, expected in ((('--help',), 0), (('--unknown',), 2), (('--out', str(self.out)), 2)):
            with self.subTest(args=args):
                result = self.RunRecovery('', *args)
                self.assertEqual(result.returncode, expected)
                if args == ('--help',):
                    self.assertIn('usage: extract--guest-os--crash-info.sh ', result.stdout)
        self.assertFalse(self.Calls())


if __name__ == '__main__':
    unittest.main()
