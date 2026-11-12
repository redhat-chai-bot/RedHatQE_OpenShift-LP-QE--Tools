#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import tarfile
import unittest
import zlib


hostDir = Path(__file__).resolve().parents[1] / 'src/scripts/host'
recovery = hostDir / 'extract--guest-os--crash-info.sh'
dfltImg = 'quay.io/kubevirt/libguestfs-tools:20261112_5c3989e66e'

mockOC = r'''
import json, os, signal, subprocess, sys, time
from pathlib import Path
root = Path(os.environ['MOCK_ROOT'])
args = sys.argv[1:]
with (root / 'oc-argv.jsonl').open('a') as calls:
    calls.write(json.dumps(args) + '\n')
if args[0].startswith('--request-timeout='):
    args.pop(0)
if args[:1] == ['-n']:
    namespace = args[1]
    if args[2] == 'get' and args[3].startswith('vm/'):
        args = ['get', 'vm', args[3].removeprefix('vm/'), '-n', namespace, *args[4:]]
    else:
        args = [args[2], '-n', namespace, *args[3:]]
with (root / 'calls.jsonl').open('a') as calls:
    calls.write(json.dumps(args) + '\n')
with (root / 'lifecycle.jsonl').open('a') as events:
    events.write(json.dumps(['oc', *args]) + '\n')
scenario = os.environ.get('SCENARIO', '')
if args[0] == 'get':
    if args[1] == 'vm':
        if scenario == 'api-error':
            print('mock API unavailable', file=sys.stderr)
            sys.exit(17)
        if scenario == 'bad-json':
            print('{')
        elif scenario == 'vm-missing':
            print('mock VM not found', file=sys.stderr)
            sys.exit(1)
        elif scenario == 'vm-status-missing':
            print('{"spec":{"running":false},"status":{"ready":false}}')
        elif scenario == 'vm-status-null':
            print('{"status":{"printableStatus":null}}')
        elif scenario == 'vm-empty':
            pass
        elif scenario == 'vm-multiple':
            print('{"status":{"printableStatus":"Stopped"}}\n{"status":{"printableStatus":"Stopped"}}')
        elif scenario == 'vm-status-bool':
            print('{"status":{"printableStatus":true}}')
        elif scenario.startswith('vm-status-'):
            status = scenario.removeprefix('vm-status-')
            print(json.dumps({'spec': {'running': False}, 'status': {'ready': False, 'printableStatus': status}}))
        elif scenario == 'vm-api-partial':
            print('{"status":{"printableStatus":"Stopped"}}')
            print('mock VM API unavailable', file=sys.stderr)
            sys.exit(17)
        else:
            print('{"status":{"printableStatus":"Stopped"}}')
    elif args[3].startswith('pod/'):
        if (root / 'helper-pod').exists():
            print(args[3])
    else:
        sys.exit(91)
elif args[0] == 'wait':
    if '--for=delete' in args:
        if scenario == 'helper-absent-client48':
            print('error: no matching resources found', file=sys.stderr)
            sys.exit(1)
        if scenario == 'transient-wait' and not (root / 'cleanup-attempted').exists():
            (root / 'cleanup-attempted').touch()
            print('mock transient deletion wait failure', file=sys.stderr)
            sys.exit(28)
        if scenario in ('cleanup-wait-error', 'cleanup-wait-timeout'):
            print('mock deletion wait failed: ' + scenario, file=sys.stderr)
            sys.exit(28)
        if (root / 'helper-pod').exists():
            print('mock helper pod still exists', file=sys.stderr)
            sys.exit(29)
        sys.exit(0)
    if '--for=create' in args:
        # kubectl polls until the named Pod exists or the timeout ends. Test
        # speed shortcut: fail at once when virtctl exited without creating
        # it, instead of waiting out the real 60s timeout.
        deadline = time.monotonic() + 5
        while not (root / 'helper-pod').exists():
            if (scenario == 'create-timeout' or time.monotonic() > deadline
                    or (root / 'virtctl-exited').exists()):
                print('error: timed out waiting for the condition',
                      file=sys.stderr)
                sys.exit(1)
            time.sleep(0.05)
        sys.exit(0)
    if not (root / 'helper-pod').exists():
        print('Error from server (NotFound): mock helper pod', file=sys.stderr)
        sys.exit(1)
    if scenario in ('virtctl-attach-error', 'virtctl-foreign-race'):
        (root / 'ready-waited').touch()
        while not (root / 'virtctl-exited').exists():
            time.sleep(0.05)
        time.sleep(0.2)
    if scenario == 'signal-group':
        os.killpg(0, signal.SIGTERM)
        time.sleep(1)
    if scenario in ('signal', 'signal-int'):
        os.kill(os.getppid(), signal.SIGINT if scenario == 'signal-int' else signal.SIGTERM)
        time.sleep(0.1)
    if scenario in ('wait-error', 'virtctl-pending'):
        print('mock startup timeout', file=sys.stderr)
        sys.exit(19)
elif args[0] == 'exec':
    if not (root / 'helper-pod').exists():
        print('mock helper pod not found', file=sys.stderr)
        sys.exit(96)
    (root / 'exec-started').touch()
    command = args[args.index('--') + 1:]
    if command[0] == 'guestfish':
        if scenario == 'exec-error':
            print('mock guestfish exec failure', file=sys.stderr)
            sys.exit(27)
        if scenario == 'no-guestfish':
            print('mock guestfish unavailable', file=sys.stderr)
            sys.exit(20)
        if 'list-filesystems' in command:
            if scenario in ('discovery-error', 'discovery-partial-error'):
                if scenario == 'discovery-partial-error':
                    print('/dev/sda3: ntfs')
                print('mock discovery failure', file=sys.stderr)
                sys.exit(26)
            if scenario == 'no-ntfs':
                print('/dev/sda1: vfat\n/dev/sda2: ext4')
            elif scenario != 'empty-filesystems':
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
    elif command[0] == 'bash':
        helperEnv = dict(os.environ, PATH=str(root / 'helper-bin') + ':' + os.environ['PATH'])
        sys.exit(subprocess.run(command, env=helperEnv).returncode)
    elif command[:2] == ['test', '-d']:
        if scenario == 'helper-test-error':
            sys.exit(34)
        destination = root / 'helper-fs' / command[2].lstrip('/')
        sys.exit(0 if destination.is_dir() else 1)
    elif command[0] == 'tar':
        if scenario == 'tar-error':
            sys.stdout.buffer.write(b'partial archive')
            sys.exit(35)
        translated = list(command)
        index = translated.index('-C') + 1
        translated[index] = str(root / 'helper-fs' / translated[index].lstrip('/'))
        sys.exit(subprocess.run(translated).returncode)
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
    if os.environ.get('MOCK_DELETE_STATUS'):
        print('mock delete failure', file=sys.stderr)
        sys.exit(int(os.environ['MOCK_DELETE_STATUS']))
    if scenario == 'transient-delete' and not (root / 'cleanup-attempted').exists():
        (root / 'cleanup-attempted').touch()
        print('mock transient deletion failure', file=sys.stderr)
        sys.exit(25)
    if scenario == 'cleanup-error':
        print('mock delete failure', file=sys.stderr)
        sys.exit(25)
    if '--wait=true' in args and (root / 'helper-pod').exists():
        if scenario == 'transient-wait' and not (root / 'cleanup-attempted').exists():
            (root / 'cleanup-attempted').touch()
            print('mock transient blocking deletion failure', file=sys.stderr)
            sys.exit(28)
        if scenario in ('cleanup-wait-error', 'cleanup-wait-timeout'):
            print('mock blocking delete failed: ' + scenario, file=sys.stderr)
            sys.exit(28)
    (root / 'helper-pod').unlink(missing_ok=True)
else:
    sys.exit(93)
'''


