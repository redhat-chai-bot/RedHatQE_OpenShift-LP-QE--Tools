#!/usr/bin/env python3
"""Offline checks for golden-image-post-reboot.ps1 against the crash-settings validator contract.

The script reads Windows state on the guest and is never executed here. Static checks
read it as text. The PowerShell checks use fixtures/ps-function-harness.ps1, which only
parses the script and runs single function definitions, taken from its syntax tree, in a
runspace with no cmdlets, providers or applications; functions that invoke commands or .NET
members other than static [math] members are refused. Without `pwsh` those checks are
skipped, or fail when BSOD_DET__TEST__REQUIRE_PWSH=1.

The expectations come from the data and helpers of the read-only validator
(validate-crash-settings.ps1 with src/data/crash-control.json), whose result fields
matchesRecommended, current.AutoReboot and pageFile.adequate are among those the preflight jq
gate requires (the preflight still runs configure-dumps.ps1, not the validator): the script
compares the DWORD values of recommended.values as strings, refuses a non-empty value for each
name in recommended.absentValues, and sizes the page file with the validator's
Get-PagefileSizeMB (RAM + 257 MB, rounded once). Value types, empty-but-present values and
DumpFile are checked only by the validator at run time. Shared constants and the harness runner
come from validator_test_utils, imported as Utils.
"""

from __future__ import annotations

import functools
import json
import re
import sys
import tempfile
import unittest
from collections.abc import Sequence
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import validator_test_utils as Utils  # noqa: E402


SCRIPT = Utils.GUEST_DIR / 'golden-image-post-reboot.ps1'
PARTNER_SCRIPT = Utils.GUEST_DIR / 'golden-image-pre-reboot.ps1'
VALIDATOR_SCRIPT = Utils.SCRIPT
# The guest's physical memory in the main-flow tests and the page file size the validator requires for it.
MAIN_FLOW_RAM_BYTES = 17179869184
MAIN_FLOW_PAGEFILE_MB = Utils.PAGEFILE_SIZES_MB[MAIN_FLOW_RAM_BYTES]


@functools.cache
def ScriptBytes() -> bytes:
    """Raw bytes of golden-image-post-reboot.ps1, read once per test run."""
    return SCRIPT.read_bytes()


@functools.cache
def ScriptText() -> str:
    """golden-image-post-reboot.ps1 as text; non-ASCII bytes become U+FFFD (the ASCII test reports them)."""
    return ScriptBytes().decode('ascii', errors='replace')


@functools.cache
def RecommendedSettings() -> dict[str, Any]:
    """The recommended section of crash-control.json, the data the validator compares with the registry. Read-only."""
    return json.loads(Utils.DATA_FILE.read_text(encoding='utf-8'))['recommended']


def RequiredAbsentNames() -> list[str]:
    """CrashControl values the validator requires to be absent: absentValues, and always DedicatedDumpFile."""
    return sorted({'DedicatedDumpFile', *RecommendedSettings().get('absentValues', [])})


def RecommendedRegistryLiteral() -> str:
    """A PowerShell hashtable of recommended.values: the CrashControl state the validator accepts."""
    values = RecommendedSettings()['values']
    return '@{ ' + '; '.join(f'{Utils.PsLiteral(name)} = {Utils.PsLiteral(value)}' for name, value in values.items()) + ' }'


def ExpectedCrashControlBlock(testCase: unittest.TestCase) -> str:
    """Body of the script's `$expected = [ordered]@{ ... }` block; fails the test when it is missing."""
    match = re.search(r'(?s)\$expected = \[ordered\]@\{(.*?)\n\}', ScriptText())
    testCase.assertIsNotNone(match, 'golden-image-post-reboot.ps1 has no $expected = [ordered]@{ ... } block')
    return match.group(1)


def AssertIndex(testCase: unittest.TestCase, text: str, anchor: str, start: int = 0) -> int:
    """Index of `anchor` in `text` at or after `start`; fails the test with a message when it is missing."""
    testCase.assertIn(anchor, text[start:], f'golden-image-post-reboot.ps1 lacks {anchor!r}')
    return text.index(anchor, start)


