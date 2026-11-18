#!/usr/bin/env python3
"""Offline consistency checks for src/scripts/guest/README.md.

The README documents the golden-image scripts as changed by their companion pull requests.
The checks against the script sources fail (they are never skipped) when those changes are
missing, so a validation checkout without them cannot pass. Nothing is executed.
"""

import json
import re
import unittest
from pathlib import Path


APP_DIR = Path(__file__).resolve().parents[1]
GUEST_DIR = APP_DIR / 'src' / 'scripts' / 'guest'
README = GUEST_DIR / 'README.md'
PRE_SCRIPT = GUEST_DIR / 'golden-image-pre-reboot.ps1'
POST_SCRIPT = GUEST_DIR / 'golden-image-post-reboot.ps1'
VALIDATOR_SCRIPT = GUEST_DIR / 'validate-crash-settings.ps1'
DATA_FILE = APP_DIR / 'src' / 'data' / 'crash-control.json'
CLEANUP_PATHS = ('C:\\Temp\\virtio-win.iso', 'C:\\Temp\\virtio-win.iso.download')
ISO_RECORD_PATH = 'C:\\ProgramData\\bsod-detector\\virtio-win-iso.json'
PAGEFILE_FORMULA = 'Round((RAM bytes + 257MB) / 1MB, 0)'