mockVirtctl = r'''
import json, os, signal, stat, sys, time
from pathlib import Path
signal.alarm(30)
root = Path(os.environ['MOCK_ROOT'])
args = sys.argv[1:]
scenario = os.environ.get('SCENARIO', '')
pod = root / 'helper-pod'


def Log(event):
    with (root / 'lifecycle.jsonl').open('a') as events:
        events.write(json.dumps(['virtctl', event]) + '\n')


def OnTerm(signum, frame):
    Log('sigterm')
    Log('removePod')
    Log({'exit': 1})
    (root / 'virtctl-exited').touch()
    os._exit(1)


Log({'argv': args, 'pid': os.getpid(),
     'stdinFIFO': stat.S_ISFIFO(os.fstat(0).st_mode)})
print('Use image: ' + args[args.index('--image') + 1], flush=True)
status = 0
if scenario == 'virtctl-error':
    print('mock PVC is used by another pod', file=sys.stderr)
    status = 41
elif scenario == 'create-timeout':
    # A virtctl that never creates its Pod. Test speed shortcut: it ends on
    # stdin EOF, whereas upstream reads stdin only after it attaches.
    while os.read(0, 1024):
        pass
    Log('eof')
else:
    pod.write_text('foreign' if scenario == 'virtctl-foreign-race' else '')
    Log('created')
    signal.signal(signal.SIGTERM, OnTerm)
    if scenario in ('virtctl-attach-error', 'virtctl-foreign-race'):
        while not (root / 'ready-waited').exists():
            time.sleep(0.05)
        status = 42 if scenario == 'virtctl-attach-error' else 1
    elif scenario == 'virtctl-pending':
        while pod.exists():
            time.sleep(0.05)
        print('mock pod is not in running state', file=sys.stderr)
        status = 44
    elif scenario == 'virtctl-drop':
        while not (root / 'exec-started').exists():
            time.sleep(0.05)
    else:
        # virtctl attaches only after it observes the Pod Running.
        time.sleep(float(os.environ.get('VIRTCTL_ATTACH_DELAY', '0')))
        if not pod.exists():
            print('mock helper pod not found', file=sys.stderr)
            status = 46
        else:
            while os.read(0, 1024):
                pass
            Log('eof')
            status = int(os.environ.get('VIRTCTL_EOF_STATUS', '0'))
    if scenario != 'virtctl-foreign-race':
        # Deferred non-blocking delete: the Pod can linger while terminating.
        Log('removePod')
Log({'exit': status})
(root / 'virtctl-exited').touch()
sys.exit(status)
'''


helperMkdir = r'''
import json, os, sys
from pathlib import Path
root = Path(os.environ['MOCK_ROOT'])
with (root / 'helper-argv.jsonl').open('a') as calls:
    calls.write(json.dumps(['mkdir', *sys.argv[1:]]) + '\n')
if os.environ.get('SCENARIO') == 'mkdir-error':
    sys.exit(30)
assert sys.argv[1] == '-p'
for destination in sys.argv[2:]:
    (root / 'helper-fs' / destination.lstrip('/')).mkdir(parents=True, exist_ok=True)
'''


