#!/usr/bin/env python3
"""Offline checks for configure-dumps.ps1 and src/data/crash-control.json.

The script writes the guest registry and downloads NotMyFault, so it is never executed. Static
checks read it as text. The PowerShell checks use fixtures/ps-function-harness.ps1, which only
parses the script and runs single pure functions, taken from its syntax tree, in a runspace with
no cmdlets, providers or applications. Without `pwsh` those checks are skipped, or fail when
BSOD_DET__TEST__REQUIRE_PWSH=1.
"""

import importlib.util
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
SCRIPT = GUEST_DIR / 'configure-dumps.ps1'
PARTNER_SCRIPTS = (GUEST_DIR / 'golden-image-pre-reboot.ps1', GUEST_DIR / 'golden-image-post-reboot.ps1')
DATA_FILE = APP_DIR / 'src' / 'data' / 'crash-control.json'
HOST_DIR = APP_DIR / 'src' / 'scripts' / 'host'
NMF_DIR = 'C:\\Temp\\nmf'
NMF_PATH = 'C:\\Temp\\nmf\\notmyfaultc64.exe'

# Mock cmdlets for Invoke-NotMyFaultStaging; they exist only inside the harness's empty runspace,
# record each call and simulate the guest file system from $global:MockState.
STAGING_MOCKS = r'''
function Test-Path ([string]$LiteralPath) { $global:MockLog.Add("Test-Path ${LiteralPath}"); $global:MockState['existing'] -contains $LiteralPath }
function New-Item ([string]$ItemType, [switch]$Force, [string]$Path) { $global:MockLog.Add("New-Item ${Path}") }
function Out-Null { process { } }
function Save-NotMyFaultArchive ([string]$Path) {
    $global:MockLog.Add("Save-NotMyFaultArchive ${Path}")
    if ($global:MockState['downloadFails'] -contains 'true') { throw 'The remote name could not be resolved' }
}
function Expand-Archive ([string]$Path, [string]$DestinationPath, [switch]$Force) {
    $global:MockLog.Add("Expand-Archive ${Path}")
    if ($global:MockState['extractCreates'] -contains 'true') { $global:MockState['existing'] = @($global:MockState['existing']) + 'C:\Temp\nmf\notmyfaultc64.exe' }
}
function Remove-Item ([string]$LiteralPath, [switch]$Force, $ErrorAction) { $global:MockLog.Add("Remove-Item ${LiteralPath}") }
function Unblock-File ([string]$Path, $ErrorAction) { $global:MockLog.Add("Unblock-File ${Path}") }
'''
HARNESS = Path(__file__).resolve().parent / 'fixtures' / 'ps-function-harness.ps1'

# Expected pagefile sizes (MB), shared with the golden-image tests. The 4095.5 and 16383.5 MiB
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


WRITE_OR_DOWNLOAD = re.compile(r'\b(New-ItemProperty|Remove-ItemProperty|Set-ItemProperty|New-Item|Remove-Item|Expand-Archive|Unblock-File)\b|DownloadFile')


