#!/usr/bin/env python3
'''Behavioral regression tests: the virtio-win ISO workspace of golden-image-pre-reboot.ps1.

The real script runs under PowerShell 7 (``pwsh``) with ``TEMP`` pointing at a scratch directory
that stands in for the administrator's TEMP directory. Only three of its functions are replaced,
found by name in the PowerShell syntax tree: ``Get-HTTPSresponseHead`` and ``Save-HTTPSdownload``
(network; the mock download writes a small placeholder file) and ``Remove-LegacyDedicatedDump``
(it would look at ``C:\\DedicatedDump.sys``). Every command that could change a machine is a
recording mock: CIM, disk image, installer, ``pnputil``, service, registry, ``Write-Host``,
``Write-Error`` and ``Restart-Computer``. Before the run, every command the script calls is
checked by name against those mocks, the script's own functions and the filesystem and pipeline
cmdlets its ISO steps use; any other command stops the test instead of running for real. The real
filesystem cmdlets create and remove the ISO directory inside the scratch TEMP, and a scratch
PowerShell drive stands in for the mounted ISO. No real ISO, download, installer, registry write,
reboot or cluster is involved.

Asserted behavior:

* a successful run puts its ISO into a new directory under TEMP (a different one on every run),
  unmounts and removes the ISO and that directory before the guest agent check, the registry
  writes and the reboot, and leaves everything that existed in TEMP before in place;
* a TEMP that is not an existing directory, or a run directory that already exists, stops the
  script before the download, with nothing created or removed;
* a failed download, mount or installer start, or a failed unmount or removal, stops the script
  with exit code 1 before the guest agent check, any registry write and the reboot; what the run
  created is removed when possible, and nothing else is removed;
* an installer failure together with a cleanup failure reports both.

Limits: PowerShell 7 on the test host is not Windows PowerShell 5.1 on a Windows guest, and the
Storage, CIM, installer, service and registry commands are mocks, so these tests do not show that
the script works on Windows. The command check covers command names, not their arguments or .NET
members the script may call directly. Without ``pwsh`` the tests are skipped, or fail when BSOD_DET__TEST__REQUIRE_PWSH=1.
'''

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


scriptPath = Path(__file__).resolve().parents[1] / 'src' / 'scripts' / 'guest' / 'golden-image-pre-reboot.ps1'
requirePwshVar = 'BSOD_DET__TEST__REQUIRE_PWSH'
runDirPattern = r'^bsod-virtio-win-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
fixedGuid = '0f8fad5b-d9cb-469f-a165-70867728950e'
# Files of the scratch drive that stands in for the mounted ISO.
isoFiles = ('guest-agent/qemu-ga-x86_64.msi', 'viostor/w11/amd64/viostor.inf', 'vioscsi/w11/amd64/vioscsi.inf')
# Mocked calls of the steps after the ISO cleanup: guest agent check, registry writes, page file and reboot.
laterStepCalls = ('Get-Service', 'Set-Service', 'Start-Service', 'Set-ItemProperty', 'Remove-ItemProperty',
                  'Set-CimInstance', 'Remove-LegacyDedicatedDump', 'Restart-Computer')
installerError = 'This command cannot be run because the file msiexec.exe was not found.'