def RunHarness(testCase: unittest.TestCase, mode: str, functionName: str = '', calls: list[Any] | None = None,
               scriptPath: Path = SCRIPT, expectSuccess: bool = True, mocksPath: Path | None = None) -> Any:
    """Utils.RunHarness with the post-reboot script as the default target."""
    return Utils.RunHarness(testCase, mode, functionName=functionName, calls=calls, scriptPath=scriptPath,
                            expectSuccess=expectSuccess, mocksPath=mocksPath)


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


def WriteMainFlowFiles(testCase: unittest.TestCase, tmpDir: str, helperNames: Sequence[str], mocks: str,
                       startLine: str | None = None, mockedHelperNames: Sequence[str] = ()) -> tuple[Path, Path]:
    """Writes the script's top-level statements as one function, plus mocks and its own helpers.

    The statements run unchanged inside Invoke-MainFlow in the harness's empty runspace. The
    script's helper functions are loaded next to the mocks (those in mockedHelperNames are only
    removed, so the mocks of the same name are used), and each top-level `exit N` becomes
    `Exit-Script N; return`, which records the status and leaves at the same point.
    """
    scriptText = ScriptText()
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
# values ('Name=Value', or 'Name=' to remove one) on top of recommended.values from crash-control.json
# (the state the validator accepts); 'missing' lists paths that do not exist,
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
    $values = @@RECOMMENDED_VALUES@@
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


@functools.cache
def PostRebootMainFlowMocks() -> str:
    """postMainFlowMocks with the registry defaults taken from recommended.values."""
    return postMainFlowMocks.replace('@@RECOMMENDED_VALUES@@', RecommendedRegistryLiteral())


