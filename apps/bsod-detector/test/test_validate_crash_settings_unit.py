#!/usr/bin/env python3
"""Isolated unit tests of single validate-crash-settings.ps1 functions.

Each function runs in fixtures/ps-function-harness.ps1's isolated runspace: only test-supplied mocks,
pure validator helpers and Set-StrictMode can be called, so no registry, file, network or process is reached.
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import validator_test_utils as Utils  # noqa: E402


class ValidatorHelperUnitTests(unittest.TestCase):
    """Single validator functions in the harness's isolated runspace.

    Every command they call is a test mock; pure validator helpers they use (no I/O) run unchanged.
    """

    def test_GetPagefileSizeMB_MatchesTheGoldenImageSize(self) -> None:
        ramValues = list(Utils.PAGEFILE_SIZES_MB)
        sizes = Utils.RunHarness(self, 'call', 'Get-PagefileSizeMB', [[ram] for ram in ramValues])
        self.assertEqual(dict(zip(ramValues, sizes)), Utils.PAGEFILE_SIZES_MB)

    def test_TestPageFileAdequate_AcceptsOnlyLargeEnoughCdriveEntries(self) -> None:
        cases = [
            ([[], 16641], False),
            ([['?:\\pagefile.sys'], 16641], False),
            ([['C:\\pagefile.sys 0 0'], 16641], False),
            ([['C:\\pagefile.sys 4096 4096'], 16641], False),
            ([['C:\\pagefile.sys 16641 16641'], 16641], True),
            ([['C:\\pagefile.sys 2048 16641'], 16641], False),
            ([['D:\\pagefile.sys 16641 16641'], 16641], False),
            ([['C:\\pagefile.sys 16641 16641'], None], False),
        ]
        results = Utils.RunHarness(self, 'call', 'Test-PageFileAdequate', [args for args, _ in cases])
        self.assertEqual(results, [expected for _, expected in cases])

    def test_GetHTTPSredirectTarget_StaysOnTheOfficialHostOverHTTPS(self) -> None:
        host = 'fedorapeople.org'
        cases = [
            (['http://fedorapeople.org/a/b.iso', host], 'https://fedorapeople.org/a/b.iso'),
            (['https://fedorapeople.org/a/b.iso?x=1', host], 'https://fedorapeople.org/a/b.iso?x=1'),
            (['https://evil.example/a/b.iso', host], None),
            (['http://fedorapeople.org.evil.example/a.iso', host], None),
            (['ftp://fedorapeople.org/a.iso', host], None),
            (['/relative/path', host], None),
        ]
        with tempfile.TemporaryDirectory() as tmpDir:
            mocks = Path(tmpDir) / 'mocks.ps1'
            mocks.write_text('function Write-Nothing { }\n', encoding='ascii')
            results = Utils.RunHarness(self, 'mockcall', 'Get-HTTPSredirectTarget', [{'state': {}, 'args': args} for args, _ in cases],
                                 mocksPath=mocks)
        self.assertEqual([result['output'] for result in results], [[expected] if expected else [] for _, expected in cases])

    def test_ResolveOfficialHTTPS_FollowsSameHostHTTPShopsOnly(self) -> None:
        alias = 'https://download.sysinternals.com/files/NotMyFault.zip'
        moved = 'http://download.sysinternals.com/files/v2/NotMyFault.zip'
        final = 'https://download.sysinternals.com/files/v2/NotMyFault.zip'
        good = {'hops': [f'{alias}>301>{moved}', f'{final}>200>']}
        foreign = {'hops': [f'{alias}>302>https://evil.example/NotMyFault.zip']}
        error = {'hops': [f'{alias}>500>']}
        loop = {'hops': [f'{alias}>301>{alias}']}
        with tempfile.TemporaryDirectory() as tmpDir:
            mocks = Path(tmpDir) / 'mocks.ps1'
            mocks.write_text(Utils.RESOLVE_MOCKS + '\n' + Utils.RunHarness(self, 'definition', 'Get-HTTPSredirectTarget')['text'] + '\n',
                             encoding='ascii')
            resolved = Utils.RunHarness(self, 'mockcall', 'Resolve-OfficialHTTPS', [{'state': good, 'args': [alias, 'download.sysinternals.com']}],
                                  mocksPath=mocks)[0]
            self.assertEqual(resolved['output'], [final])
            self.assertEqual(resolved['log'], [f'HEAD {alias}', f'HEAD {final}'])
            for state, message in ((foreign, 'leaves download.sysinternals.com'), (error, 'HTTP 500'), (loop, 'too many redirects')):
                output = Utils.RunHarness(self, 'mockcall', 'Resolve-OfficialHTTPS', [{'state': state, 'args': [alias, 'download.sysinternals.com']}],
                                    mocksPath=mocks, expectSuccess=False)
                self.assertIn(message, output)
            output = Utils.RunHarness(self, 'mockcall', 'Resolve-OfficialHTTPS', [{'state': good, 'args': ['http://download.sysinternals.com/files/NotMyFault.zip', 'download.sysinternals.com']}],
                                mocksPath=mocks, expectSuccess=False)
            self.assertIn('not an HTTPS URL', output)

    def test_GetNotMyFaultTrustProblem_RequiresAValidMicrosoftSignature(self) -> None:
        cases = [
            (f'Valid|{Utils.MICROSOFT_SIGNER}', []),
            (f'HashMismatch|{Utils.MICROSOFT_SIGNER}', [f'signature status HashMismatch, signer {Utils.MICROSOFT_SIGNER}']),
            ('NotSigned|', ['signature status NotSigned, signer none']),
            (f'Valid|{Utils.OTHER_SIGNER}', [f'signer is not Microsoft Corporation: {Utils.OTHER_SIGNER}']),
            (f'Valid|{Utils.LOOKALIKE_SIGNER}', [f'signer is not Microsoft Corporation: {Utils.LOOKALIKE_SIGNER}']),
            (f'Valid|{Utils.QUOTED_OU_SIGNER}', [f'signer is not Microsoft Corporation: {Utils.QUOTED_OU_SIGNER}']),
        ]
        with tempfile.TemporaryDirectory() as tmpDir:
            mocks = Path(tmpDir) / 'mocks.ps1'
            mocks.write_text(Utils.STAGING_MOCKS, encoding='ascii')
            results = Utils.RunHarness(self, 'mockcall', 'Get-NotMyFaultTrustProblem',
                                 [{'state': {'sig': [signature]}, 'args': [Utils.NMF_PATH]} for signature, _ in cases], mocksPath=mocks)
        self.assertEqual([result['output'] for result in results], [expected for _, expected in cases])

    def test_InvokeNotMyFaultStaging_AlwaysDownloadsAfreshAndRecordsIt(self) -> None:
        trusted = f'Valid|{Utils.MICROSOFT_SIGNER}'
        cases = [
            {'state': {'existing': [Utils.NMF_PATH], 'sig': [trusted]}, 'args': [Utils.NMF_SOURCE]},          # earlier copy present
            {'state': {'existing': [], 'sig': [trusted]}, 'args': [Utils.NMF_SOURCE]},                  # nothing staged yet
            {'state': {'existing': [Utils.NMF_PATH], 'sig': [f'Valid|{Utils.OTHER_SIGNER}']}, 'args': [Utils.NMF_SOURCE]},  # untrusted download
            {'state': {'existing': [], 'sig': [trusted], 'downloadFails': ['true']}, 'args': [Utils.NMF_SOURCE]},
            {'state': {'existing': [], 'sig': [trusted], 'archiveHasExe': ['false']}, 'args': [Utils.NMF_SOURCE]},
            {'state': {'existing': [], 'sig': [trusted], 'resolveFails': ['true']}, 'args': [Utils.NMF_SOURCE]},
        ]
        with tempfile.TemporaryDirectory() as tmpDir:
            mocks = Path(tmpDir) / 'mocks.ps1'
            mocks.write_text(Utils.STAGING_MOCKS + '\n' + Utils.RunHarness(self, 'definition', 'Get-NotMyFaultTrustProblem')['text'] + '\n'
                             + Utils.RunHarness(self, 'definition', 'Invoke-NotMyFaultStaging')['text'] + '\n', encoding='ascii')
            probe = Path(tmpDir) / 'probe.ps1'
            probe.write_text(Utils.RECORD_PROBE, encoding='ascii')
            results = Utils.RunHarness(self, 'mockcall', 'Get-StagingRecord', cases, scriptPath=probe, mocksPath=mocks)
        for result in results:
            result['record'] = dict(line.split('=', 1) for line in result['output'])
        replaced, fresh, untrusted, downloadFails, noExe, resolveFails = results
        for result in (replaced, fresh):
            log = result['log']
            self.assertIn(f'Save-HTTPSdownload {Utils.NMF_SOURCE} C:\\Temp\\nmf\\NotMyFault.zip', log)
            self.assertLess(log.index(f'Get-AuthenticodeSignature C:\\Temp\\nmf\\extract\\notmyfaultc64.exe'),
                            log.index(f'Move-Item C:\\Temp\\nmf\\extract\\notmyfaultc64.exe {Utils.NMF_PATH}'))
            self.assertIn('Remove-Item C:\\Temp\\nmf\\NotMyFault.zip', log)
        self.assertLess(replaced['log'].index(f'Remove-Item {Utils.NMF_PATH}'), replaced['log'].index(f'Save-HTTPSdownload {Utils.NMF_SOURCE} C:\\Temp\\nmf\\NotMyFault.zip'))
        # TLS 1.2 is enabled before the first HTTPS request (the alias resolution).
        self.assertLess(replaced['log'].index('Enable-TLS12'), replaced['log'].index(f'Resolve-OfficialHTTPS {Utils.NMF_SOURCE} download.sysinternals.com'))
        record = replaced['record']
        self.assertEqual(record['status'], 'staged')
        self.assertEqual(record['source'], Utils.NMF_SOURCE)
        self.assertEqual(record['stagedPath'], Utils.NMF_PATH)
        self.assertEqual(record['problem'], '')
        self.assertEqual(record['resolvedSource'], Utils.NMF_SOURCE)
        self.assertEqual((record['archiveSHA256'], record['sha256'], record['version']), ('A' * 64, 'B' * 64, '4.25'))
        self.assertEqual(record['signer'], Utils.MICROSOFT_SIGNER)
        for result, problem in ((untrusted, f'signer is not Microsoft Corporation: {Utils.OTHER_SIGNER}'),
                                (downloadFails, 'The remote name could not be resolved'),
                                (noExe, 'notmyfaultc64.exe is missing from the downloaded archive'),
                                (resolveFails, 'redirect leaves download.sysinternals.com')):
            self.assertEqual(result['record']['status'], 'failed')
            self.assertEqual(result['record']['problem'], problem)
            self.assertEqual(result['record']['sha256'], '')
            self.assertFalse([entry for entry in result['log'] if entry.endswith(f' {Utils.NMF_PATH}') and entry.startswith('Move-Item')], result)
        self.assertIn(f'Remove-Item {Utils.NMF_PATH}', untrusted['log'])
        self.assertIn('Remove-Item C:\\Temp\\nmf\\extract', untrusted['log'])

    def test_GetDesiredCrashControl_ExcludesRequiredAbsences(self) -> None:
        values = json.loads(Utils.DATA_FILE.read_text(encoding='utf-8'))['recommended']['values']
        old = dict(values, DedicatedDumpFile='C:\\DedicatedDump.sys')
        results = Utils.RunHarness(self, 'call', 'Get-DesiredCrashControl', [[old, 2], [values, 7]])
        self.assertEqual(results[0], dict(values, CrashDumpEnabled=2))
        self.assertEqual(results[1], dict(values, CrashDumpEnabled=7))
        with tempfile.TemporaryDirectory() as tmpDir:
            mocks = Path(tmpDir) / 'mocks.ps1'
            mocks.write_text(Utils.RunHarness(self, 'definition', 'Get-RequiredAbsence')['text'] + '\n', encoding='ascii')
            probe = Path(tmpDir) / 'probe.ps1'
            probe.write_text(Utils.RECORD_PROBE, encoding='ascii')
            absences = Utils.RunHarness(self, 'mockcall', 'Get-AbsenceList',
                                  [{'state': {}, 'args': [{'values': {}}]}, {'state': {}, 'args': [{'absentValues': ['DedicatedDumpFile', 'X']}]}],
                                  scriptPath=probe, mocksPath=mocks)
        self.assertEqual([result['output'] for result in absences], [['DedicatedDumpFile'], ['DedicatedDumpFile,X']])

if __name__ == '__main__':
    unittest.main()
