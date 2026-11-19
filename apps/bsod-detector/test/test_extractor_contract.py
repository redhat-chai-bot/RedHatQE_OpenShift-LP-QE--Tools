#!/usr/bin/env python3
'''Behavioral contract: preflight-rhov.sh requires the guest OS extractor.

``preflight-rhov.sh`` checks that ``extract--guest-os--crash-info.sh`` is present
next to it before it runs any required tool, because ``watch-crash.sh`` later
runs that extractor for recovery. These tests copy the host script directory
into an isolated mirror and run the real preflight script there. ``PATH``
contains only stub commands for the tools preflight requires (each records its
call and fails) plus links to the real ``bash`` and ``dirname``, the only
external commands preflight runs before its helper check. No cluster, VM or
network is touched.

Asserted behavior:

* extractor missing: preflight exits 1, names the missing extractor, stops
  there without reaching its next check, and runs none of the stubbed tools;
* extractor present (control): preflight passes the helper check and exits 1 at
  the next check, the guest configuration inputs, which the mirror omits.

Out of scope here, because existing tests exercise it:

* direct execution of the extractor (presence, executable mode, interpreter
  line, ``--help``): ``test_recovery.py`` executes the extractor by path, for
  example in ``test_Extractor_HelpSucceedsAndRejectsUnknownOrRemovedOptions``;
* the watcher's call into the extractor: ``test_recovery.py`` and
  ``test_recursive_mapping.py`` run ``watch-crash.sh``'s ``Recover`` function
  against the real extractor.

Limits: ``requiredTools`` mirrors the tools preflight requires before its helper
check. If preflight starts requiring another tool, or runs another external
command through ``PATH`` before that check, the hermetic ``PATH`` makes the run
stop early and these tests fail with preflight's output in the message. A
command called by absolute path is not caught. Moving the guest configuration
check ahead of the helper check also fails these tests, although preflight
would still fail closed. They do not show that a full preflight run succeeds.
'''

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


hostDir = Path(__file__).resolve().parents[1] / 'src' / 'scripts' / 'host'
extractorName = 'extract--guest-os--crash-info.sh'
preflightName = 'preflight-rhov.sh'
requiredTools = ('oc', 'virtctl', 'jq', 'python3', 'sha256sum', 'findmnt', 'timeout', 'realpath', 'sync')
realCommands = ('bash', 'dirname')
guestConfigError = 'preflight-rhov: ERROR: guest configuration inputs are missing'
stubScript = '''#!/bin/sh
printf '%s\\n' "${0##*/} $*" >> "${STUB_LOG}"
exit 97
'''


class PreflightExtractorHelperTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix='extractor contract ')
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        # Same depth as the repository, so preflight resolves its app directory inside the mirror.
        self.mirrorDir = self.root / 'apps' / 'bsod-detector' / 'src' / 'scripts' / 'host'
        self.mirrorDir.mkdir(parents=True)
        self.stubDir = self.root / 'stub-bin'
        self.stubDir.mkdir()
        self.stubLog = self.root / 'stub-calls.log'
        for tool in requiredTools:
            stub = self.stubDir / tool
            stub.write_text(stubScript, encoding='utf-8')
            stub.chmod(0o755)
        for command in realCommands:
            realPath = shutil.which(command)
            self.assertIsNotNone(realPath, f'{command} is required to run {preflightName}')
            (self.stubDir / command).symlink_to(realPath)
        self.missingHelperError = f'preflight-rhov: ERROR: required helper missing: {self.mirrorDir / extractorName}'

    def MirrorHostScripts(self, omit=()):
        for source in sorted(hostDir.iterdir()):
            if source.is_file() and source.name not in omit:
                shutil.copy2(source, self.mirrorDir / source.name)

    def RunPreflight(self):
        args = ['--ns', 'fixture-ns', '--vm', 'fixture-vm',
                '--out', str(self.root / 'run'), '--metadata', str(self.root / 'run' / 'metadata.json'),
                '--run-id', 'fixture-run-001', '--evidence-mount', str(self.root / 'evidence'),
                '--evidence-volume-kind', 'pvc', '--evidence-storage-id', 'fixture-storage-id',
                '--snap-class', 'fixture-snapshot-class',
                '--recovery-image', 'registry.test/recovery@sha256:' + 'a' * 64,
                '--memory-dump-pvc', 'fixture-memory-dump']
        env = {'PATH': str(self.stubDir), 'HOME': str(self.root), 'LC_ALL': 'C', 'STUB_LOG': str(self.stubLog)}
        return subprocess.run([str(self.mirrorDir / preflightName), *args], cwd=self.root, env=env,
                              capture_output=True, encoding='utf-8', timeout=30)

    def StubCalls(self):
        return self.stubLog.read_text(encoding='utf-8').splitlines() if self.stubLog.exists() else []

    def test_Preflight_MissingExtractorFailsBeforeRunningRequiredTools(self):
        self.MirrorHostScripts(omit=(extractorName,))
        result = self.RunPreflight()
        lines = result.stderr.splitlines()
        with self.subTest(check='exit status'):
            self.assertEqual(result.returncode, 1, f'unexpected exit status; stderr:\n{result.stderr}')
        with self.subTest(check='diagnostic names the extractor'):
            self.assertIn(self.missingHelperError, lines,
                          f'missing-helper error not reported; stderr:\n{result.stderr}')
        with self.subTest(check='stopped at the helper check'):
            self.assertNotIn(guestConfigError, lines,
                             f'preflight continued past the missing extractor; stderr:\n{result.stderr}')
        with self.subTest(check='no stubbed tool ran'):
            self.assertEqual(self.StubCalls(), [],
                             'preflight ran a required tool before rejecting the missing extractor')

    def test_Preflight_PresentExtractorPassesHelperCheck(self):
        self.MirrorHostScripts()
        result = self.RunPreflight()
        lines = result.stderr.splitlines()
        with self.subTest(check='exit status'):
            self.assertEqual(result.returncode, 1, f'unexpected exit status; stderr:\n{result.stderr}')
        with self.subTest(check='extractor accepted'):
            self.assertNotIn(self.missingHelperError, lines,
                             f'preflight rejected a present extractor; stderr:\n{result.stderr}')
        # The guest configuration check follows the helper check; reaching it shows the helper check passed.
        with self.subTest(check='reached the next check'):
            self.assertIn(guestConfigError, lines,
                          f'preflight stopped somewhere other than the next check; stderr:\n{result.stderr}')
        with self.subTest(check='no stubbed tool ran'):
            self.assertEqual(self.StubCalls(), [], 'preflight ran a required tool before its guest configuration check')


if __name__ == '__main__':
    unittest.main()