def BlockAfter(text, marker):
    """Text of the brace-delimited block that starts at `marker` (which ends with '{')."""
    start = text.index(marker) + len(marker)
    depth = 1
    for index in range(start, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[start:index]
    raise AssertionError(f'unbalanced block after {marker}')


class ConfigureDumpsStaticTests(unittest.TestCase):
    def setUp(self):
        self.source = SCRIPT.read_bytes()
        self.text = self.source.decode('ascii', errors='replace')
        self.data = json.loads(DATA_FILE.read_text(encoding='utf-8'))

    def test_source_is_ascii_and_ends_with_newline(self):
        self.assertTrue(self.source.isascii())
        self.assertTrue(self.source.endswith(b'\n'))

    def test_dedicated_dump_file_is_no_longer_recommended(self):
        self.assertNotIn('DedicatedDumpFile', self.data['recommended']['values'])
        self.assertIn('DedicatedDumpFile is not used', self.data['pageFile']['notes'])
        self.assertIn("Remove-ItemProperty -Path $regPath -Name 'DedicatedDumpFile'", self.text)

    def test_writes_happen_only_in_apply_mode_or_opt_in_staging(self):
        applyBlock = BlockAfter(self.text, 'if (-not $VerifyOnly) {')
        stagingBody = BlockAfter(self.text, 'function Invoke-NotMyFaultStaging ([bool]$IsVerifyOnly, [bool]$IsStageRequested) {')
        downloadBody = BlockAfter(self.text, 'function Save-NotMyFaultArchive ([string]$Path) {')
        outside = self.text
        for block in (applyBlock, stagingBody, downloadBody):
            outside = outside.replace(block, '')
        self.assertIsNone(WRITE_OR_DOWNLOAD.search(outside))
        self.assertIsNotNone(WRITE_OR_DOWNLOAD.search(applyBlock))
        self.assertEqual(self.text.count('= Invoke-NotMyFaultStaging '), 1)
        self.assertIn('$nmfStatus = Invoke-NotMyFaultStaging ([bool]$VerifyOnly) ([bool]$StageNotMyFault)', self.text)
        self.assertEqual(self.text.count('Save-NotMyFaultArchive $zip'), 1)
        # The read-only and opt-in guards come before any write in the staging function.
        firstWrite = stagingBody.index('New-Item')
        self.assertLess(stagingBody.index('if ($IsVerifyOnly) { return'), firstWrite)
        self.assertLess(stagingBody.index('if (-not $IsStageRequested) { return'), firstWrite)

    def test_preflight_forwards_staging_only_for_require_trigger(self):
        preflight = (HOST_DIR / 'preflight-rhov.sh').read_text(encoding='utf-8')
        function = re.search(r'(?ms)^function ConfigureDumpsArgs \(\) \{.*?^\}', preflight).group(0)
        for requireTrigger, expected in ((0, ['-DataFile', 'C:\\Windows\\Temp\\crash-control.json']),
                                         (1, ['-DataFile', 'C:\\Windows\\Temp\\crash-control.json', '-StageNotMyFault'])):
            script = (f'set -euo pipefail; shopt -s inherit_errexit\n{function}\n'
                      f'typeset -a argArr2=(); ConfigureDumpsArgs argArr2 {requireTrigger}; printf "%s\\n" "${{argArr2[@]}}"')
            result = subprocess.run(['bash', '-c', script], capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.splitlines(), expected)
        self.assertIn('ConfigureDumpsArgs configureArgArr "${requireTrigger}"', preflight)
        self.assertIn("--companion \"${crashControlFile}\" 'C:\\Windows\\Temp\\crash-control.json' -- \\\n  \"${configureArgArr[@]}\")\"", preflight)
        self.assertIn('--require-trigger) requireTrigger=1', preflight)

    def test_guest_agent_psfile_passes_the_switch_to_powershell(self):
        spec = importlib.util.spec_from_file_location('guestAgent', HOST_DIR / 'guest-agent.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        companions, powershellArgs = module._psfile_args(
            ['--companion', 'crash-control.json', 'C:\\Windows\\Temp\\crash-control.json', '--',
             '-DataFile', 'C:\\Windows\\Temp\\crash-control.json', '-StageNotMyFault'])
        self.assertEqual(companions, [('crash-control.json', 'C:\\Windows\\Temp\\crash-control.json')])
        self.assertEqual(powershellArgs, ['-DataFile', 'C:\\Windows\\Temp\\crash-control.json', '-StageNotMyFault'])
        self.assertIn('["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", guestpath] + powershell_args',
                      (HOST_DIR / 'guest-agent.py').read_text(encoding='utf-8'))

    def test_notmyfault_failures_are_reported_on_stderr(self):
        self.assertIsNone(re.search(r'catch\s*\{\s*(#[^\n]*\s*)*\}', self.text))
        self.assertIn('[Console]::Error.WriteLine("configure-dumps.ps1: WARN: NotMyFault staging', self.text)
        self.assertIn("$nmfDir = 'C:\\Temp\\nmf'", self.text)

    def test_tls_is_added_not_replaced(self):
        self.assertIn('[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12', self.text)

    def test_json_contract_fields(self):
        self.assertIn('pageFile           = [ordered]@{ configured = $pfConfigured; adequate = $isPfAdequate; requiredMB = $requiredMB }', self.text)
        for field in ('ok', 'action', 'requestedDumpType', 'applied', 'current', 'matchesRecommended', 'rebootRequired'):
            self.assertRegex(self.text, rf'(?m)^    {field}\s+= ')

    def test_double_quoted_strings_use_formal_variable_syntax(self):
        self.assertEqual(SimpleVariablesInDoubleQuotes(self.text), [])


class ConfigureDumpsPowerShellTests(unittest.TestCase):
    def test_parses_as_utf8_and_windows_1252_without_powershell_7_syntax(self):
        parsed = RunHarness(self, 'parse')
        self.assertEqual(parsed['utf8Errors'], 0)
        self.assertEqual(parsed['windows1252Errors'], 0)
        self.assertEqual(parsed['ps7OnlyTokens'], [])
        self.assertEqual(parsed['convertibleDoubleQuoted'], [])
        self.assertEqual(sorted(parsed['functions']), ['Fail', 'Get-PagefileSizeMB', 'Get-RegValue', 'Invoke-NotMyFaultStaging', 'Save-NotMyFaultArchive', 'Test-PageFileAdequate', 'Test-RebootRequired', 'Test-ValueMatch'])

    def test_required_pagefile_size_matches_golden_image(self):
        ramValues = list(PAGEFILE_SIZES_MB)
        sizes = RunHarness(self, 'call', 'Get-PagefileSizeMB', [[ram] for ram in ramValues])
        self.assertEqual(dict(zip(ramValues, sizes)), PAGEFILE_SIZES_MB)

    def test_pagefile_size_function_matches_golden_image_scripts_when_present(self):
        own = RunHarness(self, 'definition', 'Get-PagefileSizeMB')
        compared = 0
        for partnerScript in PARTNER_SCRIPTS:
            partner = RunHarness(self, 'definition', 'Get-PagefileSizeMB', scriptPath=partnerScript)
            if partner['found']:
                self.assertEqual(partner['text'], own['text'])
                compared += 1
        if not compared:
            self.skipTest('golden-image scripts do not define Get-PagefileSizeMB yet')

    def test_pagefile_adequacy(self):
        cases = [
            ([[], 16641], False),                                   # no page file configured
            ([['?:\\pagefile.sys'], 16641], False),                 # system managed
            ([['C:\\pagefile.sys 0 0'], 16641], False),             # system-managed size
            ([['C:\\pagefile.sys 4096 4096'], 16641], False),       # fixed but too small
            ([['C:\\pagefile.sys 16641 16641'], 16641], True),      # golden-image size
            ([['C:\\pagefile.sys 20000 20000'], 16641], True),      # larger
            ([['C:\\pagefile.sys 2048 16641'], 16641], False),      # initial size too small
            ([['D:\\pagefile.sys 16641 16641'], 16641], False),     # not on the system volume
            ([['?:\\pagefile.sys', 'C:\\pagefile.sys 16641 16641'], 16641], True),  # one adequate entry
            ([['C:\\pagefile.sys 16641 16641'], None], False),      # RAM unknown
        ]
        results = RunHarness(self, 'call', 'Test-PageFileAdequate', [args for args, _ in cases])
        self.assertEqual(results, [expected for _, expected in cases])

    def test_reboot_required(self):
        cases = [
            ([7, 7, False], False),    # already configured
            ([2, 7, False], True),     # dump type change
            ([None, 7, False], True),  # value missing
            ([7, 7, True], True),      # stale DedicatedDumpFile removed
        ]
        results = RunHarness(self, 'call', 'Test-RebootRequired', [args for args, _ in cases])
        self.assertEqual(results, [expected for _, expected in cases])

    def test_notmyfault_staging_is_opt_in_and_never_in_verify_only(self):
        cases = [
            {'state': {}, 'args': [False, False]},                                              # default / watch
            {'state': {}, 'args': [True, True]},                                                # -VerifyOnly with opt-in
            {'state': {'existing': [NMF_PATH]}, 'args': [False, True]},                         # already staged
            {'state': {'extractCreates': ['true']}, 'args': [False, True]},                     # stages when missing
            {'state': {'downloadFails': ['true']}, 'args': [False, True]},                      # download error
            {'state': {}, 'args': [False, True]},                                               # archive without the binary
        ]
        with tempfile.TemporaryDirectory() as tmpDir:
            mocks = Path(tmpDir) / 'mocks.ps1'
            mocks.write_text(STAGING_MOCKS, encoding='ascii')
            results = RunHarness(self, 'mockcall', 'Invoke-NotMyFaultStaging', cases, mocksPath=mocks)
        default, verifyOnly, present, staged, downloadError, noBinary = results
        downloads = lambda result: [entry for entry in result['log'] if entry.startswith('Save-NotMyFaultArchive')]
        writes = lambda result: [entry for entry in result['log'] if not entry.startswith(('Test-Path', 'Save-'))]
        self.assertEqual(default['output'], ['skipped: not requested'])
        self.assertEqual(default['log'], [])
        self.assertEqual(verifyOnly['output'], ['skipped: -VerifyOnly is read-only'])
        self.assertEqual(verifyOnly['log'], [])
        self.assertEqual(present['output'], ['present'])
        self.assertEqual(downloads(present) + writes(present), [])
        self.assertEqual(staged['output'], ['staged'])
        self.assertEqual(downloads(staged), [f'Save-NotMyFaultArchive {NMF_DIR}\\NotMyFault.zip'])
        self.assertIn(f'Unblock-File {NMF_PATH}', staged['log'])
        self.assertEqual(downloadError['output'], ['failed: The remote name could not be resolved'])
        self.assertEqual(noBinary['output'], [f'failed: {NMF_PATH} missing after extraction'])

    def test_isolated_runspace_cannot_reach_host_commands(self):
        names = ['New-ItemProperty', 'Remove-ItemProperty', 'Expand-Archive', 'Get-CimInstance', 'cmd', 'sh']
        results = RunHarness(self, 'isolation', calls=names)
        self.assertEqual(results, {name: 'CommandNotFoundException' for name in names})


if __name__ == '__main__':
    unittest.main()
