#!/usr/bin/env python3
"""Contract tests of validate-crash-settings.ps1 and src/data/crash-control.json.

Source and data contracts are read as text. The public JSON output and exit codes come from the real
validator in a fresh pwsh with its system commands mocked; parsing, the parameter-name scan and binding
check (which read the real guest scripts) and the probes of Fail and Save-HTTPSdownload also run in a
real pwsh (temporary files only). The guest-agent psfile check uses the baseline host helper. These are
offline contract checks, not isolated unit tests; nothing reaches a guest or the network.
"""

from __future__ import annotations

import importlib.util
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import validator_test_utils as Utils  # noqa: E402


class ValidatorSourceContractTests(unittest.TestCase):
    """Source text and data-file contracts of the validator."""

    def setUp(self) -> None:
        self.source = Utils.SCRIPT.read_bytes()
        self.text = self.source.decode('ascii', errors='replace')
        self.data = json.loads(Utils.DATA_FILE.read_text(encoding='utf-8'))

    def test_ValidatorSource_IsASCIIwithFinalNewline(self) -> None:
        self.assertTrue(self.source.isascii())
        self.assertTrue(self.source.endswith(b'\n'))
        self.assertFalse((Utils.GUEST_DIR / 'configure-dumps.ps1').exists())

    def test_ValidatorSource_NeverWritesSettingsOrReboots(self) -> None:
        code = '\n'.join(line for line in self.text.splitlines() if not line.lstrip().startswith('#'))
        self.assertIsNone(Utils.REGISTRY_OR_REBOOT_WRITES.search(code))
        stagingBody = Utils.BlockAfter(self.text, 'function Invoke-NotMyFaultStaging ([string]$source) {')
        downloadBody = Utils.BlockAfter(self.text, 'function Save-HTTPSdownload ([string]$url, [string]$path) {')
        outside = code.replace(stagingBody, '').replace(downloadBody, '')
        self.assertIsNone(Utils.FILE_WRITES.search(outside))
        # Staging happens only behind the intentional switch.
        self.assertEqual(self.text.count('Invoke-NotMyFaultStaging '), 2)
        self.assertIn('if ($stageNotMyFault) {', self.text)
        self.assertIn('Invoke-NotMyFaultStaging', Utils.BlockAfter(self.text, 'if ($stageNotMyFault) {'))
        self.assertNotRegex(self.text, r'(?i)rebootRequired|VerifyOnly|Test-IsAdministrator')

    def test_InvokeNotMyFaultStaging_HasNoPinnedHashAndRemovesEarlierCopyFirst(self) -> None:
        self.assertIsNone(re.search(r'\b[0-9A-Fa-f]{64}\b', self.text))
        stagingBody = Utils.BlockAfter(self.text, 'function Invoke-NotMyFaultStaging ([string]$source) {')
        self.assertNotIn("return 'present'", stagingBody)
        self.assertLess(stagingBody.index('Remove-Item -LiteralPath $stale'), stagingBody.index('Save-HTTPSdownload'))
        self.assertLess(stagingBody.index('Get-NotMyFaultTrustProblem $candidate'), stagingBody.index('Move-Item'))
        self.assertIn("$notMyFault = Invoke-NotMyFaultStaging '" + Utils.NMF_SOURCE + "'", self.text)

    def test_CrashControlData_HasNoSmallDumpAndListsRequiredAbsences(self) -> None:
        self.assertNotIn('small', self.data['crashDumpTypes'])
        self.assertNotIn('MinidumpDir', self.data['recommended']['values'])
        self.assertNotIn('DedicatedDumpFile', self.data['recommended']['values'])
        self.assertEqual(self.data['recommended']['absentValues'], ['DedicatedDumpFile'])
        self.assertNotRegex(Utils.DATA_FILE.read_text(encoding='utf-8'), r'(?i)minidump|configure-dumps')
        self.assertEqual(self.data['recommended']['values']['AutoReboot'], 0)

    def test_ValidatorResult_DeclaresTheJSONcontractFields(self) -> None:
        for field in ('ok', 'action', 'script', 'requestedDumpType', 'registryPath', 'desired', 'current', 'mismatches',
                      'matchesRecommended', 'pageFile', 'notMyFault'):
            self.assertRegex(self.text, rf'(?m)^    {field}\s+= ')
        self.assertIn("$notMyFault = [ordered]@{ status = 'not requested' }", self.text)

    def test_ValidatorSource_UsesFormalVariableSyntaxInDoubleQuotes(self) -> None:
        self.assertEqual(Utils.SimpleVariablesInDoubleQuotes(self.text), [])


