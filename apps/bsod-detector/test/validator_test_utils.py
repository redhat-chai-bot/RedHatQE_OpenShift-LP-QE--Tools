#!/usr/bin/env python3
"""Shared helpers for the validate-crash-settings.ps1 test modules (imported as Utils).

Constants, PowerShell mocks and the harness runner used by test_validate_crash_settings_unit.py,
test_validate_crash_settings_contract.py and test_validate_crash_settings_main_flow.py. This module
holds no tests. The PowerShell checks need `pwsh`; without it they are skipped, or fail when
BSOD_DET__TEST__REQUIRE_PWSH=1.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import unittest
from pathlib import Path
from typing import Any


APP_DIR = Path(__file__).resolve().parents[1]
GUEST_DIR = APP_DIR / 'src' / 'scripts' / 'guest'
SCRIPT = GUEST_DIR / 'validate-crash-settings.ps1'
PARTNER_SCRIPTS = (GUEST_DIR / 'golden-image-pre-reboot.ps1', GUEST_DIR / 'golden-image-post-reboot.ps1')
DATA_FILE = APP_DIR / 'src' / 'data' / 'crash-control.json'
HOST_DIR = APP_DIR / 'src' / 'scripts' / 'host'
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
function Resolve-OfficialHTTPS ([string]$url, [string]$officialHost) {
    $global:MockLog.Add("Resolve-OfficialHTTPS ${url} ${officialHost}")
    if ($global:MockState['resolveFails'] -contains 'true') { throw 'redirect leaves download.sysinternals.com' }
    $url
}
function Save-HTTPSdownload ([string]$url, [string]$path) {
    $global:MockLog.Add("Save-HTTPSdownload ${url} ${path}")
    if ($global:MockState['downloadFails'] -contains 'true') { throw 'The remote name could not be resolved' }
    $global:MockState['existing'] = @($global:MockState['existing']) + $path
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
function Get-StagingRecord ([string]$source) {
    $record = Invoke-NotMyFaultStaging $source
    foreach ($key in $record.Keys) { "${key}=$($record[$key])" }
}
function Get-AbsenceList ($recommended) {
    @(Get-RequiredAbsence $recommended) -join ','
}
'''

# Mocks for Resolve-OfficialHTTPS: 'hops' are 'URL>status>location' entries.
RESOLVE_MOCKS = r'''
function Get-HTTPSresponseHead ([string]$url) {
    $global:MockLog.Add("HEAD ${url}")
    foreach ($hop in $global:MockState['hops']) {
        $from, $status, $location = $hop -split '>', 3
        if ($from -eq $url) { return [pscustomobject]@{ StatusCode = [int]$status; Location = $location } }
    }
    [pscustomobject]@{ StatusCode = 404; Location = $null }
}
'''


def SimpleVariablesInDoubleQuotes(text: str) -> list[int]:
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


def RunHarness(testCase: unittest.TestCase, mode: str, functionName: str = '', calls: list | None = None,
               scriptPath: Path = SCRIPT, expectSuccess: bool = True, mocksPath: Path | None = None) -> Any:
    """Runs fixtures/ps-function-harness.ps1; skips (or fails with BSOD_DET__TEST__REQUIRE_PWSH=1) without pwsh."""
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


def BlockAfter(text: str, marker: str) -> str:
    """Text of the brace-delimited block that starts at `marker` (which ends with '{')."""
    start = text.index(marker) + len(marker)
    depth = 1
    for index in range(start, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[start:index]
    raise AssertionError(f'unbalanced block after {marker}')


def RunPwshScript(testCase: unittest.TestCase, scriptPath: Path, *args: str) -> subprocess.CompletedProcess:
    """Runs a probe script in a fresh pwsh with real cmdlets; probes only read sources or use a temp dir."""
    RunHarness(testCase, 'parse', scriptPath=scriptPath)  # skips or fails like the harness checks without pwsh
    return subprocess.run([shutil.which('pwsh'), '-NoProfile', '-NonInteractive', '-File', str(scriptPath), *args],
                          capture_output=True, text=True, timeout=120, check=False)


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


def PsLiteral(value: Any) -> str:
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


def MainFlowMocks() -> str:
    """Mocks for the validator's top-level flow, with the real crash-control.json data inlined."""
    data = json.loads(DATA_FILE.read_text(encoding='utf-8'))
    oldData = json.loads(json.dumps(data))
    oldData['recommended']['values']['DedicatedDumpFile'] = 'C:\\DedicatedDump.sys'
    del oldData['recommended']['absentValues']
    return r'''
function Out-Null { process { } }
function Write-StdErr ([string]$message) { $global:MockLog.Add("stderr ${message}") }
function Write-FlowError ($message) { $global:MockLog.Add("error ${message}") }
function Fail ([string]$message, [int]$exitCode, $result) {
    $global:MockLog.Add("fail ${exitCode} ${message}")
    if ($null -ne $result) { $result | ConvertTo-Json -Depth 12 }
    throw 'script-exit'
}
function Read-CrashControlData ([string]$path) {
    $global:MockLog.Add("Read-CrashControlData ${path}")
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
function Get-RegValueKind ([string]$path, [string]$name) {
    if ($global:FakeReg.ContainsKey($path) -and $global:FakeReg[$path].ContainsKey($name)) { $global:FakeKinds[$name] }
}
function Test-Path ([string]$Path) { $global:FakeReg.ContainsKey($Path) }
function Get-CimInstance ([string]$ClassName, $ErrorAction) {
    $memory = @($global:MockState['memory'])[0]
    if ($memory -eq 'error') { throw 'simulated CIM failure' }
    [pscustomobject]@{ TotalPhysicalMemory = $(if ($memory) { [int64]$memory } else { [int64]17179869184 }) }
}
function Invoke-NotMyFaultStaging ([string]$source) {
    $global:MockLog.Add("staging ${source}")
    if ($global:MockState['stagingFails'] -contains 'true') { return [ordered]@{ status = 'failed'; problem = 'signature status NotSigned, signer none' } }
    [ordered]@{ status = 'staged'; source = $source; resolvedSource = $source; sha256 = 'B' * 64 }
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
