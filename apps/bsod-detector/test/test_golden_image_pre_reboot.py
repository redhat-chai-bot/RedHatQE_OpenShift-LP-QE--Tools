#!/usr/bin/env python3
"""Offline checks for golden-image-pre-reboot.ps1.

The script changes the registry and reboots Windows, so it is never executed. Static checks
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
SCRIPT = GUEST_DIR / 'golden-image-pre-reboot.ps1'
PARTNER_SCRIPT = GUEST_DIR / 'golden-image-post-reboot.ps1'
HARNESS = Path(__file__).resolve().parent / 'fixtures' / 'ps-function-harness.ps1'
DATA_FILE = APP_DIR / 'src' / 'data' / 'crash-control.json'

# Mock cmdlets for Set-FixedPagefile; they exist only inside the harness's empty runspace.
PAGEFILE_MOCKS = r'''
function Get-CimInstance ([string]$ClassName, $ErrorAction) {
    $global:MockLog.Add("Get-CimInstance ${ClassName}")
    [pscustomobject]@{ AutomaticManagedPagefile = ($global:MockState['auto'] -contains 'true') }
}
function Set-CimInstance ($InputObject, [hashtable]$Property, $ErrorAction) {
    $global:MockLog.Add("Set-CimInstance AutomaticManagedPagefile=$($Property['AutomaticManagedPagefile'])")
    if ($global:MockState['setFails'] -contains 'true') { throw 'Access denied' }
}
function Set-ItemProperty ([string]$Path, [string]$Name, [string]$Type, [string[]]$Value, $ErrorAction) {
    $global:MockLog.Add("Set-ItemProperty ${Name} ${Type} count=$($Value.Count) [$($Value -join '|')]")
}
function Write-Host ($Object) { $global:MockLog.Add("Write-Host ${Object}") }
'''

# Expected pagefile sizes (MB), shared with the post-reboot tests. The 4095.5 and 16383.5 MiB
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


# Mocks for the whole-script tests: every command, network call and registry write is simulated.
# 'memory' is error, null, s:<text> (a non-numeric value) or a byte count; on error only the first
# Win32_ComputerSystem read fails (throwing with -ErrorAction Stop, else returning nothing).
preMainFlowMocks = r'''
function Get-CimInstance ([string]$ClassName, $ErrorAction) {
    $isFirstRead = -not ($global:MockLog -like 'Get-CimInstance *')
    $global:MockLog.Add("Get-CimInstance ${ClassName} ErrorAction=${ErrorAction}")
    $memory = @($global:MockState['memory'])[0]
    if ($memory -eq 'error' -and $isFirstRead) {
        if ("${ErrorAction}" -eq 'Stop') { throw 'simulated CIM failure' }
        return
    }
    $totalMemory = if ($memory -in 'error', 'null') { $null } elseif ($memory -like 's:*') { $memory.Substring(2) } else { [int64]$memory }
    [pscustomobject]@{ AutomaticManagedPagefile = $true; TotalPhysicalMemory = $totalMemory }
}
function Set-CimInstance ($InputObject, [hashtable]$Property, $ErrorAction) { $global:MockLog.Add('Set-CimInstance') }
function Set-ItemProperty ([string]$Path, [string]$Name, $Value, [string]$Type, $ErrorAction) {
    $global:MockLog.Add("Set-ItemProperty ${Name}=$(@($Value) -join '|') ${Type} ErrorAction=${ErrorAction}")
    if ($global:MockState['regFails'] -contains $Name) {
        # Like the real cmdlet, the failure terminates only with -ErrorAction Stop.
        if ("${ErrorAction}" -ne 'Stop') { $global:MockLog.Add("suppressed Set-ItemProperty error ${Name}"); return }
        throw 'Requested registry access is not allowed.'
    }
}
function Get-ItemProperty ([string]$Path, [string]$Name, $ErrorAction) {
    if ($Name -eq 'DedicatedDumpFile' -and $global:MockState['ddf'] -contains 'present') { [pscustomobject]@{ DedicatedDumpFile = 'C:\DedicatedDump.sys' } }
}
function Remove-ItemProperty ([string]$Path, [string]$Name, $ErrorAction) { $global:MockLog.Add("Remove-ItemProperty ${Name} ErrorAction=${ErrorAction}") }
function New-Item ([string]$ItemType, [switch]$Force, [string]$Path) { $global:MockLog.Add("New-Item ${Path}") }
function Out-Null { process { } }
function Enable-TLS12 { $global:MockLog.Add('Enable-TLS12') }
function Get-RemoteLastModifiedUTC ([string]$URL) {
    $global:MockLog.Add('Get-RemoteLastModifiedUTC')
    $remote = @($global:MockState['remote'])[0]
    if ($remote -eq 'error') { throw 'The remote name could not be resolved' }
    if ($remote -and $remote -ne 'none') { [datetime]::Parse($remote, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) }
}
function Test-Path ([string]$Path, [string]$LiteralPath) {
    $target = if ($LiteralPath) { $LiteralPath } else { $Path }
    $global:MockState['existing'] -contains $target
}
function Get-Item ([string]$Path, $ErrorAction) {
    if ($Path -like '*.iso') {
        return [pscustomobject]@{ LastWriteTimeUtc = [datetime]::Parse('2026-01-15T00:00:00Z', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal); Length = 734003200 }
    }
    [pscustomobject]@{ FullName = $Path }
}
function Save-ISOdownload ([string]$URL, [string]$Path) {
    $global:MockLog.Add("Save-ISOdownload ${Path}")
    if ($global:MockState['downloadFails'] -contains 'true') { throw 'The operation has timed out' }
}
function Move-Item ([string]$Path, [string]$Destination, [switch]$Force, $ErrorAction) { $global:MockLog.Add("Move-Item ${Path} ${Destination}") }
function Remove-Item ([string]$Path, [string]$LiteralPath, [switch]$Force, $ErrorAction) { $global:MockLog.Add("Remove-Item $(if ($LiteralPath) { $LiteralPath } else { $Path })") }
function Get-DiskImage ([string]$ImagePath, $ErrorAction) {
    $global:MockLog.Add("Get-DiskImage ${ImagePath}")
    [pscustomobject]@{ Attached = ($global:MockState['mounted'] -contains 'true') }
}
function Mount-DiskImage ([string]$ImagePath, [switch]$PassThru, $ErrorAction) {
    $global:MockLog.Add("Mount-DiskImage ${ImagePath}")
    if ($global:MockState['mountFails'] -contains 'true') { throw 'The file or directory is corrupted and unreadable.' }
    [pscustomobject]@{ Attached = $true }
}
function Get-Volume ([Parameter(ValueFromPipeline)]$DiskImage) {
    process { [pscustomobject]@{ DriveLetter = $(if ($global:MockState['noDrive'] -contains 'true') { $null } else { 'E' }) } }
}
function Start-Process ([string]$FilePath, [string]$ArgumentList, [switch]$Wait, [switch]$PassThru) {
    $global:MockLog.Add("Start-Process ${FilePath} ${ArgumentList}")
    [pscustomobject]@{ ExitCode = 0 }
}
function Get-ChildItem { $global:MockLog.Add('Get-ChildItem') }
function Where-Object { process { } }
function Select-Object { process { } }
function pnputil { $global:MockLog.Add("pnputil $($args -join ' ')"); $global:LASTEXITCODE = 0 }
function Dismount-DiskImage ([string]$ImagePath) { $global:MockLog.Add("Dismount-DiskImage ${ImagePath}") }
function Get-Service ([string]$Name, $ErrorAction) {
    if ($global:MockState['service'] -contains 'missing') { return }
    [pscustomobject]@{ Status = $(if ($global:MockState['service'] -contains 'stopped') { 'Stopped' } else { 'Running' }) }
}
function Set-Service ([string]$Name, [string]$StartupType) { $global:MockLog.Add("Set-Service ${Name} ${StartupType}") }
function Start-Service ([string]$Name, $ErrorAction) { $global:MockLog.Add("Start-Service ${Name}") }
function Write-Host ($Object) { $global:MockLog.Add("Write-Host ${Object}") }
function Write-Error ($Message) { $global:MockLog.Add("Write-Error ${Message}") }
function Start-Sleep ($Seconds) { $global:MockLog.Add("Start-Sleep ${Seconds}") }
function Restart-Computer ([switch]$Force) { $global:MockLog.Add('Restart-Computer') }
function Exit-Script ([int]$Code) { $global:MockLog.Add("exit ${Code}") }
'''


class PreRebootStaticTests(unittest.TestCase):
    def setUp(self):
        self.source = SCRIPT.read_bytes()
        self.text = self.source.decode('ascii', errors='replace')

    def test_source_is_ascii_for_windows_powershell_51(self):
        # Windows PowerShell 5.1 reads BOM-less files as ANSI; UTF-8 punctuation can end strings early.
        self.assertTrue(self.source.isascii())

    def test_source_ends_with_newline(self):
        self.assertTrue(self.source.endswith(b'\n'))

    def test_pagefile_size_uses_the_shared_function(self):
        self.assertIn('$pagefileSizeMB = Get-PagefileSizeMB $ramBytes', self.text)
        self.assertIsNone(re.search(r'\)\s*\+\s*257\b', self.text))

    def test_remote_timestamp_failure_is_handled(self):
        self.assertRegex(self.text, r'(?s)try \{\s*\$remoteLastModified = Get-RemoteLastModifiedUTC \$isoURL(?:(?!\} catch \{).)*\} catch \{')
        # A missing Last-Modified header must not be read as "now" (HttpWebResponse.LastModified does that).
        self.assertIn("$header = $resp.Headers['Last-Modified']", self.text)
        self.assertNotRegex(self.text, r'\$resp\.LastModified')

    def test_iso_download_goes_through_a_temporary_file(self):
        self.assertIn('Save-ISOdownload $isoURL $isoTmpPath', self.text)
        self.assertIn('(New-Object System.Net.WebClient).DownloadFile($URL, $Path)', self.text)
        self.assertIn('Move-Item -Path $isoTmpPath -Destination $isoPath -Force -ErrorAction Stop', self.text)
        self.assertNotIn('Save-ISOdownload $isoURL $isoPath', self.text)

    def test_memory_is_validated_before_any_side_effect(self):
        mainFlow = self.text[self.text.index('# The memory size is read before any change'):]
        guard = mainFlow.index('if (-not ($ramBytes -gt 0)) {')
        for sideEffect in ("New-Item -ItemType Directory -Force -Path 'C:\\Temp'", 'Enable-TLS12\n', 'Save-ISOdownload',
                           'Mount-DiskImage', 'Start-Process', 'Set-ItemProperty', 'Set-FixedPagefile $pagefileSizeMB', 'Restart-Computer'):
            self.assertLess(guard, mainFlow.index(sideEffect), sideEffect)
        self.assertEqual(self.text.count('TotalPhysicalMemory -as [int64]'), 1)

    def test_old_dedicated_dump_file_is_reported_not_deleted(self):
        self.assertNotRegex(self.text, r'Remove-Item[^\n]*DedicatedDump\.sys')
        self.assertIn("if (Test-Path -LiteralPath 'C:\\DedicatedDump.sys') {", self.text)

    def test_pagefile_uses_documented_cim_property_and_fails_the_script_on_error(self):
        self.assertNotIn('-Name AutomaticManagedPagefile -Value 0', self.text)
        self.assertIn('Set-CimInstance -InputObject $computer -Property @{ AutomaticManagedPagefile = $false } -ErrorAction Stop', self.text)
        self.assertRegex(self.text, r'(?s)try \{\s*Set-FixedPagefile \$pagefileSizeMB\s*\} catch \{[^}]*exit 1')

    def test_installer_exit_codes_are_checked(self):
        self.assertIn('-Wait -PassThru', self.text)
        self.assertIn('Test-InstallerSuccess $msiProcess.ExitCode', self.text)
        self.assertIn('Test-InstallerSuccess $LASTEXITCODE', self.text)

    def test_pvpanic_is_documented_as_a_qemu_monitor_device_only(self):
        self.assertNotIn('Device is added at runtime by preflight-rhov.sh', self.text)
        self.assertIn('device_add pvpanic,id=pvpanic0', self.text)
        self.assertIn('src/scripts/crash-injector/trigger-bsod-intentional.sh', self.text)
        self.assertIsNone(re.search(r'(?m)^#\s*\$pvpanic', self.text))

    def test_obsolete_recovery_settings_are_removed(self):
        self.assertNotRegex(self.text, r'(?i)bcdedit|reagentc|recoveryenabled')
        self.assertIn('CrashDumpEnabled', self.text)
        # The rationale stays documented, including that it is unverified for restarted VMs.
        self.assertIn('intentionally left at their Windows defaults for disposable test VMs', self.text)
        self.assertIn('src/scripts/host/watch-crash.sh does unless --no-restart', self.text)

    def test_double_quoted_strings_use_formal_variable_syntax(self):
        self.assertEqual(SimpleVariablesInDoubleQuotes(self.text), [])


class PreRebootPowerShellTests(unittest.TestCase):
    def test_parses_as_utf8_and_windows_1252_without_powershell_7_syntax(self):
        parsed = RunHarness(self, 'parse')
        self.assertEqual(parsed['utf8Errors'], 0)
        self.assertEqual(parsed['windows1252Errors'], 0)
        self.assertEqual(parsed['ps7OnlyTokens'], [])
        self.assertEqual(parsed['convertibleDoubleQuoted'], [])
        self.assertEqual(parsed['numberTokens'].count('257MB'), 1)
        self.assertEqual(sorted(parsed['functions']), sorted(PreRebootMainFlowTests.HELPERS + PreRebootMainFlowTests.MOCKED_HELPERS))

    def test_pagefile_size_rounds_once(self):
        ramValues = list(PAGEFILE_SIZES_MB)
        sizes = RunHarness(self, 'call', 'Get-PagefileSizeMB', [[ram] for ram in ramValues])
        self.assertEqual(dict(zip(ramValues, sizes)), PAGEFILE_SIZES_MB)

    def test_pagefile_size_matches_post_reboot_script(self):
        # Fails instead of skipping, so a validation checkout without the post-reboot change cannot pass.
        own = RunHarness(self, 'definition', 'Get-PagefileSizeMB')
        partner = RunHarness(self, 'definition', 'Get-PagefileSizeMB', scriptPath=PARTNER_SCRIPT)
        self.assertTrue(partner['found'], 'golden-image-post-reboot.ps1 lacks Get-PagefileSizeMB; include its companion change')
        self.assertEqual(partner['text'], own['text'])

    def test_fixed_pagefile_replaces_system_managed_configuration(self):
        cases = [{'state': {'auto': ['true']}, 'args': [16641]}, {'state': {'auto': ['false']}, 'args': [16641]}]
        with tempfile.TemporaryDirectory() as tmpDir:
            mocks = Path(tmpDir) / 'mocks.ps1'
            mocks.write_text(PAGEFILE_MOCKS, encoding='ascii')
            systemManaged, manual = RunHarness(self, 'mockcall', 'Set-FixedPagefile', cases, mocksPath=mocks)
            failure = RunHarness(self, 'mockcall', 'Set-FixedPagefile', [{'state': {'auto': ['true'], 'setFails': ['true']}, 'args': [16641]}],
                                 mocksPath=mocks, expectSuccess=False)
        expected = 'Set-ItemProperty PagingFiles MultiString count=1 [C:\\pagefile.sys 16641 16641]'
        self.assertIn('Set-CimInstance AutomaticManagedPagefile=False', systemManaged['log'])
        self.assertIn(expected, systemManaged['log'])
        self.assertFalse([entry for entry in manual['log'] if entry.startswith('Set-CimInstance')])
        self.assertIn(expected, manual['log'])
        self.assertIn('Access denied', failure)

    def test_iso_download_decision(self):
        older, newer = {'utc': '2026-01-01T00:00:00Z'}, {'utc': '2026-02-01T00:00:00Z'}
        cases = [
            ([None, newer], True),     # no cache
            ([None, None], True),      # no cache, remote unknown
            ([older, newer], True),    # cache older than remote
            ([newer, older], False),   # cache newer than remote
            ([newer, newer], False),   # same timestamp
            ([older, None], False),    # remote unknown: keep cache
        ]
        decisions = RunHarness(self, 'call', 'Test-ISOdownloadNeeded', [args for args, _ in cases])
        self.assertEqual(decisions, [expected for _, expected in cases])

    def test_installer_success_codes(self):
        codes = [0, 1641, 3010, 1, 1603, None]
        results = RunHarness(self, 'call', 'Test-InstallerSuccess', [[code] for code in codes])
        self.assertEqual(results, [True, True, True, False, False, False])

    def test_isolated_runspace_cannot_reach_host_commands(self):
        names = ['Restart-Computer', 'Set-ItemProperty', 'Start-Process', 'Remove-Item', 'Get-ChildItem', 'cmd', 'sh']
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


class PreRebootMainFlowTests(unittest.TestCase):
    """The whole script, run as it runs on the guest, with every command mocked.

    Network, disk-image, installer, registry and reboot operations exist only as mocks that
    record their calls. The network helpers are replaced by mocks; the other helpers run unchanged.
    """

    HELPERS = ['Get-PagefileSizeMB', 'Test-ISOdownloadNeeded', 'Test-InstallerSuccess', 'Set-FixedPagefile']
    MOCKED_HELPERS = ['Enable-TLS12', 'Get-RemoteLastModifiedUTC', 'Save-ISOdownload']
    VALID = {'memory': ['17179869184'], 'remote': ['2026-02-01T00:00:00Z'], 'existing': [], 'ddf': ['present']}
    SIDE_EFFECTS = ('New-Item', 'Enable-TLS12', 'Get-RemoteLastModifiedUTC', 'Save-ISOdownload', 'Move-Item', 'Remove-Item',
                    'Get-DiskImage', 'Mount-DiskImage', 'Start-Process', 'pnputil', 'Dismount-DiskImage', 'Set-Service',
                    'Start-Service', 'Set-ItemProperty', 'Remove-ItemProperty', 'Set-CimInstance', 'Start-Sleep', 'Restart-Computer')

    def RunScript(self, states):
        with tempfile.TemporaryDirectory() as tmpDir:
            flowPath, mocksPath = WriteMainFlowFiles(self, tmpDir, self.HELPERS, preMainFlowMocks,
                                                     mockedHelperNames=self.MOCKED_HELPERS)
            calls = [{'state': dict(self.VALID, **state), 'args': []} for state in states]
            return [result['log'] for result in RunHarness(self, 'mockcall', 'Invoke-MainFlow', calls,
                                                           scriptPath=flowPath, mocksPath=mocksPath)]

    @staticmethod
    def Starting(log, *prefixes):
        return [line for line in log if line.startswith(prefixes)]

    def testInvalidMemoryStopsBeforeAnySideEffect(self):
        memoryValues = ['error', 'null', '0', '-1073741824', 's:not-a-number']
        for memory, log in zip(memoryValues, self.RunScript([{'memory': [memory]} for memory in memoryValues])):
            with self.subTest(memory=memory):
                self.assertEqual(log[-1], 'exit 1', log)
                self.assertTrue(self.Starting(log, 'Write-Error FAIL:'), log)
                self.assertEqual(self.Starting(log, *self.SIDE_EFFECTS), [])

    def testValidRunWritesCrashControlFromTheDataFileThenReboots(self):
        log = self.RunScript([{}])[0]
        self.assertTrue(log[0].startswith('Get-CimInstance Win32_ComputerSystem ErrorAction=Stop'), log)
        self.assertNotIn('exit 1', log)
        self.assertEqual(log[-1], 'Restart-Computer')
        recommended = json.loads(DATA_FILE.read_text(encoding='utf-8'))['recommended']['values']
        expected = sorted(f"Set-ItemProperty {name}={value} {'DWord' if isinstance(value, int) else 'ExpandString'} ErrorAction=Stop"
                          for name, value in recommended.items() if name != 'DedicatedDumpFile')
        written = sorted(line for line in self.Starting(log, 'Set-ItemProperty') if not line.startswith('Set-ItemProperty PagingFiles'))
        self.assertEqual(written, expected)
        self.assertIn('Remove-ItemProperty DedicatedDumpFile ErrorAction=Stop', log)
        self.assertIn('Set-ItemProperty PagingFiles=C:\\pagefile.sys 16641 16641 MultiString ErrorAction=Stop', log)
        order = [next(index for index, line in enumerate(log) if line.startswith(prefix))
                 for prefix in ('Save-ISOdownload', 'Mount-DiskImage', 'Start-Process', 'Set-Service', 'Set-ItemProperty CrashDumpEnabled',
                                'Set-ItemProperty PagingFiles', 'Restart-Computer')]
        self.assertEqual(order, sorted(order))

    def testRegistryWriteFailureStopsBeforePagefileAndReboot(self):
        log = self.RunScript([{'regFails': ['LogEvent']}])[0]
        self.assertEqual(log[-1], 'exit 1', log)
        self.assertTrue(self.Starting(log, 'Write-Error FAIL: crash dump registry write failed: Requested registry access'), log)
        self.assertEqual(self.Starting(log, 'Set-ItemProperty PagingFiles', 'Set-CimInstance', 'Remove-ItemProperty', 'Restart-Computer'), [])

    def testMountFailureOrMissingDriveLetterStopsBeforeInstalling(self):
        for state, message in (({'mountFails': ['true']}, 'Write-Error FAIL: cannot mount'), ({'noDrive': ['true']}, 'Write-Error FAIL: C:\\Temp\\virtio-win.iso is mounted without a drive letter')):
            with self.subTest(state=state):
                log = self.RunScript([state])[0]
                self.assertEqual(log[-1], 'exit 1', log)
                self.assertTrue(self.Starting(log, message), log)
                self.assertEqual(self.Starting(log, 'Start-Process', 'pnputil', 'Set-ItemProperty', 'Restart-Computer'), [])

    def testAlreadyMountedISOisReused(self):
        log = self.RunScript([{'mounted': ['true']}])[0]
        self.assertEqual(self.Starting(log, 'Mount-DiskImage'), [])
        self.assertTrue(self.Starting(log, 'Start-Process msiexec.exe /i E:\\guest-agent\\qemu-ga-x86_64.msi'), log)
        self.assertEqual(log[-1], 'Restart-Computer')

    def testDownloadFailureStopsWithoutCacheAndFallsBackToCache(self):
        noCache, cached = self.RunScript([{'downloadFails': ['true']},
                                          {'downloadFails': ['true'], 'existing': ['C:\\Temp\\virtio-win.iso']}])
        self.assertEqual(noCache[-1], 'exit 1', noCache)
        self.assertIn('Remove-Item C:\\Temp\\virtio-win.iso.download', noCache)
        self.assertEqual(self.Starting(noCache, 'Get-DiskImage', 'Move-Item', 'Set-ItemProperty', 'Restart-Computer'), [])
        self.assertTrue([line for line in cached if line.startswith('Write-Host WARN: virtio-win ISO download failed, using the cached copy')], cached)
        self.assertEqual(cached[-1], 'Restart-Computer')

    def testMissingLastModifiedHeaderKeepsTheCache(self):
        log = self.RunScript([{'remote': ['none'], 'existing': ['C:\\Temp\\virtio-win.iso']}])[0]
        self.assertIn('Write-Host WARN: the server sent no Last-Modified header; a cached ISO is kept', log)
        self.assertEqual(self.Starting(log, 'Save-ISOdownload'), [])
        self.assertEqual(log[-1], 'Restart-Computer')

    def testAbsentDedicatedDumpFileIsLeftAloneAndAnOldDumpFileOnlyWarns(self):
        log = self.RunScript([{'ddf': [], 'existing': ['C:\\DedicatedDump.sys']}])[0]
        self.assertEqual(self.Starting(log, 'Remove-ItemProperty', 'Remove-Item'), [])
        self.assertIn('Write-Host WARN: C:\\DedicatedDump.sys from an older preparation is no longer used - delete it before sealing', log)
        self.assertEqual(log[-1], 'Restart-Computer')

    def testGuestAgentNotRunningStopsBeforeRegistryWrites(self):
        for service in ('stopped', 'missing'):
            with self.subTest(service=service):
                log = self.RunScript([{'service': [service]}])[0]
                self.assertEqual(log[-1], 'exit 1', log)
                self.assertTrue(self.Starting(log, 'Write-Error FAIL: QEMU-GA'), log)
                self.assertEqual(self.Starting(log, 'Set-ItemProperty', 'Restart-Computer'), [])


if __name__ == '__main__':
    unittest.main()