class GuestAgentInvocationContractTests(unittest.TestCase):
    """How a host caller hands the validator its arguments through guest-agent.py psfile (baseline host code)."""

    def test_GuestAgentPsfile_PassesTheCamelCaseSwitchToPowerShell(self) -> None:
        spec = importlib.util.spec_from_file_location('guestAgent', Utils.HOST_DIR / 'guest-agent.py')
        MUT = importlib.util.module_from_spec(spec)  # guest-agent.py, the module under test
        spec.loader.exec_module(MUT)
        companions, powershellArgs = MUT._psfile_args(
            ['--companion', 'crash-control.json', 'C:\\Windows\\Temp\\crash-control.json', '--',
             '-dataFile', 'C:\\Windows\\Temp\\crash-control.json', '-stageNotMyFault'])
        self.assertEqual(companions, [('crash-control.json', 'C:\\Windows\\Temp\\crash-control.json')])
        self.assertEqual(powershellArgs, ['-dataFile', 'C:\\Windows\\Temp\\crash-control.json', '-stageNotMyFault'])


class ValidatorJSONContractTests(unittest.TestCase):
    """The validator's public JSON output and exit codes, produced by the real script.

    The real validate-crash-settings.ps1 runs in a fresh pwsh. Only the system commands it calls are
    replaced by test functions: an in-memory CrashControl key, page file entry and memory size, and a
    staging directory that cannot be created (so no download starts; any HTTP request would also go to a
    closed local proxy). Registry, CIM, WMI, reboot, process and file write commands are defined to fail,
    so any such call fails the test. Nothing reaches a guest, the network or a real staging directory.
    """

    PROBE = r'''
param([string]$validator, [string]$scenario, [string]$argsJSON)
# Any HTTP(S) request would go to a closed local port instead of the network.
[System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy('http://127.0.0.1:9')
$crashControlPath = 'CRASH_CONTROL'
$crashControl = @{ CrashDumpEnabled = 7; AutoReboot = 0; AlwaysKeepMemoryDump = 1; Overwrite = 1; LogEvent = 1; DumpFile = '%SystemRoot%\MEMORY.DMP' }
$global:fakeKinds = @{ DumpFile = 'ExpandString' }
if ($scenario -eq 'mismatch') {
    $crashControl['AutoReboot'] = 1
    $crashControl['DedicatedDumpFile'] = 'C:\DedicatedDump.sys'
    $global:fakeKinds['DumpFile'] = 'String'
}
$global:fakeRegistry = @{ $crashControlPath = $crashControl; 'MEMORY_MANAGEMENT' = @{ PagingFiles = [string[]]@('C:\pagefile.sys 16641 16641') } }
function Test-Path ([string]$Path, [string]$LiteralPath) {
    $target = if ($LiteralPath) { $LiteralPath } else { $Path }
    if ($target -like 'HKLM:*') { return $global:fakeRegistry.ContainsKey($target) }
    if ($target -like 'C:\Temp\nmf*') { return $false }  # never touch a real staging directory
    Microsoft.PowerShell.Management\Test-Path -LiteralPath $target
}
function Get-ItemProperty ([string]$Path, [string]$Name, $ErrorAction) {
    $values = $global:fakeRegistry[$Path]
    if ($values -and $values.ContainsKey($Name)) { [pscustomobject]@{ $Name = $values[$Name] } }
}
function Get-Item ([string]$LiteralPath, [string]$Path, $ErrorAction) {
    $target = if ($LiteralPath) { $LiteralPath } else { $Path }
    if ($target -notlike 'HKLM:*') { return Microsoft.PowerShell.Management\Get-Item -LiteralPath $target }
    if (-not $global:fakeRegistry.ContainsKey($target)) { return }
    $key = [pscustomobject]@{ valueTable = $global:fakeRegistry[$target] }
    $key | Add-Member -MemberType ScriptMethod -Name GetValueNames -Value { @($this.valueTable.Keys) }
    $key | Add-Member -MemberType ScriptMethod -Name GetValueKind -Value {
        param($valueName)
        if ($global:fakeKinds.ContainsKey($valueName)) { $global:fakeKinds[$valueName] } elseif ($this.valueTable[$valueName] -is [string]) { 'String' } else { 'DWord' }
    }
    $key
}
function Get-CimInstance ([string]$ClassName, $ErrorAction) { [pscustomobject]@{ TotalPhysicalMemory = [int64]17179869184 } }
function New-Item { throw 'Access to the path is denied (test staging directory).' }
$forbiddenArr = @('Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Rename-ItemProperty', 'Clear-ItemProperty',
    'Set-CimInstance', 'New-CimInstance', 'Invoke-CimMethod', 'Set-WmiInstance', 'Restart-Computer', 'Stop-Computer', 'Start-Process',
    'Remove-Item', 'Move-Item', 'Expand-Archive', 'Unblock-File', 'Set-Content', 'Set-Item')
foreach ($name in $forbiddenArr) {
    Invoke-Expression "function global:${name} { [Console]::Error.WriteLine('forbidden: ${name}'); throw 'forbidden: ${name}' }"
}
$splat = @{}
foreach ($property in (ConvertFrom-Json $argsJSON).PSObject.Properties) { $splat[$property.Name] = $property.Value }
$global:LASTEXITCODE = 0
& $validator @splat
exit $LASTEXITCODE
'''.replace('CRASH_CONTROL', Utils.CRASH_CONTROL).replace('MEMORY_MANAGEMENT', Utils.MEMORY_MANAGEMENT)

    RESULT_KEYS = ['ok', 'action', 'script', 'requestedDumpType', 'registryPath', 'desired', 'current', 'mismatches',
                   'matchesRecommended', 'pageFile', 'notMyFault']

    def RunValidator(self, scenario: str, arguments: dict) -> tuple[int, dict]:
        """Exit code and parsed JSON of one real validator run with mocked system commands."""
        with tempfile.TemporaryDirectory() as tmpDir:
            dataFile = Path(tmpDir) / 'crash-control.json'
            dataFile.write_text(Utils.DATA_FILE.read_text(encoding='utf-8'), encoding='utf-8')
            probe = Path(tmpDir) / 'probe.ps1'
            probe.write_text(self.PROBE, encoding='ascii')
            arguments = {key: (str(dataFile) if value == 'DATA_FILE' else value) for key, value in arguments.items()}
            result = Utils.RunPwshScript(self, probe, str(Utils.SCRIPT), scenario, json.dumps(arguments))
        self.assertNotIn('forbidden:', result.stderr)
        self.assertTrue(result.stdout.strip(), result.stderr)
        return result.returncode, json.loads(result.stdout)

    def test_ValidatorOutput_MatchingSettingsReportTheFullContract(self) -> None:
        exitCode, output = self.RunValidator('golden', {'dataFile': 'DATA_FILE'})
        self.assertEqual(exitCode, 0)
        self.assertEqual(list(output), self.RESULT_KEYS)
        data = json.loads(Utils.DATA_FILE.read_text(encoding='utf-8'))
        self.assertIs(output['ok'], True)
        self.assertEqual((output['action'], output['script']), ('validated', 'validate-crash-settings.ps1'))
        self.assertEqual((output['requestedDumpType'], output['registryPath']), (data['recommended']['crashDumpType'], Utils.CRASH_CONTROL))
        self.assertEqual(sorted(output['desired']), sorted(name for name in data['recommended']['values'] if name != 'DedicatedDumpFile'))
        self.assertIs(type(output['desired']['AutoReboot']), int)
        # current holds every desired value as read (callers check current.AutoReboot) and each required absence.
        self.assertEqual(output['current'], dict(output['desired'], DedicatedDumpFile=None))
        self.assertIs(type(output['current']['AutoReboot']), int)
        self.assertEqual(output['mismatches'], [])
        self.assertIs(output['matchesRecommended'], True)
        self.assertEqual(output['pageFile'], {'configured': 'C:\\pagefile.sys 16641 16641', 'adequate': True, 'requiredMB': 16641})
        self.assertIs(output['pageFile']['adequate'], True)
        self.assertIs(type(output['pageFile']['requiredMB']), int)
        self.assertEqual(output['notMyFault'], {'status': 'not requested'})

    def test_ValidatorOutput_MismatchesAreTypedAndKeepExitCodeZero(self) -> None:
        # The former parameter spelling still binds (case-insensitive, no aliases).
        exitCode, output = self.RunValidator('mismatch', {'DataFile': 'DATA_FILE'})
        self.assertEqual(exitCode, 0)
        self.assertIs(output['ok'], True)
        self.assertIs(output['matchesRecommended'], False)
        self.assertEqual(output['current']['AutoReboot'], 1)
        byName = {entry['name']: entry for entry in output['mismatches']}
        for entry in output['mismatches']:
            self.assertEqual(list(entry), ['name', 'issue', 'expected', 'actual', 'expectedType', 'actualType'])
        self.assertEqual({name: entry['issue'] for name, entry in byName.items()},
                         {'AutoReboot': 'wrong value', 'DumpFile': 'wrong type', 'DedicatedDumpFile': 'must be absent'})
        self.assertEqual((byName['AutoReboot']['expected'], byName['AutoReboot']['actual'], byName['AutoReboot']['expectedType']), (0, 1, 'DWord'))
        self.assertEqual((byName['DumpFile']['expectedType'], byName['DumpFile']['actualType']), ('ExpandString', 'String'))
        self.assertEqual((byName['DedicatedDumpFile']['expected'], byName['DedicatedDumpFile']['actual']), (None, 'C:\\DedicatedDump.sys'))

    def test_ValidatorOutput_UnknownDumpTypeExitsTwoWithTheErrorShape(self) -> None:
        exitCode, output = self.RunValidator('golden', {'dataFile': 'DATA_FILE', 'dumpType': 'small'})
        self.assertEqual(exitCode, 2)
        self.assertEqual(list(output), ['ok', 'error', 'script'])
        self.assertIs(output['ok'], False)
        self.assertEqual(output['script'], 'validate-crash-settings.ps1')
        self.assertTrue(output['error'].startswith("Unknown dump type 'small'"), output['error'])

    def test_ValidatorOutput_StagingFailureExitsFourAndKeepsTheSettingsResult(self) -> None:
        exitCode, output = self.RunValidator('mismatch', {'dataFile': 'DATA_FILE', 'stageNotMyFault': True})
        self.assertEqual(exitCode, 4)
        self.assertEqual(list(output), self.RESULT_KEYS + ['error'])
        self.assertIs(output['ok'], False)
        self.assertEqual(output['action'], 'validated')
        self.assertTrue(output['error'].startswith('NotMyFault could not be staged: '), output['error'])
        # The settings result survives the staging failure.
        self.assertIs(output['matchesRecommended'], False)
        self.assertEqual({entry['name'] for entry in output['mismatches']}, {'AutoReboot', 'DumpFile', 'DedicatedDumpFile'})
        self.assertIs(output['pageFile']['adequate'], True)
        self.assertEqual(list(output['notMyFault']), ['status', 'source', 'resolvedSource', 'archiveSHA256', 'sha256', 'version', 'signer',
                                                     'stagedPath', 'problem'])
        self.assertEqual(output['notMyFault']['status'], 'failed')
        # The staging directory could not be created, so no download was attempted and nothing was recorded.
        self.assertIn('Access to the path is denied (test staging directory).', output['notMyFault']['problem'])
        self.assertEqual((output['notMyFault']['resolvedSource'], output['notMyFault']['sha256']), (None, None))


