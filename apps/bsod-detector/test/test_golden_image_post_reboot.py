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

# Mock cmdlets for Remove-SetupCacheFile. They exist only inside the harness's empty runspace,
# record each call in $global:MockLog and simulate file state from $global:MockState.
CLEANUP_MOCKS = r'''
function Test-Path ([string]$LiteralPath) { $global:MockLog.Add("Test-Path ${LiteralPath}"); $global:MockState['existing'] -contains $LiteralPath }
function Get-DiskImage ([string]$ImagePath, $ErrorAction) {
    $global:MockLog.Add("Get-DiskImage ${ImagePath}")
    [pscustomobject]@{ Attached = ($global:MockState['mounted'] -contains $ImagePath) }
}
function Remove-Item ([string]$LiteralPath, [switch]$Force, $ErrorAction) {
    $global:MockLog.Add("Remove-Item ${LiteralPath}")
    if ($global:MockState['inUse'] -contains $LiteralPath) { throw "The process cannot access the file '${LiteralPath}' because it is being used by another process." }
}
function Write-Host ($Object) { $global:MockLog.Add("Write-Host ${Object}") }
'''

# Expected pagefile sizes (MB), shared with the pre-reboot tests. The 4095.5 and 16383.5 MiB
# cases are where rounding before adding 257 differs from rounding once (banker's rounding).
PAGEFILE_SIZES_MB = {
    4294443008: 4352,
    8589934592: 8449,
    17179344896: 16640,
    17179869184: 16641,
}


def SimpleVariablesInDoubleQuotes(text):
    """Lines whose double-quoted strings use `$name` instead of the formal `${name}` syntax."""
    found = []
    for number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith('#'):
            continue
        for segment in re.findall(r'"((?:[^"`]|`.)*)"', line):
            previous = None
            while previous != segment:  # drop $( ... ) subexpressions; keep plain parentheses' text
                previous = segment
                segment = re.sub(r'\$\([^()]*\)', '', segment)
                segment = re.sub(r'(?<!\$)\(([^()]*)\)', r'<\1>', segment)
            if re.search(r'(?<!`)\$(?!\{)[A-Za-z_]', segment):
                found.append(number)
    return found


