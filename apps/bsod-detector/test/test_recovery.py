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
import tarfile
import unittest


hostDir = Path(__file__).resolve().parents[1] / 'src/scripts/host'
recovery = hostDir / 'extract--guest-os--crash-info.sh'

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
    elif args[1] == 'pod':
        print('Running')
    else:
        sys.exit(91)
elif args[0] == 'create':
    template = sys.stdin.read()
    (root / 'pod-template.yaml').write_text(template)
    if scenario == 'generator-error':
        print('mock generator failure', file=sys.stderr)
        sys.exit(31)
    if scenario == 'generator-malformed':
        print('{')
        sys.exit(0)
    result = subprocess.run([os.environ['REAL_OC'], *args], input=template, text=True, capture_output=True)
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    if scenario == 'generator-partial-error':
        print('mock generator failure after valid stdout', file=sys.stderr)
        sys.exit(31)
    sys.exit(result.returncode)
elif args[0] == 'apply':
    payload = sys.stdin.read()
    if not payload.strip():
        print('mock apply: no objects passed', file=sys.stderr)
        sys.exit(1)
    json.loads(payload)
    (root / 'pod.json').write_text(payload)
    (root / 'helper-pod').touch()
    if scenario == 'apply-error':
        sys.exit(18)
    if scenario == 'helper-absent':
        (root / 'helper-pod').unlink()
elif args[0] == 'wait':
    if '--for=delete' in args:
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
    if scenario in ('signal', 'signal-int'):
        os.kill(os.getppid(), signal.SIGINT if scenario == 'signal-int' else signal.SIGTERM)
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
    if scenario == 'transient-delete' and not (root / 'cleanup-attempted').exists():
        (root / 'cleanup-attempted').touch()
        print('mock transient deletion failure', file=sys.stderr)
        sys.exit(25)
    if scenario == 'cleanup-error':
        print('mock delete failure', file=sys.stderr)
        sys.exit(25)
    (root / 'helper-pod').unlink(missing_ok=True)