class PostRebootStaticTests(unittest.TestCase):
    def test_PostRebootSource_IsASCIIforWindowsPowerShell51(self) -> None:
        # Windows PowerShell 5.1 reads BOM-less files as ANSI; UTF-8 punctuation can end strings early.
        self.assertTrue(ScriptBytes().isascii())

    def test_PostRebootSource_EndsWithNewline(self) -> None:
        self.assertTrue(ScriptBytes().endswith(b'\n'))

    def test_PagefileCheck_UsesGetPagefileSizeMB(self) -> None:
        self.assertIn('$expectedMinMB = Get-PagefileSizeMB $computer.TotalPhysicalMemory', ScriptText())
        self.assertIsNone(re.search(r'\)\s*\+\s*257\b', ScriptText()))

    def test_RemoveSetupCacheFile_RunsOnlyAfterEveryCheckPassed(self) -> None:
        text = ScriptText()
        gate = AssertIndex(self, text, 'if ($hasFailure) {')
        cleanup = AssertIndex(self, text, "Remove-SetupCacheFile @('C:\\Temp\\virtio-win.iso', 'C:\\Temp\\virtio-win.iso.download')")
        failureExit = AssertIndex(self, text, 'exit 1', cleanup)
        success = AssertIndex(self, text, 'safe to seal the golden image')
        self.assertLess(gate, cleanup)
        self.assertLess(failureExit, success)
        self.assertEqual(text.count('Remove-Item'), 1)
        self.assertIn('Remove-Item -LiteralPath $path -Force -ErrorAction Stop', text)
        self.assertIn('Test-Path -LiteralPath $path', text)

    def test_LeftoverPaths_MatchThePreRebootScript(self) -> None:
        # Unconditional, so a validation checkout without the pre-reboot change fails instead of passing.
        partner = PARTNER_SCRIPT.read_text(encoding='utf-8')
        self.assertIn("$isoPath = 'C:\\Temp\\virtio-win.iso'", partner)
        self.assertIn('$isoTmpPath = "${isoPath}.download"', partner)

    def test_ISOrecord_IsCheckedAndKeptAtThePreRebootPath(self) -> None:
        text = ScriptText()
        record = "$isoRecordPath = 'C:\\ProgramData\\bsod-detector\\virtio-win-iso.json'"
        self.assertIn(record, text)
        self.assertIn(record, PARTNER_SCRIPT.read_text(encoding='utf-8'))
        # The record checks precede the failure gate; the cleanup removes only the ISO cache files.
        self.assertLess(AssertIndex(self, text, '$isoRecord = Read-ArtifactRecord $isoRecordPath'), AssertIndex(self, text, 'if ($hasFailure) {'))
        cleanupLine = next(line for line in text.splitlines() if 'Remove-SetupCacheFile @(' in line)
        self.assertNotIn('ProgramData', cleanupLine)

    def test_ErrorActionPreference_FailuresIgnoreTheCallersPreference(self) -> None:
        text = ScriptText()
        self.assertIn("$ErrorActionPreference = 'Continue'", text)
        self.assertLess(AssertIndex(self, text, "$ErrorActionPreference = 'Continue'"), AssertIndex(self, text, '    Write-Error '))

    def test_DedicatedDumpFile_OldFileRefusesSealingWithoutDeletion(self) -> None:
        text = ScriptText()
        check = AssertIndex(self, text, "if (Test-Path -LiteralPath 'C:\\DedicatedDump.sys') {")
        self.assertLess(check, AssertIndex(self, text, 'if ($hasFailure) {'))
        self.assertNotRegex(text, r'Remove-Item[^\n]*DedicatedDump\.sys')
        # The only cleanup call is the one for the two ISO cache paths (checked in test_RemoveSetupCacheFile_RunsOnlyAfterEveryCheckPassed).
        self.assertEqual(text.count('Remove-SetupCacheFile'), 2)

    def test_SealMessage_UsesTheFullSysprepPath(self) -> None:
        text = ScriptText()
        self.assertIn('C:\\Windows\\System32\\Sysprep\\sysprep.exe /generalize /oobe /shutdown /quiet', text)
        self.assertNotRegex(text, r'with: sysprep ')
        self.assertIn('Fix the issues (re-run golden-image-pre-reboot.ps1 if needed), then re-run this script.', text)

    def test_ExpectedCrashControl_MatchesRecommendedValues(self) -> None:
        # The script verifies the DWORD values; the string DumpFile is compared only by the validator at run time.
        recommended = RecommendedSettings()['values']
        block = ExpectedCrashControlBlock(self)
        expected = {name: int(value) for name, value in re.findall(r'(?m)^\s*(\w+)\s*=\s*(\d+)\s*$', block)}
        self.assertEqual(expected, {name: value for name, value in recommended.items() if isinstance(value, int)})

    def test_ExpectedCrashControl_RefusesEveryValueTheValidatorRequiresAbsent(self) -> None:
        # The validator's matchesRecommended, a field the preflight gate requires, needs every required-absent value missing.
        text = ScriptText()
        block = ExpectedCrashControlBlock(self)
        for name in RequiredAbsentNames():
            with self.subTest(name=name):
                self.assertNotRegex(block, rf'(?m)^\s*{re.escape(name)}\s*=')
                self.assertRegex(text, rf'Get-ItemProperty -Path \$cc -Name {re.escape(name)}\b')
                self.assertRegex(text, rf'Write-Error "FAIL: {re.escape(name)} = [^\n]*must be absent')

    def test_PvpanicNote_DescribesOnlyTheQEMUmonitorDevice(self) -> None:
        text = ScriptText()
        self.assertNotIn('Device is added at runtime by preflight-rhov.sh', text)
        self.assertIn('device_add pvpanic,id=pvpanic0', text)
        self.assertIn('src/scripts/crash-injector/trigger-bsod-intentional.sh', text)
        self.assertIsNone(re.search(r'(?m)^#\s*\$pvpanic', text))

    def test_PostRebootSource_HasNoObsoleteRecoverySettings(self) -> None:
        self.assertNotRegex(ScriptText(), r'(?i)bcdedit|reagentc|recoveryenabled')
        self.assertIn('CrashDumpEnabled', ScriptText())

    def test_PostRebootSource_UsesFormalVariableSyntaxInDoubleQuotes(self) -> None:
        self.assertEqual(Utils.SimpleVariablesInDoubleQuotes(ScriptText()), [])