class ValidatorScriptContractTests(unittest.TestCase):
    """Parsing, identity with the golden-image copies, parameter naming and binding, and real-pwsh probes."""

    def test_ValidatorScript_ParsesForWindowsPowerShell51(self) -> None:
        parsed = Utils.RunHarness(self, 'parse')
        self.assertEqual(parsed['utf8Errors'], 0)
        self.assertEqual(parsed['windows1252Errors'], 0)
        self.assertEqual(parsed['ps7OnlyTokens'], [])
        self.assertEqual(parsed['convertibleDoubleQuoted'], [])
        self.assertEqual(sorted(parsed['functions']), Utils.SCRIPT_FUNCTIONS)

    def test_SharedHelpers_MatchTheGoldenImageScripts(self) -> None:
        # A missing sibling change fails instead of skipping.
        own = Utils.RunHarness(self, 'definition', 'Get-PagefileSizeMB')
        for partnerScript in Utils.PARTNER_SCRIPTS:
            partner = Utils.RunHarness(self, 'definition', 'Get-PagefileSizeMB', scriptPath=partnerScript)
            self.assertTrue(partner['found'], f'{partnerScript.name} lacks Get-PagefileSizeMB; include its companion change')
            self.assertEqual(partner['text'], own['text'])
        for name in Utils.SHARED_DOWNLOAD_HELPERS:
            own = Utils.RunHarness(self, 'definition', name)
            partner = Utils.RunHarness(self, 'definition', name, scriptPath=Utils.PARTNER_SCRIPTS[0])
            self.assertTrue(partner['found'], f'golden-image-pre-reboot.ps1 lacks {name}; include its companion change')
            self.assertEqual(partner['text'], own['text'])

    def test_GuestScripts_DeclareCamelCaseParameters(self) -> None:
        """Every parameter the guest scripts and the harness declare (script and functions) is camelCase, without aliases."""
        with tempfile.TemporaryDirectory() as tmpDir:
            probe = Path(tmpDir) / 'params.ps1'
            probe.write_text("""
foreach ($file in $args) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
    $paramArr = @()
    if ($ast.ParamBlock) { $paramArr += $ast.ParamBlock.Parameters }
    foreach ($fn in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if ($fn.Parameters) { $paramArr += $fn.Parameters }
        if ($fn.Body.ParamBlock) { $paramArr += $fn.Body.ParamBlock.Parameters }
    }
    foreach ($p in $paramArr) {
        $isAlias = @($p.Attributes | Where-Object { $_.TypeName.FullName -match '^(System\\.Management\\.Automation\\.)?Alias(Attribute)?$' }).Count -gt 0
        '{0}|{1}{2}' -f (Split-Path -Leaf $file), $p.Name.VariablePath.UserPath, $(if ($isAlias) { '|ALIAS' } else { '' })
    }
}
""", encoding='ascii')
            scripts = [*sorted(Utils.GUEST_DIR.glob('*.ps1')), Utils.HARNESS]
            result = Utils.RunPwshScript(self, probe, *map(str, scripts))
        self.assertEqual(result.returncode, 0, result.stderr)
        declared = result.stdout.split()
        self.assertGreater(len(declared), 30)
        self.assertEqual([entry for entry in declared if not re.match(r'^[^|]+\|[a-z][A-Za-z0-9]*$', entry)], [])
        self.assertIn('validate-crash-settings.ps1|stageNotMyFault', declared)
        self.assertIn('ps-function-harness.ps1|callsJSON', declared)

    def test_ValidatorParameters_BindCamelCaseAndFormerSpellings(self) -> None:
        """The camelCase parameters still bind -DataFile/-StageNotMyFault/-DumpType (case-insensitive, no aliases)."""
        with tempfile.TemporaryDirectory() as tmpDir:
            probe = Path(tmpDir) / 'binding.ps1'
            probe.write_text("""
$ast = [System.Management.Automation.Language.Parser]::ParseFile($args[0], [ref]$null, [ref]$null)
$bind = [scriptblock]::Create($ast.ParamBlock.Extent.Text + "`n" + '"{0}|{1}|{2}" -f $dumpType, [bool]$stageNotMyFault, $dataFile')
& $bind -dumpType 'automatic' -stageNotMyFault -dataFile 'C:\\data.json'
& $bind -DumpType 'automatic' -StageNotMyFault -DataFile 'C:\\data.json'
& $bind -dataFile 'C:\\data.json'
""", encoding='ascii')
            result = Utils.RunPwshScript(self, probe, str(Utils.SCRIPT))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), ['automatic|True|C:\\data.json', 'automatic|True|C:\\data.json', '|False|C:\\data.json'])

    def test_Fail_KeepsTheValidationResultAndExitCode(self) -> None:
        definition = Utils.RunHarness(self, 'definition', 'Fail')
        with tempfile.TemporaryDirectory() as tmpDir:
            outputs = []
            for call, code in (("Fail 'NotMyFault could not be staged: download failed' 4 ([ordered]@{ ok = $true; action = 'validated'; "
                                "script = 'validate-crash-settings.ps1'; mismatches = @([ordered]@{ name = 'AutoReboot'; issue = 'missing' }); "
                                "matchesRecommended = $false; notMyFault = [ordered]@{ status = 'failed' } })", 4),
                               ("Fail 'Unknown dump type' 2", 2)):
                probe = Path(tmpDir) / f'probe{code}.ps1'
                probe.write_text(f"Set-StrictMode -Version Latest\n{definition['text']}\n{call}\n'not reached'\n", encoding='ascii')
                result = Utils.RunPwshScript(self, probe)
                self.assertEqual(result.returncode, code, result.stderr)
                outputs.append(json.loads(result.stdout))
        staging, unknown = outputs
        self.assertEqual((staging['ok'], staging['error'], staging['action']), (False, 'NotMyFault could not be staged: download failed', 'validated'))
        self.assertEqual(staging['mismatches'], [{'name': 'AutoReboot', 'issue': 'missing'}])
        self.assertEqual(staging['notMyFault'], {'status': 'failed'})
        self.assertEqual(unknown, {'ok': False, 'error': 'Unknown dump type', 'script': 'validate-crash-settings.ps1'})

    def test_SaveHTTPSdownload_RefusesPlainHTTPandRedirects(self) -> None:
        definition = Utils.RunHarness(self, 'definition', 'Save-HTTPSdownload')
        self.assertIn('$request.AllowAutoRedirect = $false', definition['text'])
        self.assertIn('if ([int]$response.StatusCode -ne 200) { throw', definition['text'])
        self.assertNotIn('WebClient', Utils.SCRIPT.read_text(encoding='ascii'))
        # A plain http:// URL is refused before any request is made (real cmdlets, no network access).
        with tempfile.TemporaryDirectory() as tmpDir:
            probe = Path(tmpDir) / 'probe.ps1'
            probe.write_text(definition['text'] + "\ntry { Save-HTTPSdownload 'http://download.sysinternals.com/files/NotMyFault.zip' "
                             f"'{Path(tmpDir) / 'x.zip'}'; 'downloaded' }} catch {{ $_.Exception.Message }}\n", encoding='ascii')
            result = Utils.RunPwshScript(self, probe)
            self.assertEqual(result.stdout.strip(), 'not an HTTPS URL: http://download.sysinternals.com/files/NotMyFault.zip', result.stderr)
            self.assertFalse((Path(tmpDir) / 'x.zip').exists())

if __name__ == '__main__':
    unittest.main()
