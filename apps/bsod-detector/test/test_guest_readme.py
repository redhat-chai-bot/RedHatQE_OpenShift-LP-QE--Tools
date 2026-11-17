#!/usr/bin/env python3
"""Offline consistency checks for src/scripts/guest/README.md.

The README documents the golden-image scripts as changed by their companion pull requests.
Checks against the script sources run once those changes are present; until then they are
skipped, which is why this README must be merged after them. Nothing is executed.
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
        self.assertIn('src/scripts/bsod-pipeline/bsod-runner.sh', self.readme)
        self.assertIn('no longer required in this disposable-VM workflow', self.readme)
        for path in CLEANUP_PATHS:
            self.assertIn(f'`{path}`', self.readme)
        self.assertIn('Win32_ComputerSystem.AutomaticManagedPagefile', self.readme)
        self.assertIn('pageFile.requiredMB', self.readme)
        self.assertIn('initial and maximum sizes of at least `requiredMB`', self.readme)
        self.assertNotIn('If the recommendation includes `DedicatedDumpFile`', self.readme)

    def test_readme_matches_scripts_when_companion_changes_are_present(self):
        pre = PRE_SCRIPT.read_text(encoding='utf-8')
        post = POST_SCRIPT.read_text(encoding='utf-8')
        if 'function Remove-SetupCacheFile' not in post or 'function Get-PagefileSizeMB' not in pre:
            self.skipTest('golden-image script changes are not present yet; this README must merge after them')
        for script in (pre, post):
            self.assertIn('[math]::Round(($MemoryBytes + 257MB) / 1MB, 0)', script)
            self.assertNotRegex(script, r'(?i)bcdedit|reagentc')
            self.assertIn('device_add pvpanic,id=pvpanic0', script)
        self.assertIn("Remove-SetupCacheFile @('{}', '{}')".format(*CLEANUP_PATHS), post)
        self.assertIn('$ExitCode -in 0, 1641, 3010', pre)
        self.assertIn('Exit codes 0, 1641 and 3010 are reported as success', self.readme)
        if 'function Set-FixedPagefile' in pre:
            self.assertIn('AutomaticManagedPagefile = $false', pre)
            self.assertNotIn('-Name AutomaticManagedPagefile -Value 0', pre)

    def test_readme_matches_configure_dumps_when_its_changes_are_present(self):
        script = CONFIGURE_SCRIPT.read_text(encoding='utf-8')
        if 'function Test-PageFileAdequate' not in script:
            self.skipTest('configure-dumps.ps1 changes are not present yet; this README must merge after them')
        data = json.loads(DATA_FILE.read_text(encoding='utf-8'))
        self.assertNotIn('DedicatedDumpFile', data['recommended']['values'])
        self.assertIn('requiredMB = $requiredMB', script)
        self.assertIn('[Console]::Error.WriteLine', script)
        self.assertIn('no longer recommends it', self.readme)


if __name__ == '__main__':
    unittest.main()