class PostRebootPowerShellTests(unittest.TestCase):
    def test_PostRebootScript_ParsesForWindowsPowerShell51(self) -> None:
        parsed = RunHarness(self, 'parse')
        self.assertEqual(parsed['utf8Errors'], 0)
        self.assertEqual(parsed['windows1252Errors'], 0)
        self.assertEqual(parsed['ps7OnlyTokens'], [])
        self.assertEqual(parsed['convertibleDoubleQuoted'], [])
        self.assertEqual(parsed['numberTokens'].count('257MB'), 1)
        self.assertEqual(sorted(parsed['functions']), ['Get-PagefileSizeMB', 'Read-ArtifactRecord', 'Remove-SetupCacheFile'])

    def test_GetPagefileSizeMB_RoundsOnce(self) -> None:
        ramValues = list(Utils.PAGEFILE_SIZES_MB)
        sizes = RunHarness(self, 'call', 'Get-PagefileSizeMB', [[ram] for ram in ramValues])
        self.assertEqual(dict(zip(ramValues, sizes)), Utils.PAGEFILE_SIZES_MB)

    def test_ReadArtifactRecord_MatchesThePreRebootScript(self) -> None:
        # The pre-reboot tests run the reader against real files; this copy must stay identical.
        own = RunHarness(self, 'definition', 'Read-ArtifactRecord')
        partner = RunHarness(self, 'definition', 'Read-ArtifactRecord', scriptPath=PARTNER_SCRIPT)
        self.assertTrue(partner['found'], 'golden-image-pre-reboot.ps1 lacks Read-ArtifactRecord; include its companion change')
        self.assertEqual(partner['text'], own['text'])

    def test_GetPagefileSizeMB_MatchesThePreRebootScriptAndTheValidator(self) -> None:
        # The pre-reboot script configures the size and the validator reports it as
        # pageFile.requiredMB, so all three copies must stay identical. The validator contract tests
        # check the same identity from the validator side; this keeps it visible when only this module
        # runs. Fails instead of skipping, so a validation checkout without the companion changes cannot pass.
        own = RunHarness(self, 'definition', 'Get-PagefileSizeMB')
        self.assertTrue(own['found'], 'golden-image-post-reboot.ps1 lacks Get-PagefileSizeMB; include its companion change')
        for partnerScript in (PARTNER_SCRIPT, VALIDATOR_SCRIPT):
            with self.subTest(partner=partnerScript.name):
                partner = RunHarness(self, 'definition', 'Get-PagefileSizeMB', scriptPath=partnerScript)
                self.assertTrue(partner['found'], f'{partnerScript.name} lacks Get-PagefileSizeMB; include its companion change')
                self.assertEqual(partner['text'], own['text'])

    def test_RemoveSetupCacheFile_RemovesOnlyUnmountedCacheFiles(self) -> None:
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

    def test_HarnessMockcall_RefusesUnmockedCommandsAndMethodCalls(self) -> None:
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

    def test_HarnessIsolation_CannotReachHostCommands(self) -> None:
        names = ['Get-CimInstance', 'Get-WindowsDriver', 'Set-Service', 'Remove-Item', 'Get-ChildItem', 'cmd', 'sh']
        results = RunHarness(self, 'isolation', calls=names)
        self.assertEqual(results, {name: 'CommandNotFoundException' for name in names})

    def test_HarnessCall_RefusesFunctionsThatReachOutsideTheRunspace(self) -> None:
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
    """The whole script, run as it runs on the guest, with every command mocked.

    The default state is one the validator accepts: recommended.values in the registry, no
    DedicatedDumpFile and an active page file of exactly the required size.
    """

    VALID = {'memory': [str(MAIN_FLOW_RAM_BYTES)], 'pagefileMB': [str(MAIN_FLOW_PAGEFILE_MB)]}
    SEAL = 'Write-Host === Seal the image with: C:\\Windows\\System32\\Sysprep\\sysprep.exe /generalize /oobe /shutdown /quiet ==='

    def RunScript(self, states: list[dict[str, list[str]]]) -> list[list[str]]:
        with tempfile.TemporaryDirectory() as tmpDir:
            flowPath, mocksPath = WriteMainFlowFiles(
                self, tmpDir, ['Get-PagefileSizeMB', 'Remove-SetupCacheFile'], PostRebootMainFlowMocks(), mockedHelperNames=['Read-ArtifactRecord'])
            calls = [{'state': dict(self.VALID, **state), 'args': []} for state in states]
            return [result['log'] for result in RunHarness(self, 'mockcall', 'Invoke-MainFlow', calls,
                                                           scriptPath=flowPath, mocksPath=mocksPath)]

    def AssertRefusedBeforeCleanup(self, log: list[str], failure: str) -> None:
        self.assertEqual(log[-1], 'exit 1', log)
        self.assertTrue([line for line in log if line.startswith(f'Write-Error FAIL: {failure}')], log)
        self.assertTrue([line for line in log if line.startswith('Write-Error ===') and 'DO NOT SEAL' in line], log)
        cleanupOrSeal = [line for line in log if line.startswith(('Get-DiskImage', 'Remove-Item')) or 'safe to seal' in line]
        self.assertEqual(cleanupOrSeal, [])

    def test_MainFlow_InvalidMemorySizeFailsBeforeCleanupAndSealMessage(self) -> None:
        # The validator leaves pageFile.requiredMB null (not adequate) for the same memory values.
        memoryValues = ['error', 'null', '0', '-1073741824']
        for memory, log in zip(memoryValues, self.RunScript([{'memory': [memory], 'pagefileMB': ['300']} for memory in memoryValues])):
            with self.subTest(memory=memory):
                self.AssertRefusedBeforeCleanup(log, 'physical memory size')
                passedChecks = [line for line in log if line.startswith(('Write-Host OK: AutomaticManagedPagefile', 'Write-Host OK: pagefile.sys'))]
                self.assertEqual(passedChecks, [])

    def test_MainFlow_ValidatorAcceptedStatePassesThenRemovesTheISOcacheBeforeSealing(self) -> None:
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

    def test_MainFlow_EveryFailedCheckRefusesSealingBeforeCleanup(self) -> None:
        tooSmallMB = MAIN_FLOW_PAGEFILE_MB - 1
        absentCases = [({'reg': [f'{name}=C:\\DedicatedDump.sys']}, f"{name} = 'C:\\DedicatedDump.sys'") for name in RequiredAbsentNames()]
        cases = absentCases + [
            ({'ddfFile': ['true']}, 'C:\\DedicatedDump.sys from an older preparation still exists'),
            ({'reg': ['CrashDumpEnabled=2']}, "CrashDumpEnabled = '2' (expected '7')"),
            ({'reg': ['AutoReboot=']}, "AutoReboot = '' (expected '0')"),
            # The preflight gate also requires current.AutoReboot == 0.
            ({'reg': ['AutoReboot=1']}, "AutoReboot = '1' (expected '0')"),
            ({'auto': ['true']}, 'AutomaticManagedPagefile is still true'),
            ({'pagefileMB': [str(tooSmallMB)]},
             f'pagefile.sys active but too small - AllocatedBaseSize={tooSmallMB} MB (expected >= {MAIN_FLOW_PAGEFILE_MB} MB'),
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

    def test_MainFlow_CleanupFailureRefusesSealing(self) -> None:
        log = self.RunScript([{'removeFails': ['true']}])[0]
        self.assertEqual(log[-1], 'exit 1', log)
        self.assertIn('Write-Error === Stale setup files remain - DO NOT SEAL. Unmount or close them, remove them and re-run this script. ===', log)
        self.assertFalse([line for line in log if 'safe to seal' in line], log)


if __name__ == '__main__':
    unittest.main()