helperGuestfish = r'''
import json, os, sys
from pathlib import Path
root = Path(os.environ['MOCK_ROOT'])
args = sys.argv[1:]
with (root / 'helper-argv.jsonl').open('a') as calls:
    calls.write(json.dumps(['guestfish', *args]) + '\n')
assert args[:2] == ['-ra', '/dev/vda']
assert args[args.index('mount-ro') + 1] == '/dev/sda3'
index = args.index('copy-out')
source, destination = args[index + 1:index + 3]
assert source in ('/Windows/System32/winevt/Logs/System.evtx', '/Windows/System32/winevt/Logs/Application.evtx')
target = root / 'helper-fs' / destination.lstrip('/')
assert target.is_dir(), 'copy-out destination must exist in helper filesystem'
scenario = os.environ.get('SCENARIO', '')
if scenario == 'copy-error' or (scenario == 'system-missing' and source.endswith('System.evtx')) or (scenario == 'partial-batch' and source.endswith('Application.evtx')):
    sys.exit(22)
(target / Path(source).name).write_bytes((root / 'fixture.evtx').read_bytes())
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
        virtctl = self.bin / 'virtctl'
        virtctl.write_text(f'#!{sys.executable}\n' + mockVirtctl)
        virtctl.chmod(0o755)
        helperBin = self.root / 'helper-bin'
        helperBin.mkdir()
        (self.root / 'helper-fs').mkdir()
        for name, body in (('mkdir', helperMkdir), ('guestfish', helperGuestfish)):
            tool = helperBin / name
            tool.write_text(f'#!{sys.executable}\n' + body)
            tool.chmod(0o755)
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
                        BSOD_DET__GUEST_FS__CTR_IMG='registry.test/guestfs:fixture')

    def RunRecovery(self, scenario='', *args, script=recovery, cwd=None):
        self.meta.write_text(json.dumps(self.metadata))
        return subprocess.run([str(script), *(args or ('--metadata', str(self.meta)))],
                              cwd=cwd, env=dict(self.env, SCENARIO=scenario), text=True, capture_output=True, timeout=10)

    def Calls(self):
        path = self.root / 'calls.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def Lifecycle(self):
        path = self.root / 'lifecycle.jsonl'
        return ([json.loads(line) for line in path.read_text().splitlines()]
                if path.exists() else [])

    def VirtctlArgv(self):
        return [event[1]['argv'] for event in self.Lifecycle()
                if event[0] == 'virtctl' and 'argv' in event[1]]

    def AssertDeleted(self, waitCount=None, count=None):
        deletes = [call for call in self.Calls() if call[0] == 'delete']
        if count is None:
            count = 2 if (self.out / 'extraction-summary.json').exists() else 1
        self.assertEqual(len(deletes), count)
        for call in deletes:
            self.assertEqual(call[1:3], ['-n', self.metadata['namespace']])
            self.assertEqual(call[3], 'pod/libguestfs-tools-'
                             + self.metadata['guestPvc'])
            self.assertEqual(call[4:], ['--ignore-not-found', '--timeout=60s', '--wait=true'])
        waits = [call for call in self.Calls() if call[0] == 'wait' and '--for=delete' in call]
        self.assertEqual(len(waits), 0 if waitCount is None else waitCount)
        for call in waits:
            self.assertEqual(call[1:4], deletes[0][1:4])
            self.assertEqual(call[4:], ['--for=delete', '--timeout=60s'])

    def test_container_name_matches_executable_helper_calls(self):
        self.assertIn("helperPodCtr='libguestfs'", recovery.read_text())
        result = self.RunRecovery()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [call for call in self.Calls() if call[0] in ('exec', 'cp')]
        self.assertTrue(calls)
        for call in calls:
            self.assertEqual(call[call.index('-c') + 1], 'libguestfs')
        self.AssertDeleted()

    def test_image_environment_is_marshaled_literally_in_executable(self):
        image = 'registry.test/guestfs:"quote"\n$(touch injected) `touch injected` \\ end'
        self.env['BSOD_DET__GUEST_FS__CTR_IMG'] = image
        self.env['BSOD_DET__GUESTFS__NTFS_IMAGE'] = 'registry.test/legacy:ignored'
        result = self.RunRecovery(cwd=self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.VirtctlArgv(), [[
            '-n', 'fixture-ns', 'guestfs', '--vm', 'fixture-vm',
            '--image', image, 'rootdisk']])
        self.assertFalse((self.root / 'injected').exists())
        self.AssertDeleted()

    def test_unset_or_empty_image_environment_defaults_without_legacy_override(self):
        for value, legacy in ((None, False), ('', False), (None, True), ('', True)):
            with self.subTest(value=value, legacy=legacy):
                case = RecoveryTests('test_success_contract')
                case.setUp()
                self.addCleanup(case.doCleanups)
                del case.env['BSOD_DET__GUEST_FS__CTR_IMG']
                if value is not None:
                    case.env['BSOD_DET__GUEST_FS__CTR_IMG'] = value
                case.env.pop('BSOD_DET__GUESTFS__NTFS_IMAGE', None)
                if legacy:
                    case.env['BSOD_DET__GUESTFS__NTFS_IMAGE'] = 'registry.test/legacy:ignored'
                result = case.RunRecovery()
                self.assertEqual(result.returncode, 0, result.stderr)
                argv, = case.VirtctlArgv()
                self.assertEqual(argv[argv.index('--image') + 1], dfltImg)
                self.assertTrue(any(call[0] == 'exec' for call in case.Calls()))
                self.assertTrue((case.out / 'extraction-summary.json').exists())
                case.AssertDeleted()

    def test_success_contract(self):
        result = self.RunRecovery()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.AssertDeleted()
        self.assertFalse(list(self.root.glob('bsod-evtx-*')))
        argv, = self.VirtctlArgv()
        self.assertEqual(argv[argv.index('--image') + 1],
                         self.env['BSOD_DET__GUEST_FS__CTR_IMG'])
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
        self.assertFalse(any(arg.startswith('--request-timeout') for call in rawCalls for arg in call))
        wait, = [call for call in rawCalls if '--for=condition=Ready' in call]
        self.assertEqual(wait, ['-n', 'fixture-ns', 'wait',
                                'pod/libguestfs-tools-rootdisk',
                                '--for=condition=Ready', '--timeout=180s'])
        self.assertTrue(all(call[0] in ('exec', 'cp', '-n')
                            for call in rawCalls))
        discovery, = [call for call in rawCalls if call[:3] == ['-n', 'fixture-ns', 'exec']]
        self.assertEqual(discovery[:3], ['-n', 'fixture-ns', 'exec'])
        self.assertEqual(discovery[discovery.index('--') + 1:],
                         ['guestfish', '--ro', '-a', '/dev/vda', 'run', ':', 'list-filesystems'])
        discoveries = [call for call in rawCalls if 'list-filesystems' in call]
        self.assertEqual(discoveries, [discovery])
        self.assertLess(rawCalls.index(wait), rawCalls.index(discovery))
        deadlines = [json.loads(line) for line in (self.root / 'timeouts.jsonl').read_text().splitlines()]
        self.assertEqual(len(deadlines), 1)
        self.assertEqual(deadlines[0][:4], ['--signal=TERM', '--kill-after=5', '60', 'python3'])
        cleanup = [call for call in rawCalls if call[:3] == ['-n', 'fixture-ns', 'delete'] or
                   (call[:3] == ['-n', 'fixture-ns', 'wait'] and '--for=delete' in call)]
        self.assertEqual(len(cleanup), 4)
        self.AssertDeleted()
        source = recovery.read_text()
        self.assertNotRegex(source, r'\bOc\b')
        self.assertNotIn('cmdTimeout', source)
        self.assertNotIn('BSOD_DET__COMMAND__TIMEOUT', source)
        self.assertNotIn('--request-timeout', source)
        self.assertNotIn('unset -n varRef', source)
        self.AssertDeleted()

    def test_ready_wait_failure_prevents_helper_execution(self):
        result = self.RunRecovery('wait-error')
        self.assertEqual(result.returncode, 19, result.stderr)
        self.assertIn('mock startup timeout', result.stderr)
        self.assertFalse(any(call[0] in ('exec', 'cp') for call in self.Calls()))
        self.assertFalse((self.out / 'extraction-summary.json').exists())
        self.AssertDeleted()

    def test_direct_failure_breadcrumbs_replace_die(self):
        source = recovery.read_text()
        self.assertNotRegex(source, r'\bDie\b')
        messages = re.findall(r'(?:^|\{)[ \t]*: ([\'"])(.*?)\1', source, re.MULTILINE)
        self.assertEqual(len(messages), 4)
        for quote, message in messages:
            with self.subTest(message=message):
                self.assertTrue(message[0].isupper())
                if ': ' not in message:
                    self.assertTrue(message.endswith('.'))
        self.assertIn(('"', 'Required tool missing: ${tool}'), messages)
        self.assertIn(('"', r'Missing \`${fldChk[${k}]}\` in metadata.'), messages)

    def test_relative_host_path_resolves_helpers(self):
        result = self.RunRecovery(script=f'./{recovery.name}', cwd=hostDir)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads((self.out / 'extraction-summary.json').read_text())['ok'])
        self.AssertDeleted()

    def test_metadata_only_output_contract(self):
        source = recovery.read_text()
        self.assertNotIn('--out', source[:source.index("typeset tool=")])
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

    def test_directory_alias_existing_outputs_reach_extraction(self):
        for staleName in ('MEMORY.DMP', 'Minidump', 'guestFS_sda3', 'events.json',
                          'extraction-summary.json', 'checksums.sha256'):
            with self.subTest(staleName=staleName):
                case = ArchiveRecoveryTests('test_archive_contains_only_requested_files_and_validator_remains_deferred')
                case.setUp()
                self.addCleanup(case.doCleanups)
                alias = case.root / 'directory alias'
                alias.symlink_to(case.out, target_is_directory=True)
                case.metadata['outputDir'] = str(alias)
                stale = case.out / staleName
                stale.mkdir() if staleName in ('Minidump', 'guestFS_sda3') else stale.write_text('preserve-stale')
                if stale.is_dir():
                    (stale / 'watcher-note.txt').write_text('preserve-watcher')
                result = case.RunRecovery()
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertNotIn('Pre-existing extraction artifact rejected:', result.stderr)
                self.assertTrue(case.VirtctlArgv())
                self.assertEqual(len(case.ArchiveContents()), 2)
                case.AssertDeleted()
                self.assertTrue(stale.exists())
                if staleName == 'MEMORY.DMP':
                    self.assertEqual(stale.read_text(), 'preserve-stale')
                elif stale.is_dir():
                    self.assertEqual((stale / 'watcher-note.txt').read_text(), 'preserve-watcher')
                else:
                    self.assertNotEqual(stale.read_text(), 'preserve-stale')
                summary = json.loads((case.out / 'extraction-summary.json').read_text())
                self.assertFalse(summary['ok'])
                self.assertFalse((case.out / 'extraction.log').exists())

    def test_api_failure_preserves_descendant_directory_alias(self):
        external = self.root / 'external'
        external.mkdir()
        (external / 'events.json').write_text('external-stale')
        (self.out / 'nested alias').symlink_to(external, target_is_directory=True)
        result = self.RunRecovery('api-error')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('mock API unavailable', result.stderr)
        self.assertNotIn('Pre-existing extraction artifact rejected:', result.stderr)
        self.assertEqual([call[0] for call in self.Calls()], ['get'])
        self.assertEqual((external / 'events.json').read_text(), 'external-stale')

    def test_invalid_metadata_output_rejected_before_oc_or_writes(self):
        for scenario in ('missing', 'null', 'empty', 'non-string', 'file'):
            with self.subTest(scenario=scenario):
                case = RecoveryTests('test_success_contract')
                case.setUp()
                self.addCleanup(case.doCleanups)
                if scenario == 'missing':
                    del case.metadata['outputDir']
                elif scenario in ('null', 'empty', 'non-string'):
                    case.metadata['outputDir'] = {'null': None, 'empty': '', 'non-string': 42}[scenario]
                elif scenario == 'file':
                    case.metadata['outputDir'] = str(case.root / 'fixture.evtx')
                before = {path.name: path.read_bytes() for path in case.out.iterdir()}
                result = case.RunRecovery()
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn('Cannot create output directory:' if scenario == 'file' else
                              'Missing `.outputDir` in metadata.', result.stderr)
                self.assertFalse(case.Calls())
                self.assertEqual({path.name: path.read_bytes() for path in case.out.iterdir()}, before)

    def test_missing_output_directory_is_created_literally(self):
        target = self.root / 'new output' / 'nested'
        self.metadata['outputDir'] = str(target) + '/.'
        result = self.RunRecovery()
        self.assertTrue(target.is_dir(), result.stderr)
        self.assertEqual(target.stat().st_mode & 0o777, 0o700)
        self.assertTrue(self.VirtctlArgv())
        copies = [call for call in self.Calls() if call[0] == 'cp']
        self.assertTrue(copies)
        self.assertTrue(all(call[2].startswith(self.metadata['outputDir'] + '/') for call in copies))
        summary = json.loads((target / 'extraction-summary.json').read_text())
        self.assertIn('memory', summary['missingRequiredArtifactTypes'])
        self.assertEqual(result.returncode, 1)
        self.AssertDeleted(count=2)

    def test_output_creation_failure_precedes_api_and_logs(self):
        target = self.root / 'denied output'
        self.metadata['outputDir'] = str(target)
        mock = self.bin / 'mkdir'
        mock.write_text('#!/usr/bin/env bash\nprintf "mock permission denied\\n" 1>&2\nexit 73\n')
        mock.chmod(0o755)
        result = self.RunRecovery()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('mock permission denied', result.stderr)
        self.assertFalse(target.exists())
        self.assertFalse(self.Calls())

    def test_stopped_target_status_allows_extraction_without_vmi_query(self):
        result = self.RunRecovery()
        self.assertEqual(result.returncode, 0, result.stderr)
        reads = [call for call in self.Calls() if call[0] == 'get']
        self.assertEqual(reads[0], ['get', 'vm', 'fixture-vm',
                                    '-n', 'fixture-ns', '-o', 'json'])
        self.assertFalse(any('vmi' in call for call in reads))
        rawReads = [json.loads(line) for line in (self.root / 'oc-argv.jsonl').read_text().splitlines()
                    if '"get"' in line]
        podRead = ['-n', 'fixture-ns', 'get', 'pod/libguestfs-tools-rootdisk',
                   '--ignore-not-found', '-o', 'name']
        self.assertEqual(rawReads[0], ['-n', 'fixture-ns', 'get',
                                       'vm/fixture-vm', '-o', 'json'])
        self.assertEqual(rawReads[1:], [podRead])
        self.AssertDeleted()

    def test_vm_status_partial_output_does_not_propagate_producer_failure(self):
        result = self.RunRecovery('vm-api-partial')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('mock VM API unavailable', result.stderr)
        self.assertEqual([call[1] for call in self.Calls()
                          if call[:2] == ['get', 'vm']], ['vm'])
        self.assertTrue(self.VirtctlArgv())
        self.assertTrue(json.loads((self.out / 'extraction-summary.json').read_text())['ok'])
        self.AssertDeleted()
        producer = subprocess.run([str(self.bin / 'oc'), '-n', 'fixture-ns', 'get', 'vm/fixture-vm', '-o', 'json'],
                                  env=dict(self.env, SCENARIO='vm-api-partial'), text=True,
                                  capture_output=True, timeout=10)
        self.assertEqual(producer.returncode, 17, producer.stderr)
        self.assertEqual(json.loads(producer.stdout)['status']['printableStatus'], 'Stopped')

    def test_powered_off_guard_rejects_before_helper_mutation(self):
        scenarios = (
            'vm-status-Running', 'vm-status-Starting', 'vm-status-Stopping',
            'vm-status-Unknown', 'vm-status-', 'vm-status-missing', 'vm-status-null',
            'vm-status-bool', 'vm-missing', 'vm-empty', 'vm-multiple', 'bad-json',
            'api-error',
        )
        for scenario in scenarios:
            with self.subTest(scenario=scenario):
                case = RecoveryTests('test_success_contract')
                case.setUp()
                self.addCleanup(case.doCleanups)
                before = {path.name: path.read_bytes() for path in case.out.iterdir()}
                result = case.RunRecovery(scenario)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertTrue(case.Calls())
                self.assertTrue(all(call[0] == 'get' for call in case.Calls()))
                self.assertFalse(case.VirtctlArgv())
                self.assertEqual(before, {path.name: path.read_bytes() for path in case.out.iterdir()})
                if scenario == 'api-error':
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn('mock API unavailable', result.stderr)

    def test_unsafe_failures_stop_executed_script(self):
        for scenario in ('api-error', 'bad-json', 'vm-status-Running', 'vm-status-Starting', 'metadata-error'):
            with self.subTest(scenario=scenario):
                case = RecoveryTests('test_success_contract')
                case.setUp()
                self.addCleanup(case.doCleanups)
                if scenario == 'metadata-error':
                    case.metadata['guestPvc'] = False
                result = case.RunRecovery(scenario)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertFalse(any(call[0] == 'cp' for call in case.Calls()))
                self.assertFalse(case.VirtctlArgv())
                self.assertFalse((case.root / 'helper-pod').exists())
                self.assertFalse((case.out / 'extraction-summary.json').exists())

    def test_cleanup_absent_helper_is_idempotent_with_blocking_delete(self):
        result = self.RunRecovery('helper-absent')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.AssertDeleted()

    def test_empty_helper_exit_trap_makes_no_cleanup_calls(self):
        result = self.RunRecovery('api-error')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual([call[0] for call in self.Calls()], ['get'])
        self.assertIn('Cleanup', result.stderr)
        self.assertNotIn('parameter null or not set', result.stderr)
        self.assertFalse((self.root / 'helper-pod').exists())

    def test_cleanup_error_replaces_original_failure_on_exit(self):
        mock = self.bin / 'oc'
        mock.write_text(mock.read_text().replace("scenario == 'cleanup-error'", "scenario == 'wait-error'"))
        result = self.RunRecovery('wait-error')
        self.assertEqual(result.returncode, 25, result.stderr)
        self.assertIn('mock startup timeout', result.stderr)
        self.assertIn('mock delete failure', result.stderr)
        self.assertEqual([call[0] for call in self.Calls()],
                         ['get', 'get', 'wait', 'wait', 'delete'])
        self.assertTrue((self.root / 'helper-pod').exists())
        self.assertFalse((self.out / 'extraction-summary.json').exists())

    def test_empty_cleanup_argument_replaces_malformed_vm_json_status(self):
        result = self.RunRecovery('bad-json')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('parse error', result.stderr)
        self.assertIn('1: parameter null or not set', result.stderr)
        self.assertEqual([call[0] for call in self.Calls()], ['get'])
        self.assertFalse((self.out / 'parse-dump-header.json').exists())
        self.assertFalse((self.out / 'extraction-summary.json').exists())

    def test_cleanup_has_only_exit_trap_and_supplied_commands(self):
        source = recovery.read_text()
        self.assertNotIn('hasPod', source)
        self.assertNotIn("trap 'exit 130' INT", source)
        self.assertNotIn("trap 'exit 143' TERM", source)
        self.assertEqual(re.findall(r'^trap .*$', source, re.MULTILINE), [(
            'trap \'Cleanup "$?" "${guestfsPid}" "${guestfsIn}" '
            '"${hlprPod}"\' EXIT')])
        cleanup = re.search(r'^function Cleanup \(\) \{\n.*?^\}', source, re.MULTILINE | re.DOTALL).group()
        self.assertNotIn('timeout --', cleanup)
        self.assertNotIn('--wait=false', cleanup)
        self.assertNotIn('--request-timeout', cleanup)

    def test_parameterized_helper_arguments_and_native_calls(self):
        source = recovery.read_text()
        for name, arguments, expected in (
            ('Cleanup', [], 1), ('Cleanup', ['0', '0', '0'], 1),
            ('Cleanup', ['0', '0', '0', ''], 0),
            ('Cleanup', ['0', '0', '0', 'other-pod'], 0),
            ('Cleanup', ['0', 'LIVE', '0', 'other-pod'], 0),
            ('Cleanup', ['3', 'LIVE', '0', 'other-pod', 'ignored'], 3),
            ('FindNTFS', [], 1), ('FindNTFS', ['other-pod'], 1),
            ('FindNTFS', ['', 'other-container'], 1), ('FindNTFS', ['other-pod', ''], 1),
            ('FindNTFS', ['other-pod', 'other-container'], 0),
            ('FindNTFS', ['other-pod', 'other-container', 'ignored'], 0),
        ):
            with self.subTest(name=name, arguments=arguments):
                callsFile = self.root / 'oc-argv.jsonl'
                callsFile.unlink(missing_ok=True)
                (self.root / 'helper-pod').touch()
                helper = re.search(r'^function ' + name + r' \(\) \{\n.*?^\}', source,
                                   re.MULTILINE | re.DOTALL).group()
                live = ('sleep 0.2 &\nset -- "${@/#LIVE/$!}"\n'
                        if 'LIVE' in arguments else '')
                command = ('set -euxo pipefail; shopt -s inherit_errexit\n'
                           'typeset ns=fixture-ns hlprPod=wrong-pod '
                           'helperPodCtr=wrong-container\n'
                           + helper + '\n' + live + name + ' "$@"\n')
                result = subprocess.run(['bash', '-c', command, 'argument-fixture', *arguments],
                                        env=self.env, text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, expected, result.stderr)
                calls = [json.loads(line) for line in callsFile.read_text().splitlines()] if callsFile.exists() else []
                if expected == 1:
                    self.assertEqual(calls, [])
                    self.assertIn('parameter not set' if name == 'Cleanup' else
                                  'parameter null or not set', result.stderr)
                elif name == 'Cleanup':
                    # No child (PID 0) means nothing to delete or reap.
                    self.assertNotIn('+ kill -0 0\n', result.stderr)
                    self.assertNotIn('+ wait 0\n', result.stderr)
                    self.assertEqual(calls, [
                        ['-n', 'fixture-ns', 'delete', 'pod/other-pod', '--ignore-not-found',
                         '--timeout=60s', '--wait=true'],
                    ] if arguments[1] == 'LIVE' else [])
                    if arguments[1] == 'LIVE':
                        reap = result.stderr.index('+ wait ')
                        delete = result.stderr.index(
                            '+ oc -n fixture-ns delete')
                        self.assertEqual(reap < delete, arguments[0] == '0')
                else:
                    self.assertEqual(calls, [[
                        '-n', 'fixture-ns', 'exec', 'other-pod', '-c', 'other-container', '--',
                        'guestfish', '--ro', '-a', '/dev/vda', 'run', ':', 'list-filesystems',
                    ]])
                    self.assertEqual(result.stdout, '/dev/sda2\n/dev/sda3\n/dev/sda4\n')

    def test_parameterized_helpers_have_direct_main_and_exit_callers(self):
        source = recovery.read_text()
        self.assertIn('done 0< <(FindNTFS "${hlprPod}" "${helperPodCtr}")',
                      source)
        self.assertIn('"${hlprPod}"\' EXIT', source)
        self.assertNotIn('ntfsOutput', source)
        self.assertNotRegex(source, r'\bcontainer=|\$\{container\}|\bdevice=|\$\{device\}')
        self.assertNotIn('Cleanup ||', source)

    def test_cleanup_wait_and_delete_failures_remain_visible(self):
        for scenario in ('cleanup-error', 'cleanup-wait-error', 'cleanup-wait-timeout'):
            with self.subTest(scenario=scenario):
                case = RecoveryTests('test_success_contract')
                case.setUp()
                self.addCleanup(case.doCleanups)
                result = case.RunRecovery(scenario)
                self.assertEqual(result.returncode, 25 if scenario == 'cleanup-error' else 28, result.stderr)
                case.AssertDeleted(count=2, waitCount=0 if scenario == 'cleanup-error' else 2)
                self.assertFalse((case.out / 'extraction-summary.json').exists())
                self.assertFalse((case.out / 'stage-errors.jsonl').exists())
                self.assertFalse((case.out / 'extraction.log').exists())
                self.assertIn('mock delete failure' if scenario == 'cleanup-error' else
                              'mock deletion wait failed', result.stderr)

    def test_sigint_without_custom_trap_can_continue(self):
        result = self.RunRecovery('signal-int')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.out / 'extraction-summary.json').exists())
        self.AssertDeleted()

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
        self.env.pop('BSOD_DET__GUEST_FS__CTR_IMG', None)
        self.env['BSOD_DET__GUESTFS__NTFS_IMAGE'] = 'registry.test/legacy:ignored'
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
        argv, = self.VirtctlArgv()
        self.assertEqual(argv[argv.index('--image') + 1], dfltImg)
        self.AssertDeleted()

    def test_watcher_reports_transient_cleanup_failure(self):
        watcher = (hostDir / 'watch-crash.sh').read_text()
        runTimed = re.search(r'^function RunTimed \(\) \{.*\}$', watcher, re.MULTILINE).group()
        recover = re.search(r'^function Recover \(\) \{\n.*?^\}', watcher, re.MULTILINE | re.DOTALL).group()
        command = ('set -euxo pipefail; shopt -s inherit_errexit\n'
                   'typeset scriptDir="${1}" metadataFile="${2}" pipelineLog="${3}"\n'
                   + runTimed + '\n' + recover + '\nRecover\n')
        for scenario, expected in (('transient-delete', 25), ('transient-wait', 28)):
            with self.subTest(scenario=scenario):
                case = RecoveryTests('test_success_contract')
                case.setUp()
                self.addCleanup(case.doCleanups)
                case.meta.write_text(json.dumps(case.metadata))
                result = subprocess.run(['bash', '-c', command, 'watcher-fixture', str(hostDir),
                                         str(case.meta), str(case.root / 'pipeline.log')],
                                        cwd=case.root, env=dict(case.env, SCENARIO=scenario),
                                        text=True, capture_output=True, timeout=10)
                log = (case.root / 'pipeline.log').read_text()
                self.assertIn('mock transient deletion', log)
                case.AssertDeleted(count=2, waitCount=1 if scenario == 'transient-delete' else 2)
                self.assertFalse((case.root / 'helper-pod').exists())
                self.assertFalse((case.out / 'extraction-summary.json').exists())
                self.assertNotEqual(result.returncode, 0, log)
                self.assertEqual(result.returncode, expected, log)

    def test_executable_reports_transient_cleanup_failure(self):
        for scenario, expected in (('transient-delete', 25), ('transient-wait', 28)):
            with self.subTest(scenario=scenario):
                case = RecoveryTests('test_success_contract')
                case.setUp()
                self.addCleanup(case.doCleanups)
                result = case.RunRecovery(scenario)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertIn('mock transient deletion', result.stderr)
                case.AssertDeleted(count=2, waitCount=1 if scenario == 'transient-delete' else 2)
                self.assertFalse((case.root / 'helper-pod').exists())
                self.assertFalse((case.out / 'extraction-summary.json').exists())

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
        self.env['BSOD_DET__GUEST_FS__CTR_IMG'] = ''
        self.env['BSOD_DET__GUESTFS__NTFS_IMAGE'] = 'registry.test/legacy:ignored'
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
        argv, = self.VirtctlArgv()
        self.assertEqual(argv[argv.index('--image') + 1], dfltImg)
        self.AssertDeleted()

    def test_diagnostics_follow_invoked_name(self):
        alias = self.root / 'fixture-extractor.sh'
        alias.symlink_to(recovery)
        for args, expected, message in (
                (('--help',), 0, f'usage: {alias.name} '),
                (('--unknown',), 2, f'{alias.stem}: unknown argument:'),
                (('--metadata', str(self.root / 'missing.json')), 2, f'{alias.stem}: `--metadata` is required and must be readable')):
            with self.subTest(args=args):
                result = self.RunRecovery('', *args, script=alias)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertIn(message, result.stdout if expected == 0 else result.stderr)
        self.metadata['guestPvc'] = ''
        result = self.RunRecovery(script=alias)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f'typeset scrName={alias.name}', result.stderr)
        self.assertIn('Missing `.guestPvc` in metadata.', result.stderr)
        self.assertFalse(self.Calls())

    def test_metadata_guard_rejects_missing_or_unreadable_inputs(self):
        unreadable = self.root / 'unreadable.json'
        unreadable.write_text('{}')
        unreadable.chmod(0o000)
        for args in ((),
                     ('--metadata', str(self.root / 'missing.json')),
                     ('--metadata', str(unreadable))):
            with self.subTest(args=args):
                if args == ('--metadata', str(unreadable)) and os.access(unreadable, os.R_OK):
                    self.skipTest('effective user can read mode-000 files')
                result = (self.RunRecovery('', *args) if args else
                          subprocess.run([str(recovery)], env=self.env, text=True, capture_output=True, timeout=10))
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual([line for line in result.stderr.splitlines() if not line.startswith('+')],
                                 [f'{recovery.stem}: `--metadata` is required and must be readable'])
                self.assertEqual(result.stdout, '')
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
        self.assertIn("jq -e '.ok == true'", result.stderr)
        self.assertFalse((self.out / 'stage-errors.jsonl').exists())

    def test_failure_stages(self):
        for scenario in ('wait-error', 'no-guestfish', 'discovery-error', 'exec-error', 'copy-error',
                         'empty-copy', 'no-ntfs', 'cleanup-error'):
            with self.subTest(scenario=scenario):
                case = RecoveryTests('test_success_contract')
                case.setUp()
                self.addCleanup(case.doCleanups)
                result = case.RunRecovery(scenario)
                expected = {'wait-error': 19, 'cleanup-error': 25}.get(scenario, 1)
                self.assertEqual(result.returncode, expected, result.stderr)
                case.AssertDeleted(count=2 if scenario == 'cleanup-error' else None,
                                   waitCount=0 if scenario == 'cleanup-error' else None)
                if scenario != 'cleanup-error':
                    self.assertFalse(list(case.out.glob('**/*.evtx')))

    def test_discovery_failure_or_empty_result_stops_and_cleans(self):
        for scenario in ('discovery-error', 'discovery-partial-error', 'no-ntfs', 'empty-filesystems'):
            with self.subTest(scenario=scenario):
                case = RecoveryTests('test_success_contract')
                case.setUp()
                self.addCleanup(case.doCleanups)
                result = case.RunRecovery(scenario)
                self.assertEqual(result.returncode, 1, result.stderr)
                case.AssertDeleted()
                self.assertFalse(any(call[0] == 'cp' for call in case.Calls()))
                self.assertFalse((case.out / 'parse-dump-header.json').exists())
                self.assertFalse((case.out / 'extraction-summary.json').exists())
                self.assertFalse((case.out / 'stage-errors.jsonl').exists())
                if scenario.startswith('discovery-'):
                    self.assertIn('mock discovery failure', result.stderr)

    def test_find_ntfs_status_in_conditional_context(self):
        helper = re.search(r'^function FindNTFS \(\) \{\n.*?^\}', recovery.read_text(), re.MULTILINE | re.DOTALL).group()
        self.assertIn('done 0< <(\n        oc -n "${ns}" exec', helper)
        self.assertNotIn('output=', helper)
        self.assertNotIn('<<<', helper)
        self.assertIn('producerPid=$!\n    wait "${producerPid}" || return 1', helper)
        for scenario in ('', 'discovery-error', 'discovery-partial-error', 'no-ntfs', 'empty-filesystems'):
            with self.subTest(scenario=scenario):
                (self.root / 'probe-done').touch()
                command = ('set -euxo pipefail; shopt -s inherit_errexit\n'
                           'typeset ns=fixture-ns\n'
                           + helper + '\ntypeset -i status=0\nFindNTFS fixture-pod libguestfs || status=$?\nexit "${status}"\n')
                result = subprocess.run(['bash', '-c', command, 'discovery-fixture'],
                                        env=dict(self.env, SCENARIO=scenario), text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0 if not scenario else 1, result.stderr)
                self.assertEqual(result.stdout, '/dev/sda2\n/dev/sda3\n/dev/sda4\n' if not scenario else '')
                if scenario.startswith('discovery-'):
                    self.assertIn('mock discovery failure', result.stderr)

    def test_unsafe_inputs_never_apply(self):
        for scenario in ('api-error', 'bad-json', 'vm-status-Running', 'vm-status-Starting'):
            with self.subTest(scenario=scenario):
                case = RecoveryTests('test_success_contract')
                case.setUp()
                self.addCleanup(case.doCleanups)
                result = case.RunRecovery(scenario)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertFalse(case.VirtctlArgv())
                if scenario == 'api-error':
                    self.assertIn('mock API unavailable', result.stderr)
                if scenario == 'bad-json':
                    self.assertIn('parse error', result.stderr)

    def test_only_consumed_metadata_fields_are_required(self):
        self.metadata = {key: self.metadata[key] for key in
                         ('runId', 'outputDir', 'namespace', 'vm', 'guestPvc')}
        self.marker.unlink()
        (self.bin / 'findmnt').unlink()
        result = self.RunRecovery()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.AssertDeleted()

    def test_malformed_required_fields_fail_before_mutation(self):
        for field in ('runId', 'outputDir', 'namespace', 'vm', 'guestPvc'):
            for value in ('missing', None, '', 42, [], {}, False, True):
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
                    self.assertIn(f'Missing `.{field}` in metadata.', result.stderr)
                    self.assertNotIn('command not found', result.stderr)
                    self.assertFalse(case.Calls())
                    self.assertEqual({path.name: path.read_bytes() for path in case.out.iterdir()}, before)

    def test_metadata_mapping_preserves_schema_and_treats_values_as_data(self):
        source = recovery.read_text()
        self.assertIn('[guestPVC]=.guestPvc', source)
        self.assertIn('typeset -n varRef="${k}"', source)
        self.assertIn('eval "typeset ${k}=\'\'"', source)
        self.assertNotIn('${guestPvc}', source)
        for obsolete in ('fieldArr', 'fieldRef', 'fldChkLst', '--arg kPath', '--arg key'):
            self.assertNotIn(obsolete, source)
        self.assertIn('select((type == "string") and (length > 0))', source)
        sentinel = self.root / 'must-not-execute'
        self.metadata['vm'] = f'$(touch "{sentinel}")'
        self.metadata['guestPVC'] = 'ignored-schema-alias'
        for name in ('k', 'fldChk', 'varRef'):
            self.metadata[name] = f'$(touch "{sentinel}")'
        result = self.RunRecovery()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(sentinel.exists())
        self.assertEqual(self.VirtctlArgv()[0][-1], 'rootdisk')
        summary = json.loads((self.out / 'extraction-summary.json').read_text())
        self.assertEqual(summary['vm'], self.metadata['vm'])
        self.AssertDeleted()

    def test_metadata_loop_preserves_all_five_literal_values(self):
        source = recovery.read_text()
        loop = source[source.index("typeset k=''"):source.index('mkdir -p "${outDir}"')]
        mappings = {'runId': 'runId', 'outDir': 'outputDir', 'ns': 'namespace',
                    'vm': 'vm', 'guestPVC': 'guestPvc'}
        self.assertEqual(dict(re.findall(r'^    \[(\w+)\]=\.(\w+)$', loop, re.M)), mappings)
        self.assertEqual(re.findall(r'^    eval (.*)$', loop, re.M), ['"typeset ${k}=\'\'"'])
        sentinel = self.root / 'must-not-execute'
        values = [f'{key} \' " `touch {sentinel}` $(touch {sentinel}) \\ literal\nnext'
                  for key in mappings]
        self.meta.write_text(json.dumps(dict(zip(mappings.values(), values))))
        command = ('set -euxo pipefail; shopt -s inherit_errexit\nmetadataFile="${1}"\n'
                   + loop + '\nprintf \'%s\\0\' "${runId}" "${outDir}" "${ns}" "${vm}" "${guestPVC}"\n')
        result = subprocess.run(['bash', '-c', command, 'literal-metadata', str(self.meta)],
                                env=self.env, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stdout.decode().split('\0'), values + [''])
        self.assertFalse(sentinel.exists())
        self.assertFalse(self.Calls())

    def test_sigterm_uses_default_signal_and_exit_cleanup(self):
        result = self.RunRecovery('signal')
        self.assertEqual(result.returncode, -15, result.stderr)
        self.AssertDeleted()
        self.assertFalse((self.out / 'stage-errors.jsonl').exists())

    def test_extractor_inherits_streams_without_log_artifacts(self):
        source = recovery.read_text()
        for obsolete in ('RecordError', 'extractLog', 'stageErrors', 'extraction.log'):
            self.assertNotIn(obsolete, source)
        mock = self.bin / 'oc'
        mock.write_text(mock.read_text().replace('args = sys.argv[1:]',
                        'args = sys.argv[1:]\n'
                        'if "delete" in args[:3]:\n'
                        '    print("mock native stdout")\n'
                        'print("mock native stderr", file=sys.stderr)'))
        result = self.RunRecovery()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('mock native stdout', result.stdout)
        self.assertIn('mock native stderr', result.stderr)
        self.assertFalse((self.out / 'extraction.log').exists())
        self.assertFalse((self.out / 'stage-errors.jsonl').exists())
        self.AssertDeleted()

    def test_watcher_stage_errors_are_read_without_modification(self):
        errors = self.out / 'stage-errors.jsonl'
        content = '{"stage":"watcher","error":"prior watcher failure","at":"fixture"}\n'
        errors.write_text(content)
        errors.chmod(0o640)
        result = self.RunRecovery()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(errors.read_text(), content)
        self.assertEqual(errors.stat().st_mode & 0o777, 0o640)
        summary = json.loads((self.out / 'extraction-summary.json').read_text())
        self.assertEqual(summary['stageErrors'], [json.loads(content)])
        self.assertFalse(summary['ok'])
        self.AssertDeleted()

    def test_cli_statuses(self):
        for args, expected in ((('--help',), 0), (('--unknown',), 2), (('--out', str(self.out)), 2)):
            with self.subTest(args=args):
                result = self.RunRecovery('', *args)
                self.assertEqual(result.returncode, expected)
                if args == ('--help',):
                    self.assertEqual(result.stdout, 'usage: extract--guest-os--crash-info.sh --metadata METADATA.json\n')
                    self.assertNotIn('PRE_STOP_METADATA.json', result.stdout)
        self.assertFalse(self.Calls())


class ArchiveRecoveryTests(unittest.TestCase):
    RunRecovery = RecoveryTests.RunRecovery
    Calls = RecoveryTests.Calls

    def setUp(self):
        RecoveryTests.setUp(self)
        python = self.bin / 'python3'
        python.write_text(f'#!{sys.executable}\n'
                          'import os, sys\n'
                          'from pathlib import Path\n'
                          'if any(arg.endswith("/reliability.py") for arg in sys.argv[1:]):\n'
                          '    Path(os.environ["MOCK_ROOT"], "reliability-invoked").touch()\n'
                          f'os.execv({sys.executable!r}, [{sys.executable!r}, *sys.argv[1:]])\n')
        python.chmod(0o755)

    def AssertDeleted(self, waitCount=None, count=None):
        if count is None:
            count = 1
        RecoveryTests.AssertDeleted(self, waitCount=waitCount, count=count)

    def ArchiveContents(self):
        archive = self.out / 'guest-fs--crash-info.tgz'
        self.assertEqual(archive.stat().st_mode & 0o777, 0o600)
        with tarfile.open(archive, 'r:gz') as payload:
            return {member.name.removeprefix('./'): payload.extractfile(member).read()
                    for member in payload.getmembers() if member.isfile()}

    def AssertSummaryBypassed(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(list(self.out.rglob('*.evtx')))
        self.assertFalse(list(self.out.glob('guestFS_*')))
        self.assertFalse(any(call[0] == 'cp' for call in self.Calls()))
        for call in self.Calls():
            if call[0] == 'exec':
                self.assertEqual(call[3].removeprefix('pod/'),
                                 'libguestfs-tools-rootdisk')
                self.assertEqual(call[call.index('-c') + 1], 'libguestfs')
        self.assertFalse((self.out / 'extraction-summary.json').exists())
        self.assertFalse((self.root / 'reliability-invoked').exists())
        check = subprocess.run(['sha256sum', '-c', 'checksums.sha256'], cwd=self.out,
                               text=True, capture_output=True)
        self.assertEqual(check.returncode, 0, check.stderr)
        self.AssertDeleted()

    def test_archive_contains_only_requested_files_and_validator_remains_deferred(self):
        result = self.RunRecovery()
        self.AssertSummaryBypassed(result)
        content = self.ArchiveContents()
        expected = {f'Windows/System32/winevt/Logs/{name}.evtx': (self.root / 'fixture.evtx').read_bytes()
                    for name in ('System', 'Application')}
        self.assertEqual(content, expected)

    def test_existing_summary_and_stage_errors_are_not_revalidated_or_modified(self):
        summary = self.out / 'extraction-summary.json'
        stageErrors = self.out / 'stage-errors.jsonl'
        summary.write_bytes(b'preexisting summary sentinel')
        stageErrors.write_bytes(b'{"stage":"fixture","error":"preserve"}\n')
        before = {path: path.read_bytes() for path in (summary, stageErrors)}
        result = self.RunRecovery()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / 'reliability-invoked').exists())
        self.assertEqual({path: path.read_bytes() for path in before}, before)
        self.assertEqual(len(self.ArchiveContents()), 2)
        self.AssertDeleted(count=1)

    def test_json_stubs_and_checksum_manifest_contents(self):
        (self.out / 'extra data.dat').write_bytes(b'include this file')
        (self.out / 'nested').mkdir()
        (self.out / 'nested' / 'data.dat').write_bytes(b'nested data')
        (self.out / 'linked.dat').symlink_to('extra data.dat')
        for name in ('ignored.tmp', 'ignored.log', 'prior-summary.json'):
            (self.out / name).write_text('{}')
        (self.out / 'stage-errors.jsonl').write_text('')
        result = self.RunRecovery()
        self.AssertSummaryBypassed(result)
        parser = {'ok': True, 'totalDumps': 0, 'dumps': [],
                  'warnings': ['no on-disk dump available; primary artifact is vm-memory.elf.tar.gz']}
        events = {'ok': True, 'note': 'extract-evtx.py is a developer tool — run offline against guestFS_<partition>/Windows/System32/winevt/Logs/*.evtx',
                  'events': []}
        for name, value in (('parse-dump-header.json', parser), ('events.json', events)):
            expected = subprocess.check_output(['jq', '-n', json.dumps(value, ensure_ascii=False)])
            self.assertEqual((self.out / name).read_bytes(), expected)
        names = {'vm-memory.elf', 'guest-fs--crash-info.tgz', 'parse-dump-header.json', 'events.json',
                 'extra data.dat', 'linked.dat', 'nested/data.dat'}
        rows = (self.out / 'checksums.sha256').read_text().splitlines()
        self.assertEqual(len(rows), len(names))
        self.assertEqual(rows, [hashlib.sha256((self.out / name).read_bytes()).hexdigest() + '  ' + name
                                for name in sorted(names)])
        for name in ('parse-dump-header.json', 'events.json', 'checksums.sha256'):
            self.assertEqual((self.out / name).stat().st_mode & 0o777, 0o600)
        self.assertFalse((self.out / 'checksums.sha256.tmp').exists())

    def test_existing_json_modes_and_checksum_replacement(self):
        for content in ('', '{"ok":true,"totalDumps":0,"dumps":[],"watcher":"preserve"}\n'):
            with self.subTest(parser=content):
                case = ArchiveRecoveryTests('test_archive_contains_only_requested_files_and_validator_remains_deferred')
                case.setUp()
                self.addCleanup(case.doCleanups)
                parser = case.out / 'parse-dump-header.json'
                parser.write_text(content)
                parser.chmod(0o640)
                events = case.out / 'events.json'
                events.write_text('overwrite existing events')
                events.chmod(0o644)
                checksum = case.out / 'checksums.sha256'
                checksum.write_text('overwrite existing checksum')
                checksum.chmod(0o644)
                result = case.RunRecovery()
                case.AssertSummaryBypassed(result)
                self.assertEqual(parser.stat().st_mode & 0o777, 0o640)
                if content:
                    self.assertEqual(parser.read_text(), content)
                else:
                    self.assertEqual(json.loads(parser.read_text())['totalDumps'], 0)
                self.assertEqual(events.stat().st_mode & 0o777, 0o644)
                self.assertEqual(json.loads(events.read_text())['events'], [])
                self.assertEqual(checksum.stat().st_mode & 0o777, 0o600)
                self.assertNotIn('overwrite existing checksum', checksum.read_text())
                self.assertFalse((case.out / 'checksums.sha256.tmp').exists())

    def test_existing_archive_is_replaced_not_appended(self):
        archive = self.out / 'guest-fs--crash-info.tgz'
        original = b'preexisting archive sentinel' * 4096
        archive.write_bytes(original)
        archive.chmod(0o600)
        result = self.RunRecovery()
        self.AssertSummaryBypassed(result)
        self.assertEqual(len(self.ArchiveContents()), 2)
        replacement = archive.read_bytes()
        self.assertNotEqual(replacement, original)
        payload = zlib.decompressobj(16 + zlib.MAX_WBITS)
        payload.decompress(replacement)
        self.assertTrue(payload.eof)
        self.assertEqual(payload.unused_data, b'')

    def test_existing_watcher_files_are_not_deleted_or_modified(self):
        parser = self.out / 'parse-dump-header.json'
        parser.write_text('{"ok":true,"totalDumps":0,"dumps":[],"watcher":"preserve"}\n')
        note = self.out / 'watcher.log'
        note.write_text('preserve watcher log\n')
        watched = [self.out / 'vm-memory.elf', parser, note]
        before = {path: path.read_bytes() for path in watched}
        result = self.RunRecovery()
        self.AssertSummaryBypassed(result)
        self.assertEqual(len(self.ArchiveContents()), 2)
        self.assertEqual({path: path.read_bytes() for path in watched}, before)

    def test_helper_filesystem_mkdir_test_and_timestamp_path(self):
        result = self.RunRecovery()
        self.AssertSummaryBypassed(result)
        calls = self.Calls()
        tests = [call for call in calls if call[0] == 'exec' and call[call.index('--') + 1:][:2] == ['test', '-d']]
        self.assertEqual(len(tests), 1)
        destination = tests[0][-1]
        self.assertRegex(destination, r'^/tmp/bsod--guest-files--[0-9]+/$')
        self.assertFalse(Path(destination).exists())
        self.assertTrue((self.root / 'helper-fs' / destination.lstrip('/')).is_dir())
        helperCalls = [json.loads(line) for line in (self.root / 'helper-argv.jsonl').read_text().splitlines()]
        directories = [call[2] for call in helperCalls if call[0] == 'mkdir']
        self.assertEqual(directories, [destination + '/Windows/System32/winevt/Logs'] * 2)
        self.assertNotIn('.bin', destination)
        copies = [call[call.index('--') + 1:] for call in calls if call[0] == 'exec' and 'bash' in call]
        self.assertEqual(len(copies), 2)
        for command in copies:
            self.assertEqual(command[:6], ['bash', '-o', 'pipefail', '-O', 'inherit_errexit', '-euxc'])
            self.assertIn('exec -a virt-sh guestfish', command[6])
            self.assertEqual(command[-4], '')
            self.assertEqual(command[-3], '/dev/sda3')
            self.assertTrue(command[-2].endswith('.evtx'))
            self.assertEqual(command[-1], directories[0])
        self.assertEqual(len(self.ArchiveContents()), 2)

    def test_guestfish_probe_and_each_copy_are_readonly(self):
        result = self.RunRecovery()
        self.AssertSummaryBypassed(result)
        commands = [call[call.index('--') + 1:] for call in self.Calls() if call[0] == 'exec']
        discovery = [command for command in commands if 'list-filesystems' in command]
        self.assertEqual(len(discovery), 1)
        self.assertIn('--ro', discovery[0])
        probes = [command for command in commands if 'set-program' in command]
        self.assertEqual(len(probes), 2)
        self.assertTrue(all(command[:5] == ['guestfish', '-ra', '/dev/vda', 'set-program', 'virt-sh'] for command in probes))
        helperCalls = [json.loads(line) for line in (self.root / 'helper-argv.jsonl').read_text().splitlines()]
        copies = [command for command in helperCalls if command[0] == 'guestfish']
        self.assertEqual(len(copies), 2)
        self.assertTrue(all(command[1:3] == ['-ra', '/dev/vda'] and 'mount-ro' in command and command[-1] == 'umount-all'
                            for command in copies))
        tar = [command for command in commands if command[0] == 'tar']
        self.assertEqual(len(tar), 1)
        self.assertEqual(tar[0][1:3], ['zc', '-C'])
        self.assertEqual(tar[0][-1], './')

    def test_each_missing_file_does_not_discard_the_other(self):
        for scenario, expected in (('system-missing', 'Application.evtx'), ('partial-batch', 'System.evtx')):
            with self.subTest(scenario=scenario):
                case = ArchiveRecoveryTests('test_archive_contains_only_requested_files_and_validator_remains_deferred')
                case.setUp()
                self.addCleanup(case.doCleanups)
                result = case.RunRecovery(scenario)
                case.AssertSummaryBypassed(result)
                self.assertEqual(list(case.ArchiveContents()), ['Windows/System32/winevt/Logs/' + expected])

    def test_failed_copies_can_return_zero_with_empty_archive(self):
        result = self.RunRecovery('copy-error')
        self.AssertSummaryBypassed(result)
        self.assertEqual(self.ArchiveContents(), {})

    def test_remote_mkdir_failure_does_not_create_runner_destination(self):
        result = self.RunRecovery('mkdir-error')
        self.AssertSummaryBypassed(result)
        self.assertFalse((self.out / 'guest-fs--crash-info.tgz').exists())
        self.assertFalse(any('tar' in call for call in self.Calls()))
        self.assertFalse(list((self.root / 'helper-fs').rglob('*.evtx')))

    def test_helper_directory_test_failure_prevents_tar(self):
        result = self.RunRecovery('helper-test-error')
        self.AssertSummaryBypassed(result)
        self.assertFalse((self.out / 'guest-fs--crash-info.tgz').exists())
        self.assertFalse(any('tar' in call for call in self.Calls()))

    def test_tar_failure_keeps_status_partial_archive_and_cleans_helper(self):
        result = self.RunRecovery('tar-error')
        self.assertEqual(result.returncode, 35, result.stderr)
        self.assertEqual((self.out / 'guest-fs--crash-info.tgz').read_bytes(), b'partial archive')
        self.assertFalse((self.out / 'extraction-summary.json').exists())
        self.AssertDeleted()

    def test_native_wait_apply_and_cleanup_failures_remain_nonzero(self):
        for scenario, expected in (('wait-error', 19), ('virtctl-error', 41),
                                   ('cleanup-error', 25),
                                   ('cleanup-wait-error', 28),
                                   ('transient-delete', 25), ('transient-wait', 28)):
            with self.subTest(scenario=scenario):
                case = ArchiveRecoveryTests('test_archive_contains_only_requested_files_and_validator_remains_deferred')
                case.setUp()
                self.addCleanup(case.doCleanups)
                result = case.RunRecovery(scenario)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertFalse((case.out / 'extraction-summary.json').exists())
                if scenario == 'virtctl-error':
                    self.assertFalse([call for call in case.Calls()
                                      if call[0] in ('delete', 'exec')])
                    continue
                case.AssertDeleted(count=1, waitCount=0 if scenario in ('cleanup-error', 'transient-delete') else 1)
                if scenario == 'wait-error':
                    self.assertFalse(any(call[0] == 'exec' for call in case.Calls()))
                    self.assertFalse((case.out / 'guest-fs--crash-info.tgz').exists())

    def test_failed_discovery_still_cleans_without_copy_or_archive(self):
        result = self.RunRecovery('discovery-error')
        self.AssertSummaryBypassed(result)
        self.assertFalse((self.out / 'guest-fs--crash-info.tgz').exists())
        self.assertFalse(any(call[0] == 'exec' and 'bash' in call for call in self.Calls()))

    def test_actual_watcher_consumer_returns_archive_without_summary_validation(self):
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
        self.AssertSummaryBypassed(result)
        self.assertEqual(len(self.ArchiveContents()), 2)

    def test_actual_container_consumer_returns_archive_without_summary_validation(self):
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
        self.AssertSummaryBypassed(result)
        self.assertEqual(len(self.ArchiveContents()), 2)

    def test_early_vm_failures_skip_helper_in_actual_consumers(self):
        watcher = (hostDir / 'watch-crash.sh').read_text()
        runTimed = re.search(r'^function RunTimed \(\) \{.*\}$', watcher, re.MULTILINE).group()
        recover = re.search(r'^function Recover \(\) \{\n.*?^\}', watcher, re.MULTILINE | re.DOTALL).group()
        entrypoint = Path(__file__).resolve().parents[3] / 'image/container/bsod-detector/entrypoint.sh'
        for consumer in ('executable', 'watcher', 'container'):
            for scenario in ('vm-status-Running', 'api-error'):
                with self.subTest(consumer=consumer, scenario=scenario):
                    case = RecoveryTests('test_success_contract')
                    case.setUp()
                    self.addCleanup(case.doCleanups)
                    case.meta.write_text(json.dumps(case.metadata))
                    env = dict(case.env, SCENARIO=scenario)
                    if consumer == 'executable':
                        command = [str(recovery), '--metadata', str(case.meta)]
                    elif consumer == 'watcher':
                        body = ('set -euxo pipefail; shopt -s inherit_errexit\n'
                                'typeset scriptDir="${1}" metadataFile="${2}" pipelineLog="${3}"\n'
                                + runTimed + '\n' + recover + '\nRecover\n')
                        command = ['bash', '-c', body, 'watcher-fixture', str(hostDir),
                                   str(case.meta), str(case.root / 'pipeline.log')]
                    else:
                        body = '''set -euxo pipefail; shopt -s inherit_errexit
