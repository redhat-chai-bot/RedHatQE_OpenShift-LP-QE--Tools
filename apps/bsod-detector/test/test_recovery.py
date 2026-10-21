#!/usr/bin/env python3
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest


hostDir = Path(__file__).resolve().parents[1] / 'src/scripts/host'
recovery = hostDir / 'recover-natural-crash.sh'

mockOC = r'''
import json, os, signal, sys, time
from pathlib import Path
root = Path(os.environ['MOCK_ROOT'])
args = sys.argv[1:]
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
        if scenario == 'exec-timeout':
            time.sleep(5)
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
                        MOCK_ROOT=str(self.root), BSOD_DET__COMMAND__TIMEOUT='0.3',
                        BSOD_DET__GUESTFS__NTFS_IMAGE='registry.test/guestfs:fixture')

    def RunRecovery(self, scenario='', *args):
        self.meta.write_text(json.dumps(self.metadata))
        return subprocess.run([str(recovery), *(args or ('--metadata', str(self.meta), '--out', str(self.out)))],
                              env=dict(self.env, SCENARIO=scenario), text=True, capture_output=True, timeout=10)

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
        for scenario in ('wait-error', 'no-guestfish', 'discovery-error', 'exec-timeout', 'copy-error',
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
        for scenario in ('api-error', 'bad-json', 'attached-pvc', 'attached-dv', 'stale', 'mount', 'image'):
            with self.subTest(scenario=scenario):
                case = RecoveryTests('test_success_contract')
                case.setUp()
                self.addCleanup(case.doCleanups)
                if scenario == 'stale':
                    (case.out / 'events.json').write_text('stale')
                if scenario == 'mount':
                    case.marker.unlink()
                    case.metadata['evidenceMount']['source'] = 'other:/mount'
                if scenario == 'image':
                    case.metadata['recoveryImage'] = 'registry.test/unpinned'
                result = case.RunRecovery(scenario)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertFalse(any(call[0] == 'apply' for call in case.Calls()))

    def test_native_mount_contract(self):
        self.marker.unlink()
        result = self.RunRecovery()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_signal_cleans_once(self):
        result = self.RunRecovery('signal')
        self.assertEqual(result.returncode, 143, result.stderr)
        self.AssertDeleted()
        self.assertIn('interrupted', (self.out / 'stage-errors.jsonl').read_text())

    def test_cli_statuses(self):
        for args, expected in ((('--help',), 0), (('--unknown',), 2), (('--out', str(self.out)), 2)):
            with self.subTest(args=args):
                self.assertEqual(self.RunRecovery('', *args).returncode, expected)
        self.assertFalse(self.Calls())


if __name__ == '__main__':
    unittest.main()
