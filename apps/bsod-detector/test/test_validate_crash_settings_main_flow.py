#!/usr/bin/env python3
"""The validate-crash-settings.ps1 top-level flow, run with every command mocked.

The flow runs in the harness's isolated runspace under the script's own strict mode, with the real
helper functions next to the mocks; no registry, CIM, file-system or reboot write is reachable.
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import validator_test_utils as Utils  # noqa: E402


class ValidatorMainFlowTests(unittest.TestCase):
    """The validator's top-level statements, run in order with every command mocked.

    The pure helpers run unchanged next to the mocks; registry reads come from an in-memory
    registry. The script's own `Set-StrictMode -Version Latest` runs through the real cmdlet the
    harness provides, so the flow runs in strict mode (pwsh 7.4 rules; a Windows PowerShell 5.1
    run remains authoritative). No mock for a registry, CIM or reboot write exists, so any such
    call would fail the run.
    """

    VALID = {'crashControl': Utils.GOLDEN_IMAGE, 'pagingFiles': ['C:\\pagefile.sys 16641 16641']}

    def RunScript(self, states: list[dict]) -> list[list[str]]:
        """Mock logs of the validator flow, one per mock state."""
        scriptText = Utils.SCRIPT.read_text(encoding='ascii')
        helperTexts = []
        for name in Utils.SCRIPT_FUNCTIONS:
            definition = Utils.RunHarness(self, 'definition', name)
            self.assertTrue(definition['found'], name)
            self.assertEqual(scriptText.count(definition['text']), 1, name)
            scriptText = scriptText.replace(definition['text'], '')
            if name in Utils.REAL_HELPERS:
                helperTexts.append(definition['text'])
        body = scriptText[scriptText.index('Set-StrictMode -Version Latest'):]
        self.assertNotRegex(body, r'(?mi)^\s*exit\b')
        # The script's camelCase parameters, set as the guest-agent call would bind them.
        preamble = ("$dumpType = @($global:MockState['dumpType'])[0]\n"
                    "$stageNotMyFault = $global:MockState['stage'] -contains 'true'\n"
                    "$dataFile = 'C:\\Windows\\Temp\\crash-control.json'\n")
        with tempfile.TemporaryDirectory() as tmpDir:
            flowPath = Path(tmpDir) / 'main-flow.ps1'
            mocksPath = Path(tmpDir) / 'main-flow-mocks.ps1'
            flowPath.write_text('function Invoke-MainFlow {\ntry {\n' + preamble + body +
                                '\n} catch { if ("$_" -ne \'script-exit\') { Write-FlowError "$_" } }\n}\n', encoding='ascii')
            mocksPath.write_text(Utils.MainFlowMocks() + '\n' + '\n'.join(helperTexts) + '\n', encoding='ascii')
            calls = [{'state': dict(self.VALID, **state), 'args': []} for state in states]
            return [result['log'] for result in Utils.RunHarness(self, 'mockcall', 'Invoke-MainFlow', calls,
                                                           scriptPath=flowPath, mocksPath=mocksPath)]

    @staticmethod
    def Json(log: list[str]) -> str | None:
        lines = [line for line in log if line.startswith('json ')]
        return lines[0] if len(lines) == 1 else None

    def test_MainFlow_MatchingGoldenImageValidatesWithoutStaging(self) -> None:
        log = self.RunScript([{}])[0]
        desired = ','.join(json.loads(Utils.DATA_FILE.read_text(encoding='utf-8'))['recommended']['values'])
        self.assertEqual(self.Json(log), f'json action=validated match=True issues= adequate=True requiredMB=16641 nmf=not requested desired={desired}')
        self.assertFalse([line for line in log if line.startswith(('staging', 'stderr', 'fail', 'error'))], log)

    def test_MainFlow_ReportsEveryMismatchKindWithoutChanges(self) -> None:
        cases = [
            ({'crashControl': [entry for entry in Utils.GOLDEN_IMAGE if not entry.startswith('AutoReboot')]}, 'AutoReboot:missing'),
            ({'crashControl': [entry if not entry.startswith('CrashDumpEnabled') else 'CrashDumpEnabled=2' for entry in Utils.GOLDEN_IMAGE]}, 'CrashDumpEnabled:wrong value'),
            ({'kind': ['DumpFile=String']}, 'DumpFile:wrong type'),
            ({'kind': ['Overwrite=String']}, 'Overwrite:wrong type'),
            ({'crashControl': Utils.GOLDEN_IMAGE + ['DedicatedDumpFile=C:\\DedicatedDump.sys']}, 'DedicatedDumpFile:must be absent'),
        ]
        for (state, issue), log in zip(cases, self.RunScript([state for state, _ in cases])):
            with self.subTest(issue=issue):
                self.assertIn(' match=False ', self.Json(log))
                self.assertIn(f'issues={issue} ', self.Json(log))
        keyMissing = self.RunScript([{'keyMissing': ['true']}])[0]
        self.assertIn(f'issues={Utils.CRASH_CONTROL}:key missing,CrashDumpEnabled:missing,', self.Json(keyMissing))

    def test_MainFlow_OlderDataStillRequiresDedicatedDumpFileAbsent(self) -> None:
        log = self.RunScript([{'data': ['old'], 'crashControl': Utils.GOLDEN_IMAGE + ['DedicatedDumpFile=C:\\DedicatedDump.sys']}])[0]
        self.assertIn('stderr WARN: crash-control.json still recommends DedicatedDumpFile; it is validated as must-be-absent instead', log)
        self.assertIn('issues=DedicatedDumpFile:must be absent ', self.Json(log))
        self.assertNotIn('DedicatedDumpFile', self.Json(log).split('desired=')[1])

    def test_MainFlow_IntentionalRunStagesTheLatestNotMyFault(self) -> None:
        staged, failed = self.RunScript([{'stage': ['true']}, {'stage': ['true'], 'stagingFails': ['true']}])
        self.assertIn(f'staging {Utils.NMF_SOURCE}', staged)
        self.assertIn(' nmf=staged ', self.Json(staged))
        self.assertIn('fail 4 NotMyFault could not be staged: signature status NotSigned, signer none', failed)
        self.assertIn(' nmf=failed ', self.Json(failed))

    def test_MainFlow_StagingFailureKeepsMismatchesVisible(self) -> None:
        state = {'stage': ['true'], 'stagingFails': ['true'],
                 'crashControl': [entry for entry in Utils.GOLDEN_IMAGE if not entry.startswith('AutoReboot')], 'pagingFiles': ['?:\\pagefile.sys']}
        log = self.RunScript([state])[0]
        self.assertIn('fail 4 NotMyFault could not be staged: signature status NotSigned, signer none', log)
        self.assertIn(' match=False issues=AutoReboot:missing adequate=False ', self.Json(log))
        self.assertIn(' nmf=failed ', self.Json(log))
        self.assertLess(log.index(next(line for line in log if line.startswith('fail 4'))), log.index(self.Json(log)))

    def test_MainFlow_UnknownDumpTypeFailsAndInvalidMemoryWarns(self) -> None:
        unknown = self.RunScript([{'dumpType': ['small']}])[0]
        self.assertTrue([line for line in unknown if line.startswith("fail 2 Unknown dump type 'small'")], unknown)
        for memory in ('error', '0'):
            with self.subTest(memory=memory):
                log = self.RunScript([{'memory': [memory]}])[0]
                self.assertTrue([line for line in log if line.startswith('stderr WARN: ') and 'physical memory size' in line], log)
                self.assertIn(' adequate=False requiredMB= ', self.Json(log))

if __name__ == '__main__':
    unittest.main()