function exec () {
    [ "$1" = "/usr/local/bin/${MOCK_EXTRACTOR_NAME}" ] || return 99
    shift
    command "${MOCK_EXTRACTOR}" "$@"
}
source "$1" "${@:2}"
'''
                        command = ['bash', '-c', body, 'container-fixture', str(entrypoint),
                                   '--metadata', str(case.meta)]
                        env.update(MODE='recover', EVIDENCE_DIR=str(case.root),
                                   MOCK_EXTRACTOR=str(recovery), MOCK_EXTRACTOR_NAME=recovery.name)
                    result = subprocess.run(command, cwd=case.root, env=env,
                                            text=True, capture_output=True, timeout=10)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    diagnostics = result.stderr
                    if consumer == 'watcher':
                        diagnostics += (case.root / 'pipeline.log').read_text()
                    self.assertNotIn('parameter null or not set', diagnostics)
                    if scenario == 'api-error':
                        self.assertIn('mock API unavailable', diagnostics)
                    self.assertEqual([call[0] for call in case.Calls()],
                                     ['get'])
                    self.assertFalse(case.VirtctlArgv())
                    self.assertFalse((case.root / 'helper-pod').exists())
                    self.assertFalse((case.out / 'guest-fs--crash-info.tgz').exists())


if __name__ == '__main__':
    unittest.main()