# Runs the script with the mocks below and writes its exit code and the recorded calls as JSON.
wrapperScript = r'''
param([string]$targetPath, [string]$runPath, [string]$statePath, [string]$logPath, [string]$isoRoot)
$mockState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
$mockLog = [System.Collections.Generic.List[object]]::new()
$mockDisk = @{ attached = $false; isoPath = '' }
function Add-MockCall ([string]$name, [string]$detail) { $mockLog.Add([ordered]@{ name = $name; detail = $detail }) }
function Get-TempListing { @(Get-ChildItem -LiteralPath $env:TEMP -Force -Name) -join '|' }

# The script without the replaced functions; everything else runs as written.
$replaced = @('Get-HTTPSresponseHead', 'Save-HTTPSdownload', 'Remove-LegacyDedicatedDump')
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($targetPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw "cannot parse ${targetPath}: $($parseErrors -join '; ')" }
$definitions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $replaced }, $false))
if ($definitions.Count -ne $replaced.Count -or @($definitions.Name | Sort-Object -Unique).Count -ne $replaced.Count) {
    throw "expected exactly one top-level definition each of $($replaced -join ', ')"
}
$text = $ast.Extent.Text
foreach ($definition in ($definitions | Sort-Object { $_.Extent.StartOffset } -Descending)) {
    $text = $text.Remove($definition.Extent.StartOffset, $definition.Extent.EndOffset - $definition.Extent.StartOffset)
}
[System.IO.File]::WriteAllText($runPath, $text)

function Get-HTTPSresponseHead ([string]$url) {
    Add-MockCall 'Get-HTTPSresponseHead' $url
    if ($url -like '*/latest-virtio/*') {
        return [pscustomobject]@{ StatusCode = 302; Location = 'http://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-9.9.9-1/virtio-win-9.9.9.iso' }
    }
    [pscustomobject]@{ StatusCode = 200; Location = $null }
}
function Save-HTTPSdownload ([string]$url, [string]$path) {
    Add-MockCall 'Save-HTTPSdownload' $path
    $mockDisk.isoPath = $path
    Set-Content -LiteralPath $path -Value 'placeholder, not an ISO' -ErrorAction Stop
    if ($mockState.downloadFails) { throw 'The operation has timed out' }
}
function Remove-LegacyDedicatedDump ([string]$path, [string]$configuredTarget) { Add-MockCall 'Remove-LegacyDedicatedDump' $path; 'absent' }
function Get-CimInstance ([string]$ClassName, $ErrorAction) {
    Add-MockCall 'Get-CimInstance' $ClassName
    [pscustomobject]@{ TotalPhysicalMemory = 17179869184; AutomaticManagedPagefile = $true }
}
function Set-CimInstance ($InputObject, [hashtable]$Property, $ErrorAction) { Add-MockCall 'Set-CimInstance' ($Property.Keys -join ',') }
function Mount-DiskImage ([string]$ImagePath, [switch]$PassThru, $ErrorAction) {
    Add-MockCall 'Mount-DiskImage' $ImagePath
    if ($mockState.mountFails) { throw 'The file or directory is corrupted and unreadable.' }
    $mockDisk.attached = $true
    [pscustomobject]@{ ImagePath = $ImagePath }
}
function Get-Volume {
    [CmdletBinding()] param([Parameter(ValueFromPipeline)]$DiskImage)
    process { [pscustomobject]@{ DriveLetter = 'BSODISO' } }
}
function Get-DiskImage ([string]$ImagePath, $ErrorAction) { Add-MockCall 'Get-DiskImage' $ImagePath; [pscustomobject]@{ Attached = $mockDisk.attached } }
function Dismount-DiskImage ([string]$ImagePath, $ErrorAction) {
    Add-MockCall 'Dismount-DiskImage' $ImagePath
    if ($mockState.dismountFails) { throw 'The disk image is in use.' }
    $mockDisk.attached = $false
}
function Start-Process ([string]$FilePath, [string]$ArgumentList, [switch]$Wait, [switch]$PassThru) {
    Add-MockCall 'Start-Process' "${FilePath} ${ArgumentList}"
    if ($mockState.installLeavesFile) { Set-Content -LiteralPath (Join-Path (Split-Path -Parent $mockDisk.isoPath) 'installer.log') -Value 'log' }
    if ($mockState.installFails) { throw $mockState.installError }
    [pscustomobject]@{ ExitCode = 0 }
}
function pnputil { Add-MockCall 'pnputil' ($args -join ' '); $global:LASTEXITCODE = 0 }
# The guest agent check and the reboot record what TEMP holds at that moment.
function Get-Service ([string]$Name, $ErrorAction) { Add-MockCall 'Get-Service' (Get-TempListing); [pscustomobject]@{ Status = 'Running' } }
function Set-Service ([string]$Name, [string]$StartupType) { Add-MockCall 'Set-Service' "${Name} ${StartupType}" }
function Start-Service ([string]$Name, $ErrorAction) { Add-MockCall 'Start-Service' $Name }
function Start-Sleep ($Seconds) { Add-MockCall 'Start-Sleep' "${Seconds}" }
function Set-ItemProperty ([string]$Path, [string]$Name, $Value, [string]$Type, $ErrorAction) { Add-MockCall 'Set-ItemProperty' "${Name}=${Value}" }
function Get-ItemProperty ([string]$Path, [string]$Name, $ErrorAction) { Add-MockCall 'Get-ItemProperty' $Name }
function Remove-ItemProperty ([string]$Path, [string]$Name, $ErrorAction) { Add-MockCall 'Remove-ItemProperty' $Name }
function Write-Host ($Object) { Add-MockCall 'Write-Host' "${Object}" }
function Write-Error ($Message) { Add-MockCall 'Write-Error' "${Message}" }
function Restart-Computer ([switch]$Force) { Add-MockCall 'Restart-Computer' (Get-TempListing) }
if ($mockState.fixedGuid) { function New-Guid { [pscustomobject]@{ Guid = $mockState.fixedGuid } } }

# Every command the script calls must be one of the mocks above, one of its own functions or one of
# the filesystem and pipeline cmdlets its ISO steps use; any other command stops the test here
# instead of running for real.
$mockNames = @(Get-ChildItem -Path function: | Where-Object { $_.ScriptBlock.File -eq $PSCommandPath }).Name
$safeCommands = @('Get-ChildItem', 'Get-Item', 'Join-Path', 'New-Guid', 'New-Item', 'Out-Null', 'Remove-Item', 'Select-Object', 'Test-Path', 'Where-Object')
$runAst = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$parseErrors)
$scriptFunctions = @($runAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true).Name)
$unexpected = @($runAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
    ForEach-Object { if ($_.GetCommandName()) { $_.GetCommandName() } else { "dynamic call '$($_.Extent.Text)'" } } |
    Where-Object { $_ -notin $mockNames -and $_ -notin $scriptFunctions -and $_ -notin $safeCommands } | Sort-Object -Unique)
if ($unexpected) { throw "commands without a mock in ${targetPath}: $($unexpected -join ', ')" }
New-PSDrive -Name BSODISO -PSProvider FileSystem -Root $isoRoot | Out-Null

$global:LASTEXITCODE = 0
& $runPath
$exitCode = $LASTEXITCODE
[System.IO.File]::WriteAllText($logPath, (ConvertTo-Json -Depth 4 -InputObject @{ exitCode = $exitCode; calls = $mockLog }))
'''


class GoldenImageISOworkspaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.pwsh = shutil.which('pwsh')
        if not cls.pwsh:
            if os.environ.get(requirePwshVar) == '1':
                raise AssertionError(f'pwsh is not installed, but {requirePwshVar}=1 requires these tests')
            raise unittest.SkipTest('pwsh (PowerShell 7) is not installed')

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory(prefix='iso workspace ')
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        # TEMP already holds an unrelated file and an unrelated directory with a similar name.
        self.tempDir = self.root / 'TEMP'
        (self.tempDir / 'bsod-virtio-win-unrelated').mkdir(parents=True)
        (self.tempDir / 'bsod-virtio-win-unrelated' / 'keep.txt').write_text('keep', encoding='utf-8')
        (self.tempDir / 'unrelated.txt').write_text('keep', encoding='utf-8')
        self.isoRoot = self.root / 'mounted-iso'
        for relPath in isoFiles:
            (self.isoRoot / relPath).parent.mkdir(parents=True, exist_ok=True)
            (self.isoRoot / relPath).write_text('placeholder', encoding='utf-8')
        (self.root / 'cwd').mkdir()
        self.wrapperPath = self.root / 'run-with-mocks.ps1'
        self.wrapperPath.write_text(wrapperScript, encoding='utf-8')

    @staticmethod
    def Tree(path: Path) -> list[str]:
        return sorted(str(item.relative_to(path)) for item in path.rglob('*'))

    def RunScript(self, tempDir: Path | None = None, **state: object) -> dict:
        statePath = self.root / 'state.json'
        logPath = self.root / 'calls.json'
        statePath.write_text(json.dumps(dict(state, installError=installerError)), encoding='utf-8')
        logPath.unlink(missing_ok=True)
        env = dict(os.environ, TEMP=str(tempDir or self.tempDir))
        result = subprocess.run([self.pwsh, '-NoProfile', '-NonInteractive', '-File', str(self.wrapperPath), str(scriptPath),
                                 str(self.root / 'script-under-test.ps1'), str(statePath), str(logPath), str(self.isoRoot)],
                                cwd=self.root / 'cwd', env=env, capture_output=True, encoding='utf-8', errors='replace',
                                timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(logPath.exists(), result.stdout + result.stderr)
        run = json.loads(logPath.read_text(encoding='utf-8'))
        return {'exitCode': run['exitCode'], 'calls': [(call['name'], call['detail']) for call in run['calls']]}

    @staticmethod
    def Names(run: dict) -> list[str]:
        return [name for name, _ in run['calls']]

    @staticmethod
    def Details(run: dict, callName: str) -> list[str]:
        return [detail for name, detail in run['calls'] if name == callName]

    def IsoPath(self, run: dict) -> Path:
        isoPath, = self.Details(run, 'Save-HTTPSdownload')
        return Path(isoPath)

    def AssertStoppedBeforeLaterSteps(self, run: dict) -> None:
        self.assertEqual(run['exitCode'], 1, run['calls'])
        self.assertEqual([name for name in self.Names(run) if name in laterStepCalls], [], run['calls'])

    def AssertOnlyRunDirectoryLeft(self, tempBefore: list[str], runDir: Path) -> None:
        # Everything that was in TEMP before is still there; anything new is inside this run's directory.
        tempAfter = self.Tree(self.tempDir)
        self.assertLessEqual(set(tempBefore), set(tempAfter))
        self.assertEqual([item for item in tempAfter if item not in tempBefore and Path(item).parts[0] != runDir.name], [])

    def test_success_removes_its_own_iso_directory_before_the_later_steps(self) -> None:
        tempBefore = self.Tree(self.tempDir)
        run = self.RunScript()
        self.assertEqual(run['exitCode'], 0, run['calls'])
        self.assertEqual(self.Details(run, 'Write-Error'), [])
        self.assertEqual(self.Names(run)[-1], 'Restart-Computer')
        isoPath = self.IsoPath(run)
        self.assertEqual(isoPath.parent.parent, self.tempDir)
        self.assertRegex(isoPath.parent.name, runDirPattern)
        self.assertNotIn(isoPath.parent.name, tempBefore)
        self.assertEqual(self.Details(run, 'Mount-DiskImage'), [str(isoPath)])
        self.assertEqual(self.Details(run, 'Dismount-DiskImage'), [str(isoPath)])
        self.assertEqual(len(self.Details(run, 'pnputil')), 2, run['calls'])
        names = self.Names(run)
        order = [names.index(name) for name in ('Save-HTTPSdownload', 'Mount-DiskImage', 'Start-Process', 'pnputil',
                                                 'Dismount-DiskImage', 'Get-Service', 'Set-ItemProperty', 'Set-CimInstance',
                                                 'Restart-Computer')]
        self.assertEqual(order, sorted(order), run['calls'])
        # At the guest agent check (before any registry write) and at the reboot, TEMP holds only what was there before.
        topLevelBefore = sorted(item.name for item in self.tempDir.iterdir())
        for callName in ('Get-Service', 'Restart-Computer'):
            listing, = self.Details(run, callName)
            self.assertEqual(sorted(listing.split('|')), topLevelBefore, callName)
        self.assertEqual(self.Tree(self.tempDir), tempBefore)

    def test_every_run_uses_a_new_directory(self) -> None:
        tempBefore = self.Tree(self.tempDir)
        first, second = self.RunScript(), self.RunScript()
        self.assertEqual((first['exitCode'], second['exitCode']), (0, 0))
        self.assertNotEqual(self.IsoPath(first).parent, self.IsoPath(second).parent)
        self.assertEqual(self.Tree(self.tempDir), tempBefore)

    def test_setup_failure_stops_before_the_download_and_changes_nothing(self) -> None:
        missingTemp = self.root / 'missing'
        fileTemp = self.tempDir / 'unrelated.txt'
        existingRunDir = self.tempDir / f'bsod-virtio-win-{fixedGuid}'
        existingRunDir.mkdir()
        (existingRunDir / 'sentinel.txt').write_text('keep', encoding='utf-8')
        # label: (TEMP, mock state, expected failure or None for the platform's "already exists" message)
        cases = {
            'TEMP is missing': (missingTemp, {}, f"FAIL: TEMP ('{missingTemp}') is not an existing directory"),
            'TEMP is a file': (fileTemp, {}, f"FAIL: TEMP ('{fileTemp}') is not an existing directory"),
            'run directory already exists': (self.tempDir, {'fixedGuid': fixedGuid}, None),
        }
        for label, (tempDir, state, message) in cases.items():
            with self.subTest(label):
                tempBefore = self.Tree(self.tempDir)
                run = self.RunScript(tempDir, **state)
                self.AssertStoppedBeforeLaterSteps(run)
                failures = self.Details(run, 'Write-Error')
                self.assertEqual(len(failures), 1, run['calls'])
                if message:
                    self.assertEqual(failures[0], message)
                else:
                    self.assertTrue(failures[0].startswith('FAIL: ') and str(existingRunDir) in failures[0], failures)
                self.assertEqual(self.Details(run, 'Save-HTTPSdownload'), [])
                self.assertEqual(self.Tree(self.tempDir), tempBefore)

    def test_download_mount_or_installer_failure_removes_the_iso_and_stops(self) -> None:
        # label: (mock state, expected failure prefix, whether the ISO was mounted and must be unmounted)
        cases = {
            'download fails': ({'downloadFails': True}, 'FAIL: the latest virtio-win ISO could not be downloaded: The operation has timed out', False),
            'mount fails': ({'mountFails': True}, 'FAIL: cannot mount ', False),
            'installer fails': ({'installFails': True}, f'FAIL: {installerError}', True),
        }
        for label, (state, message, wasMounted) in cases.items():
            with self.subTest(label):
                tempBefore = self.Tree(self.tempDir)
                run = self.RunScript(**state)
                self.AssertStoppedBeforeLaterSteps(run)
                failures = self.Details(run, 'Write-Error')
                self.assertEqual(len(failures), 1, run['calls'])
                self.assertTrue(failures[0].startswith(message), failures)
                self.assertEqual(self.Details(run, 'Dismount-DiskImage'), [str(self.IsoPath(run))] if wasMounted else [])
                # The partial or mounted ISO and the run's directory are gone; nothing else changed.
                self.assertEqual(self.Tree(self.tempDir), tempBefore)

    def test_cleanup_failure_stops_before_the_registry_and_reboot(self) -> None:
        with self.subTest('unmount fails'):
            tempBefore = self.Tree(self.tempDir)
            run = self.RunScript(dismountFails=True)
            self.AssertStoppedBeforeLaterSteps(run)
            isoPath = self.IsoPath(run)
            self.assertEqual(self.Details(run, 'Write-Error'),
                             [f'FAIL: cannot unmount and remove the virtio-win ISO in {isoPath.parent}: The disk image is in use.'])
            self.assertTrue(isoPath.exists())
            self.AssertOnlyRunDirectoryLeft(tempBefore, isoPath.parent)
            shutil.rmtree(isoPath.parent)
        with self.subTest('run directory is not empty'):
            tempBefore = self.Tree(self.tempDir)
            run = self.RunScript(installLeavesFile=True)
            self.AssertStoppedBeforeLaterSteps(run)
            isoPath = self.IsoPath(run)
            self.assertEqual(self.Details(run, 'Write-Error'), [f'FAIL: {isoPath.parent} is not empty and was left in place'])
            # Only the ISO is removed: the file this run did not create stays with its directory.
            self.assertFalse(isoPath.exists())
            self.assertEqual(self.Tree(isoPath.parent), ['installer.log'])
            self.AssertOnlyRunDirectoryLeft(tempBefore, isoPath.parent)

    def test_installer_and_cleanup_failures_are_both_reported(self) -> None:
        run = self.RunScript(installFails=True, dismountFails=True)
        self.AssertStoppedBeforeLaterSteps(run)
        isoPath = self.IsoPath(run)
        self.assertEqual(self.Details(run, 'Write-Error'), [
            f'FAIL: {installerError}',
            f'FAIL: cannot unmount and remove the virtio-win ISO in {isoPath.parent}: The disk image is in use.',
        ])


if __name__ == '__main__':
    unittest.main()
