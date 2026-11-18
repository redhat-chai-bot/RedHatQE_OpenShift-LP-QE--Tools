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
DATA_FILE = APP_DIR / 'src' / 'data' / 'crash-control.json'

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
        [pwsh, '-NoProfile', '-NonInteractive', '-File', str(HARNESS), '-mode', mode,
         '-scriptPath', str(scriptPath), '-functionName', functionName, '-callsJSON', json.dumps(calls or []),
         '-mocksPath', str(mocksPath or '')],
        capture_output=True, text=True, timeout=180, check=False)
    if not expectSuccess:
        testCase.assertNotEqual(result.returncode, 0, result.stdout)
        return result.stderr + result.stdout
    testCase.assertEqual(result.returncode, 0, result.stderr)
    return json.loads(result.stdout)


def WriteMainFlowFiles(testCase, tmpDir, helperNames, mocks, startLine=None, mockedHelperNames=()):
    """Writes the script's top-level statements as one function, plus mocks and its own helpers.

    The statements run unchanged inside Invoke-MainFlow in the harness's empty runspace. The
    script's helper functions are loaded next to the mocks (those in mockedHelperNames are only
    removed, so the mocks of the same name are used), and each top-level `exit N` becomes
    `Exit-Script N; return`, which records the status and leaves at the same point.
    """
    scriptText = SCRIPT.read_text(encoding='ascii')
    helperTexts = []
    for helperName in helperNames:
        definition = RunHarness(testCase, 'definition', helperName)
        testCase.assertTrue(definition['found'], helperName)
        testCase.assertEqual(scriptText.count(definition['text']), 1, helperName)
        scriptText = scriptText.replace(definition['text'], '')
        helperTexts.append(definition['text'])
    for helperName in mockedHelperNames:
        definition = RunHarness(testCase, 'definition', helperName)
        testCase.assertTrue(definition['found'], helperName)
        testCase.assertEqual(scriptText.count(definition['text']), 1, helperName)
        scriptText = scriptText.replace(definition['text'], '')
    if startLine is not None:
        scriptText = scriptText[scriptText.index(startLine):]
    mainFlow, exitCount = re.subn(r'(?mi)^(\s*)exit (\d+)[ \t]*$', r'\1Exit-Script \2; return', scriptText)
    codeLines = [line for line in (mainFlow + '\n' + '\n'.join(helperTexts)).splitlines() if not line.lstrip().startswith('#')]
    testCase.assertGreater(exitCount, 0)
    testCase.assertFalse([line for line in codeLines if re.search(r'(^|[;{])\s*exit\b(?!-)', line, re.IGNORECASE)])
    flowPath = Path(tmpDir) / 'main-flow.ps1'
    mocksPath = Path(tmpDir) / 'main-flow-mocks.ps1'
    flowPath.write_text('function Invoke-MainFlow {\n' + mainFlow + '\n}\n', encoding='ascii')
    mocksPath.write_text(mocks + '\n' + '\n'.join(helperTexts) + '\n', encoding='ascii')
    return flowPath, mocksPath