def RunHarness(testCase, mode, functionName='', calls=None, scriptPath=SCRIPT, expectSuccess=True, mocksPath=None):
    pwsh = shutil.which('pwsh')
    if not pwsh:
        if os.environ.get('BSOD_DET__TEST__REQUIRE_PWSH') == '1':
            testCase.fail('pwsh is required (BSOD_DET__TEST__REQUIRE_PWSH=1) but not installed')
        testCase.skipTest('pwsh is not installed')
    result = subprocess.run(
        [pwsh, '-NoProfile', '-NonInteractive', '-File', str(HARNESS), '-Mode', mode,
         '-ScriptPath', str(scriptPath), '-FunctionName', functionName, '-CallsJson', json.dumps(calls or []),
         '-MocksPath', str(mocksPath or '')],
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

    def test_stale_files_are_removed_only_after_every_check_passed(self):
        gate = self.text.index('if ($hasFailure) {')
        cleanup = self.text.index("Remove-SetupCacheFile @('C:\\Temp\\virtio-win.iso', 'C:\\Temp\\virtio-win.iso.download')")
        failureExit = self.text.index('exit 1', cleanup)
        success = self.text.index('safe to seal the golden image')
        self.assertLess(gate, cleanup)
        self.assertLess(failureExit, success)
        self.assertEqual(self.text.count('Remove-Item'), 1)
        self.assertIn('Remove-Item -LiteralPath $path -Force -ErrorAction Stop', self.text)
        self.assertIn('Test-Path -LiteralPath $path', self.text)

    def test_leftover_paths_match_the_pre_reboot_script(self):
        partner = PARTNER_SCRIPT.read_text(encoding='utf-8')
        self.assertIn('C:\\Temp\\virtio-win.iso', partner)
        if '$isoTmpPath' in partner:
            self.assertIn('$isoTmpPath = "${isoPath}.download"', partner)

    def test_pvpanic_is_documented_as_a_qemu_monitor_device_only(self):
        self.assertNotIn('Device is added at runtime by preflight-rhov.sh', self.text)
        self.assertIn('device_add pvpanic,id=pvpanic0', self.text)
        self.assertIn('src/scripts/crash-injector/trigger-bsod-intentional.sh', self.text)
        self.assertIsNone(re.search(r'(?m)^#\s*\$pvpanic', self.text))

    def test_obsolete_recovery_settings_are_removed(self):
        self.assertNotRegex(self.text, r'(?i)bcdedit|reagentc|recoveryenabled')
        self.assertIn('CrashDumpEnabled', self.text)

    def test_double_quoted_strings_use_formal_variable_syntax(self):
        self.assertEqual(SimpleVariablesInDoubleQuotes(self.text), [])


class PostRebootPowerShellTests(unittest.TestCase):
    def test_parses_as_utf8_and_windows_1252_without_powershell_7_syntax(self):
        parsed = RunHarness(self, 'parse')
        self.assertEqual(parsed['utf8Errors'], 0)
        self.assertEqual(parsed['windows1252Errors'], 0)
        self.assertEqual(parsed['ps7OnlyTokens'], [])
        self.assertEqual(parsed['convertibleDoubleQuoted'], [])
        self.assertEqual(parsed['numberTokens'].count('257MB'), 1)
        self.assertEqual(sorted(parsed['functions']), ['Get-PagefileSizeMB', 'Remove-SetupCacheFile'])

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

    def test_stale_file_cleanup_with_mocks(self):
        iso, partial = 'C:\\Temp\\virtio-win.iso', 'C:\\Temp\\virtio-win.iso.download'
        paths = [[iso, partial]]
        cases = [
            {'state': {'existing': []}, 'args': paths},                                       # already clean
            {'state': {'existing': [iso, partial]}, 'args': paths},                           # stale files
            {'state': {'existing': [iso, partial], 'mounted': [iso]}, 'args': paths},         # ISO still mounted
            {'state': {'existing': [iso], 'inUse': [iso]}, 'args': paths},                    # removal fails
        ]
        with tempfile.TemporaryDirectory() as tmpDir:
            mocks = Path(tmpDir) / 'mocks.ps1'
            mocks.write_text(CLEANUP_MOCKS, encoding='ascii')
            results = RunHarness(self, 'mockcall', 'Remove-SetupCacheFile', cases, mocksPath=mocks)
        clean, stale, mounted, inUse = results
        self.assertEqual(clean['output'], [])
        self.assertFalse([entry for entry in clean['log'] if entry.startswith('Remove-Item')])
        self.assertEqual(stale['output'], [])
        self.assertIn(f'Remove-Item {iso}', stale['log'])
        self.assertIn(f'Remove-Item {partial}', stale['log'])
        self.assertEqual(mounted['output'], [f'{iso} is still mounted'])
        self.assertNotIn(f'Remove-Item {iso}', mounted['log'])
        self.assertIn(f'Remove-Item {partial}', mounted['log'])
        self.assertEqual(len(inUse['output']), 1)
        self.assertTrue(inUse['output'][0].startswith(f'{iso} could not be removed: The process cannot access'))
        for result in results:
            touched = {entry.split(' ', 1)[1] for entry in result['log'] if not entry.startswith('Write-Host')}
            self.assertLessEqual(touched, {iso, partial})

    def test_mockcall_refuses_unmocked_commands_and_method_calls(self):
        with tempfile.TemporaryDirectory() as tmpDir:
            mocks = Path(tmpDir) / 'mocks.ps1'
            mocks.write_text(CLEANUP_MOCKS, encoding='ascii')
            probe = Path(tmpDir) / 'probe.ps1'
            probe.write_text(
                "function Get-WithUnmockedCommand { Get-ChildItem 'C:\\Temp' }\n"
                "function Get-WithMethodCall ($File) { $File.Delete() }\n",
                encoding='ascii')
            for name in ('Get-WithUnmockedCommand', 'Get-WithMethodCall'):
                output = RunHarness(self, 'mockcall', name, [{'state': {}, 'args': []}], scriptPath=probe,
                                    expectSuccess=False, mocksPath=mocks)
                self.assertIn('refused', output)

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
