import json
import re
import subprocess
import sys
import tarfile
import unittest
import zlib
from pathlib import Path

if __package__:
    from . import test_recovery as fixtures
else:
    import test_recovery as fixtures


guestfish = r'''
import json, os, shutil, sys
from pathlib import Path
root = Path(os.environ['MOCK_ROOT'])
args = sys.argv[1:]
with (root / 'helper-argv.jsonl').open('a') as calls:
    calls.write(json.dumps(['guestfish', *args]) + '\n')
assert args[:2] == ['-ra', '/dev/vda']
assert args[args.index('mount-ro') + 1] == '/dev/sda3'
assert args[-2:] == [':', 'umount-all']
index = args.index('copy-out')
source, parent = args[index + 1:index + 3]
assert source.startswith('/') and not source.endswith('/')
origin = root / 'guest-disk' / source.lstrip('/')
destination = root / 'helper-fs' / parent.lstrip('/')
assert destination.is_dir()
if not origin.exists() or source == os.environ.get('FAIL_SOURCE'):
    sys.exit(22)
destination /= origin.name
if origin.is_dir():
    shutil.copytree(origin, destination, dirs_exist_ok=True)
else:
    shutil.copy2(origin, destination)
'''

move = r'''
import json, os, subprocess, sys
from pathlib import Path
root = Path(os.environ['MOCK_ROOT'])
args = sys.argv[1:]
assert args[:2] == ['-T', '--']
with (root / 'helper-argv.jsonl').open('a') as calls:
    calls.write(json.dumps(['mv', *args]) + '\n')
paths = [str(root / 'helper-fs' / value.lstrip('/')) for value in args[2:]]
sys.exit(subprocess.run(['/usr/bin/mv', '-T', '--', *paths]).returncode)
'''