# Mocks for the main-flow tests. Every check passes unless the state says otherwise: 'memory' is
# error, null or a byte count; 'pagefileMB' is the active page file size; 'reg' overrides CrashControl
# values ('Name=Value', or 'Name=' to remove one); 'missing' lists paths that do not exist,
# 'ddfFile' makes C:\DedicatedDump.sys exist and 'record' is the virtio-win ISO record (complete
# unless it is missing, noHash or http).
postMainFlowMocks = r'''
function Read-ArtifactRecord ([string]$path) {
    $global:MockLog.Add("Read-ArtifactRecord ${path}")
    $kind = @($global:MockState['record'])[0]
    if ($kind -eq 'missing') { return }
    [pscustomobject]@{
        version = '9.9.9'
        resolvedSource = $(if ($kind -eq 'http') { 'http://fedorapeople.org/virtio-win-9.9.9.iso' } else { 'https://fedorapeople.org/virtio-win-9.9.9.iso' })
        sha256 = $(if ($kind -eq 'noHash') { '' } else { 'CD' * 32 })
    }
}
function Get-Service ($Name, $ErrorAction) {
    if ($global:MockState['service'] -contains 'missing') { return }
    [pscustomobject]@{ Status = $(if ($global:MockState['service'] -contains 'stopped') { 'Stopped' } else { 'Running' }) }
}
function Set-Service ($Name, $StartupType, $ErrorAction) { $global:MockLog.Add("Set-Service ${Name} ${StartupType}") }
function Get-WindowsDriver ([switch]$Online) {
    [pscustomobject]@{ OriginalFileName = 'C:\Windows\System32\DriverStore\FileRepository\viostor.inf' }
    [pscustomobject]@{ OriginalFileName = 'C:\Windows\System32\DriverStore\FileRepository\vioscsi.inf' }
}
function Where-Object ([scriptblock]$FilterScript) {
    process {
        $context = [System.Collections.Generic.List[psvariable]]@([psvariable]::new('_', $_))
        if ($FilterScript.InvokeWithContext($null, $context)) { $_ }
    }
}
function Test-Path ([string]$Path, [string]$LiteralPath) {
    $target = if ($LiteralPath) { $LiteralPath } else { $Path }
    if ($target -eq 'C:\DedicatedDump.sys') { return ($global:MockState['ddfFile'] -contains 'true') }
    $global:MockState['missing'] -notcontains $target
}
function Get-ItemProperty ([string]$Path, [string]$Name, $ErrorAction) {
    $values = @{ CrashDumpEnabled = '7'; AutoReboot = '0'; AlwaysKeepMemoryDump = '1'; Overwrite = '1'; LogEvent = '1' }
    foreach ($pair in $global:MockState['reg']) {
        $key, $value = $pair -split '=', 2
        if ($value) { $values[$key] = $value } else { $values.Remove($key) }
    }
    if ($values.ContainsKey($Name)) { [pscustomobject]@{ $Name = $values[$Name] } }
}
function Get-CimInstance ([string]$ClassName, $ErrorAction) {
    $global:MockLog.Add("Get-CimInstance ${ClassName} ErrorAction=${ErrorAction}")
    if ($ClassName -eq 'Win32_PageFileUsage') {
        $size = [int64]@($global:MockState['pagefileMB'])[0]
        if ($size -gt 0) { return [pscustomobject]@{ Name = 'C:\pagefile.sys'; AllocatedBaseSize = $size; CurrentUsage = 10 } }
        return
    }
    $memory = @($global:MockState['memory'])[0]
    if ($memory -eq 'error') {
        if ("${ErrorAction}" -eq 'Stop') { throw 'simulated CIM failure' }
        return
    }
    $totalMemory = if ($memory -eq 'null') { $null } else { [int64]$memory }
    [pscustomobject]@{ AutomaticManagedPagefile = ($global:MockState['auto'] -contains 'true'); TotalPhysicalMemory = $totalMemory }
}
function Get-DiskImage ($ImagePath, $ErrorAction) { $global:MockLog.Add("Get-DiskImage ${ImagePath}"); [pscustomobject]@{ Attached = $false } }
function Remove-Item ($LiteralPath, [switch]$Force, $ErrorAction) {
    $global:MockLog.Add("Remove-Item ${LiteralPath}")
    # Like the real cmdlet, the failure terminates only with -ErrorAction Stop.
    if ($global:MockState['removeFails'] -contains 'true' -and "${ErrorAction}" -eq 'Stop') { throw 'The process cannot access the file because it is being used by another process.' }
}
function Write-Host ($Object, $ForegroundColor) { $global:MockLog.Add("Write-Host ${Object}") }
function Write-Error ($Message) { $global:MockLog.Add("Write-Error ${Message}") }
function Exit-Script ([int]$code) { $global:MockLog.Add("exit ${code}") }
'''


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
        # Unconditional, so a validation checkout without the pre-reboot change fails instead of passing.
        partner = PARTNER_SCRIPT.read_text(encoding='utf-8')
        self.assertIn("$isoPath = 'C:\\Temp\\virtio-win.iso'", partner)
        self.assertIn('$isoTmpPath = "${isoPath}.download"', partner)

    def test_iso_record_is_checked_and_kept_with_the_pre_reboot_path(self):
        record = "$isoRecordPath = 'C:\\ProgramData\\bsod-detector\\virtio-win-iso.json'"
        self.assertIn(record, self.text)
        self.assertIn(record, PARTNER_SCRIPT.read_text(encoding='utf-8'))
        # The record checks precede the failure gate; the cleanup removes only the ISO cache files.
        self.assertLess(self.text.index('$isoRecord = Read-ArtifactRecord $isoRecordPath'), self.text.index('if ($hasFailure) {'))
        cleanupLine = next(line for line in self.text.splitlines() if 'Remove-SetupCacheFile @(' in line)
        self.assertNotIn('ProgramData', cleanupLine)

    def test_failures_do_not_depend_on_the_callers_error_preference(self):
        self.assertIn("$ErrorActionPreference = 'Continue'", self.text)
        self.assertLess(self.text.index("$ErrorActionPreference = 'Continue'"), self.text.index('    Write-Error '))

    def test_old_dedicated_dump_file_refuses_sealing_without_deleting_it(self):
        check = self.text.index("if (Test-Path -LiteralPath 'C:\\DedicatedDump.sys') {")
        self.assertLess(check, self.text.index('if ($hasFailure) {'))
        self.assertNotRegex(self.text, r'Remove-Item[^\n]*DedicatedDump\.sys')
        # The only cleanup call is the one for the two ISO cache paths (checked in the stale-files test).
        self.assertEqual(self.text.count('Remove-SetupCacheFile'), 2)

    def test_sealing_command_uses_the_full_sysprep_path(self):
        self.assertIn('C:\\Windows\\System32\\Sysprep\\sysprep.exe /generalize /oobe /shutdown /quiet', self.text)
        self.assertNotRegex(self.text, r'with: sysprep ')
        self.assertIn('Fix the issues (re-run golden-image-pre-reboot.ps1 if needed), then re-run this script.', self.text)

    def test_expected_crash_control_values_match_the_data_file(self):
        recommended = json.loads(DATA_FILE.read_text(encoding='utf-8'))['recommended']['values']
        block = re.search(r'(?s)\$expected = \[ordered\]@\{(.*?)\n\}', self.text).group(1)
        expected = {name: int(value) for name, value in re.findall(r'(?m)^\s*(\w+)\s*=\s*(\d+)\s*$', block)}
        self.assertEqual(expected, {name: value for name, value in recommended.items() if isinstance(value, int)})

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
        self.assertEqual(sorted(parsed['functions']), ['Get-PagefileSizeMB', 'Read-ArtifactRecord', 'Remove-SetupCacheFile'])

    def test_minimum_pagefile_size_rounds_once(self):
        ramValues = list(PAGEFILE_SIZES_MB)
        sizes = RunHarness(self, 'call', 'Get-PagefileSizeMB', [[ram] for ram in ramValues])
        self.assertEqual(dict(zip(ramValues, sizes)), PAGEFILE_SIZES_MB)

    def test_artifact_record_reader_matches_pre_reboot_script(self):
        # The pre-reboot tests run the reader against real files; this copy must stay identical.
        own = RunHarness(self, 'definition', 'Read-ArtifactRecord')
        partner = RunHarness(self, 'definition', 'Read-ArtifactRecord', scriptPath=PARTNER_SCRIPT)
        self.assertTrue(partner['found'], 'golden-image-pre-reboot.ps1 lacks Read-ArtifactRecord; include its companion change')
        self.assertEqual(partner['text'], own['text'])

    def test_pagefile_size_matches_pre_reboot_script(self):
        # Fails instead of skipping, so a validation checkout without the pre-reboot change cannot pass.
        own = RunHarness(self, 'definition', 'Get-PagefileSizeMB')
        partner = RunHarness(self, 'definition', 'Get-PagefileSizeMB', scriptPath=PARTNER_SCRIPT)
        self.assertTrue(partner['found'], 'golden-image-pre-reboot.ps1 lacks Get-PagefileSizeMB; include its companion change')
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


