#!/usr/bin/env python3
"""Contract tests of validate-crash-settings.ps1, its host callers and src/data/crash-control.json.

Source and data contracts are read as text; the host callers' shell helpers run in bash with jq;
parsing, the parameter-name scan and binding check (which read the real guest scripts) and the probes
of Fail and Save-HTTPSdownload (temporary files only) run in a real pwsh. These are offline contract
checks, not isolated unit tests.
"""

from __future__ import annotations

import importlib.util
import json
import re
import subprocess
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


class HostCallerContractTests(unittest.TestCase):
    """preflight-rhov.sh and the trigger use the validator, its read-only gates and the staging record."""

    def setUp(self) -> None:
        self.preflight = Utils.PREFLIGHT.read_text(encoding='utf-8')
        self.trigger = Utils.TRIGGER.read_text(encoding='utf-8')

    def test_Preflight_RunsOnlyTheReadOnlyValidator(self) -> None:
        self.assertIn('typeset validatorScript="${BSOD_DET__VALIDATE__CRASH_SETTINGS:-${BSOD_DET__CONFIGURE__DUMPS:-${appDir}/src/scripts/guest/validate-crash-settings.ps1}}"', self.preflight)
        self.assertIn('psfile "${validatorScript}"', self.preflight)
        self.assertIn('"${validatorArgArr[@]}"', self.preflight)
        self.assertIn('ValidatorArgs validatorArgArr "${requireTrigger}"', self.preflight)
        self.assertIn('ValidationAccepted "${validation}" ||', self.preflight)
        self.assertIn('NotMyFaultStaged "${validation}" ||', self.preflight)
        # The deprecated alias may only name the validator: another file is refused before it runs.
        self.assertLess(self.preflight.index('[[ "${validatorScript##*/}" == validate-crash-settings.ps1 ]] ||'),
                        self.preflight.index('psfile "${validatorScript}"'))
        # The documented legacy alias keeps working without a warning echo (preflight runs under xtrace).
        aliasLines = [line for line in self.preflight.splitlines() if 'CONFIGURE__DUMPS' in line and not line.lstrip().startswith('#')]
        self.assertEqual(aliasLines, [line for line in aliasLines if line.startswith('typeset validatorScript=')])
        self.assertNotRegex(self.preflight, r'configure-dumps\.ps1|rebootRequired|configureScript|[Mm]ini[Dd]ump')

    def test_ValidatorArgs_StagesOnlyForRequireTrigger(self) -> None:
        function = Utils.ShellFunction(self.preflight, 'ValidatorArgs')
        for requireTrigger, expected in ((0, ['-dataFile', 'C:\\Windows\\Temp\\crash-control.json']),
                                         (1, ['-dataFile', 'C:\\Windows\\Temp\\crash-control.json', '-stageNotMyFault'])):
            script = (f'set -euo pipefail; shopt -s inherit_errexit\n{function}\n'
                      f'typeset -a argArr2=(); ValidatorArgs argArr2 {requireTrigger}; printf "%s\\n" "${{argArr2[@]}}"')
            result = subprocess.run(['bash', '-c', script], capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.splitlines(), expected)

    def RunGate(self, name: str, document: dict) -> int:
        """Exit status of one preflight jq gate function run in bash on a JSON document."""
        script = f'set -uo pipefail\n{Utils.ShellFunction(self.preflight, name)}\n{name} "$1"'
        return subprocess.run(['bash', '-c', script, 'gate', json.dumps(document)], capture_output=True, text=True).returncode

    def test_ValidationAccepted_AcceptsOnlyAMatchingValidatorResult(self) -> None:
        valid = {'script': 'validate-crash-settings.ps1', 'action': 'validated', 'ok': True, 'matchesRecommended': True,
                 'mismatches': [], 'current': {'AutoReboot': 0}, 'pageFile': {'adequate': True, 'requiredMB': 16641}}
        self.assertEqual(self.RunGate('ValidationAccepted', valid), 0)
        # The former configuration script's apply output, a mismatch, a frozen-VM violation and an inadequate page file.
        oldScript = {key: value for key, value in valid.items() if key not in ('script', 'action')}
        rejected = [dict(oldScript, action='applied', rebootRequired=False), dict(valid, matchesRecommended=False),
                    dict(valid, current={'AutoReboot': 1}), dict(valid, pageFile={'adequate': False}),
                    dict(valid, ok=False), {'ok': False, 'error': 'x', 'script': 'validate-crash-settings.ps1'}]
        for document in rejected:
            with self.subTest(document=document):
                self.assertNotEqual(self.RunGate('ValidationAccepted', document), 0)

    def test_NotMyFaultStaged_RequiresBothHashesFromTheOfficialHost(self) -> None:
        staged = {'notMyFault': {'status': 'staged', 'source': Utils.NMF_SOURCE, 'resolvedSource': Utils.NMF_SOURCE,
                                 'archiveSHA256': 'A' * 64, 'sha256': 'b' * 64, 'version': '4.25', 'signer': Utils.MICROSOFT_SIGNER}}
        self.assertEqual(self.RunGate('NotMyFaultStaged', staged), 0)
        record = staged['notMyFault']
        rejected = [{'notMyFault': {'status': 'not requested'}}, {'notMyFault': dict(record, status='failed')},
                    {'notMyFault': dict(record, sha256=None)}, {'notMyFault': dict(record, archiveSHA256='A' * 63)},
                    {'notMyFault': dict(record, resolvedSource='http://download.sysinternals.com/files/NotMyFault.zip')},
                    {'notMyFault': dict(record, resolvedSource='https://download.sysinternals.com.evil.example/x.zip')}]
        for document in rejected:
            with self.subTest(document=document):
                self.assertNotEqual(self.RunGate('NotMyFaultStaged', document), 0)

    def test_PreflightMetadata_RecordsOnlyTheNotMyFaultArtifact(self) -> None:
        self.assertIn(".notMyFault | .sha256 |= ascii_downcase | .archiveSHA256 |= ascii_downcase", self.preflight)
        self.assertIn('artifacts:{notMyFault:$notMyFault}', self.preflight)
        # The guest agent comes from the golden image: no MSI download, record or override remains.
        self.assertNotRegex(self.preflight, r'qemuGaMsi|QEMU_GA_MSI_URL')

    def test_PreflightAgentGate_FailsWithGoldenImageGuidanceAndNoBootstrap(self) -> None:
        # No bootstrap: no QGA MSI download, upload or install and no alias resolver for it.
        self.assertNotRegex(self.preflight, r'BootstrapQGA|qemu-ga bootstrap|post-bootstrap|qemu-ga-x86_64\.msi|msiexec|ResolveOfficialHTTPS')
        gates = [line for line in self.preflight.splitlines() if line.startswith('[[ "${pingOk}" == 1 ]] || Die')]
        self.assertEqual(len(gates), 1, 'the agent ping gate is missing')
        gate = gates[0]
        for phrase in ('did not answer 5 pings', 'QEMU-GA service installed and running', 'golden-image-pre-reboot.ps1 installs it',
                       'golden-image-post-reboot.ps1 checks it', 'rebuild the image'):
            self.assertIn(phrase, gate)

    def RunAgentGate(self, answerOnPing: int) -> subprocess.CompletedProcess:
        """Runs preflight's ping loop and agent gate in bash; the stub agent answers only on ping number answerOnPing."""
        start = self.preflight.index('typeset pingOk=0\n')
        end = self.preflight.index('\n', self.preflight.index('[[ "${pingOk}" == 1 ]] || Die', start))
        script = ('set -euo pipefail\n'
                  'function Die () { echo "preflight-rhov: ERROR: $*" >&2; exit 1; }\n'
                  'function RunTimed () { shift; "$@"; }\n'
                  'function sleep () { :; }\n'
                  'function FakeAgent () { echo "$1" >> "${PING_LOG}"; (( $(wc -l < "${PING_LOG}") == ANSWER_ON_PING )); }\n'
                  'typeset -a guestAgent=(FakeAgent)\n'
                  + self.preflight[start:end] + '\necho agent-ok\n')
        with tempfile.TemporaryDirectory() as tmpDir:
            return subprocess.run(['bash', '-c', script], capture_output=True, text=True, timeout=60, check=False,
                                  env={'PATH': '/usr/bin:/bin', 'PING_LOG': str(Path(tmpDir) / 'pings'), 'ANSWER_ON_PING': str(answerOnPing)})

    def test_PreflightAgentGate_StopsAfterFiveSilentPingsAndPassesOnAnswer(self) -> None:
        silent = self.RunAgentGate(answerOnPing=0)
        self.assertEqual(silent.returncode, 1, silent.stderr)
        self.assertEqual(silent.stderr.count('ping attempt'), 5)
        self.assertIn('preflight-rhov: ERROR: qemu guest agent did not answer 5 pings', silent.stderr)
        self.assertNotIn('agent-ok', silent.stdout)
        answered = self.RunAgentGate(answerOnPing=3)
        self.assertEqual((answered.returncode, answered.stdout.strip()), (0, 'agent-ok'), answered.stderr)
        self.assertEqual(answered.stderr.count('ping attempt'), 2)

    def test_Dockerfile_ShipsTheValidatorUnderTheNamesPreflightReads(self) -> None:
        dockerfile = (Utils.APP_DIR.parents[1] / 'image' / 'container' / 'bsod-detector' / 'Dockerfile').read_text(encoding='utf-8')
        self.assertIn('COPY apps/bsod-detector/src/scripts/guest/validate-crash-settings.ps1 '
                      '/usr/share/bsod-detector/guest/validate-crash-settings.ps1', dockerfile)
        self.assertIn('BSOD_DET__VALIDATE__CRASH_SETTINGS=/usr/share/bsod-detector/guest/validate-crash-settings.ps1', dockerfile)
        self.assertIn('BSOD_DET__CRASH_CONTROL__FILE=/usr/share/bsod-detector/data/crash-control.json', dockerfile)
        self.assertNotRegex(dockerfile, r'configure-dumps|BSOD_CONFIGURE_DUMPS|[Mm]ini[Dd]ump')
        for name in ('BSOD_DET__VALIDATE__CRASH_SETTINGS', 'BSOD_DET__CRASH_CONTROL__FILE'):
            self.assertIn('${' + name + ':-', self.preflight)

    def test_Trigger_UsesTheStagedLatestNotMyFaultWithoutAHostCopy(self) -> None:
        self.assertNotRegex(self.trigger, r'nmfBin|nmfExpectedSize|put "\$\{nmfBin\}"|[Mm]ini[Dd]ump|minidumpCount')
        self.assertIn('--require-trigger', self.trigger)
        self.assertIn(".artifacts.notMyFault.status == \"staged\"", self.trigger)
        self.assertIn(".memory == false", self.trigger)

    def test_GuestAgentPsfile_PassesTheCamelCaseSwitchToPowerShell(self) -> None:
        spec = importlib.util.spec_from_file_location('guestAgent', Utils.HOST_DIR / 'guest-agent.py')
        MUT = importlib.util.module_from_spec(spec)  # guest-agent.py, the module under test
        spec.loader.exec_module(MUT)
        companions, powershellArgs = MUT._psfile_args(
            ['--companion', 'crash-control.json', 'C:\\Windows\\Temp\\crash-control.json', '--',
             '-dataFile', 'C:\\Windows\\Temp\\crash-control.json', '-stageNotMyFault'])
        self.assertEqual(companions, [('crash-control.json', 'C:\\Windows\\Temp\\crash-control.json')])
        self.assertEqual(powershellArgs, ['-dataFile', 'C:\\Windows\\Temp\\crash-control.json', '-stageNotMyFault'])


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
