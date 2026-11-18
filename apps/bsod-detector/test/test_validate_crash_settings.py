#!/usr/bin/env python3
"""Offline checks for validate-crash-settings.ps1, its host callers and src/data/crash-control.json.

The validator reads the guest registry and, only for intentional runs, downloads NotMyFault, so
it is never executed on the test host. Static checks read the scripts as text. The PowerShell
checks use fixtures/ps-function-harness.ps1, which parses the script and runs single functions,
or the script's top-level flow, in an isolated runspace where only test-supplied mocks (and
Set-StrictMode) can be called. Shell helpers of preflight-rhov.sh run in bash with a stub curl.
Without `pwsh` the PowerShell checks are skipped, or fail when BSOD_DET__TEST__REQUIRE_PWSH=1.
"""

import importlib.util
import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


APP_DIR = Path(__file__).resolve().parents[1]
GUEST_DIR = APP_DIR / 'src' / 'scripts' / 'guest'
SCRIPT = GUEST_DIR / 'validate-crash-settings.ps1'
PARTNER_SCRIPTS = (GUEST_DIR / 'golden-image-pre-reboot.ps1', GUEST_DIR / 'golden-image-post-reboot.ps1')
DATA_FILE = APP_DIR / 'src' / 'data' / 'crash-control.json'
HOST_DIR = APP_DIR / 'src' / 'scripts' / 'host'
PREFLIGHT = HOST_DIR / 'preflight-rhov.sh'
TRIGGER = APP_DIR / 'src' / 'scripts' / 'crash-injector' / 'trigger-bsod-intentional.sh'
HARNESS = Path(__file__).resolve().parent / 'fixtures' / 'ps-function-harness.ps1'
NMF_SOURCE = 'https://download.sysinternals.com/files/NotMyFault.zip'
NMF_PATH = 'C:\\Temp\\nmf\\notmyfaultc64.exe'
CRASH_CONTROL = 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl'
MEMORY_MANAGEMENT = 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Memory Management'
MICROSOFT_SIGNER = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
OTHER_SIGNER = 'CN=Contoso, O=Contoso Ltd, C=US'
LOOKALIKE_SIGNER = 'CN=Microsoft Corporation, O=Microsoft Corporation Fake, C=US'
QUOTED_OU_SIGNER = 'CN=Contoso, OU="Dev, O=Microsoft Corporation, x", O=Contoso Ltd, C=US'
SHARED_DOWNLOAD_HELPERS = ('Enable-TLS12', 'Get-HTTPSredirectTarget', 'Get-HTTPSresponseHead', 'Resolve-OfficialHTTPS', 'Save-HTTPSdownload')
REGISTRY_OR_REBOOT_WRITES = re.compile(
    r'(?i)\b(New-ItemProperty|Set-ItemProperty|Remove-ItemProperty|Rename-ItemProperty|Set-CimInstance|New-CimInstance|'
    r'Invoke-CimMethod|Restart-Computer|Stop-Computer|bcdedit|reg(\.exe)?\s+(add|delete)|shutdown(\.exe)?)\b')
FILE_WRITES = re.compile(r'\b(New-Item|Remove-Item|Move-Item|Expand-Archive|Unblock-File|Set-Content)\b|DownloadFile')

# Expected pagefile sizes (MB), shared with the golden-image tests. The 4095.5 and 16383.5 MiB
# cases are where rounding before adding 257 differs from rounding once (banker's rounding).
PAGEFILE_SIZES_MB = {
    4294443008: 4352,
    8589934592: 8449,
    17179344896: 16640,
    17179869184: 16641,
}

# Mocks for Invoke-NotMyFaultStaging and Get-NotMyFaultTrustProblem. 'existing' lists files that
# exist; 'sig' is 'Status|Subject' for the extracted executable; other keys switch failures.
STAGING_MOCKS = r'''
function Test-Path ([string]$LiteralPath) { $global:MockState['existing'] -contains $LiteralPath }
function Remove-Item ([string]$LiteralPath, [switch]$Recurse, [switch]$Force, $ErrorAction) {
    $global:MockLog.Add("Remove-Item ${LiteralPath}")
    $global:MockState['existing'] = @($global:MockState['existing'] | Where-Object { $_ -ne $LiteralPath })
}
function Where-Object ([scriptblock]$FilterScript) {
    process {
        $context = [System.Collections.Generic.List[psvariable]]@([psvariable]::new('_', $_))
        if ($FilterScript.InvokeWithContext($null, $context)) { $_ }
    }
}
function New-Item ([string]$ItemType, [switch]$Force, [string]$Path) { $global:MockLog.Add("New-Item ${Path}") }
function Out-Null { process { } }
function Enable-TLS12 { $global:MockLog.Add('Enable-TLS12') }
function Resolve-OfficialHTTPS ([string]$URL, [string]$OfficialHost) {
    $global:MockLog.Add("Resolve-OfficialHTTPS ${URL} ${OfficialHost}")
    if ($global:MockState['resolveFails'] -contains 'true') { throw 'redirect leaves download.sysinternals.com' }
    $URL
}
function Save-HTTPSdownload ([string]$URL, [string]$Path) {
    $global:MockLog.Add("Save-HTTPSdownload ${URL} ${Path}")
    if ($global:MockState['downloadFails'] -contains 'true') { throw 'The remote name could not be resolved' }
    $global:MockState['existing'] = @($global:MockState['existing']) + $Path
}
function Get-FileHash ([string]$LiteralPath, [string]$Algorithm) {
    $global:MockLog.Add("Get-FileHash ${LiteralPath} ${Algorithm}")
    $hash = if ($LiteralPath -like '*.zip') { 'A' * 64 } else { 'B' * 64 }
    [pscustomobject]@{ Hash = $hash }
}
function Expand-Archive ([string]$Path, [string]$DestinationPath, [switch]$Force) {
    $global:MockLog.Add("Expand-Archive ${Path} ${DestinationPath}")
    if ($global:MockState['archiveHasExe'] -notcontains 'false') {
        $global:MockState['existing'] = @($global:MockState['existing']) + "${DestinationPath}\notmyfaultc64.exe" + $DestinationPath
    }
}
function Get-AuthenticodeSignature ([string]$LiteralPath) {
    $global:MockLog.Add("Get-AuthenticodeSignature ${LiteralPath}")
    $status, $subject = "$($global:MockState['sig'])" -split '\|', 2
    $certificate = if ($subject) { [pscustomobject]@{ Subject = $subject } } else { $null }
    [pscustomobject]@{ Status = $status; SignerCertificate = $certificate }
}
function Get-Item ([string]$LiteralPath) { [pscustomobject]@{ VersionInfo = [pscustomobject]@{ FileVersion = '4.25' } } }
function Move-Item ([string]$LiteralPath, [string]$Destination, [switch]$Force) {
    $global:MockLog.Add("Move-Item ${LiteralPath} ${Destination}")
    $global:MockState['existing'] = @($global:MockState['existing'] | Where-Object { $_ -ne $LiteralPath }) + $Destination
}
function Unblock-File ([string]$Path, $ErrorAction) { $global:MockLog.Add("Unblock-File ${Path}") }
'''

