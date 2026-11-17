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
CONFIGURE_SCRIPT = GUEST_DIR / 'configure-dumps.ps1'
DATA_FILE = APP_DIR / 'src' / 'data' / 'crash-control.json'
CLEANUP_PATHS = ('C:\\Temp\\virtio-win.iso', 'C:\\Temp\\virtio-win.iso.download')
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
        self.assertIn('### Pinned virtio-win ISO', self.readme)
        self.assertIn('must not have more RAM than the VM that prepared it', self.readme)
        self.assertIn('C:\\Windows\\System32\\Sysprep\\sysprep.exe /generalize /oobe /shutdown /quiet', self.readme)
        for path in CLEANUP_PATHS:
            self.assertIn(f'`{path}`', self.readme)
        self.assertIn('Win32_ComputerSystem.AutomaticManagedPagefile', self.readme)
        self.assertIn('pageFile.requiredMB', self.readme)
        self.assertIn('initial and maximum sizes of at least `requiredMB`', self.readme)
        self.assertIn('| `-StageNotMyFault` |', self.readme)
        self.assertIn('watch runs, default apply and `-VerifyOnly` never download', self.readme)
        self.assertIn('The script stages nothing unless the caller passes `-StageNotMyFault`', self.readme)
        self.assertIn('they do not constitute a successful Windows execution or crash-dump test', self.readme)
        self.assertNotIn('If the recommendation includes `DedicatedDumpFile`', self.readme)

    def test_no_unsupported_caller_or_consumer_claims(self):
        # Claims that no code in this repository supports: an unconditional preflight forwarding
        # claim, a pending runner update, and a consumer that always discards its VMs.
        self.assertNotRegex(self.readme, r'preflight-rhov\.sh` passes `-StageNotMyFault`')
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
        # The README documents exactly the virtio-win build and digest the script pins.
        isoURL = re.search(r"(?m)^\$isoURL\s*=\s*'([^']+)'", pre).group(1)
        isoSHA256 = re.search(r"(?m)^\$isoSHA256\s*=\s*'([0-9a-f]{64})'", pre).group(1)
        self.assertIn(f'`{isoURL}`', self.readme)
        self.assertIn(f'`{isoSHA256}`', self.readme)
        # Memory is validated before any change; an old dump file only warns before, and refuses sealing after, the reboot.
        self.assertLess(pre.index('if (-not ($ramBytes -gt 0)) {'), pre.index("New-Item -ItemType Directory -Force -Path 'C:\\Temp'"))
        self.assertIn("reads the guest's physical memory size first", self.readme)
        self.assertIn("Write-Error 'FAIL: C:\\DedicatedDump.sys from an older preparation still exists", post)
        self.assertIn('**Old dedicated dump file:**', self.readme)
        self.assertIn("$ErrorActionPreference = 'Continue'", post)
        self.assertIn('C:\\Windows\\System32\\Sysprep\\sysprep.exe /generalize /oobe /shutdown /quiet', post)

    def test_readme_matches_configure_dumps(self):
        script = CONFIGURE_SCRIPT.read_text(encoding='utf-8')
        self.assertIn('function Test-PageFileAdequate', script, 'include the configure-dumps.ps1 change')
        data = json.loads(DATA_FILE.read_text(encoding='utf-8'))
        self.assertNotIn('DedicatedDumpFile', data['recommended']['values'])
        self.assertIn('requiredMB = $requiredMB', script)
        self.assertIn('[Console]::Error.WriteLine', script)
        self.assertIn('no longer recommends it', self.readme)
        self.assertIn('[switch]$StageNotMyFault', script)
        self.assertIn("if ($IsVerifyOnly) { return 'skipped: -VerifyOnly is read-only' }", script)
        # DedicatedDumpFile exclusion, exit code 4 and the signature check are documented as implemented.
        self.assertIn("if ($prop.Name -ne 'DedicatedDumpFile')", script)
        self.assertIn('It ignores a `DedicatedDumpFile` entry', self.readme)
        self.assertIn('Fail "cannot write CrashControl at ${regPath}: $($_.Exception.Message)" 4', script)
        self.assertIn('exits with code 4', self.readme)
        self.assertIn('Get-AuthenticodeSignature -LiteralPath $Path', script)
        self.assertIn("-cnotcontains 'O=Microsoft Corporation'", script)
        self.assertIn('`Get-AuthenticodeSignature` reports `Valid`', self.readme)
        self.assertIn('notmyfaultc64.exe.untrusted', self.readme)
        self.assertIn('exits with code 5', self.readme)
        # Whichever preflight version is present, the script help must not claim that it passes the switch.
        self.assertIn('Nothing passes this switch implicitly', script)


if __name__ == '__main__':
    unittest.main()