class RecursiveMappingTests(unittest.TestCase):
    RunRecovery = fixtures.RecoveryTests.RunRecovery
    Calls = fixtures.RecoveryTests.Calls

    def setUp(self):
        fixtures.RecoveryTests.setUp(self)
        self.disk = self.root / 'guest-disk'
        self.disk.mkdir()
        for name, body in (('guestfish', guestfish), ('mv', move)):
            command = self.root / 'helper-bin' / name
            command.write_text(f'#!{sys.executable}\n' + body)
            command.chmod(0o755)
        python = self.bin / 'python3'
        python.write_text(f'#!{sys.executable}\nimport os, sys\n'
                         'from pathlib import Path\n'
                         'if any(arg.endswith("/reliability.py") for arg in sys.argv[1:]):\n'
                         '    Path(os.environ["MOCK_ROOT"], "reliability-invoked").touch()\n'
                         f'os.execv({sys.executable!r}, [{sys.executable!r}, *sys.argv[1:]])\n')
        python.chmod(0o755)
        self.files = {'pagefile.sys': b'RAW PAGEFILE NOT A CONVERTED DUMP',
                      'Windows/System32/winevt/Logs/System.evtx': b'system fixture',
                      'Windows/System32/winevt/Logs/Application.evtx': b'application fixture'}
        for name, content in self.files.items():
            self.WriteGuest(name, content)

    def WriteGuest(self, name, content):
        path = self.disk / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)

    def MappedScript(self, mapping):
        source = fixtures.recovery.read_text()
        entries = '\n'.join(f"    ['{key}']='{value}'" for key, value in mapping.items())
        source, count = re.subn(r'typeset -A fileArr=\(\n.*?\n\)',
                               'typeset -A fileArr=(\n' + entries + '\n)', source,
                               count=1, flags=re.DOTALL)
        self.assertEqual(count, 1)
        script = self.root / fixtures.recovery.name
        script.write_text(source)
        script.chmod(0o755)
        return script

    def Contents(self):
        archive = self.out / 'guest-fs--crash-info--sda3.tgz'
        self.assertEqual(archive.stat().st_mode & 0o777, 0o600)
        with tarfile.open(archive) as payload:
            return {entry.name.removeprefix('./'): payload.extractfile(entry).read()
                    for entry in payload if entry.isfile()}

    def AssertCompleted(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ('parse-dump-header.json', 'events.json', 'checksums.sha256',
                     'checksums.sha256.tmp', 'extraction-summary.json'):
            self.assertFalse((self.out / name).exists(), name)
        self.assertFalse((self.root / 'reliability-invoked').exists())
        self.assertEqual(len([call for call in self.Calls() if call[0] == 'delete']), 1)
        self.assertFalse((self.root / 'helper-pod').exists())
        self.assertFalse(list(self.out.rglob('*.evtx')))

    def test_default_mapping_raw_pagefile_archive_and_no_generated_reports(self):
        before = (self.out / 'vm-memory.elf').read_bytes()
        self.AssertCompleted(self.RunRecovery())
        expected = dict(self.files)
        expected['MEMORY.DMP'] = expected.pop('pagefile.sys')
        self.assertEqual(self.Contents(), expected)
        self.assertEqual((self.out / 'vm-memory.elf').read_bytes(), before)

    def test_files_directories_slashes_spaces_dotfiles_and_same_basename(self):
        for source, destination in (('/foo/bar', '/foo/new'), ('foo/bar/', 'foo/new/'),
                                    ('/foo/bar///', '/foo/new///'), ('foo/bar', ''),
                                    ('/foo/bar/', '/other/bar/')):
            for directory in (False, True):
                with self.subTest(source=source, destination=destination, directory=directory):
                    case = RecursiveMappingTests('test_default_mapping_raw_pagefile_archive_and_no_generated_reports')
                    case.setUp()
                    self.addCleanup(case.doCleanups)
                    children = {'nested/space file': b'child', '.hidden': b'dot'} if directory else {'': b'file'}
                    for child, content in children.items():
                        case.WriteGuest('foo/bar' + ('/' + child if child else ''), content)
                    result = case.RunRecovery(script=case.MappedScript({source: destination}))
                    case.AssertCompleted(result)
                    final = (destination or source).strip('/')
                    self.assertEqual(case.Contents(), {final + ('/' + child if child else ''): content
                                                      for child, content in children.items()})

    def test_space_paths_and_mapping_lookup_before_normalization(self):
        self.WriteGuest('space dir/file name', b'spaces')
        script = self.MappedScript({'space dir/file name/': '/new dir/new name/'})
        self.AssertCompleted(self.RunRecovery(script=script))
        self.assertEqual(self.Contents(), {'new dir/new name': b'spaces'})

    def test_missing_item_does_not_prevent_other_copies(self):
        (self.disk / 'pagefile.sys').unlink()
        self.AssertCompleted(self.RunRecovery())
        self.assertEqual(self.Contents(), {key: value for key, value in self.files.items() if key != 'pagefile.sys'})

    def test_partition_archive_replaces_existing_archive_with_one_gzip_member(self):
        archive = self.out / 'guest-fs--crash-info--sda3.tgz'
        archive.write_bytes(b'previous archive bytes')
        archive.chmod(0o600)
        self.AssertCompleted(self.RunRecovery())
        decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
        decoder.decompress(archive.read_bytes())
        self.assertTrue(decoder.eof)
        self.assertEqual(decoder.unused_data, b'')
        self.assertEqual(len(self.Contents()), 3)

    def test_failed_copy_never_renames_preexisting_unrelated_artifact(self):
        source = fixtures.recovery.read_text()
        remote = re.search(r"bash -o pipefail -O inherit_errexit -euxc '(.*?)' ''", source, re.DOTALL).group(1)
        parent = '/tmp/mapping-fixture'
        physical = self.root / 'helper-fs' / parent.lstrip('/')
        physical.mkdir(parents=True)
        sentinel = physical / 'pagefile.sys'
        sentinel.write_bytes(b'unrelated preexisting bytes')
        env = dict(self.env, PATH=str(self.root / 'helper-bin') + ':' + self.env['PATH'],
                   FAIL_SOURCE='/pagefile.sys')
        result = subprocess.run(['bash', '-o', 'pipefail', '-O', 'inherit_errexit', '-euxc',
                                 remote, '', '/dev/sda3', '/pagefile.sys', parent + '/MEMORY.DMP'],
                                env=env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 22, result.stderr)
        self.assertEqual(sentinel.read_bytes(), b'unrelated preexisting bytes')
        self.assertFalse((physical / 'MEMORY.DMP').exists())
        self.assertNotIn('"mv"', (self.root / 'helper-argv.jsonl').read_text())

    def test_helper_filesystem_is_separate_and_readonly(self):
        self.AssertCompleted(self.RunRecovery())
        calls = [json.loads(line) for line in (self.root / 'helper-argv.jsonl').read_text().splitlines()]
        copies = [call for call in calls if call[0] == 'guestfish']
        self.assertEqual(len(copies), 3)
        self.assertEqual(len([call for call in calls if call[0] == 'mv']), 1)
        for call in copies:
            self.assertEqual(call[1:3], ['-ra', '/dev/vda'])
            self.assertIn('mount-ro', call)
            destination = call[call.index('copy-out') + 2]
            self.assertRegex(destination, r'^/tmp/bsod--guest-files--[0-9]+(?:/.*)?$')
            self.assertFalse(Path(destination).exists())
        self.assertEqual({key: (self.disk / key).read_bytes() for key in self.files}, self.files)

    def test_existing_outputs_are_not_rewritten_or_validated(self):
        names = ('events.json', 'parse-dump-header.json', 'checksums.sha256',
                 'stage-errors.jsonl', 'extraction-summary.json', 'watcher.log')
        for name in names:
            (self.out / name).write_text('preserve invalid existing ' + name)
        before = {name: (self.out / name).read_bytes() for name in names}
        result = self.RunRecovery()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual({name: (self.out / name).read_bytes() for name in names}, before)
        self.assertEqual(len(self.Contents()), 3)

    def test_native_failure_and_cleanup_contracts(self):
        for scenario, status in (('api-error', 1), ('wait-error', 19), ('apply-error', 18),
                                 ('cleanup-error', 25), ('cleanup-wait-error', 28), ('tar-error', 35)):
            with self.subTest(scenario=scenario):
                case = RecursiveMappingTests('test_default_mapping_raw_pagefile_archive_and_no_generated_reports')
                case.setUp()
                self.addCleanup(case.doCleanups)
                result = case.RunRecovery(scenario)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual(len([call for call in case.Calls() if call[0] == 'delete']), 1)

    def test_actual_watcher_and_container_dispatch(self):
        watcher = (fixtures.hostDir / 'watch-crash.sh').read_text()
        runTimed = re.search(r'^function RunTimed \(\) \{.*\}$', watcher, re.MULTILINE).group()
        recover = re.search(r'^function Recover \(\) \{\n.*?^\}', watcher, re.MULTILINE | re.DOTALL).group()
        command = ('set -euxo pipefail; shopt -s inherit_errexit\n'
                   'typeset scriptDir="${1}" metadataFile="${2}" pipelineLog="${3}"\n'
                   + runTimed + '\n' + recover + '\nRecover\n')
        self.meta.write_text(json.dumps(self.metadata))
        result = subprocess.run(['bash', '-c', command, '', str(fixtures.hostDir),
                                 str(self.meta), str(self.root / 'watcher.log')],
                                env=self.env, text=True, capture_output=True, timeout=10)
        self.AssertCompleted(result)
        self.assertEqual(len(self.Contents()), 3)
        entrypoint = fixtures.hostDir.parents[4] / 'image/container/bsod-detector/entrypoint.sh'
        text = entrypoint.read_text().replace('exec /usr/local/bin/extract--guest-os--crash-info.sh',
                                             'exec ' + str(fixtures.recovery))
        self.assertNotEqual(text, entrypoint.read_text())
        result = subprocess.run(['bash', '-c', text, '', '--metadata', str(self.meta)],
                                env=dict(self.env, MODE='recover', EVIDENCE_DIR=str(self.out)),
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.Contents()), 3)


if __name__ == '__main__':
    unittest.main()
