#!/usr/bin/env python3
"""Offline checks for golden-image-post-reboot.ps1.

The script reads Windows state on the guest and is never executed here. Static checks
read it as text. The PowerShell checks use fixtures/ps-function-harness.ps1, which only
parses the script and runs single function definitions, taken from its syntax tree, in a
runspace with no cmdlets, providers or applications; functions that invoke commands or .NET
members other than static [math] members are refused. Without `pwsh` those checks are
skipped, or fail when BSOD_DET__TEST__REQUIRE_PWSH=1.
"""

import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


APP_DIR = Path(__file__).resolve().parents[1]
GUEST_DIR = APP_DIR / 'src' / 'scripts' / 'guest'
SCRIPT = GUEST_DIR / 'golden-image-post-reboot.ps1'
PARTNER_SCRIPT = GUEST_DIR / 'golden-image-pre-reboot.ps1'
HARNESS = Path(__file__).resolve().parent / 'fixtures' / 'ps-function-harness.ps1'

# Expected pagefile sizes (MB), shared with the pre-reboot tests. The 4095.5 and 16383.5 MiB
# cases are where rounding before adding 257 differs from rounding once (banker's rounding).
PAGEFILE_SIZES_MB = {
    4294443008: 4352,
    8589934592: 8449,
    17179344896: 16640,
    17179869184: 16641,
}


def RunHarness(testCase, mode, functionName='', calls=None, scriptPath=SCRIPT, expectSuccess=True):
    pwsh = shutil.which('pwsh')
    if not pwsh:
        if os.environ.get('BSOD_DET__TEST__REQUIRE_PWSH') == '1':
            testCase.fail('pwsh is required (BSOD_DET__TEST__REQUIRE_PWSH=1) but not installed')
        testCase.skipTest('pwsh is not installed')
    result = subprocess.run(
        [pwsh, '-NoProfile', '-NonInteractive', '-File', str(HARNESS), '-Mode', mode,
         '-ScriptPath', str(scriptPath), '-FunctionName', functionName, '-CallsJson', json.dumps(calls or [])],
        capture_output=True, text=True, timeout=180, check=False)
    if not expectSuccess:
        testCase.assertNotEqual(result.returncode, 0, result.stdout)
        return result.stderr + result.stdout
    testCase.assertEqual(result.returncode, 0, result.stderr)
    return json.loads(result.stdout)


class PostRebootStaticTests(unittest.TestCase):
    def setUp(self):
        self.source = SCRIPT.read_bytes()
        self.text = self.source.decode('ascii', errors='replace')

    def test_source_is_ascii_for_windows_powershell_51(self):
        # Windows PowerShell 5.1 reads BOM-less files as ANSI; UTF-8 punctuation can end strings early.
        self.assertTrue(self.source.isascii())

    def test_source_ends_with_newline(self):
        self.assertTrue(self.source.endswith(b'\n'))

    def test_minimum_pagefile_uses_the_shared_function(self):
        self.assertIn('$expectedMinMB = Get-PagefileSizeMB $computer.TotalPhysicalMemory', self.text)
        self.assertIsNone(re.search(r'\)\s*\+\s*257\b', self.text))

    def test_leftover_setup_files_are_reported_without_failing_the_seal_check(self):
        block = self.text[self.text.index('--- Checking leftover setup files ---'):self.text.index('if ($hasFailure) {')]
        self.assertIn("@('C:\\Temp\\virtio-win.iso', 'C:\\Temp\\virtio-win.iso.download')", block)
        self.assertIn('WARN: $path is still present', block)
        self.assertNotIn('$hasFailure = $true', block)

    def test_leftover_paths_match_the_pre_reboot_script(self):
        partner = PARTNER_SCRIPT.read_text(encoding='utf-8')
        self.assertIn('C:\\Temp\\virtio-win.iso', partner)
        if '$isoTmpPath' in partner:
            self.assertIn('$isoTmpPath = "$isoPath.download"', partner)

    def test_pvpanic_comment_does_not_credit_preflight(self):
        self.assertNotIn('Device is added at runtime by preflight-rhov.sh', self.text)


class PostRebootPowerShellTests(unittest.TestCase):
    def test_parses_as_utf8_and_windows_1252_without_powershell_7_syntax(self):
        parsed = RunHarness(self, 'parse')
        self.assertEqual(parsed['utf8Errors'], 0)
        self.assertEqual(parsed['windows1252Errors'], 0)
        self.assertEqual(parsed['ps7OnlyTokens'], [])
        self.assertEqual(parsed['numberTokens'].count('257MB'), 1)
        self.assertEqual(parsed['functions'], ['Get-PagefileSizeMB'])
        # Verification only: leftover files are reported, never deleted by this script.
        self.assertNotIn('Remove-Item', parsed['commands'])

    def test_minimum_pagefile_size_rounds_once(self):
        ramValues = list(PAGEFILE_SIZES_MB)
        sizes = RunHarness(self, 'call', 'Get-PagefileSizeMB', [[ram] for ram in ramValues])
        self.assertEqual(dict(zip(ramValues, sizes)), PAGEFILE_SIZES_MB)

    def test_pagefile_size_matches_pre_reboot_script_when_present(self):
        own = RunHarness(self, 'definition', 'Get-PagefileSizeMB')
        partner = RunHarness(self, 'definition', 'Get-PagefileSizeMB', scriptPath=PARTNER_SCRIPT)
        if not partner['found']:
            self.skipTest('pre-reboot script does not define Get-PagefileSizeMB yet')
        self.assertEqual(partner['text'], own['text'])

    def test_isolated_runspace_cannot_reach_host_commands(self):
        names = ['Get-CimInstance', 'Get-WindowsDriver', 'Set-Service', 'Remove-Item', 'Get-ChildItem', 'cmd', 'sh']
        results = RunHarness(self, 'isolation', calls=names)
        self.assertEqual(results, {name: 'CommandNotFoundException' for name in names})

    def test_harness_refuses_functions_that_reach_outside_the_runspace(self):
        with tempfile.TemporaryDirectory() as tmpDir:
            probe = Path(tmpDir) / 'probe.ps1'
            probe.write_text(
                "function Get-WithCommand { Get-Date }\n"
                "function Get-WithDotNet { [System.IO.File]::Exists('C:\\Windows') }\n",
                encoding='ascii')
            for name in ('Get-WithCommand', 'Get-WithDotNet'):
                output = RunHarness(self, 'call', name, [[]], scriptPath=probe, expectSuccess=False)
                self.assertIn('refused', output)


if __name__ == '__main__':
    unittest.main()
