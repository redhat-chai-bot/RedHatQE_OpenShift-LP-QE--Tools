#!/usr/bin/env python3
'''Offline tests for the guest-agent.py `put` usage check.

guest-agent.py runs as a subprocess with PATH holding only a stub `oc` that records every call, and with
a target that would need `oc get pod` to resolve, so a usage error is shown to stop before the cluster is
contacted. No cluster, VM or guest is contacted.

Naming follows the team guide: camelCase variables and module constants, PascalCase helpers and single
quotes. Technical exceptions: unittest only discovers methods starting with `test` and calls the `setUp`
hook; standard library names, the guest-agent.py CLI and environment variable names are used as defined.
The stub `oc` is a POSIX `#!/bin/sh` script without errexit/xtrace: it only appends its arguments to a log.
'''
from __future__ import annotations

import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

guestAgentScript = Path(__file__).resolve().parent.parent / 'src' / 'scripts' / 'host' / 'guest-agent.py'


class GuestAgentPutUsageTests(unittest.TestCase):
    '''An incomplete `put` is a usage error: exit 2, one usage line on stderr, no traceback, no `oc` call.'''

    def setUp(self) -> None:
        tmpDir = tempfile.TemporaryDirectory()
        self.addCleanup(tmpDir.cleanup)
        self.workDir = Path(tmpDir.name)
        binDir = self.workDir / 'bin'
        binDir.mkdir()
        self.ocLog = self.workDir / 'oc-calls.log'
        ocStub = binDir / 'oc'
        ocStub.write_text(f'#!/bin/sh\necho "$@" >> {shlex.quote(str(self.ocLog))}\nexit 97\n')
        ocStub.chmod(0o755)
        # The Pod name is unset on purpose: resolving the target would call `oc get pod`.
        self.runEnv = {'PATH': str(binDir), 'BSOD_DET__NAMESPACE': 'ns', 'BSOD_DET__VM__NAME': 'vm'}

    def testIncompletePutIsAUsageError(self) -> None:
        (self.workDir / 'payload.bin').write_bytes(b'data')
        for cliArgs in (('put',), ('put', 'payload.bin')):
            with self.subTest(cliArgs=cliArgs):
                cliRun = subprocess.run(
                    [sys.executable, '-I', str(guestAgentScript), *cliArgs], cwd=self.workDir, env=self.runEnv,
                    stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60, check=False)
                self.assertEqual((cliRun.returncode, cliRun.stdout, cliRun.stderr),
                                 (2, '', 'put requires a local path and a guest path\n'))
                self.assertFalse(self.ocLog.exists(), 'guest-agent.py called oc')


if __name__ == '__main__':
    unittest.main()