else:
    sys.exit(93)
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
                        REAL_OC=shutil.which('oc'),
                        BSOD_DET__GUEST_FS__CTR_IMG='registry.test/guestfs:fixture')

    def RunRecovery(self, scenario='', *args, script=recovery, cwd=None):
        self.meta.write_text(json.dumps(self.metadata))
        return subprocess.run([str(script), *(args or ('--metadata', str(self.meta)))],
                              cwd=cwd, env=dict(self.env, SCENARIO=scenario), text=True, capture_output=True, timeout=10)

    def Calls(self):
        path = self.root / 'calls.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def AssertDeleted(self, waitCount=None, count=None):
        deletes = [call for call in self.Calls() if call[0] == 'delete']
        if count is None:
            count = 2 if (self.out / 'extraction-summary.json').exists() else 1
        self.assertEqual(len(deletes), count)
        for call in deletes:
            self.assertEqual(call[1:3], ['-n', self.metadata['namespace']])
            self.assertRegex(call[3], r'^pod/guest-fs--ntfs--[0-9]+-[0-9]+$')
            self.assertEqual(call[4:], ['--ignore-not-found'])
        waits = [call for call in self.Calls() if call[0] == 'wait' and '--for=delete' in call]
        self.assertEqual(len(waits), count if waitCount is None else waitCount)
        for call in waits:
            self.assertEqual(call[1:4], deletes[0][1:4])
            self.assertEqual(call[4:], ['--for=delete', '--timeout=60s'])
        self.assertFalse(any(call[:2] == ['get', 'pod'] for call in self.Calls()))

    def test_pod_template_rendering_is_repeatable_and_literal(self):
        source = recovery.read_text()
        start = source.index('{\n    oc create -f - --dry-run=client')
        end = source.index('\nocEOF\n', start) + len('\nocEOF\n')
        renderer = source[start:end].replace('| oc apply -f -', '| cat')
        self.assertIn("0<<'ocEOF'", renderer)
        self.assertNotIn('yq', renderer)
        self.assertIn('--arg ctrName "${helperPodCtr}"', renderer)
        self.assertIn('--arg ctrImg "${BSOD_DET__GUEST_FS__CTR_IMG:-quay.io/konveyor/oadp-vmfr-access:latest}"', renderer)
        self.assertNotIn('guestfsImage', source)
        self.assertNotIn('BSOD_DET__GUESTFS__NTFS_IMAGE', source)
        self.assertIn('helperPod="guest-fs--ntfs--$(date -u +\'%s\')-$$"', source)
        values = {'helperPod': 'guest-fs--ntfs--123-456', 'ns': 'fixture-ns', 'helperPodCtr': 'fixture-guestfs',
                  'BSOD_DET__GUEST_FS__CTR_IMG': 'registry.test/guestfs:fixture', 'guestPVC': 'rootdisk'}
        for unusual in (False, True):
            with self.subTest(unusual=unusual):
                if unusual:
                    values = {key: f'{key}: "quote"\n$(touch injected) `touch injected` \\ end'
                              for key in values}
                results = [subprocess.run(['bash', '-euc', 'set -o pipefail\n' + renderer],
                                          cwd=self.root, env=dict(self.env, **values, PATH=os.environ['PATH']),
                                          text=True, capture_output=True, timeout=10) for unused in range(2)]
                for result in results:
                    self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(results[0].stdout, results[1].stdout)
                pod = json.loads(results[0].stdout)
                self.assertEqual(pod['metadata']['name'], values['helperPod'])
                self.assertEqual(pod['metadata']['namespace'], values['ns'])
                self.assertEqual(pod['spec']['containers'][0]['name'], values['helperPodCtr'])
                self.assertEqual(pod['spec']['containers'][0]['image'], values['BSOD_DET__GUEST_FS__CTR_IMG'])
                self.assertEqual(pod['spec']['volumes'][0]['persistentVolumeClaim']['claimName'], values['guestPVC'])
                annotation = json.loads(pod['metadata']['annotations']['kubectl.kubernetes.io/last-applied-configuration'])
                self.assertEqual(annotation['metadata']['name'], 'guest-fs--ntfs')
                self.assertEqual(annotation['spec']['containers'][0]['name'], '')
                self.assertEqual(annotation['spec']['containers'][0]['image'], '')
                self.assertNotIn('creationTimestamp', pod['metadata'])
                self.assertNotIn('status', pod)
                self.assertFalse((self.root / 'injected').exists())
        for broken in (renderer.replace('apiVersion: v1', 'apiVersion: ['),
                       renderer.replace('.metadata|=(', '.metadata|=(]')):
            result = subprocess.run(['bash', '-euc', 'set -o pipefail\n' + broken],
                                    cwd=self.root, env=dict(self.env, **values, PATH=os.environ['PATH']),
                                    text=True, capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, '')
            self.assertTrue(result.stderr)

    def test_grouped_marshalling_preserves_generated_and_custom_annotations(self):
        source = recovery.read_text()
        start = source.index('{\n    oc create -f - --dry-run=client')
        end = source.index('\nocEOF\n', start) + len('\nocEOF\n')
        renderer = source[start:end].replace('| oc apply -f -', '| cat')
        template = renderer.split("} 0<<'ocEOF' | cat\n", 1)[1].rsplit('ocEOF\n', 1)[0]
        self.assertNotIn('annotations:', template)
        sentinel = 'literal "quote" $(touch injected) `touch injected`'
        annotatedTemplate = template.replace('metadata:\n', 'metadata:\n  annotations:\n    test.example/sentinel: ' + json.dumps(sentinel) + '\n', 1)
        annotatedRenderer = renderer.replace(template, annotatedTemplate)
        generated = subprocess.run([self.env['REAL_OC'], 'create', '-f', '-', '--dry-run=client',
                                    '-o', 'json', '--save-config'], input=annotatedTemplate,
                                   text=True, capture_output=True, timeout=10)
        self.assertEqual(generated.returncode, 0, generated.stderr)
        expected = json.loads(generated.stdout)
        originalAnnotations = expected['metadata']['annotations'].copy()
        self.assertEqual(originalAnnotations['test.example/sentinel'], sentinel)
        self.assertIn('kubectl.kubernetes.io/last-applied-configuration', originalAnnotations)
        values = {'helperPod': 'guest-fs--ntfs--123-456', 'ns': 'fixture-ns', 'helperPodCtr': 'fixture-guestfs',
                  'BSOD_DET__GUEST_FS__CTR_IMG': 'registry.test/guestfs:fixture', 'guestPVC': 'rootdisk'}
        result = subprocess.run(['bash', '-euc', 'set -o pipefail\n' + annotatedRenderer],
                                cwd=self.root, env=dict(self.env, **values, PATH=os.environ['PATH']),
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = json.loads(result.stdout)
        expected['metadata']['name'] = values['helperPod']
        expected['metadata']['namespace'] = values['ns']
        expected['spec']['containers'][0]['name'] = values['helperPodCtr']
        expected['spec']['containers'][0]['image'] = values['BSOD_DET__GUEST_FS__CTR_IMG']
        expected['spec']['volumes'][0]['persistentVolumeClaim']['claimName'] = values['guestPVC']
        self.assertEqual(actual, expected)
        self.assertEqual(actual['metadata']['annotations'], originalAnnotations)
        self.assertFalse((self.root / 'injected').exists())

    def test_container_name_matches_executable_helper_calls(self):
        source = recovery.read_text()
        altered = source.replace("helperPodCtr='libguestfs'", "helperPodCtr='fixture-guestfs'")
        self.assertNotEqual(source, altered)
        script = self.root / recovery.name
        script.write_text(altered)
        script.chmod(0o755)
        (self.root / 'reliability.py').symlink_to(hostDir / 'reliability.py')
        result = self.RunRecovery(script=script)
        self.assertEqual(result.returncode, 0, result.stderr)
        pod = json.loads((self.root / 'pod.json').read_text())
        self.assertEqual(pod['spec']['containers'][0]['name'], 'fixture-guestfs')
        calls = [call for call in self.Calls() if call[0] in ('exec', 'cp')]
        self.assertTrue(calls)
        for call in calls:
            self.assertEqual(call[call.index('-c') + 1], pod['spec']['containers'][0]['name'])
        self.AssertDeleted()

    def test_image_environment_is_marshaled_literally_in_executable(self):
        image = 'registry.test/guestfs:"quote"\n$(touch injected) `touch injected` \\ end'
        self.env['BSOD_DET__GUEST_FS__CTR_IMG'] = image
        self.env['BSOD_DET__GUESTFS__NTFS_IMAGE'] = 'registry.test/legacy:ignored'
        result = self.RunRecovery(cwd=self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        pod = json.loads((self.root / 'pod.json').read_text())
        self.assertEqual(pod['spec']['containers'][0]['image'], image)
        self.assertRegex(pod['metadata']['name'], r'^guest-fs--ntfs--[0-9]+-[0-9]+$')
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
                pod = json.loads((case.root / 'pod.json').read_text())
                self.assertEqual(pod['spec']['containers'][0]['image'],
                                 'quay.io/konveyor/oadp-vmfr-access:latest')
                self.assertTrue(any(call[0] == 'exec' for call in case.Calls()))
                self.assertTrue((case.out / 'extraction-summary.json').exists())
                case.AssertDeleted()

    def test_pod_generator_and_marshaler_fail_before_resource_apply(self):
        for scenario in ('generator-error', 'generator-malformed', 'marshaler-error'):
            with self.subTest(scenario=scenario):
                case = RecoveryTests('test_success_contract')
                case.setUp()
                self.addCleanup(case.doCleanups)
                if scenario == 'marshaler-error':
                    jq = case.bin / 'jq'
                    jq.write_text('#!/usr/bin/env bash\n'
                                  'if [ "$1" = -c ]; then printf "mock marshaler failure\\n" 1>&2; exit 32; fi\n'
                                  f'exec {shutil.which("jq")} "$@"\n')
                    jq.chmod(0o755)
                result = case.RunRecovery(scenario)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertFalse((case.root / 'pod.json').exists())
                self.assertFalse((case.root / 'helper-pod').exists())
                self.assertFalse(any(call[0] in ('exec', 'cp') for call in case.Calls()))
                self.assertFalse((case.out / 'extraction-summary.json').exists())
                self.assertIn('mock apply: no objects passed', result.stderr)
                self.assertIn({'generator-error': 'mock generator failure',
                               'generator-malformed': 'parse error',
                               'marshaler-error': 'mock marshaler failure'}[scenario], result.stderr)
                case.AssertDeleted()

    def test_pod_generator_uses_quoted_static_template(self):
        result = self.RunRecovery()
        self.assertEqual(result.returncode, 0, result.stderr)
        creates = [call for call in self.Calls() if call[0] == 'create']
        self.assertEqual(creates, [['create', '-f', '-', '--dry-run=client', '-o', 'json', '--save-config']])
        template = (self.root / 'pod-template.yaml').read_text()
        fixture = Path(__file__).parent / 'fixtures/guestfs-pod-template.yaml'
        override = fixture.with_name('guestfs-resource-override.yaml').read_text()
        expectedTemplate = re.sub(r'^      resources:\n(?:        .*\n)+',
                                  ''.join('      ' + line for line in override.splitlines(True)),
                                  fixture.read_text(), count=1, flags=re.MULTILINE)
        expectedTemplate = expectedTemplate.replace('    - name: libguestfs\n', "    - name: ''\n", 1)
        self.assertEqual(template, expectedTemplate)
        self.assertIn('name: guest-fs--ntfs', template)
        self.assertIn("namespace: ''", template)
        self.assertIn("claimName: ''", template)
        self.assertIn("image: ''", template)
        self.assertIn("    - name: ''", template)
        self.assertNotIn(self.env['BSOD_DET__GUEST_FS__CTR_IMG'], template)
        pod = json.loads((self.root / 'pod.json').read_text())
        self.assertNotIn('annotations:', fixture.read_text())
        self.assertNotIn('annotations:', template)
        parsed = subprocess.run([self.env['REAL_OC'], 'create', '-f', '-',
                                 '--dry-run=client', '-o', 'json'], input=template,
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(parsed.returncode, 0, parsed.stderr)
        self.assertNotIn('annotations', json.loads(parsed.stdout)['metadata'])
        generated = subprocess.run([self.env['REAL_OC'], 'create', '-f', '-',
                                    '--dry-run=client', '-o', 'json', '--save-config'], input=template,
                                   text=True, capture_output=True, timeout=10)
        self.assertEqual(generated.returncode, 0, generated.stderr)
        expected = json.loads(generated.stdout)
        resourceBudget = {
            'requests': {'memory': '512Mi', 'cpu': '500m', 'devices.kubevirt.io/kvm': '1'},
            'limits': {'memory': '2Gi', 'cpu': '2000m', 'devices.kubevirt.io/kvm': '1'},
        }
        self.assertEqual(pod['metadata']['annotations'], expected['metadata']['annotations'])
        annotation = json.loads(expected['metadata']['annotations']['kubectl.kubernetes.io/last-applied-configuration'])
        self.assertEqual(annotation['metadata']['name'], 'guest-fs--ntfs')
        self.assertEqual(annotation['spec']['containers'][0]['name'], '')
        self.assertEqual(annotation['spec']['containers'][0]['image'], '')
        self.assertEqual(expected['spec']['containers'][0]['resources'], resourceBudget)
        expected['metadata']['name'] = pod['metadata']['name']
        expected['metadata']['namespace'] = self.metadata['namespace']
        expected['spec']['containers'][0]['name'] = 'libguestfs'
        expected['spec']['containers'][0]['image'] = self.env['BSOD_DET__GUEST_FS__CTR_IMG']
        expected['spec']['volumes'][0]['persistentVolumeClaim']['claimName'] = self.metadata['guestPvc']
        self.assertEqual(pod, expected)
        self.assertEqual(pod['metadata']['labels'], {'app': 'bsod--guest-fs--extraction'})
        spec = pod['spec']
        self.assertNotIn('nodeSelector', spec)
        self.assertNotIn('fsGroup', spec['securityContext'])
        container = spec['containers'][0]
        self.assertEqual(container['resources'], resourceBudget)
        self.assertIn({'name': 'LIBGUESTFS_BACKEND_SETTINGS', 'value': 'force_kvm'}, container['env'])
        self.assertEqual(container['volumeDevices'], [{'name': 'vm-disk', 'devicePath': '/dev/vda'}])
        self.assertEqual(container['volumeMounts'], [
            {'name': 'guest-fs--tmp', 'mountPath': '/tmp/guestfs'},
            {'name': 'guest-fs--home', 'mountPath': '/home/guestfs'},
        ])

    def test_partial_generator_failure_stops_after_apply_and_cleans(self):
        result = self.RunRecovery('generator-partial-error')
        self.assertEqual(result.returncode, 31, result.stderr)
        self.assertTrue((self.root / 'pod.json').exists())
        self.assertFalse((self.root / 'helper-pod').exists())
        self.assertFalse(any(call[0] in ('exec', 'cp') for call in self.Calls()))
        self.assertFalse((self.out / 'extraction-summary.json').exists())
        self.AssertDeleted()

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
        self.assertEqual(container['image'], self.env['BSOD_DET__GUEST_FS__CTR_IMG'])
        self.assertFalse(container['securityContext']['allowPrivilegeEscalation'])
        self.assertEqual(container['command'], ['/bin/bash', '-c'])
        self.assertEqual(container['args'], ['exec tail -f /dev/null'])
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
                                'pod/' + json.loads((self.root / 'pod.json').read_text())['metadata']['name'],
                                '--for=condition=Ready', '--timeout=180s'])
        self.assertTrue(all(call[0] in ('get', 'create', 'apply', 'exec', 'cp', '-n') for call in rawCalls))
        creates = [call for call in rawCalls if call[0] == 'create']
        self.assertEqual(creates, [['create', '-f', '-', '--dry-run=client', '-o', 'json', '--save-config']])
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
        self.assertTrue(any(call[0] == 'apply' for call in self.Calls()))
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
        self.assertEqual(reads, [
            ['get', 'vm', 'fixture-vm', '-n', 'fixture-ns', '-o', 'json'],
        ])
        rawReads = [json.loads(line) for line in (self.root / 'oc-argv.jsonl').read_text().splitlines()
                    if '"get"' in line]
        self.assertEqual(rawReads, [['-n', 'fixture-ns', 'get', 'vm/fixture-vm', '-o', 'json']])
        self.AssertDeleted()

    def test_vm_status_partial_output_does_not_propagate_producer_failure(self):
        result = self.RunRecovery('vm-api-partial')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('mock VM API unavailable', result.stderr)
        self.assertEqual([call[1] for call in self.Calls() if call[0] == 'get'], ['vm'])
        self.assertTrue((self.root / 'pod.json').exists())
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
                self.assertFalse((case.root / 'pod.json').exists())
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
                self.assertFalse(any(call[0] in ('apply', 'cp') for call in case.Calls()))
                self.assertFalse((case.root / 'helper-pod').exists())
                self.assertFalse((case.out / 'extraction-summary.json').exists())

    def test_cleanup_absent_helper_is_idempotent_and_waited(self):
        result = self.RunRecovery('helper-absent')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.AssertDeleted()

    def test_empty_helper_exit_trap_makes_no_cleanup_calls(self):
        result = self.RunRecovery('api-error')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual([call[0] for call in self.Calls()], ['get'])
        self.assertIn('Cleanup', result.stderr)
        self.assertIn('1: parameter null or not set', result.stderr)
        self.assertFalse((self.root / 'helper-pod').exists())

    def test_cleanup_error_replaces_original_failure_on_exit(self):
        mock = self.bin / 'oc'
        mock.write_text(mock.read_text().replace("scenario == 'cleanup-error'", "scenario == 'wait-error'"))
        result = self.RunRecovery('wait-error')
        self.assertEqual(result.returncode, 25, result.stderr)
        self.assertIn('mock startup timeout', result.stderr)
        self.assertIn('mock delete failure', result.stderr)
        calls = [call[0] for call in self.Calls()]
        self.assertEqual(calls[0], 'get')
        self.assertCountEqual(calls[1:3], ['create', 'apply'])
        self.assertEqual(calls[3:], ['wait', 'delete'])
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
        self.assertEqual(re.findall(r'^trap .*$', source, re.MULTILINE), ['trap \'Cleanup "${helperPod}"\' EXIT'])
        cleanup = re.search(r'^function Cleanup \(\) \{\n.*?^\}', source, re.MULTILINE | re.DOTALL).group()
        self.assertNotIn('timeout --', cleanup)
        self.assertNotIn('--wait=false', cleanup)
        self.assertNotIn('--request-timeout', cleanup)

    def test_parameterized_helper_arguments_and_native_calls(self):
        source = recovery.read_text()
        for name, arguments, expected in (
            ('Cleanup', [], 1), ('Cleanup', [''], 1),
            ('Cleanup', ['other-pod'], 0), ('Cleanup', ['other-pod', 'ignored'], 0),
            ('FindNTFS', [], 1), ('FindNTFS', ['other-pod'], 1),
            ('FindNTFS', ['', 'other-container'], 1), ('FindNTFS', ['other-pod', ''], 1),
            ('FindNTFS', ['other-pod', 'other-container'], 0),
            ('FindNTFS', ['other-pod', 'other-container', 'ignored'], 0),
        ):
            with self.subTest(name=name, arguments=arguments):
                callsFile = self.root / 'oc-argv.jsonl'
                callsFile.unlink(missing_ok=True)
                helper = re.search(r'^function ' + name + r' \(\) \{\n.*?^\}', source,
                                   re.MULTILINE | re.DOTALL).group()
                command = ('set -euxo pipefail; shopt -s inherit_errexit\n'
                           'typeset ns=fixture-ns helperPod=wrong-pod helperPodCtr=wrong-container\n'
                           + helper + '\n' + name + ' "$@"\n')
                result = subprocess.run(['bash', '-c', command, 'argument-fixture', *arguments],
                                        env=self.env, text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, expected, result.stderr)
                calls = [json.loads(line) for line in callsFile.read_text().splitlines()] if callsFile.exists() else []
                if expected:
                    self.assertEqual(calls, [])
                    self.assertIn('parameter null or not set', result.stderr)
                elif name == 'Cleanup':
                    self.assertEqual(calls, [
                        ['-n', 'fixture-ns', 'delete', 'pod/other-pod', '--ignore-not-found'],
                        ['-n', 'fixture-ns', 'wait', 'pod/other-pod', '--for=delete', '--timeout=60s'],
                    ])
                else:
                    self.assertEqual(calls, [[
                        '-n', 'fixture-ns', 'exec', 'other-pod', '-c', 'other-container', '--',
                        'guestfish', '--ro', '-a', '/dev/vda', 'run', ':', 'list-filesystems',
                    ]])
                    self.assertEqual(result.stdout, '/dev/sda2\n/dev/sda3\n/dev/sda4\n')

    def test_parameterized_helpers_have_direct_main_and_exit_callers(self):
        source = recovery.read_text()
        self.assertIn('done 0< <(FindNTFS "${helperPod}" "${helperPodCtr}")', source)
        self.assertIn('\nCleanup "${helperPod}"\n', source)
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
        pod = json.loads((self.root / 'pod.json').read_text())
        self.assertEqual(pod['spec']['containers'][0]['image'],
                         'quay.io/konveyor/oadp-vmfr-access:latest')
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
        pod = json.loads((self.root / 'pod.json').read_text())
        self.assertEqual(pod['spec']['containers'][0]['image'],
                         'quay.io/konveyor/oadp-vmfr-access:latest')
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

    def test_failed_apply_stops_before_extraction(self):
        result = self.RunRecovery('apply-error')
        self.assertNotEqual(result.returncode, 0, result.stderr)
        calls = [call[0] for call in self.Calls()]
        self.assertEqual(calls[0], 'get')
        self.assertCountEqual(calls[1:3], ['create', 'apply'])
        self.assertEqual(calls[3:], ['delete', 'wait'])
        self.AssertDeleted()
        self.assertFalse((self.root / 'helper-pod').exists())

    def test_unsafe_inputs_never_apply(self):
        for scenario in ('api-error', 'bad-json', 'vm-status-Running', 'vm-status-Starting', 'stale'):
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
        pod = json.loads((self.root / 'pod.json').read_text())
        self.assertEqual(pod['spec']['volumes'][0]['persistentVolumeClaim']['claimName'], 'rootdisk')
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
                        'args = sys.argv[1:]\nif args[0] == "apply": print("mock native stdout")\n'
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
    setUp = RecoveryTests.setUp
    RunRecovery = RecoveryTests.RunRecovery
    Calls = RecoveryTests.Calls
    AssertDeleted = RecoveryTests.AssertDeleted

    def ArchiveContents(self):
        archive = self.out / 'guest-fs--crash-info.tgz'
        self.assertEqual(archive.stat().st_mode & 0o777, 0o600)
        with tarfile.open(archive, 'r:gz') as payload:
            return {member.name.removeprefix('./'): payload.extractfile(member).read()
                    for member in payload.getmembers() if member.isfile()}

    def AssertDeferredValidator(self, result):
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertFalse(list(self.out.rglob('*.evtx')))
        self.assertFalse(list(self.out.glob('guestFS_*')))
        self.assertFalse(any(call[0] == 'cp' for call in self.Calls()))
        pod = json.loads((self.root / 'pod.json').read_text())
        for call in self.Calls():
            if call[0] == 'exec':
                self.assertEqual(call[3].removeprefix('pod/'), pod['metadata']['name'])
                self.assertEqual(call[call.index('-c') + 1], pod['spec']['containers'][0]['name'])
        summary = json.loads((self.out / 'extraction-summary.json').read_text())
        self.assertFalse(summary['ok'])
        self.assertEqual(summary['missingRequiredArtifactTypes'], ['evtx'])
        self.assertEqual(summary['invalidArtifacts'], [])
        check = subprocess.run(['sha256sum', '-c', 'checksums.sha256'], cwd=self.out,
                               text=True, capture_output=True)
        self.assertEqual(check.returncode, 0, check.stderr)
        self.AssertDeleted()

    def test_archive_contains_only_requested_files_and_validator_remains_deferred(self):
        result = self.RunRecovery()
        self.AssertDeferredValidator(result)
        content = self.ArchiveContents()
        expected = {f'Windows/System32/winevt/Logs/{name}.evtx': (self.root / 'fixture.evtx').read_bytes()
                    for name in ('System', 'Application')}
        self.assertEqual(content, expected)

    def test_helper_filesystem_mkdir_test_and_timestamp_path(self):
        result = self.RunRecovery()
        self.AssertDeferredValidator(result)
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
        self.AssertDeferredValidator(result)
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
                case.AssertDeferredValidator(result)
                self.assertEqual(list(case.ArchiveContents()), ['Windows/System32/winevt/Logs/' + expected])

    def test_failed_copies_can_leave_an_empty_archive_not_success(self):
        result = self.RunRecovery('copy-error')
        self.AssertDeferredValidator(result)
        self.assertEqual(self.ArchiveContents(), {})

    def test_remote_mkdir_failure_does_not_create_runner_destination(self):
        result = self.RunRecovery('mkdir-error')
        self.AssertDeferredValidator(result)
        self.assertFalse((self.out / 'guest-fs--crash-info.tgz').exists())
        self.assertFalse(any('tar' in call for call in self.Calls()))
        self.assertFalse(list((self.root / 'helper-fs').rglob('*.evtx')))

    def test_helper_directory_test_failure_prevents_tar(self):
        result = self.RunRecovery('helper-test-error')
        self.AssertDeferredValidator(result)
        self.assertFalse((self.out / 'guest-fs--crash-info.tgz').exists())
        self.assertFalse(any('tar' in call for call in self.Calls()))

    def test_tar_failure_keeps_status_partial_archive_and_cleans_helper(self):
        result = self.RunRecovery('tar-error')
        self.assertEqual(result.returncode, 35, result.stderr)
        self.assertEqual((self.out / 'guest-fs--crash-info.tgz').read_bytes(), b'partial archive')
        self.assertFalse((self.out / 'extraction-summary.json').exists())
        self.AssertDeleted()

    def test_native_wait_apply_and_cleanup_failures_remain_nonzero(self):
        for scenario, expected in (('wait-error', 19), ('apply-error', 18), ('cleanup-error', 25), ('cleanup-wait-error', 28)):
            with self.subTest(scenario=scenario):
                case = ArchiveRecoveryTests('test_archive_contains_only_requested_files_and_validator_remains_deferred')
                case.setUp()
                self.addCleanup(case.doCleanups)
                result = case.RunRecovery(scenario)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertFalse((case.out / 'extraction-summary.json').exists())
                self.assertTrue(any(call[0] == 'delete' for call in case.Calls()))
                if scenario in ('wait-error', 'apply-error'):
                    self.assertFalse(any(call[0] == 'exec' for call in case.Calls()))
                    self.assertFalse((case.out / 'guest-fs--crash-info.tgz').exists())

    def test_failed_discovery_still_cleans_without_copy_or_archive(self):
        result = self.RunRecovery('discovery-error')
        self.AssertDeferredValidator(result)
        self.assertFalse((self.out / 'guest-fs--crash-info.tgz').exists())
        self.assertFalse(any(call[0] == 'exec' and 'bash' in call for call in self.Calls()))

    def test_actual_watcher_consumer_propagates_deferred_validator_failure(self):
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
        self.AssertDeferredValidator(result)
        self.assertEqual(len(self.ArchiveContents()), 2)

    def test_actual_container_consumer_propagates_deferred_validator_failure(self):
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
        self.AssertDeferredValidator(result)
        self.assertEqual(len(self.ArchiveContents()), 2)


if __name__ == '__main__':
    unittest.main()