class GuestReadmeTests(unittest.TestCase):
    def setUp(self):
        self.readme = README.read_text(encoding='utf-8')

    def test_no_generation_artifacts(self):
        for phrase in ('supplied script versions', 'script attachments'):
            self.assertNotIn(phrase, self.readme)

    def test_relative_links_and_documented_scripts_exist(self):
        for target in re.findall(r'\]\((?!https?://)([^)#]+)\)', self.readme):
            self.assertTrue((GUEST_DIR / target).resolve().exists(), target)
        for script in set(re.findall(r'`([\w-]+\.ps1)`', self.readme)):
            self.assertTrue((GUEST_DIR / script).is_file(), script)

    def test_documents_current_golden_image_decisions(self):
        self.assertIn(PAGEFILE_FORMULA, self.readme)
        self.assertIn('virtio-win.iso.download', self.readme)
        self.assertIn('device_add pvpanic,id=pvpanic0', self.readme)
        self.assertIn('best effort and non-fatal', self.readme)
        self.assertIn('src/scripts/crash-injector/trigger-bsod-intentional.sh', self.readme)
        self.assertIn('intentionally leave the Windows defaults, because the intended test flow does not restart a VM after a simulated crash', self.readme)
        self.assertIn('`src/scripts/host/watch-crash.sh` still starts the VM again after extracting evidence unless it runs with `--no-restart`', self.readme)
        self.assertIn('### Latest virtio-win ISO and its record', self.readme)
        self.assertIn('it is not a publisher attestation', self.readme)
        self.assertIn(f'`{ISO_RECORD_PATH}`', self.readme)
        self.assertIn('must not have more RAM than the VM that prepared it', self.readme)
        self.assertIn('C:\\Windows\\System32\\Sysprep\\sysprep.exe /generalize /oobe /shutdown /quiet', self.readme)
        for path in CLEANUP_PATHS:
            self.assertIn(f'`{path}`', self.readme)
        self.assertIn('Win32_ComputerSystem.AutomaticManagedPagefile', self.readme)
        self.assertIn('pageFile.requiredMB', self.readme)
        self.assertIn('initial and maximum sizes of at least `requiredMB`', self.readme)
        self.assertIn('| `-StageNotMyFault` |', self.readme)
        self.assertIn('normal validation never downloads or stages anything', self.readme)
        self.assertIn('Never runs NotMyFault, crashes or reboots the guest', self.readme)
        self.assertIn('they do not constitute a successful Windows execution or crash-dump test', self.readme)

    def test_no_stale_script_dump_or_pin_claims(self):
        # The configuration script, minidump support and the pinned ISO are gone from the frozen-VM flow.
        self.assertNotRegex(self.readme, r'(?i)configure-dumps|minidump|smalldump|small memory dump|-VerifyOnly|rebootRequired')
        self.assertNotRegex(self.readme, r'(?i)\bpinned\b|archive-virtio/|virtio-win-[0-9]+\.[0-9]+')
        self.assertIsNone(re.search(r'\b[0-9A-Fa-f]{64}\b', self.readme))

    def test_no_unsupported_caller_or_consumer_claims(self):
        # Claims that no code in this repository supports: an unconditional preflight forwarding
        # claim, a pending runner update, and a consumer that always discards its VMs.
        self.assertNotRegex(self.readme, r'preflight-rhov\.sh` passes `-StageNotMyFault`(?! only with `--require-trigger`)')
        self.assertNotIn('does not pass it yet, and its update is pending', self.readme)
        self.assertNotIn('src/scripts/bsod-pipeline/bsod-runner.sh', self.readme)
        self.assertNotIn('each pytest run tears down its VM', self.readme)
        self.assertNotIn('always equal the configured size', self.readme)

    def test_readme_matches_the_golden_image_scripts(self):
        pre = PRE_SCRIPT.read_text(encoding='utf-8')
        post = POST_SCRIPT.read_text(encoding='utf-8')
        self.assertIn('function Remove-SetupCacheFile', post, 'include the golden-image-post-reboot.ps1 change')
        self.assertIn('function Get-PagefileSizeMB', pre, 'include the golden-image-pre-reboot.ps1 change')
        for script in (pre, post):
            self.assertIn('[math]::Round(($MemoryBytes + 257MB) / 1MB, 0)', script)
            self.assertNotRegex(script, r'(?i)bcdedit|reagentc')
            self.assertIn('device_add pvpanic,id=pvpanic0', script)
        self.assertIn("Remove-SetupCacheFile @('{}', '{}')".format(*CLEANUP_PATHS), post)
        self.assertIn('$ExitCode -in 0, 1641, 3010', pre)
        self.assertIn('Exit codes 0, 1641 and 3010 are reported as success', self.readme)
        self.assertIn('AutomaticManagedPagefile = $false', pre)
        self.assertNotIn('-Name AutomaticManagedPagefile -Value 0', pre)
        # The README documents the alias and the record path the scripts use; neither script pins a digest.
        isoAliasURL = re.search(r"(?m)^\$isoAliasURL\s*=\s*'([^']+)'", pre).group(1)
        self.assertIn(f'`{isoAliasURL}`', self.readme)
        for script in (pre, post):
            self.assertIn(f"$isoRecordPath = '{ISO_RECORD_PATH}'", script)
            self.assertIsNone(re.search(r'\b[0-9A-Fa-f]{64}\b', script))
        self.assertIn('**virtio-win ISO record:**', self.readme)
        # Memory is validated before any change; an old dump file only warns before, and refuses sealing after, the reboot.
        self.assertLess(pre.index('if (-not ($ramBytes -gt 0)) {'), pre.index("New-Item -ItemType Directory -Force -Path 'C:\\Temp'"))
        self.assertIn("reads the guest's physical memory size first", self.readme)
        self.assertIn("Write-Error 'FAIL: C:\\DedicatedDump.sys from an older preparation still exists", post)
        self.assertIn('**Old dedicated dump file:**', self.readme)
        self.assertIn("$ErrorActionPreference = 'Continue'", post)
        self.assertIn('C:\\Windows\\System32\\Sysprep\\sysprep.exe /generalize /oobe /shutdown /quiet', post)

    def test_readme_matches_validate_crash_settings(self):
        script = VALIDATOR_SCRIPT.read_text(encoding='utf-8')
        self.assertIn('function Test-PageFileAdequate', script, 'include the validate-crash-settings.ps1 change')
        data = json.loads(DATA_FILE.read_text(encoding='utf-8'))
        self.assertNotIn('DedicatedDumpFile', data['recommended']['values'])
        self.assertIn('DedicatedDumpFile', data['recommended']['absentValues'])
        self.assertIn('`recommended.absentValues`', self.readme)
        self.assertIn('requiredMB = $requiredMB', script)
        self.assertIn('[Console]::Error.WriteLine', script)
        # Read-only: no registry, CIM or file-system write outside the NotMyFault staging directory.
        self.assertNotRegex(script, r'(?i)Set-ItemProperty|New-ItemProperty|Remove-ItemProperty|Set-CimInstance|Restart-Computer')
        self.assertIn('(read-only)', self.readme)
        self.assertIn('[switch]$StageNotMyFault', script)
        self.assertIn("$notMyFault = [ordered]@{ status = 'not requested' }", script)
        self.assertIn('`{ "status": "not requested" }` without `-StageNotMyFault`', self.readme)
        # DedicatedDumpFile is a required absence; exit codes 2 and 4 and the signature check are documented as implemented.
        self.assertIn('always `DedicatedDumpFile`, as `must be absent`', self.readme)
        self.assertIn("Fail \"Unknown dump type '${type}'. Valid: $($typeNames -join ', ').\" 2", script)
        self.assertIn('Fail "NotMyFault could not be staged: $($notMyFault.problem)" 4', script)
        self.assertIn('exits with code 2', self.readme)
        self.assertIn('exits with code 4', self.readme)
        # A staging failure keeps the settings result (mismatches, page file) next to the error.
        self.assertIn('Fail "NotMyFault could not be staged: $($notMyFault.problem)" 4 $result', script)
        self.assertIn('still emits the full result', self.readme)
        self.assertIn('Get-AuthenticodeSignature -LiteralPath $Path', script)
        self.assertIn("-cnotcontains 'O=Microsoft Corporation'", script)
        self.assertIn('exactly `Microsoft Corporation`', self.readme)
        self.assertIn('`artifacts.notMyFault`', self.readme)


if __name__ == '__main__':
    unittest.main()