# Probe functions that turn returned objects into comparable strings; they run under strict mode
# and may only call the real validator functions loaded next to the mocks.
RECORD_PROBE = r'''
Set-StrictMode -Version Latest
function Get-StagingRecord ([string]$Source) {
    $record = Invoke-NotMyFaultStaging $Source
    foreach ($key in $record.Keys) { "${key}=$($record[$key])" }
}
function Get-AbsenceList ($Recommended) {
    @(Get-RequiredAbsence $Recommended) -join ','
}
'''

# Mocks for Resolve-OfficialHTTPS: 'hops' are 'URL>status>location' entries.
RESOLVE_MOCKS = r'''
function Get-HTTPSresponseHead ([string]$URL) {
    $global:MockLog.Add("HEAD ${URL}")
    foreach ($hop in $global:MockState['hops']) {
        $from, $status, $location = $hop -split '>', 3
        if ($from -eq $URL) { return [pscustomobject]@{ StatusCode = [int]$status; Location = $location } }
    }
    [pscustomobject]@{ StatusCode = 404; Location = $null }
}
'''


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


def BlockAfter(text, marker):
    """Text of the brace-delimited block that starts at `marker` (which ends with '{')."""
    start = text.index(marker) + len(marker)
    depth = 1
    for index in range(start, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[start:index]
    raise AssertionError(f'unbalanced block after {marker}')


def ShellFunction(text, name):
    match = re.search(r'(?ms)^function ' + re.escape(name) + r' \(\) \{.*?^\}', text)
    assert match, name
    return match.group(0)


class ValidatorStaticTests(unittest.TestCase):
    def setUp(self):
        self.source = SCRIPT.read_bytes()
        self.text = self.source.decode('ascii', errors='replace')
        self.data = json.loads(DATA_FILE.read_text(encoding='utf-8'))

    def test_source_is_ascii_and_ends_with_newline(self):
        self.assertTrue(self.source.isascii())
        self.assertTrue(self.source.endswith(b'\n'))
        self.assertFalse((GUEST_DIR / 'configure-dumps.ps1').exists())

    def test_validator_never_writes_settings_or_reboots(self):
        code = '\n'.join(line for line in self.text.splitlines() if not line.lstrip().startswith('#'))
        self.assertIsNone(REGISTRY_OR_REBOOT_WRITES.search(code))
        stagingBody = BlockAfter(self.text, 'function Invoke-NotMyFaultStaging ([string]$Source) {')
        downloadBody = BlockAfter(self.text, 'function Save-HTTPSdownload ([string]$URL, [string]$Path) {')
        outside = code.replace(stagingBody, '').replace(downloadBody, '')
        self.assertIsNone(FILE_WRITES.search(outside))
        # Staging happens only behind the intentional switch.
        self.assertEqual(self.text.count('Invoke-NotMyFaultStaging '), 2)
        self.assertIn('if ($StageNotMyFault) {', self.text)
        self.assertIn('Invoke-NotMyFaultStaging', BlockAfter(self.text, 'if ($StageNotMyFault) {'))
        self.assertNotRegex(self.text, r'(?i)rebootRequired|VerifyOnly|Test-IsAdministrator')

    def test_no_hardcoded_hash_or_version_and_existing_copy_is_never_reused(self):
        self.assertIsNone(re.search(r'\b[0-9A-Fa-f]{64}\b', self.text))
        stagingBody = BlockAfter(self.text, 'function Invoke-NotMyFaultStaging ([string]$Source) {')
        self.assertNotIn("return 'present'", stagingBody)
        self.assertLess(stagingBody.index('Remove-Item -LiteralPath $stale'), stagingBody.index('Save-HTTPSdownload'))
        self.assertLess(stagingBody.index('Get-NotMyFaultTrustProblem $candidate'), stagingBody.index('Move-Item'))
        self.assertIn("$notMyFault = Invoke-NotMyFaultStaging '" + NMF_SOURCE + "'", self.text)

    def test_data_file_has_no_small_dump_settings_and_lists_required_absences(self):
        self.assertNotIn('small', self.data['crashDumpTypes'])
        self.assertNotIn('MinidumpDir', self.data['recommended']['values'])
        self.assertNotIn('DedicatedDumpFile', self.data['recommended']['values'])
        self.assertEqual(self.data['recommended']['absentValues'], ['DedicatedDumpFile'])
        self.assertNotRegex(DATA_FILE.read_text(encoding='utf-8'), r'(?i)minidump|configure-dumps')
        self.assertEqual(self.data['recommended']['values']['AutoReboot'], 0)

    def test_json_contract_fields(self):
        for field in ('ok', 'action', 'script', 'requestedDumpType', 'registryPath', 'desired', 'current', 'mismatches',
                      'matchesRecommended', 'pageFile', 'notMyFault'):
            self.assertRegex(self.text, rf'(?m)^    {field}\s+= ')
        self.assertIn("$notMyFault = [ordered]@{ status = 'not requested' }", self.text)

    def test_double_quoted_strings_use_formal_variable_syntax(self):
        self.assertEqual(SimpleVariablesInDoubleQuotes(self.text), [])


class HostCallerTests(unittest.TestCase):
    """preflight-rhov.sh and the trigger use the validator, its read-only gates and the staging record."""

    def setUp(self):
        self.preflight = PREFLIGHT.read_text(encoding='utf-8')
        self.trigger = TRIGGER.read_text(encoding='utf-8')

    def test_preflight_calls_the_read_only_validator(self):
        self.assertIn('typeset validatorScript="${BSOD_DET__VALIDATE__CRASH_SETTINGS:-${BSOD_DET__CONFIGURE__DUMPS:-${appDir}/src/scripts/guest/validate-crash-settings.ps1}}"', self.preflight)
        self.assertIn('psfile "${validatorScript}"', self.preflight)
        self.assertIn('"${validatorArgArr[@]}"', self.preflight)
        self.assertIn('ValidatorArgs validatorArgArr "${requireTrigger}"', self.preflight)
        self.assertIn('ValidationAccepted "${validation}" ||', self.preflight)
        self.assertIn('NotMyFaultStaged "${validation}" ||', self.preflight)
        # The deprecated alias may only name the validator: another file is refused before it runs.
        self.assertLess(self.preflight.index('[[ "${validatorScript##*/}" == validate-crash-settings.ps1 ]] ||'),
                        self.preflight.index('psfile "${validatorScript}"'))
        self.assertIn('BSOD_DET__CONFIGURE__DUMPS is deprecated; set BSOD_DET__VALIDATE__CRASH_SETTINGS', self.preflight)
        self.assertNotRegex(self.preflight, r'configure-dumps\.ps1|rebootRequired|configureScript|[Mm]ini[Dd]ump')

    def test_validator_arguments_stage_only_for_require_trigger(self):
        function = ShellFunction(self.preflight, 'ValidatorArgs')
        for requireTrigger, expected in ((0, ['-DataFile', 'C:\\Windows\\Temp\\crash-control.json']),
                                         (1, ['-DataFile', 'C:\\Windows\\Temp\\crash-control.json', '-StageNotMyFault'])):
            script = (f'set -euo pipefail; shopt -s inherit_errexit\n{function}\n'
                      f'typeset -a argArr2=(); ValidatorArgs argArr2 {requireTrigger}; printf "%s\\n" "${{argArr2[@]}}"')
            result = subprocess.run(['bash', '-c', script], capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.splitlines(), expected)

    def RunGate(self, name, document):
        script = f'set -uo pipefail\n{ShellFunction(self.preflight, name)}\n{name} "$1"'
        return subprocess.run(['bash', '-c', script, 'gate', json.dumps(document)], capture_output=True, text=True).returncode

    def test_validation_gate_accepts_only_a_matching_validator_result(self):
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

    def test_staging_gate_requires_both_hashes_from_the_official_host(self):
        staged = {'notMyFault': {'status': 'staged', 'source': NMF_SOURCE, 'resolvedSource': NMF_SOURCE,
                                 'archiveSHA256': 'A' * 64, 'sha256': 'b' * 64, 'version': '4.25', 'signer': MICROSOFT_SIGNER}}
        self.assertEqual(self.RunGate('NotMyFaultStaged', staged), 0)
        record = staged['notMyFault']
        rejected = [{'notMyFault': {'status': 'not requested'}}, {'notMyFault': dict(record, status='failed')},
                    {'notMyFault': dict(record, sha256=None)}, {'notMyFault': dict(record, archiveSHA256='A' * 63)},
                    {'notMyFault': dict(record, resolvedSource='http://download.sysinternals.com/files/NotMyFault.zip')},
                    {'notMyFault': dict(record, resolvedSource='https://download.sysinternals.com.evil.example/x.zip')}]
        for document in rejected:
            with self.subTest(document=document):
                self.assertNotEqual(self.RunGate('NotMyFaultStaged', document), 0)

    def test_staging_record_and_qemu_ga_hash_reach_the_metadata(self):
        self.assertIn(".notMyFault | .sha256 |= ascii_downcase | .archiveSHA256 |= ascii_downcase", self.preflight)
        self.assertIn('artifacts:{notMyFault:$notMyFault,qemuGaMsi:$qemuGaMsi}', self.preflight)
        self.assertIn('msiSha="$(sha256sum "${msiLocal}" | cut -d\' \' -f1)"', self.preflight)
        self.assertIn("curl --proto '=https' --proto-redir '=https' -fsSL", self.preflight)
        self.assertNotRegex(self.preflight, r'curl -fsSL -o "\$\{msiLocal\}" "\$\{msiUrl\}"')

    def test_official_alias_resolution_stays_on_https_and_the_same_host(self):
        function = ShellFunction(self.preflight, 'ResolveOfficialHTTPS')
        alias = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-qemu-ga/qemu-ga-x86_64.msi'
        archive = 'fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-qemu-ga/qemu-ga-win-1.2.3-1/qemu-ga-x86_64.msi'
        cases = [
            ([f'{alias} 301 http://{archive}', f'https://{archive} 200'], 0, [f'https://{archive}']),
            ([f'{alias} 301 https://evil.example/qemu-ga-x86_64.msi'], 1, []),
            ([f'{alias} 301 http://fedorapeople.org.evil.example/x.msi'], 1, []),
            ([f'{alias} 301 {alias}'], 1, []),                     # redirect loop
            ([f'{alias} 404'], 1, []),                             # error status without a location
            ([f'{alias} 204'], 1, []),                             # success without content is not a download
            ([f'{alias} 200 https://fedorapeople.org/x.msi'], 1, []),  # location without a redirect status
            ([], 1, []),                                           # curl error
        ]
        with tempfile.TemporaryDirectory() as tmpDir:
            mapFile = Path(tmpDir) / 'map'
            logFile = Path(tmpDir) / 'curl.log'
            curl = Path(tmpDir) / 'curl'
            curl.write_text('#!/usr/bin/env bash\n'
                            'printf \'%s\\n\' "$*" >> "$CURL_LOG"\n'
                            'url="${@: -1}"\n'
                            'while read -r from code to; do [[ "$from" == "$url" ]] && { printf \'%s %s\' "$code" "$to"; exit 0; }; done < "$CURL_MAP"\n'
                            'exit 22\n', encoding='ascii')
            curl.chmod(curl.stat().st_mode | stat.S_IEXEC)
            for mapping, expectedStatus, expectedOutput in cases:
                with self.subTest(mapping=mapping):
                    mapFile.write_text('\n'.join(mapping) + '\n', encoding='ascii')
                    logFile.write_text('', encoding='ascii')
                    script = (f'set -uo pipefail\nfunction RunTimed () {{ shift; "$@"; }}\n{function}\n'
                              f'ResolveOfficialHTTPS "{alias}" fedorapeople.org')
                    result = subprocess.run(['bash', '-c', script], capture_output=True, text=True,
                                            env=dict(os.environ, PATH=f'{tmpDir}:{os.environ["PATH"]}', CURL_MAP=str(mapFile),
                                                     CURL_LOG=str(logFile)))
                    self.assertEqual(result.returncode, expectedStatus, result.stderr)
                    self.assertEqual(result.stdout.splitlines(), expectedOutput)
                    self.assertNotIn(' -L', script)
                    for line in logFile.read_text(encoding='ascii').splitlines():
                        self.assertIn('--proto =https', line)
                        self.assertNotIn(' -L', line)
                        self.assertRegex(line, r'https://\S+$')

    def test_container_image_ships_the_validator_under_the_names_preflight_reads(self):
        dockerfile = (APP_DIR.parents[1] / 'image' / 'container' / 'bsod-detector' / 'Dockerfile').read_text(encoding='utf-8')
        self.assertIn('COPY apps/bsod-detector/src/scripts/guest/validate-crash-settings.ps1 '
                      '/usr/share/bsod-detector/guest/validate-crash-settings.ps1', dockerfile)
        self.assertIn('BSOD_DET__VALIDATE__CRASH_SETTINGS=/usr/share/bsod-detector/guest/validate-crash-settings.ps1', dockerfile)
        self.assertIn('BSOD_DET__CRASH_CONTROL__FILE=/usr/share/bsod-detector/data/crash-control.json', dockerfile)
        self.assertNotRegex(dockerfile, r'configure-dumps|BSOD_CONFIGURE_DUMPS|[Mm]ini[Dd]ump')
        for name in ('BSOD_DET__VALIDATE__CRASH_SETTINGS', 'BSOD_DET__CRASH_CONTROL__FILE'):
            self.assertIn('${' + name + ':-', self.preflight)

    def test_trigger_uses_the_staged_latest_notmyfault_without_a_host_copy(self):
        self.assertNotRegex(self.trigger, r'nmfBin|nmfExpectedSize|put "\$\{nmfBin\}"|[Mm]ini[Dd]ump|minidumpCount')
        self.assertIn('--require-trigger', self.trigger)
        self.assertIn(".artifacts.notMyFault.status == \"staged\"", self.trigger)
        self.assertIn(".memory == false", self.trigger)

    def test_guest_agent_psfile_passes_the_switch_to_powershell(self):
        spec = importlib.util.spec_from_file_location('guestAgent', HOST_DIR / 'guest-agent.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        companions, powershellArgs = module._psfile_args(
            ['--companion', 'crash-control.json', 'C:\\Windows\\Temp\\crash-control.json', '--',
             '-DataFile', 'C:\\Windows\\Temp\\crash-control.json', '-StageNotMyFault'])
        self.assertEqual(companions, [('crash-control.json', 'C:\\Windows\\Temp\\crash-control.json')])
        self.assertEqual(powershellArgs, ['-DataFile', 'C:\\Windows\\Temp\\crash-control.json', '-StageNotMyFault'])


class ValidatorPowerShellTests(unittest.TestCase):
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

    def test_shared_functions_match_the_golden_image_scripts(self):
        # A missing sibling change fails instead of skipping.
        own = RunHarness(self, 'definition', 'Get-PagefileSizeMB')
        for partnerScript in PARTNER_SCRIPTS:
            partner = RunHarness(self, 'definition', 'Get-PagefileSizeMB', scriptPath=partnerScript)
            self.assertTrue(partner['found'], f'{partnerScript.name} lacks Get-PagefileSizeMB; include its companion change')
            self.assertEqual(partner['text'], own['text'])
        for name in SHARED_DOWNLOAD_HELPERS:
            own = RunHarness(self, 'definition', name)
            partner = RunHarness(self, 'definition', name, scriptPath=PARTNER_SCRIPTS[0])
            self.assertTrue(partner['found'], f'golden-image-pre-reboot.ps1 lacks {name}; include its companion change')
            self.assertEqual(partner['text'], own['text'])

    def test_pagefile_adequacy(self):
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
        results = RunHarness(self, 'call', 'Test-PageFileAdequate', [args for args, _ in cases])
        self.assertEqual(results, [expected for _, expected in cases])

    def test_redirect_target_stays_on_the_official_host_and_uses_https(self):
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
            results = RunHarness(self, 'mockcall', 'Get-HTTPSredirectTarget', [{'state': {}, 'args': args} for args, _ in cases],
                                 mocksPath=mocks)
        self.assertEqual([result['output'] for result in results], [[expected] if expected else [] for _, expected in cases])

    def test_alias_resolution_follows_same_host_https_hops_only(self):
        alias = 'https://download.sysinternals.com/files/NotMyFault.zip'
        moved = 'http://download.sysinternals.com/files/v2/NotMyFault.zip'
        final = 'https://download.sysinternals.com/files/v2/NotMyFault.zip'
        good = {'hops': [f'{alias}>301>{moved}', f'{final}>200>']}
        foreign = {'hops': [f'{alias}>302>https://evil.example/NotMyFault.zip']}
        error = {'hops': [f'{alias}>500>']}
        loop = {'hops': [f'{alias}>301>{alias}']}
        with tempfile.TemporaryDirectory() as tmpDir:
            mocks = Path(tmpDir) / 'mocks.ps1'
            mocks.write_text(RESOLVE_MOCKS + '\n' + RunHarness(self, 'definition', 'Get-HTTPSredirectTarget')['text'] + '\n',
                             encoding='ascii')
            resolved = RunHarness(self, 'mockcall', 'Resolve-OfficialHTTPS', [{'state': good, 'args': [alias, 'download.sysinternals.com']}],
                                  mocksPath=mocks)[0]
            self.assertEqual(resolved['output'], [final])
            self.assertEqual(resolved['log'], [f'HEAD {alias}', f'HEAD {final}'])
            for state, message in ((foreign, 'leaves download.sysinternals.com'), (error, 'HTTP 500'), (loop, 'too many redirects')):
                output = RunHarness(self, 'mockcall', 'Resolve-OfficialHTTPS', [{'state': state, 'args': [alias, 'download.sysinternals.com']}],
                                    mocksPath=mocks, expectSuccess=False)
                self.assertIn(message, output)
            output = RunHarness(self, 'mockcall', 'Resolve-OfficialHTTPS', [{'state': good, 'args': ['http://download.sysinternals.com/files/NotMyFault.zip', 'download.sysinternals.com']}],
                                mocksPath=mocks, expectSuccess=False)
            self.assertIn('not an HTTPS URL', output)

    def test_failure_json_keeps_a_validation_result_and_the_exit_code(self):
        definition = RunHarness(self, 'definition', 'Fail')
        with tempfile.TemporaryDirectory() as tmpDir:
            outputs = []
            for call, code in (("Fail 'NotMyFault could not be staged: download failed' 4 ([ordered]@{ ok = $true; action = 'validated'; "
                                "script = 'validate-crash-settings.ps1'; mismatches = @([ordered]@{ name = 'AutoReboot'; issue = 'missing' }); "
                                "matchesRecommended = $false; notMyFault = [ordered]@{ status = 'failed' } })", 4),
                               ("Fail 'Unknown dump type' 2", 2)):
                probe = Path(tmpDir) / f'probe{code}.ps1'
                probe.write_text(f"Set-StrictMode -Version Latest\n{definition['text']}\n{call}\n'not reached'\n", encoding='ascii')
                result = subprocess.run([shutil.which('pwsh'), '-NoProfile', '-NonInteractive', '-File', str(probe)],
                                        capture_output=True, text=True, timeout=120, check=False)
                self.assertEqual(result.returncode, code, result.stderr)
                outputs.append(json.loads(result.stdout))
        staging, unknown = outputs
        self.assertEqual((staging['ok'], staging['error'], staging['action']), (False, 'NotMyFault could not be staged: download failed', 'validated'))
        self.assertEqual(staging['mismatches'], [{'name': 'AutoReboot', 'issue': 'missing'}])
        self.assertEqual(staging['notMyFault'], {'status': 'failed'})
        self.assertEqual(unknown, {'ok': False, 'error': 'Unknown dump type', 'script': 'validate-crash-settings.ps1'})

    def test_download_refuses_plain_http_and_never_follows_redirects(self):
        definition = RunHarness(self, 'definition', 'Save-HTTPSdownload')
        self.assertIn('$request.AllowAutoRedirect = $false', definition['text'])
        self.assertIn('if ([int]$response.StatusCode -ne 200) { throw', definition['text'])
        self.assertNotIn('WebClient', SCRIPT.read_text(encoding='ascii'))
        # A plain http:// URL is refused before any request is made (real cmdlets, no network access).
        with tempfile.TemporaryDirectory() as tmpDir:
            probe = Path(tmpDir) / 'probe.ps1'
            probe.write_text(definition['text'] + "\ntry { Save-HTTPSdownload 'http://download.sysinternals.com/files/NotMyFault.zip' "
                             f"'{Path(tmpDir) / 'x.zip'}'; 'downloaded' }} catch {{ $_.Exception.Message }}\n", encoding='ascii')
            result = subprocess.run([shutil.which('pwsh'), '-NoProfile', '-NonInteractive', '-File', str(probe)],
                                    capture_output=True, text=True, timeout=120, check=False)
            self.assertEqual(result.stdout.strip(), 'not an HTTPS URL: http://download.sysinternals.com/files/NotMyFault.zip', result.stderr)
            self.assertFalse((Path(tmpDir) / 'x.zip').exists())

    def test_notmyfault_trust_requires_a_valid_microsoft_signature(self):
        cases = [
            (f'Valid|{MICROSOFT_SIGNER}', []),
            (f'HashMismatch|{MICROSOFT_SIGNER}', [f'signature status HashMismatch, signer {MICROSOFT_SIGNER}']),
            ('NotSigned|', ['signature status NotSigned, signer none']),
            (f'Valid|{OTHER_SIGNER}', [f'signer is not Microsoft Corporation: {OTHER_SIGNER}']),
            (f'Valid|{LOOKALIKE_SIGNER}', [f'signer is not Microsoft Corporation: {LOOKALIKE_SIGNER}']),
            (f'Valid|{QUOTED_OU_SIGNER}', [f'signer is not Microsoft Corporation: {QUOTED_OU_SIGNER}']),
        ]
        with tempfile.TemporaryDirectory() as tmpDir:
            mocks = Path(tmpDir) / 'mocks.ps1'
            mocks.write_text(STAGING_MOCKS, encoding='ascii')
            results = RunHarness(self, 'mockcall', 'Get-NotMyFaultTrustProblem',
                                 [{'state': {'sig': [signature]}, 'args': [NMF_PATH]} for signature, _ in cases], mocksPath=mocks)
        self.assertEqual([result['output'] for result in results], [expected for _, expected in cases])

    def test_staging_always_downloads_afresh_and_records_the_download(self):
        trusted = f'Valid|{MICROSOFT_SIGNER}'
        cases = [
            {'state': {'existing': [NMF_PATH], 'sig': [trusted]}, 'args': [NMF_SOURCE]},          # earlier copy present
            {'state': {'existing': [], 'sig': [trusted]}, 'args': [NMF_SOURCE]},                  # nothing staged yet
            {'state': {'existing': [NMF_PATH], 'sig': [f'Valid|{OTHER_SIGNER}']}, 'args': [NMF_SOURCE]},  # untrusted download
            {'state': {'existing': [], 'sig': [trusted], 'downloadFails': ['true']}, 'args': [NMF_SOURCE]},
            {'state': {'existing': [], 'sig': [trusted], 'archiveHasExe': ['false']}, 'args': [NMF_SOURCE]},
            {'state': {'existing': [], 'sig': [trusted], 'resolveFails': ['true']}, 'args': [NMF_SOURCE]},
        ]
        with tempfile.TemporaryDirectory() as tmpDir:
            mocks = Path(tmpDir) / 'mocks.ps1'
            mocks.write_text(STAGING_MOCKS + '\n' + RunHarness(self, 'definition', 'Get-NotMyFaultTrustProblem')['text'] + '\n'
                             + RunHarness(self, 'definition', 'Invoke-NotMyFaultStaging')['text'] + '\n', encoding='ascii')
            probe = Path(tmpDir) / 'probe.ps1'
            probe.write_text(RECORD_PROBE, encoding='ascii')
            results = RunHarness(self, 'mockcall', 'Get-StagingRecord', cases, scriptPath=probe, mocksPath=mocks)
        for result in results:
            result['record'] = dict(line.split('=', 1) for line in result['output'])
        replaced, fresh, untrusted, downloadFails, noExe, resolveFails = results
        for result in (replaced, fresh):
            log = result['log']
            self.assertIn(f'Save-HTTPSdownload {NMF_SOURCE} C:\\Temp\\nmf\\NotMyFault.zip', log)
            self.assertLess(log.index(f'Get-AuthenticodeSignature C:\\Temp\\nmf\\extract\\notmyfaultc64.exe'),
                            log.index(f'Move-Item C:\\Temp\\nmf\\extract\\notmyfaultc64.exe {NMF_PATH}'))
            self.assertIn('Remove-Item C:\\Temp\\nmf\\NotMyFault.zip', log)
        self.assertLess(replaced['log'].index(f'Remove-Item {NMF_PATH}'), replaced['log'].index(f'Save-HTTPSdownload {NMF_SOURCE} C:\\Temp\\nmf\\NotMyFault.zip'))
        # TLS 1.2 is enabled before the first HTTPS request (the alias resolution).
        self.assertLess(replaced['log'].index('Enable-TLS12'), replaced['log'].index(f'Resolve-OfficialHTTPS {NMF_SOURCE} download.sysinternals.com'))
        record = replaced['record']
        self.assertEqual(record['status'], 'staged')
        self.assertEqual(record['source'], NMF_SOURCE)
        self.assertEqual(record['stagedPath'], NMF_PATH)
        self.assertEqual(record['problem'], '')
        self.assertEqual(record['resolvedSource'], NMF_SOURCE)
        self.assertEqual((record['archiveSHA256'], record['sha256'], record['version']), ('A' * 64, 'B' * 64, '4.25'))
        self.assertEqual(record['signer'], MICROSOFT_SIGNER)
        for result, problem in ((untrusted, f'signer is not Microsoft Corporation: {OTHER_SIGNER}'),
                                (downloadFails, 'The remote name could not be resolved'),
                                (noExe, 'notmyfaultc64.exe is missing from the downloaded archive'),
                                (resolveFails, 'redirect leaves download.sysinternals.com')):
            self.assertEqual(result['record']['status'], 'failed')
            self.assertEqual(result['record']['problem'], problem)
            self.assertEqual(result['record']['sha256'], '')
            self.assertFalse([entry for entry in result['log'] if entry.endswith(f' {NMF_PATH}') and entry.startswith('Move-Item')], result)
        self.assertIn(f'Remove-Item {NMF_PATH}', untrusted['log'])
        self.assertIn('Remove-Item C:\\Temp\\nmf\\extract', untrusted['log'])

    def test_desired_values_and_required_absences(self):
        values = json.loads(DATA_FILE.read_text(encoding='utf-8'))['recommended']['values']
        old = dict(values, DedicatedDumpFile='C:\\DedicatedDump.sys')
        results = RunHarness(self, 'call', 'Get-DesiredCrashControl', [[old, 2], [values, 7]])
        self.assertEqual(results[0], dict(values, CrashDumpEnabled=2))
        self.assertEqual(results[1], dict(values, CrashDumpEnabled=7))
        with tempfile.TemporaryDirectory() as tmpDir:
            mocks = Path(tmpDir) / 'mocks.ps1'
            mocks.write_text(RunHarness(self, 'definition', 'Get-RequiredAbsence')['text'] + '\n', encoding='ascii')
            probe = Path(tmpDir) / 'probe.ps1'
            probe.write_text(RECORD_PROBE, encoding='ascii')
            absences = RunHarness(self, 'mockcall', 'Get-AbsenceList',
                                  [{'state': {}, 'args': [{'values': {}}]}, {'state': {}, 'args': [{'absentValues': ['DedicatedDumpFile', 'X']}]}],
                                  scriptPath=probe, mocksPath=mocks)
        self.assertEqual([result['output'] for result in absences], [['DedicatedDumpFile'], ['DedicatedDumpFile,X']])


SCRIPT_FUNCTIONS = sorted([
    'Enable-TLS12', 'Fail', 'Get-DesiredCrashControl', 'Get-ExpectedValueKind', 'Get-HTTPSredirectTarget', 'Get-HTTPSresponseHead',
    'Get-NotMyFaultTrustProblem', 'Get-PagefileSizeMB', 'Get-RegValue', 'Get-RegValueKind', 'Get-RequiredAbsence',
    'Invoke-NotMyFaultStaging', 'Read-CrashControlData', 'Resolve-OfficialHTTPS', 'Save-HTTPSdownload',
    'Test-PageFileAdequate', 'Test-ValueMatch', 'Write-StdErr'])
# Helpers that run unchanged next to the mocks in the main-flow tests; the other functions are mocked.
REAL_HELPERS = ['Get-RegValue', 'Test-ValueMatch', 'Get-PagefileSizeMB', 'Test-PageFileAdequate', 'Get-DesiredCrashControl',
                'Get-RequiredAbsence', 'Get-ExpectedValueKind']
GOLDEN_IMAGE = ['CrashDumpEnabled=7', 'AutoReboot=0', 'AlwaysKeepMemoryDump=1', 'Overwrite=1', 'LogEvent=1',
                'DumpFile=%SystemRoot%\\MEMORY.DMP']


def PsLiteral(value):
    """A PowerShell expression for a JSON value, so the mocks use the real crash-control.json data."""
    if isinstance(value, dict):
        return '[pscustomobject][ordered]@{ ' + '; '.join(f"'{key}' = {PsLiteral(item)}" for key, item in value.items()) + ' }'
    if isinstance(value, list):
        return '@(' + ', '.join(PsLiteral(item) for item in value) + ')'
    if isinstance(value, bool):
        return '$true' if value else '$false'
    if isinstance(value, int):
        return str(value)
    return "'" + str(value).replace("'", "''") + "'"


def MainFlowMocks():
    data = json.loads(DATA_FILE.read_text(encoding='utf-8'))
    oldData = json.loads(json.dumps(data))
    oldData['recommended']['values']['DedicatedDumpFile'] = 'C:\\DedicatedDump.sys'
    del oldData['recommended']['absentValues']
    return r'''
function Out-Null { process { } }
function Write-StdErr ([string]$Message) { $global:MockLog.Add("stderr ${Message}") }
function Write-FlowError ($Message) { $global:MockLog.Add("error ${Message}") }
function Fail ([string]$Message, [int]$ExitCode, $Result) {
    $global:MockLog.Add("fail ${ExitCode} ${Message}")
    if ($null -ne $Result) { $Result | ConvertTo-Json -Depth 12 }
    throw 'script-exit'
}
function Read-CrashControlData ([string]$Path) {
    $global:MockLog.Add("Read-CrashControlData ${Path}")
    $crashControl = @{}; $global:FakeKinds = @{}
    foreach ($pair in $global:MockState['crashControl']) {
        $name, $value = $pair -split '=', 2
        $crashControl[$name] = $(if ($value -match '^\d+$') { [int]$value } else { $value })
        $global:FakeKinds[$name] = $(if ($value -match '^\d+$') { 'DWord' } else { 'ExpandString' })
    }
    foreach ($pair in $global:MockState['kind']) { $name, $kind = $pair -split '=', 2; $global:FakeKinds[$name] = $kind }
    $global:FakeReg = @{ 'MEMORY_MANAGEMENT' = @{ PagingFiles = [string[]]@($global:MockState['pagingFiles']) } }
    if ($global:MockState['keyMissing'] -notcontains 'true') { $global:FakeReg['CRASH_CONTROL'] = $crashControl }
    if ($global:MockState['data'] -contains 'old') { OLD_DATA } else { NEW_DATA }
}
function Get-ItemProperty ([string]$Path, [string]$Name, $ErrorAction) {
    if ($global:FakeReg.ContainsKey($Path) -and $global:FakeReg[$Path].ContainsKey($Name)) { [pscustomobject]@{ $Name = $global:FakeReg[$Path][$Name] } }
}
function Get-RegValueKind ([string]$Path, [string]$Name) {
    if ($global:FakeReg.ContainsKey($Path) -and $global:FakeReg[$Path].ContainsKey($Name)) { $global:FakeKinds[$Name] }
}
function Test-Path ([string]$Path) { $global:FakeReg.ContainsKey($Path) }
function Get-CimInstance ([string]$ClassName, $ErrorAction) {
    $memory = @($global:MockState['memory'])[0]
    if ($memory -eq 'error') { throw 'simulated CIM failure' }
    [pscustomobject]@{ TotalPhysicalMemory = $(if ($memory) { [int64]$memory } else { [int64]17179869184 }) }
}
function Invoke-NotMyFaultStaging ([string]$Source) {
    $global:MockLog.Add("staging ${Source}")
    if ($global:MockState['stagingFails'] -contains 'true') { return [ordered]@{ status = 'failed'; problem = 'signature status NotSigned, signer none' } }
    [ordered]@{ status = 'staged'; source = $Source; resolvedSource = $Source; sha256 = 'B' * 64 }
}
function ConvertTo-Json ([Parameter(ValueFromPipeline)]$InputObject, $Depth) {
    process {
        $issues = @($InputObject.mismatches | ForEach-Object { "$($_.name):$($_.issue)" }) -join ','
        $global:MockLog.Add("json action=$($InputObject.action) match=$($InputObject.matchesRecommended) issues=${issues} adequate=$($InputObject.pageFile.adequate) requiredMB=$($InputObject.pageFile.requiredMB) nmf=$($InputObject.notMyFault.status) desired=$(@($InputObject.desired.Keys) -join ',')")
    }
}
function ForEach-Object ([scriptblock]$Process) {
    process {
        $context = [System.Collections.Generic.List[psvariable]]@([psvariable]::new('_', $_))
        $Process.InvokeWithContext($null, $context)
    }
}
'''.replace('CRASH_CONTROL', CRASH_CONTROL).replace('MEMORY_MANAGEMENT', MEMORY_MANAGEMENT) \
        .replace('OLD_DATA', PsLiteral(oldData)).replace('NEW_DATA', PsLiteral(data))


class ValidatorMainFlowTests(unittest.TestCase):
    """The validator's top-level statements, run in order with every command mocked.

    The pure helpers run unchanged next to the mocks; registry reads come from an in-memory
    registry. The script's own `Set-StrictMode -Version Latest` runs through the real cmdlet the
    harness provides, so the flow runs in strict mode (pwsh 7.4 rules; a Windows PowerShell 5.1
    run remains authoritative). No mock for a registry, CIM or reboot write exists, so any such
    call would fail the run.
    """

    VALID = {'crashControl': GOLDEN_IMAGE, 'pagingFiles': ['C:\\pagefile.sys 16641 16641']}

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
                    "$StageNotMyFault = $global:MockState['stage'] -contains 'true'\n"
                    "$DataFile = 'C:\\Windows\\Temp\\crash-control.json'\n")
        with tempfile.TemporaryDirectory() as tmpDir:
            flowPath = Path(tmpDir) / 'main-flow.ps1'
            mocksPath = Path(tmpDir) / 'main-flow-mocks.ps1'
            flowPath.write_text('function Invoke-MainFlow {\ntry {\n' + preamble + body +
                                '\n} catch { if ("$_" -ne \'script-exit\') { Write-FlowError "$_" } }\n}\n', encoding='ascii')
            mocksPath.write_text(MainFlowMocks() + '\n' + '\n'.join(helperTexts) + '\n', encoding='ascii')
            calls = [{'state': dict(self.VALID, **state), 'args': []} for state in states]
            return [result['log'] for result in RunHarness(self, 'mockcall', 'Invoke-MainFlow', calls,
                                                           scriptPath=flowPath, mocksPath=mocksPath)]

    @staticmethod
    def Json(log):
        lines = [line for line in log if line.startswith('json ')]
        return lines[0] if len(lines) == 1 else None

    def testMatchingGoldenImageValidatesWithoutStaging(self):
        log = self.RunScript([{}])[0]
        desired = ','.join(json.loads(DATA_FILE.read_text(encoding='utf-8'))['recommended']['values'])
        self.assertEqual(self.Json(log), f'json action=validated match=True issues= adequate=True requiredMB=16641 nmf=not requested desired={desired}')
        self.assertFalse([line for line in log if line.startswith(('staging', 'stderr', 'fail', 'error'))], log)

    def testEveryKindOfMismatchIsReportedWithoutChanges(self):
        cases = [
            ({'crashControl': [entry for entry in GOLDEN_IMAGE if not entry.startswith('AutoReboot')]}, 'AutoReboot:missing'),
            ({'crashControl': [entry if not entry.startswith('CrashDumpEnabled') else 'CrashDumpEnabled=2' for entry in GOLDEN_IMAGE]}, 'CrashDumpEnabled:wrong value'),
            ({'kind': ['DumpFile=String']}, 'DumpFile:wrong type'),
            ({'kind': ['Overwrite=String']}, 'Overwrite:wrong type'),
            ({'crashControl': GOLDEN_IMAGE + ['DedicatedDumpFile=C:\\DedicatedDump.sys']}, 'DedicatedDumpFile:must be absent'),
        ]
        for (state, issue), log in zip(cases, self.RunScript([state for state, _ in cases])):
            with self.subTest(issue=issue):
                self.assertIn(' match=False ', self.Json(log))
                self.assertIn(f'issues={issue} ', self.Json(log))
        keyMissing = self.RunScript([{'keyMissing': ['true']}])[0]
        self.assertIn(f'issues={CRASH_CONTROL}:key missing,CrashDumpEnabled:missing,', self.Json(keyMissing))

    def testOlderDataStillRequiresDedicatedDumpFileAbsent(self):
        log = self.RunScript([{'data': ['old'], 'crashControl': GOLDEN_IMAGE + ['DedicatedDumpFile=C:\\DedicatedDump.sys']}])[0]
        self.assertIn('stderr WARN: crash-control.json still recommends DedicatedDumpFile; it is validated as must-be-absent instead', log)
        self.assertIn('issues=DedicatedDumpFile:must be absent ', self.Json(log))
        self.assertNotIn('DedicatedDumpFile', self.Json(log).split('desired=')[1])

    def testIntentionalRunStagesTheLatestNotMyFault(self):
        staged, failed = self.RunScript([{'stage': ['true']}, {'stage': ['true'], 'stagingFails': ['true']}])
        self.assertIn(f'staging {NMF_SOURCE}', staged)
        self.assertIn(' nmf=staged ', self.Json(staged))
        self.assertIn('fail 4 NotMyFault could not be staged: signature status NotSigned, signer none', failed)
        self.assertIn(' nmf=failed ', self.Json(failed))

    def testStagingFailureKeepsTheSettingsMismatchesVisible(self):
        state = {'stage': ['true'], 'stagingFails': ['true'],
                 'crashControl': [entry for entry in GOLDEN_IMAGE if not entry.startswith('AutoReboot')], 'pagingFiles': ['?:\\pagefile.sys']}
        log = self.RunScript([state])[0]
        self.assertIn('fail 4 NotMyFault could not be staged: signature status NotSigned, signer none', log)
        self.assertIn(' match=False issues=AutoReboot:missing adequate=False ', self.Json(log))
        self.assertIn(' nmf=failed ', self.Json(log))
        self.assertLess(log.index(next(line for line in log if line.startswith('fail 4'))), log.index(self.Json(log)))

    def testUnknownDumpTypeAndInvalidMemory(self):
        unknown = self.RunScript([{'dumpType': ['small']}])[0]
        self.assertTrue([line for line in unknown if line.startswith("fail 2 Unknown dump type 'small'")], unknown)
        for memory in ('error', '0'):
            with self.subTest(memory=memory):
                log = self.RunScript([{'memory': [memory]}])[0]
                self.assertTrue([line for line in log if line.startswith('stderr WARN: ') and 'physical memory size' in line], log)
                self.assertIn(' adequate=False requiredMB= ', self.Json(log))


if __name__ == '__main__':
    unittest.main()
