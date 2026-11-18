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
# The latest-virtio alias and a sample resolved release (any version: nothing is hardcoded in the script).
ALIAS_URL = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso'
RESOLVED_URL = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-9.9.9-1/virtio-win-9.9.9.iso'
OLDER_URL = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-9.9.8-1/virtio-win-9.9.8.iso'
RECORD_PATH = 'C:\\ProgramData\\bsod-detector\\virtio-win-iso.json'
DOWNLOAD_SHA256 = 'CD' * 32
OTHER_SHA256 = 'AB' * 32

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
function Get-FileHash ([string]$LiteralPath, [string]$Algorithm, $ErrorAction) {
    $global:MockLog.Add("Get-FileHash ${LiteralPath} ${Algorithm}")
    $key = if ($LiteralPath -like '*.download') { 'downloadHash' } else { 'cacheHash' }
    [pscustomobject]@{ Hash = "$(@($global:MockState[$key])[0])" }
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
function Resolve-OfficialHTTPS ([string]$url, [string]$officialHost) {
    $global:MockLog.Add("Resolve-OfficialHTTPS ${url} ${officialHost}")
    $resolved = @($global:MockState['resolved'])[0]
    if ($resolved -eq 'error') { throw 'redirect from the alias leaves fedorapeople.org' }
    $resolved
}
function Read-ArtifactRecord ([string]$path) {
    $global:MockLog.Add("Read-ArtifactRecord ${path}")
    if (-not $global:MockState['record']) { return }
    $source, $sha256 = "$(@($global:MockState['record'])[0])" -split '\|', 2
    [pscustomobject]@{ resolvedSource = $source; sha256 = $sha256 }
}
function Write-ArtifactRecord ([string]$path, $record) {
    $global:MockLog.Add("Write-ArtifactRecord ${path} source=$($record['source']) resolvedSource=$($record['resolvedSource']) version=$($record['version']) sha256=$($record['sha256']) sizeBytes=$($record['sizeBytes'])")
    if ($global:MockState['recordFails'] -contains 'true') { throw 'Access to the path is denied.' }
}
function Save-HTTPSdownload ([string]$url, [string]$path) {
    $global:MockLog.Add("Save-HTTPSdownload ${url} ${path}")
    if ($global:MockState['downloadFails'] -contains 'true') { throw 'The operation has timed out' }
    $global:MockState['existing'] = @($global:MockState['existing']) + $path
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
function Dismount-DiskImage ([string]$ImagePath, $ErrorAction) { $global:MockLog.Add("Dismount-DiskImage ${ImagePath}") }
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
function Exit-Script ([int]$code) { $global:MockLog.Add("exit ${code}") }
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

    def test_iso_is_the_resolved_latest_release_with_a_recorded_hash(self):
        self.assertIn(f"$isoAliasURL   = '{ALIAS_URL}'", self.text)
        self.assertIn("$isoURL = Resolve-OfficialHTTPS $isoAliasURL 'fedorapeople.org'", self.text)
        self.assertIn(f"$isoRecordPath = '{RECORD_PATH.replace(chr(92) * 2, chr(92))}'", self.text)
        # No hardcoded version or digest, no plain-HTTP request and no Last-Modified decision.
        self.assertIsNone(re.search(r'\b[0-9A-Fa-f]{64}\b', self.text))
        self.assertNotRegex(self.text, r'virtio-win-[0-9]+\.[0-9]+|archive-virtio/|stable-virtio|Last-Modified')
        code = '\n'.join(line for line in self.text.splitlines() if not line.lstrip().startswith('#'))
        self.assertNotIn('http://', code)  # comments explain that the alias redirects to plain http://
        # The hash is calculated from the download, recorded only after the move, and called an audit record.
        self.assertLess(self.text.index('Save-HTTPSdownload $isoURL $isoTmpPath'), self.text.index('$isoSHA256 = (Get-FileHash -LiteralPath $isoTmpPath -Algorithm SHA256 -ErrorAction Stop).Hash'))
        self.assertLess(self.text.index('Move-Item -Path $isoTmpPath -Destination $isoPath'), self.text.index('Write-ArtifactRecord $isoRecordPath'))
        self.assertIn('audit record, not publisher verification', self.text)
        self.assertNotIn('MinidumpDir', self.text)

    def test_iso_download_goes_through_a_temporary_file(self):
        self.assertIn('Save-HTTPSdownload $isoURL $isoTmpPath', self.text)
        # The shared download (identical in validate-crash-settings.ps1) does not follow redirects.
        self.assertIn('$request.AllowAutoRedirect = $false', self.text)
        self.assertNotIn('WebClient', self.text)
        self.assertIn('Move-Item -Path $isoTmpPath -Destination $isoPath -Force -ErrorAction Stop', self.text)
        self.assertNotIn('Save-HTTPSdownload $isoURL $isoPath', self.text)

    def test_memory_is_validated_before_any_side_effect(self):
        mainFlow = self.text[self.text.index('# The memory size is read before any change'):]
        guard = mainFlow.index('if (-not ($ramBytes -gt 0)) {')
        for sideEffect in ("New-Item -ItemType Directory -Force -Path 'C:\\Temp'", 'Enable-TLS12\n', 'Save-HTTPSdownload',
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
        self.assertIn('the intended flow does not restart a VM after a', self.text)
        self.assertIn('src/scripts/host/watch-crash.sh still starts the VM again unless it', self.text)

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

    def test_iso_hash_check(self):
        iso = 'C:\\Temp\\virtio-win.iso'
        cases = [
            ({'existing': []}, False),                                                  # missing: not hashed
            ({'existing': [iso], 'cacheHash': [DOWNLOAD_SHA256.upper()]}, True),        # match (Get-FileHash is upper case)
            ({'existing': [iso], 'cacheHash': [OTHER_SHA256]}, False),                  # mismatch
        ]
        with tempfile.TemporaryDirectory() as tmpDir:
            mocks = Path(tmpDir) / 'mocks.ps1'
            mocks.write_text(preMainFlowMocks, encoding='ascii')
            results = RunHarness(self, 'mockcall', 'Test-ISOhash',
                                 [{'state': state, 'args': [iso, DOWNLOAD_SHA256.lower()]} for state, _ in cases], mocksPath=mocks)
        self.assertEqual([result['output'] for result in results], [[str(expected)] for _, expected in cases])
        self.assertFalse([entry for entry in results[0]['log'] if entry.startswith('Get-FileHash')])
        self.assertIn(f'Get-FileHash {iso} SHA256', results[1]['log'])

    def test_artifact_record_round_trip(self):
        # The two record helpers only touch the path they are given, so they run with real cmdlets in
        # a fresh pwsh on files in a temporary directory (the rest of the script is never executed).
        definitions = [RunHarness(self, 'definition', name) for name in ('Read-ArtifactRecord', 'Write-ArtifactRecord')]
        self.assertTrue(all(definition['found'] for definition in definitions))
        with tempfile.TemporaryDirectory() as tmpDir:
            record = Path(tmpDir) / 'ProgramData' / 'virtio-win-iso.json'
            corrupt = Path(tmpDir) / 'corrupt.json'
            corrupt.write_text('{ not json', encoding='ascii')
            probe = Path(tmpDir) / 'probe.ps1'
            probe.write_text('\n'.join(definition['text'] for definition in definitions) + f"""
Set-StrictMode -Version Latest
Write-ArtifactRecord '{record}' ([ordered]@{{ schema = 1; resolvedSource = '{RESOLVED_URL}'; version = '9.9.9'; sha256 = '{DOWNLOAD_SHA256}' }})
$read = Read-ArtifactRecord '{record}'
# Under the default error preference a failed write must still throw: first the parent is a file,
# then the record path is an existing directory (a failed Set-Content).
$writeFailure = 'written'
try {{ Write-ArtifactRecord '{corrupt / 'record.json'}' ([ordered]@{{ schema = 1 }}) }} catch {{ $writeFailure = 'threw' }}
$contentFailure = 'written'
try {{ Write-ArtifactRecord '{Path(tmpDir) / 'ProgramData'}' ([ordered]@{{ schema = 1 }}) }} catch {{ $contentFailure = 'threw' }}
[ordered]@{{
    read = $read
    missing = @(Read-ArtifactRecord '{Path(tmpDir) / 'missing.json'}').Count
    corrupt = @(Read-ArtifactRecord '{corrupt}').Count
    writeFailure = $writeFailure
    contentFailure = $contentFailure
}} | ConvertTo-Json -Compress
""", encoding='ascii')
            RunHarness(self, 'parse', scriptPath=probe)  # skips or fails like the other checks without pwsh
            result = subprocess.run([shutil.which('pwsh'), '-NoProfile', '-NonInteractive', '-File', str(probe)],
                                    capture_output=True, text=True, timeout=120, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            stored = record.read_bytes()
        output = json.loads(result.stdout)
        self.assertEqual((output['missing'], output['corrupt'], output['writeFailure'], output['contentFailure']), (0, 0, 'threw', 'threw'))
        self.assertEqual({key: output['read'][key] for key in ('schema', 'resolvedSource', 'version', 'sha256')},
                         {'schema': 1, 'resolvedSource': RESOLVED_URL, 'version': '9.9.9', 'sha256': DOWNLOAD_SHA256})
        self.assertRegex(output['read']['recordedUTC'], r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d')
        stored.decode('ascii')  # ASCII, as written for Windows PowerShell 5.1

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

    HELPERS = ['Get-PagefileSizeMB', 'Test-ISOhash', 'Test-InstallerSuccess', 'Set-FixedPagefile']
    MOCKED_HELPERS = ['Enable-TLS12', 'Save-HTTPSdownload', 'Get-HTTPSredirectTarget', 'Get-HTTPSresponseHead', 'Resolve-OfficialHTTPS',
                      'Read-ArtifactRecord', 'Write-ArtifactRecord']
    VALID = {'memory': ['17179869184'], 'existing': [], 'ddf': ['present'], 'downloadHash': [DOWNLOAD_SHA256], 'resolved': [RESOLVED_URL]}
    SIDE_EFFECTS = ('New-Item', 'Enable-TLS12', 'Resolve-OfficialHTTPS', 'Read-ArtifactRecord', 'Write-ArtifactRecord', 'Get-FileHash',
                    'Save-HTTPSdownload', 'Move-Item', 'Remove-Item',
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
        self.assertIn(f'Resolve-OfficialHTTPS {ALIAS_URL} fedorapeople.org', log)
        self.assertIn(f'Save-HTTPSdownload {RESOLVED_URL} C:\\Temp\\virtio-win.iso.download', log)
        self.assertIn(f'Write-ArtifactRecord {RECORD_PATH} source={ALIAS_URL} resolvedSource={RESOLVED_URL} version=9.9.9 '
                      f'sha256={DOWNLOAD_SHA256} sizeBytes=734003200', log)
        order = [next(index for index, line in enumerate(log) if line.startswith(prefix))
                 for prefix in ('Resolve-OfficialHTTPS', 'Save-HTTPSdownload', 'Get-FileHash C:\\Temp\\virtio-win.iso.download SHA256', 'Move-Item',
                                'Write-ArtifactRecord', 'Mount-DiskImage', 'Start-Process', 'Set-Service', 'Set-ItemProperty CrashDumpEnabled',
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

    def testRecordedLatestCacheIsReusedWithoutDownload(self):
        for state in ({}, {'mounted': ['true']}):
            with self.subTest(state=state):
                log = self.RunScript([dict(state, existing=['C:\\Temp\\virtio-win.iso'], record=[f'{RESOLVED_URL}|{OTHER_SHA256}'],
                                           cacheHash=[OTHER_SHA256])])[0]
                self.assertIn(f'Write-Host OK: cached virtio-win ISO is the latest release and matches its recorded SHA-256 {OTHER_SHA256}', log)
                self.assertEqual(self.Starting(log, 'Save-HTTPSdownload', 'Move-Item', 'Write-ArtifactRecord'), [])
                self.assertEqual(log[-1], 'Restart-Computer')

    def testNewerReleaseOrChangedCacheIsDownloadedAgain(self):
        cases = [
            {'existing': ['C:\\Temp\\virtio-win.iso'], 'record': [f'{OLDER_URL}|{OTHER_SHA256}'], 'cacheHash': [OTHER_SHA256]},          # newer latest release
            {'existing': ['C:\\Temp\\virtio-win.iso'], 'record': [f'{RESOLVED_URL}|{OTHER_SHA256}'], 'cacheHash': [DOWNLOAD_SHA256]},    # cache changed since recorded
            {'record': [f'{RESOLVED_URL}|{OTHER_SHA256}']},                                              # record without cache
        ]
        for state, log in zip(cases, self.RunScript(cases)):
            with self.subTest(state=state):
                self.assertIn(f'Save-HTTPSdownload {RESOLVED_URL} C:\\Temp\\virtio-win.iso.download', log)
                self.assertLess(log.index('Move-Item C:\\Temp\\virtio-win.iso.download C:\\Temp\\virtio-win.iso'),
                                next(index for index, line in enumerate(log) if line.startswith('Write-ArtifactRecord')))
                self.assertEqual(log[-1], 'Restart-Computer')

    def testOldRecordIsRemovedBeforeANewDownload(self):
        log = self.RunScript([{'existing': ['C:\\Temp\\virtio-win.iso', RECORD_PATH.replace(chr(92) * 2, chr(92))],
                               'record': [f'{OLDER_URL}|{OTHER_SHA256}'], 'cacheHash': [OTHER_SHA256]}])[0]
        removal = log.index('Remove-Item ' + RECORD_PATH.replace(chr(92) * 2, chr(92)))
        self.assertLess(removal, next(index for index, line in enumerate(log) if line.startswith('Save-HTTPSdownload')))
        self.assertEqual(log[-1], 'Restart-Computer')

    def testMountedOlderCacheIsDismountedBeforeItIsReplaced(self):
        log = self.RunScript([{'mounted': ['true'], 'existing': ['C:\\Temp\\virtio-win.iso'], 'record': [f'{OLDER_URL}|{OTHER_SHA256}'], 'cacheHash': [OTHER_SHA256]}])[0]
        dismount = log.index('Dismount-DiskImage C:\\Temp\\virtio-win.iso')
        self.assertLess(log.index('Get-FileHash C:\\Temp\\virtio-win.iso.download SHA256'), dismount)
        self.assertLess(dismount, log.index('Move-Item C:\\Temp\\virtio-win.iso.download C:\\Temp\\virtio-win.iso'))
        self.assertEqual(log[-1], 'Restart-Computer')

    def testResolutionDownloadOrRecordFailureStopsBeforeInstalling(self):
        cases = [
            ({'resolved': ['error']}, 'Write-Error FAIL: cannot resolve the latest virtio-win ISO over HTTPS: redirect from the alias leaves fedorapeople.org'),
            ({'downloadFails': ['true']}, 'Write-Error FAIL: the latest virtio-win ISO could not be downloaded and recorded: The operation has timed out'),
            ({'recordFails': ['true']}, 'Write-Error FAIL: the latest virtio-win ISO could not be downloaded and recorded: Access to the path is denied.'),
            ({'downloadFails': ['true'], 'existing': ['C:\\Temp\\virtio-win.iso'], 'record': [f'{OLDER_URL}|{OTHER_SHA256}'], 'cacheHash': [OTHER_SHA256]},
             'Write-Error FAIL: the latest virtio-win ISO could not be downloaded and recorded'),
        ]
        for (state, message), log in zip(cases, self.RunScript([state for state, _ in cases])):
            with self.subTest(state=state):
                self.assertEqual(log[-1], 'exit 1', log)
                self.assertTrue(self.Starting(log, message), log)
                self.assertEqual(self.Starting(log, 'Get-DiskImage', 'Mount-DiskImage', 'Start-Process', 'pnputil', 'Set-ItemProperty', 'Restart-Computer'), [])
        self.assertEqual(self.Starting(self.RunScript([{'resolved': ['error']}])[0], 'Save-HTTPSdownload', 'Read-ArtifactRecord'), [])

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
