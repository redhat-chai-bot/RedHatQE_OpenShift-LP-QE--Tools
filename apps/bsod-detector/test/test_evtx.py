#!/usr/bin/env python3
import builtins
import importlib.util
import json
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock


HOST = Path(__file__).resolve().parents[1] / "src" / "scripts" / "host"
APP = Path(__file__).resolve().parents[1]


class EvtxFailureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("extract_evtx", HOST / "extract-evtx.py")
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def test_missing_python_evtx_is_failure(self):
        original_import = builtins.__import__

        def missing(name, *args, **kwargs):
            if name == "Evtx.Evtx":
                raise ImportError("fixture missing")
            return original_import(name, *args, **kwargs)

        with mock.patch("builtins.__import__", side_effect=missing):
            with self.assertRaisesRegex(self.module.EvtxParseError, "not installed"):
                self.module.extract_events_from_evtx("fixture.evtx", [])

    def test_corrupt_evtx_is_failure(self):
        package = types.ModuleType("Evtx")
        implementation = types.ModuleType("Evtx.Evtx")

        class BrokenEvtx:
            def __init__(self, _path):
                pass

            def __enter__(self):
                raise ValueError("corrupt fixture")

            def __exit__(self, *_args):
                return False

        implementation.Evtx = BrokenEvtx
        package.Evtx = implementation
        with tempfile.NamedTemporaryFile() as fixture, mock.patch.dict(
            sys.modules, {"Evtx": package, "Evtx.Evtx": implementation}
        ):
            with self.assertRaisesRegex(self.module.EvtxParseError, "cannot parse"):
                self.module.extract_events_from_evtx(fixture.name, [])

    def test_cli_loads_active_parser_data_before_rejecting_missing_input(self):
        result = subprocess.run(
            [
                sys.executable,
                str(HOST / "extract-evtx.py"),
                "--data-dir",
                str(APP / "src" / "data"),
                "/nonexistent/fixture.evtx",
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
        self.assertNotEqual(result.returncode, 0)
        output = json.loads(result.stdout)
        self.assertIn("file not found", output["error"])
        self.assertNotIn("cannot load parser data", output["error"])


if __name__ == "__main__":
    unittest.main()
