#!/usr/bin/env python3
"""Offline checks for configure-dumps.ps1 and src/data/crash-control.json.

The script writes the guest registry and downloads NotMyFault, so it is never executed on the
test host. Static checks read it as text. The PowerShell checks use fixtures/ps-function-harness.ps1,
which only parses the script and runs single functions, taken from its syntax tree, in a runspace
with no cmdlets, providers or applications. The main-flow tests run the script's top-level
statements the same way, with every command mocked and the registry simulated in memory. Without
`pwsh` those checks are skipped, or fail when BSOD_DET__TEST__REQUIRE_PWSH=1.
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

MICROSOFT_SIGNER = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
OTHER_SIGNER = 'CN=Contoso, O=Contoso Ltd, C=US'
LOOKALIKE_SIGNER = 'CN=Microsoft Corporation, O=Microsoft Corporation Fake, C=US'
QUOTED_OU_SIGNER = 'CN=Contoso, OU="Dev, O=Microsoft Corporation, x", O=Contoso Ltd, C=US'

# Mock cmdlets for Invoke-NotMyFaultStaging; they exist only inside the harness's empty runspace,
# record each call and simulate the guest file system from $global:MockState. A signature is
# 'Status|Subject'; 'cachedSig' applies before the download and 'downloadedSig' after it.
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
    $global:MockState['downloaded'] = 'true'
    if ($global:MockState['extractCreates'] -contains 'true') { $global:MockState['existing'] = @($global:MockState['existing']) + 'C:\Temp\nmf\notmyfaultc64.exe' }
}
function Get-AuthenticodeSignature ([string]$LiteralPath) {
    $global:MockLog.Add("Get-AuthenticodeSignature ${LiteralPath}")
    $key = if ($global:MockState['downloaded'] -contains 'true') { 'downloadedSig' } else { 'cachedSig' }
    $status, $subject = "$($global:MockState[$key])" -split '\|', 2
    $certificate = if ($subject) { [pscustomobject]@{ Subject = $subject } } else { $null }
    [pscustomobject]@{ Status = $status; SignerCertificate = $certificate }
}
function Move-Item ([string]$LiteralPath, [string]$Destination, [switch]$Force) {
    $global:MockLog.Add("Move-Item ${LiteralPath} ${Destination}")
    if ($global:MockState['moveFails'] -contains 'true') { throw 'Access to the path is denied.' }
    $global:MockState['existing'] = @($global:MockState['existing'] | Where-Object { $_ -ne $LiteralPath })
}
function Where-Object ([scriptblock]$FilterScript) {
    process {
        $context = [System.Collections.Generic.List[psvariable]]@([psvariable]::new('_', $_))
        if ($FilterScript.InvokeWithContext($null, $context)) { $_ }
    }
}
function Remove-Item ([string]$LiteralPath, [switch]$Force, $ErrorAction) { $global:MockLog.Add("Remove-Item ${LiteralPath}") }
function Unblock-File ([string]$Path, $ErrorAction) { $global:MockLog.Add("Unblock-File ${Path}") }
'''

# Mocks for Remove-DedicatedDumpFile (together with the script's own Get-RegValue).
REMOVAL_MOCKS = r'''
function Get-ItemProperty ([string]$Path, [string]$Name, $ErrorAction) {
    $global:MockLog.Add("Get-ItemProperty ${Name}")
    if ($global:MockState['ddf'] -contains 'present') { [pscustomobject]@{ DedicatedDumpFile = 'C:\DedicatedDump.sys' } }
}
function Remove-ItemProperty ([string]$Path, [string]$Name, $ErrorAction) {
    $global:MockLog.Add("Remove-ItemProperty ${Name} ErrorAction=${ErrorAction}")
    # Like the real cmdlet, a failure terminates only with -ErrorAction Stop.
    if ($global:MockState['removeFails'] -contains 'true' -and "${ErrorAction}" -eq 'Stop') { throw 'Requested registry access is not allowed.' }
}
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


WRITE_OR_DOWNLOAD = re.compile(r'\b(New-ItemProperty|Remove-ItemProperty|Set-ItemProperty|New-Item|Remove-Item|Move-Item|Expand-Archive|Unblock-File)\b|DownloadFile')


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
        self.assertIn("Remove-ItemProperty -Path $Path -Name 'DedicatedDumpFile' -ErrorAction Stop", self.text)
        self.assertNotRegex(self.text, r'Remove-ItemProperty[^\n]*DedicatedDumpFile[^\n]*SilentlyContinue')

    def test_writes_happen_only_in_apply_mode_or_opt_in_staging(self):
        applyBlock = BlockAfter(self.text, 'if (-not $VerifyOnly) {')
        stagingBody = BlockAfter(self.text, 'function Invoke-NotMyFaultStaging ([bool]$IsVerifyOnly, [bool]$IsStageRequested) {')
        downloadBody = BlockAfter(self.text, 'function Save-NotMyFaultArchive ([string]$Path) {')
        removalBody = BlockAfter(self.text, 'function Remove-DedicatedDumpFile ([string]$Path) {')
        outside = self.text
        for block in (applyBlock, stagingBody, downloadBody, removalBody):
            outside = outside.replace(block, '')
        self.assertIsNone(WRITE_OR_DOWNLOAD.search(outside))
        self.assertIsNotNone(WRITE_OR_DOWNLOAD.search(applyBlock))
        # The removal helper is called once, from the apply block only.
        self.assertEqual(self.text.count('Remove-DedicatedDumpFile $regPath'), 1)
        self.assertIn('Remove-DedicatedDumpFile $regPath', applyBlock)
        self.assertEqual(self.text.count('= Invoke-NotMyFaultStaging '), 1)
        self.assertIn('$nmfStatus = Invoke-NotMyFaultStaging ([bool]$VerifyOnly) ([bool]$StageNotMyFault)', self.text)
        self.assertEqual(self.text.count('Save-NotMyFaultArchive $zip'), 1)
        # The read-only and opt-in guards come before any write in the staging function.
        firstWrite = stagingBody.index('New-Item')
        self.assertLess(stagingBody.index('if ($IsVerifyOnly) { return'), firstWrite)
        self.assertLess(stagingBody.index('if (-not $IsStageRequested) { return'), firstWrite)

    def test_staging_switch_documentation_matches_the_host_preflight(self):
        # The help text must not claim that a host script passes -StageNotMyFault. Whichever
        # preflight version is present, it must never stage NotMyFault for watch runs.
        self.assertNotIn('The host\n    preflight passes it', self.text)
        self.assertNotRegex(self.text, r'preflight(-rhov\.sh)? passes (it|-StageNotMyFault)')
        self.assertIn('Nothing passes this switch implicitly', self.text)
        preflight = (HOST_DIR / 'preflight-rhov.sh').read_text(encoding='utf-8')
        function = re.search(r'(?ms)^function ConfigureDumpsArgs \(\) \{.*?^\}', preflight)
        if function is None:
            self.assertNotIn('-StageNotMyFault', preflight)
            return
        for requireTrigger, expected in ((0, ['-DataFile', 'C:\\Windows\\Temp\\crash-control.json']),
                                         (1, ['-DataFile', 'C:\\Windows\\Temp\\crash-control.json', '-StageNotMyFault'])):
            script = (f'set -euo pipefail; shopt -s inherit_errexit\n{function.group(0)}\n'
                      f'typeset -a argArr2=(); ConfigureDumpsArgs argArr2 {requireTrigger}; printf "%s\\n" "${{argArr2[@]}}"')
            result = subprocess.run(['bash', '-c', script], capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.splitlines(), expected)
        # The function must be called with the --require-trigger state and its result passed on.
        self.assertIn('ConfigureDumpsArgs configureArgArr "${requireTrigger}"', preflight)
        self.assertIn('"${configureArgArr[@]}")"', preflight)
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
        self.assertIn('[Console]::Error.WriteLine("configure-dumps.ps1: ${Message}")',
                      BlockAfter(self.text, 'function Write-StdErr ([string]$Message) {'))
        self.assertIn('Write-StdErr "WARN: NotMyFault staging to C:\\Temp\\nmf: ${nmfStatus}"', self.text)
        self.assertIn("$nmfDir = 'C:\\Temp\\nmf'", self.text)

    def test_notmyfault_is_trusted_only_after_a_signature_check(self):
        stagingBody = BlockAfter(self.text, 'function Invoke-NotMyFaultStaging ([bool]$IsVerifyOnly, [bool]$IsStageRequested) {')
        # Both the cached and the downloaded copy are checked, and the downloaded one before it is unblocked.
        self.assertEqual(stagingBody.count('Get-NotMyFaultTrustProblem $nmfPath'), 2)
        self.assertLess(stagingBody.index("return 'present'"), stagingBody.index('Save-NotMyFaultArchive'))
        self.assertLess(stagingBody.rindex('Get-NotMyFaultTrustProblem $nmfPath'), stagingBody.index('Unblock-File'))
        self.assertIn('Get-AuthenticodeSignature -LiteralPath $Path', self.text)
        # A copy that could not be renamed away stops the script instead of staying in place.
        self.assertIn("if ($nmfStatus -like 'unsafe*') { Fail \"NotMyFault staging: ${nmfStatus}\" 5 }", self.text)

    def test_tls_is_added_not_replaced(self):
        self.assertIn('[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12', self.text)

    def test_json_contract_fields(self):
        self.assertIn('pageFile           = [ordered]@{ configured = $pfConfigured; adequate = $isPfAdequate; requiredMB = $requiredMB }', self.text)
        for field in ('ok', 'action', 'requestedDumpType', 'applied', 'current', 'dedicatedDumpFile', 'matchesRecommended', 'rebootRequired'):
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
        self.assertEqual(sorted(parsed['functions']), SCRIPT_FUNCTIONS)

    def test_required_pagefile_size_matches_golden_image(self):
        ramValues = list(PAGEFILE_SIZES_MB)
        sizes = RunHarness(self, 'call', 'Get-PagefileSizeMB', [[ram] for ram in ramValues])
        self.assertEqual(dict(zip(ramValues, sizes)), PAGEFILE_SIZES_MB)

    def test_pagefile_size_function_matches_golden_image_scripts(self):
        # A missing sibling change fails instead of skipping, so a validation checkout that lacks
        # the golden-image script changes cannot pass.
        own = RunHarness(self, 'definition', 'Get-PagefileSizeMB')
        for partnerScript in PARTNER_SCRIPTS:
            partner = RunHarness(self, 'definition', 'Get-PagefileSizeMB', scriptPath=partnerScript)
            self.assertTrue(partner['found'], f'{partnerScript.name} lacks Get-PagefileSizeMB; include its companion change')
            self.assertEqual(partner['text'], own['text'])

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

    def test_notmyfault_staging_is_opt_in_verified_and_never_in_verify_only(self):
        trusted, tampered = f'Valid|{MICROSOFT_SIGNER}', f'HashMismatch|{MICROSOFT_SIGNER}'
        cases = [
            {'state': {}, 'args': [False, False]},                                                     # default / watch
            {'state': {}, 'args': [True, True]},                                                       # -VerifyOnly with opt-in
            {'state': {'existing': [NMF_PATH], 'cachedSig': [trusted]}, 'args': [False, True]},        # trusted cached copy
            {'state': {'extractCreates': ['true'], 'downloadedSig': [trusted]}, 'args': [False, True]},  # stages when missing
            {'state': {'downloadFails': ['true']}, 'args': [False, True]},                             # download error
            {'state': {'downloadedSig': [trusted]}, 'args': [False, True]},                            # archive without the binary
            {'state': {'existing': [NMF_PATH], 'cachedSig': [tampered], 'extractCreates': ['true'],
                       'downloadedSig': [trusted]}, 'args': [False, True]},                            # untrusted cache replaced
            {'state': {'extractCreates': ['true'], 'downloadedSig': ['NotSigned|']}, 'args': [False, True]},  # unsigned download
            {'state': {'extractCreates': ['true'], 'downloadedSig': [f'Valid|{OTHER_SIGNER}']}, 'args': [False, True]},  # other publisher
            {'state': {'existing': [NMF_PATH], 'cachedSig': [tampered], 'moveFails': ['true']}, 'args': [False, True]},  # rename fails
            {'state': {'extractCreates': ['true'], 'downloadedSig': ['NotSigned|'], 'moveFails': ['true']}, 'args': [False, True]},
            {'state': {'existing': [NMF_PATH], 'cachedSig': [tampered], 'downloadFails': ['true']}, 'args': [False, True]},  # replaced, then download fails
        ]
        with tempfile.TemporaryDirectory() as tmpDir:
            mocks = Path(tmpDir) / 'mocks.ps1'
            mocks.write_text(STAGING_MOCKS + '\n' + RunHarness(self, 'definition', 'Get-NotMyFaultTrustProblem')['text'] + '\n',
                             encoding='ascii')
            results = RunHarness(self, 'mockcall', 'Invoke-NotMyFaultStaging', cases, mocksPath=mocks)
        default, verifyOnly, present, staged, downloadError, noBinary, replaced, unsigned, otherPublisher, cachedStuck, downloadStuck, replacedThenFailed = results
        downloads = lambda result: [entry for entry in result['log'] if entry.startswith('Save-NotMyFaultArchive')]
        writes = lambda result: [entry for entry in result['log'] if not entry.startswith(('Test-Path', 'Save-', 'Get-Authenticode'))]
        quarantine = f'Move-Item {NMF_PATH} {NMF_PATH}.untrusted'
        self.assertEqual(default['output'], ['skipped: not requested'])
        self.assertEqual(default['log'], [])
        self.assertEqual(verifyOnly['output'], ['skipped: -VerifyOnly is read-only'])
        self.assertEqual(verifyOnly['log'], [])
        self.assertEqual(present['output'], ['present'])
        self.assertIn(f'Get-AuthenticodeSignature {NMF_PATH}', present['log'])
        self.assertEqual(downloads(present) + writes(present), [])
        self.assertEqual(staged['output'], ['staged'])
        self.assertEqual(downloads(staged), [f'Save-NotMyFaultArchive {NMF_DIR}\\NotMyFault.zip'])
        self.assertLess(staged['log'].index(f'Get-AuthenticodeSignature {NMF_PATH}'), staged['log'].index(f'Unblock-File {NMF_PATH}'))
        self.assertEqual(downloadError['output'], ['failed: The remote name could not be resolved'])
        self.assertEqual(noBinary['output'], [f'failed: {NMF_PATH} missing after extraction'])
        # An untrusted cached copy is renamed (never deleted or run), then replaced by a verified download.
        self.assertTrue(replaced['output'][0].startswith(f'staged (an untrusted copy was renamed to {NMF_PATH}.untrusted: signature status HashMismatch'), replaced)
        self.assertLess(replaced['log'].index(quarantine), replaced['log'].index(f'Save-NotMyFaultArchive {NMF_DIR}\\NotMyFault.zip'))
        self.assertFalse([entry for entry in replaced['log'] if entry == f'Remove-Item {NMF_PATH}'])
        # An untrusted download is renamed away and never unblocked, so a presence check cannot pass.
        for result, reason in ((unsigned, 'signature status NotSigned, signer none'),
                               (otherPublisher, f'signer is not Microsoft Corporation: {OTHER_SIGNER}')):
            self.assertEqual(result['output'], [f'failed: the downloaded {NMF_PATH} is not trusted and was renamed to {NMF_PATH}.untrusted: {reason}'])
            self.assertIn(quarantine, result['log'])
            self.assertFalse([entry for entry in result['log'] if entry.startswith('Unblock-File')])
        # A rename that fails is reported as unsafe (the script then exits 5); nothing is downloaded or unblocked after it.
        self.assertTrue(cachedStuck['output'][0].startswith(f'unsafe: the untrusted {NMF_PATH} could not be renamed (signature status HashMismatch'), cachedStuck)
        self.assertEqual(downloads(cachedStuck), [])
        self.assertTrue(downloadStuck['output'][0].startswith(f'unsafe: the untrusted downloaded {NMF_PATH} could not be renamed (signature status NotSigned'), downloadStuck)
        self.assertFalse([entry for entry in downloadStuck['log'] if entry.startswith('Unblock-File')])
        self.assertEqual(replacedThenFailed['output'], [f'failed: The remote name could not be resolved (an untrusted copy was renamed to {NMF_PATH}.untrusted: signature status HashMismatch, signer {MICROSOFT_SIGNER})'])

    def test_notmyfault_trust_requires_a_valid_microsoft_signature(self):
        cases = [
            (f'Valid|{MICROSOFT_SIGNER}', []),
            (f'HashMismatch|{MICROSOFT_SIGNER}', [f'signature status HashMismatch, signer {MICROSOFT_SIGNER}']),
            (f'UnknownError|{MICROSOFT_SIGNER}', [f'signature status UnknownError, signer {MICROSOFT_SIGNER}']),
            ('NotSigned|', ['signature status NotSigned, signer none']),
            (f'Valid|{OTHER_SIGNER}', [f'signer is not Microsoft Corporation: {OTHER_SIGNER}']),
            (f'Valid|{LOOKALIKE_SIGNER}', [f'signer is not Microsoft Corporation: {LOOKALIKE_SIGNER}']),
            (f'Valid|{QUOTED_OU_SIGNER}', [f'signer is not Microsoft Corporation: {QUOTED_OU_SIGNER}']),
        ]
        with tempfile.TemporaryDirectory() as tmpDir:
            mocks = Path(tmpDir) / 'mocks.ps1'
            mocks.write_text(STAGING_MOCKS, encoding='ascii')
            results = RunHarness(self, 'mockcall', 'Get-NotMyFaultTrustProblem',
                                 [{'state': {'cachedSig': [signature]}, 'args': [NMF_PATH]} for signature, _ in cases],
                                 mocksPath=mocks)
        self.assertEqual([result['output'] for result in results], [expected for _, expected in cases])

    def test_desired_values_never_include_dedicated_dump_file(self):
        old = dict(self.Data()['recommended']['values'], DedicatedDumpFile='C:\\DedicatedDump.sys')
        new = self.Data()['recommended']['values']
        results = RunHarness(self, 'call', 'Get-DesiredCrashControl', [[old, 2], [new, 7]])
        expected = {name: value for name, value in new.items() if name != 'DedicatedDumpFile'}
        self.assertEqual(results[0], dict(expected, CrashDumpEnabled=2))
        self.assertEqual(results[1], dict(expected, CrashDumpEnabled=7))

    def test_dedicated_dump_file_removal_distinguishes_absent_from_failed(self):
        with tempfile.TemporaryDirectory() as tmpDir:
            mocks = Path(tmpDir) / 'mocks.ps1'
            mocks.write_text(REMOVAL_MOCKS + '\n' + RunHarness(self, 'definition', 'Get-RegValue')['text'] + '\n', encoding='ascii')
            absent, removed = RunHarness(self, 'mockcall', 'Remove-DedicatedDumpFile',
                                         [{'state': {}, 'args': [CRASH_CONTROL]}, {'state': {'ddf': ['present']}, 'args': [CRASH_CONTROL]}],
                                         mocksPath=mocks)
            failed = RunHarness(self, 'mockcall', 'Remove-DedicatedDumpFile',
                                [{'state': {'ddf': ['present'], 'removeFails': ['true']}, 'args': [CRASH_CONTROL]}],
                                mocksPath=mocks, expectSuccess=False)
        self.assertEqual(absent['output'], ['absent'])
        self.assertFalse([entry for entry in absent['log'] if entry.startswith('Remove-ItemProperty')])
        self.assertEqual(removed['output'], ['removed'])
        self.assertIn('Remove-ItemProperty DedicatedDumpFile ErrorAction=Stop', removed['log'])
        self.assertIn('Requested registry access is not allowed.', failed)

    @staticmethod
    def Data():
        return json.loads(DATA_FILE.read_text(encoding='utf-8'))

    def test_isolated_runspace_cannot_reach_host_commands(self):
        names = ['New-ItemProperty', 'Remove-ItemProperty', 'Expand-Archive', 'Get-CimInstance', 'cmd', 'sh']
        results = RunHarness(self, 'isolation', calls=names)
        self.assertEqual(results, {name: 'CommandNotFoundException' for name in names})


CRASH_CONTROL = 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl'
MEMORY_MANAGEMENT = 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Memory Management'
SCRIPT_FUNCTIONS = sorted([
    'Fail', 'Get-DesiredCrashControl', 'Get-NotMyFaultTrustProblem', 'Get-PagefileSizeMB', 'Get-RegValue',
    'Invoke-NotMyFaultStaging', 'Read-CrashControlData', 'Remove-DedicatedDumpFile', 'Save-NotMyFaultArchive',
    'Test-IsAdministrator', 'Test-PageFileAdequate', 'Test-RebootRequired', 'Test-ValueMatch', 'Write-StdErr'])
# Helpers that run unchanged next to the mocks in the main-flow tests; the other functions are mocked.
REAL_HELPERS = ['Get-RegValue', 'Test-ValueMatch', 'Get-PagefileSizeMB', 'Test-PageFileAdequate', 'Test-RebootRequired',
                'Get-DesiredCrashControl', 'Remove-DedicatedDumpFile']
OLD_IMAGE = {'crashControl': ['CrashDumpEnabled=7', 'AutoReboot=0', 'AlwaysKeepMemoryDump=1', 'Overwrite=1', 'LogEvent=1',
                              'MinidumpDir=%SystemRoot%\\Minidump', 'DumpFile=%SystemRoot%\\MEMORY.DMP',
                              'DedicatedDumpFile=C:\\DedicatedDump.sys'],
             'pagingFiles': ['C:\\pagefile.sys 4096 4096']}
NEW_IMAGE = {'crashControl': [entry for entry in OLD_IMAGE['crashControl'] if not entry.startswith('DedicatedDumpFile=')],
             'pagingFiles': ['C:\\pagefile.sys 16641 16641']}


def PsLiteral(value):
    """A PowerShell expression for a JSON value, so the mocks use the real crash-control.json data."""
    if isinstance(value, dict):
        return '[pscustomobject][ordered]@{ ' + '; '.join(f"'{key}' = {PsLiteral(item)}" for key, item in value.items()) + ' }'
    if isinstance(value, bool):
        return '$true' if value else '$false'
    if isinstance(value, int):
        return str(value)
    return "'" + str(value).replace("'", "''") + "'"


def MainFlowMocks():
    data = json.loads(DATA_FILE.read_text(encoding='utf-8'))
    oldData = json.loads(json.dumps(data))
    oldData['recommended']['values']['DedicatedDumpFile'] = 'C:\\DedicatedDump.sys'
    return r'''
function Set-StrictMode ($Version) { }
function Out-Null { process { } }
function Write-StdErr ([string]$Message) { $global:MockLog.Add("stderr ${Message}") }
function Write-FlowError ($Message) { $global:MockLog.Add("error ${Message}") }
function Fail ([string]$Message, [int]$ExitCode) { $global:MockLog.Add("fail ${ExitCode} ${Message}"); throw 'script-exit' }
function Test-IsAdministrator { $global:MockLog.Add('Test-IsAdministrator'); $global:MockState['admin'] -notcontains 'false' }
function Read-CrashControlData ([string]$Path) {
    $global:MockLog.Add("Read-CrashControlData ${Path}")
    if ($global:MockState['keepRegistry'] -notcontains 'true') {
        $crashControl = @{}
        foreach ($pair in $global:MockState['crashControl']) {
            $name, $value = $pair -split '=', 2
            $crashControl[$name] = $(if ($value -match '^\d+$') { [int]$value } else { $value })
        }
        $memoryManagement = @{}
        if ($global:MockState['pagingFiles']) { $memoryManagement['PagingFiles'] = [string[]]$global:MockState['pagingFiles'] }
        $global:FakeReg = @{ 'CRASH_CONTROL' = $crashControl; 'MEMORY_MANAGEMENT' = $memoryManagement }
    }
    if ($global:MockState['data'] -contains 'old') { OLD_DATA } else { NEW_DATA }
}
function Get-ItemProperty ([string]$Path, [string]$Name, $ErrorAction) {
    if ($global:FakeReg.ContainsKey($Path) -and $global:FakeReg[$Path].ContainsKey($Name)) { [pscustomobject]@{ $Name = $global:FakeReg[$Path][$Name] } }
}
function New-ItemProperty ([string]$Path, [string]$Name, $Value, [string]$PropertyType, [switch]$Force) {
    $global:MockLog.Add("New-ItemProperty ${Name}=${Value} ${PropertyType}")
    $global:FakeReg[$Path][$Name] = $Value
}
function Remove-ItemProperty ([string]$Path, [string]$Name, $ErrorAction) {
    $global:MockLog.Add("Remove-ItemProperty ${Name}")
    if ($global:MockState['removeFails'] -contains 'true') {
        # Like the real cmdlet, a failure terminates unless errors are suppressed for the call.
        if ("${ErrorAction}" -in 'SilentlyContinue', 'Ignore', 'Continue') { $global:MockLog.Add('suppressed Remove-ItemProperty error'); return }
        throw 'Requested registry access is not allowed.'
    }
    $global:FakeReg[$Path].Remove($Name)
}
function Test-Path ([string]$Path) { $global:FakeReg.ContainsKey($Path) }
function New-Item ([string]$Path, [switch]$Force) { $global:MockLog.Add("New-Item ${Path}"); $global:FakeReg[$Path] = @{} }
function Get-CimInstance ([string]$ClassName, $ErrorAction) {
    $memory = @($global:MockState['memory'])[0]
    if ($memory -eq 'error') { throw 'simulated CIM failure' }
    [pscustomobject]@{ TotalPhysicalMemory = $(if ($memory) { [int64]$memory } else { [int64]17179869184 }) }
}
function Invoke-NotMyFaultStaging ($IsVerifyOnly, $IsStageRequested) {
    $global:MockLog.Add("staging verifyOnly=${IsVerifyOnly} stage=${IsStageRequested}")
    if ($global:MockState['nmfStatus']) { @($global:MockState['nmfStatus'])[0] } else { 'skipped: not requested' }
}
function ConvertTo-Json ([Parameter(ValueFromPipeline)]$InputObject, $Depth) {
    process {
        $appliedNames = if ($null -ne $InputObject.applied) { @($InputObject.applied.Keys) -join ',' } else { 'null' }
        $global:MockLog.Add("json action=$($InputObject.action) reboot=$($InputObject.rebootRequired) match=$($InputObject.matchesRecommended) ddf=$($InputObject.dedicatedDumpFile) adequate=$($InputObject.pageFile.adequate) requiredMB=$($InputObject.pageFile.requiredMB) applied=${appliedNames}")
    }
}
'''.replace('CRASH_CONTROL', CRASH_CONTROL).replace('MEMORY_MANAGEMENT', MEMORY_MANAGEMENT) \
        .replace('OLD_DATA', PsLiteral(oldData)).replace('NEW_DATA', PsLiteral(data))


class ConfigureDumpsMainFlowTests(unittest.TestCase):
    """The script's top-level statements, run in order with every command mocked.

    Helper definitions are taken out of the script; the pure ones run unchanged next to the
    mocks, the others are replaced by mocks. The registry lives in $global:FakeReg and persists
    between calls when 'keepRegistry' is set, so a second run sees the first run's writes.
    Limitation: the harness runspace has no Set-StrictMode cmdlet, so these runs are not in strict
    mode; strict-mode behavior is covered only by review and needs a Windows PowerShell 5.1 run.
    """

    def RunScript(self, states):
        scriptText = SCRIPT.read_text(encoding='ascii')
        helperTexts = []
        for name in SCRIPT_FUNCTIONS:
            definition = RunHarness(self, 'definition', name)
            self.assertTrue(definition['found'], name)
            self.assertEqual(scriptText.count(definition['text']), 1, name)
            scriptText = scriptText.replace(definition['text'], '')
            if name in REAL_HELPERS:
                helperTexts.append(definition['text'])
        body = scriptText[scriptText.index('Set-StrictMode -Version Latest'):]
        self.assertNotRegex(body, r'(?mi)^\s*exit\b')
        preamble = ("$DumpType = @($global:MockState['dumpType'])[0]\n"
                    "$VerifyOnly = $global:MockState['verifyOnly'] -contains 'true'\n"
                    "$StageNotMyFault = $global:MockState['stage'] -contains 'true'\n"
                    "$DataFile = 'C:\\Windows\\Temp\\crash-control.json'\n")
        with tempfile.TemporaryDirectory() as tmpDir:
            flowPath = Path(tmpDir) / 'main-flow.ps1'
            mocksPath = Path(tmpDir) / 'main-flow-mocks.ps1'
            flowPath.write_text('function Invoke-MainFlow {\ntry {\n' + preamble + body +
                                '\n} catch { if ("$_" -ne \'script-exit\') { Write-FlowError "$_" } }\n}\n', encoding='ascii')
            mocksPath.write_text(MainFlowMocks() + '\n' + '\n'.join(helperTexts) + '\n', encoding='ascii')
            calls = [{'state': state, 'args': []} for state in states]
            return [result['log'] for result in RunHarness(self, 'mockcall', 'Invoke-MainFlow', calls,
                                                           scriptPath=flowPath, mocksPath=mocksPath)]

    @staticmethod
    def Json(log):
        lines = [line for line in log if line.startswith('json ')]
        return lines[0] if len(lines) == 1 else None

    def testOldDataOnOldImageRemovesDedicatedDumpFileOnceAndNeverWritesItBack(self):
        first, second = self.RunScript([dict(OLD_IMAGE, data=['old']), {'data': ['old'], 'keepRegistry': ['true']}])
        recommended = [name for name in json.loads(DATA_FILE.read_text(encoding='utf-8'))['recommended']['values']]
        for log in (first, second):
            self.assertIn('stderr WARN: crash-control.json still recommends DedicatedDumpFile; it is ignored (dumps use the page file only)', log)
            self.assertFalse([line for line in log if line.startswith('New-ItemProperty DedicatedDumpFile')], log)
            self.assertFalse([line for line in log if line.startswith(('fail', 'error'))], log)
        self.assertEqual([line for line in first if line.startswith('Remove-ItemProperty')], ['Remove-ItemProperty DedicatedDumpFile'])
        self.assertEqual(self.Json(first),
                         f"json action=applied reboot=True match=True ddf= adequate=False requiredMB=16641 applied={','.join(recommended)}")
        # Idempotent: the second run finds nothing to remove and no reboot is pending from this script.
        self.assertFalse([line for line in second if line.startswith('Remove-ItemProperty')], second)
        self.assertEqual(self.Json(second),
                         f"json action=applied reboot=False match=True ddf= adequate=False requiredMB=16641 applied={','.join(recommended)}")

    def testCurrentDataOnCurrentImageIsAdequateWithoutRemoval(self):
        log = self.RunScript([dict(NEW_IMAGE)])[0]
        self.assertFalse([line for line in log if line.startswith(('Remove-ItemProperty', 'stderr', 'fail', 'error'))], log)
        self.assertTrue(self.Json(log).startswith('json action=applied reboot=False match=True ddf= adequate=True requiredMB=16641 '), log)
        self.assertIn('staging verifyOnly=False stage=False', log)

    def testVerifyOnlyWritesNothingAndReportsDedicatedDumpFile(self):
        log = self.RunScript([dict(OLD_IMAGE, verifyOnly=['true'], stage=['true'])])[0]
        self.assertFalse([line for line in log if line.startswith(('New-ItemProperty', 'Remove-ItemProperty', 'New-Item', 'Test-IsAdministrator'))], log)
        self.assertIn('staging verifyOnly=True stage=True', log)
        self.assertEqual(self.Json(log), 'json action=verified reboot=False match=False ddf=C:\\DedicatedDump.sys adequate=False requiredMB=16641 applied=null')

    def testFailedRemovalExitsWithCode4BeforeWritingValues(self):
        log = self.RunScript([dict(OLD_IMAGE, removeFails=['true'])])[0]
        self.assertTrue([line for line in log if line.startswith('fail 4 cannot write CrashControl at ' + CRASH_CONTROL + ': Requested registry access is not allowed.')], log)
        self.assertFalse([line for line in log if line.startswith(('New-ItemProperty', 'json', 'staging'))], log)

    def testNotElevatedExitsWithCode3BeforeAnyRegistryAccess(self):
        log = self.RunScript([dict(OLD_IMAGE, admin=['false'])])[0]
        self.assertTrue([line for line in log if line.startswith('fail 3 ')], log)
        self.assertFalse([line for line in log if line.startswith(('New-ItemProperty', 'Remove-ItemProperty', 'New-Item', 'json'))], log)

    def testStagingResultsAreWarnedOrStopTheScript(self):
        cases = ['present', 'failed: The remote name could not be resolved',
                 'staged (an untrusted copy was renamed to C:\\Temp\\nmf\\notmyfaultc64.exe.untrusted: signature status HashMismatch)',
                 'unsafe: the untrusted C:\\Temp\\nmf\\notmyfaultc64.exe could not be renamed (signature status HashMismatch): Access denied']
        present, failed, replaced, unsafe = self.RunScript([dict(NEW_IMAGE, stage=['true'], nmfStatus=[status]) for status in cases])
        self.assertFalse([line for line in present if line.startswith('stderr')], present)
        for log, status in ((failed, cases[1]), (replaced, cases[2])):
            self.assertIn(f'stderr WARN: NotMyFault staging to C:\\Temp\\nmf: {status}', log)
            self.assertIsNotNone(self.Json(log), log)
        self.assertIn(f'fail 5 NotMyFault staging: {cases[3]}', unsafe)
        self.assertIsNone(self.Json(unsafe), unsafe)

    def testUnknownOrNonPositiveMemoryIsNotAdequate(self):
        for memory in ('error', '0', '-1073741824'):
            with self.subTest(memory=memory):
                log = self.RunScript([dict(NEW_IMAGE, memory=[memory])])[0]
                self.assertTrue([line for line in log if line.startswith('stderr WARN: ') and 'physical memory size' in line], log)
                self.assertTrue(self.Json(log).startswith('json action=applied reboot=False match=True ddf= adequate=False requiredMB= '), log)


if __name__ == '__main__':
    unittest.main()
