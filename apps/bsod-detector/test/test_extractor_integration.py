#!/usr/bin/env python3
"""No-network validation that the active host callers reference the guest OS extractor."""

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]


class ExtractorIntegrationTests(unittest.TestCase):
    def test_active_callers_reference_extractor(self):
        hostDir = ROOT / 'apps/bsod-detector/src/scripts/host'
        name = 'extract--guest-os--crash-info.sh'
        extractor = hostDir / name
        self.assertTrue(extractor.is_file())
        self.assertTrue(extractor.stat().st_mode & 0o111)
        for caller in ('watch-crash.sh', 'preflight-rhov.sh'):
            self.assertIn(name, (hostDir / caller).read_text())


if __name__ == "__main__":
    unittest.main()