class PostRebootMainFlowTests(unittest.TestCase):
    """The whole script, run as it runs on the guest, with every command mocked."""

    VALID = {'memory': ['17179869184'], 'pagefileMB': ['16641']}
    SEAL = 'Write-Host === Seal the image with: C:\\Windows\\System32\\Sysprep\\sysprep.exe /generalize /oobe /shutdown /quiet ==='

    def RunScript(self, states):
        with tempfile.TemporaryDirectory() as tmpDir:
            flowPath, mocksPath = WriteMainFlowFiles(
                self, tmpDir, ['Get-PagefileSizeMB', 'Remove-SetupCacheFile'], postMainFlowMocks, mockedHelperNames=['Read-ArtifactRecord'])
            calls = [{'state': dict(self.VALID, **state), 'args': []} for state in states]
            return [result['log'] for result in RunHarness(self, 'mockcall', 'Invoke-MainFlow', calls,
                                                           scriptPath=flowPath, mocksPath=mocksPath)]

    def AssertRefusedBeforeCleanup(self, log, failure):
        self.assertEqual(log[-1], 'exit 1', log)
        self.assertTrue([line for line in log if line.startswith(f'Write-Error FAIL: {failure}')], log)
        self.assertTrue([line for line in log if line.startswith('Write-Error ===') and 'DO NOT SEAL' in line], log)
        cleanupOrSeal = [line for line in log if line.startswith(('Get-DiskImage', 'Remove-Item')) or 'safe to seal' in line]
        self.assertEqual(cleanupOrSeal, [])

    def testInvalidMemorySizeFailsBeforeCleanupAndSealMessage(self):
        memoryValues = ['error', 'null', '0', '-1073741824']
        for memory, log in zip(memoryValues, self.RunScript([{'memory': [memory], 'pagefileMB': ['300']} for memory in memoryValues])):
            with self.subTest(memory=memory):
                self.AssertRefusedBeforeCleanup(log, 'physical memory size')
                passedChecks = [line for line in log if line.startswith(('Write-Host OK: AutomaticManagedPagefile', 'Write-Host OK: pagefile.sys'))]
                self.assertEqual(passedChecks, [])

    def testValidMemorySizePassesThenRemovesTheISOcacheBeforeSealing(self):
        log = self.RunScript([{}])[0]
        self.assertNotIn('exit 1', log)
        self.assertIn('Write-Host OK: AutomaticManagedPagefile = false', log)
        self.assertIn('Read-ArtifactRecord C:\\ProgramData\\bsod-detector\\virtio-win-iso.json', log)
        self.assertIn('Write-Host OK: virtio-win 9.9.9 from https://fedorapeople.org/virtio-win-9.9.9.iso, SHA-256 ' + 'CD' * 32 +
                      ' (kept in C:\\ProgramData\\bsod-detector\\virtio-win-iso.json)', log)
        removals = [index for index, line in enumerate(log) if line.startswith('Remove-Item')]
        self.assertEqual([log[index] for index in removals],
                         ['Remove-Item C:\\Temp\\virtio-win.iso', 'Remove-Item C:\\Temp\\virtio-win.iso.download'])
        sealIndex = next(index for index, line in enumerate(log) if 'safe to seal' in line)
        self.assertLess(removals[-1], sealIndex)
        self.assertEqual(log[-1], self.SEAL)

    def testEveryFailedCheckRefusesSealingBeforeCleanup(self):
        cases = [
            ({'reg': ['DedicatedDumpFile=C:\\DedicatedDump.sys']}, "DedicatedDumpFile = 'C:\\DedicatedDump.sys'"),
            ({'ddfFile': ['true']}, 'C:\\DedicatedDump.sys from an older preparation still exists'),
            ({'reg': ['CrashDumpEnabled=2']}, "CrashDumpEnabled = '2' (expected '7')"),
            ({'reg': ['AutoReboot=']}, "AutoReboot = '' (expected '0')"),
            ({'auto': ['true']}, 'AutomaticManagedPagefile is still true'),
            ({'pagefileMB': ['16640']}, 'pagefile.sys active but too small - AllocatedBaseSize=16640 MB (expected >= 16641 MB'),
            ({'pagefileMB': ['0']}, 'pagefile.sys not active in running kernel'),
            ({'service': ['stopped']}, 'QEMU-GA not running (status: Stopped)'),
            ({'service': ['missing']}, 'QEMU-GA not running (status: not installed)'),
            ({'record': ['missing']}, 'C:\\ProgramData\\bsod-detector\\virtio-win-iso.json is missing or incomplete'),
            ({'record': ['noHash']}, 'C:\\ProgramData\\bsod-detector\\virtio-win-iso.json is missing or incomplete'),
            ({'record': ['http']}, 'C:\\ProgramData\\bsod-detector\\virtio-win-iso.json is missing or incomplete'),
        ]
        for (state, failure), log in zip(cases, self.RunScript([state for state, _ in cases])):
            with self.subTest(state=state):
                self.AssertRefusedBeforeCleanup(log, failure)

    def testCleanupFailureRefusesSealing(self):
        log = self.RunScript([{'removeFails': ['true']}])[0]
        self.assertEqual(log[-1], 'exit 1', log)
        self.assertIn('Write-Error === Stale setup files remain - DO NOT SEAL. Unmount or close them, remove them and re-run this script. ===', log)
        self.assertFalse([line for line in log if 'safe to seal' in line], log)


if __name__ == '__main__':
    unittest.main()
