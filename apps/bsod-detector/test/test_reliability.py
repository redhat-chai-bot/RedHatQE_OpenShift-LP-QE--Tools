#!/usr/bin/env python3
import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


APP = Path(__file__).resolve().parents[1]
HOST = APP / "src" / "scripts" / "host"
RELIABILITY = HOST / "reliability.py"
FIXTURES = APP / "test" / "fixtures"


def run_helper(*args, stdin=""):
    return subprocess.run(
        [sys.executable, str(RELIABILITY), *args], input=stdin, text=True,
        capture_output=True, check=False, timeout=10,
    )


def png_bytes():
    import zlib

    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)

    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">II5B", 1, 1, 8, 2, 0, 0, 0)) + chunk(b"IEND", b"")


def elf_bytes():
    data = bytearray(124)
    data[:16] = b"\x7fELF\x02\x01\x01" + bytes(9)
    struct.pack_into("<H", data, 0x10, 4)
    struct.pack_into("<Q", data, 0x20, 64)
    struct.pack_into("<H", data, 0x34, 64)
    struct.pack_into("<HH", data, 0x36, 56, 1)
    struct.pack_into("<IIQ", data, 64, 1, 0, 120)
    struct.pack_into("<Q", data, 64 + 32, 4)
    data[120:] = b"CORE"
    return bytes(data)


def pagedu64_bytes(code=1):
    data = bytearray(0x2000)
    data[:8] = b"PAGEDU64"
    struct.pack_into("<I", data, 0x38, code)
    return bytes(data)


def minidump_bytes():
    data = bytearray(44)
    data[:4] = b"MDMP"
    struct.pack_into("<II", data, 8, 1, 32)
    return bytes(data)


def evtx_bytes():
    data = bytearray(4096)
    data[:8] = b"ElfFile\x00"
    struct.pack_into("<I", data, 0x78, 4096)
    return bytes(data)


class ReliabilityTests(unittest.TestCase):
    def test_unknown_domstate_fails_at_threshold_instead_of_looping(self):
        for misses in (2, 3, 108):
            result = run_helper(
                "decision", "--misses", str(misses), "--threshold", "2",
                "--domstate", "unknown", "--vmi-phase", "Running", "--pod-present",
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(json.loads(result.stdout)["reason"], "ambiguous-domstate-unknown")

    def test_current_pvpanic_corroborates_unavailable_domstate(self):
        result = run_helper(
            "decision", "--misses", "2", "--threshold", "2", "--domstate", "unavailable",
            "--vmi-phase", "Running", "--pod-present", "--pvpanic",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["decision"], "capture")

    def test_running_domain_after_guest_agent_loss_is_captured(self):
        result = run_helper(
            "decision", "--misses", "2", "--threshold", "2", "--domstate", "running",
            "--vmi-phase", "Running", "--pod-present",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        decision = json.loads(result.stdout)
        self.assertEqual(decision["decision"], "capture")
        self.assertEqual(decision["reason"], "qga-threshold-domstate-running")

    def test_write_progress_then_quiescence_completes(self):
        sequence = (FIXTURES / "domstats-progress.json").read_text(encoding="utf-8")
        result = run_helper("progress-sequence", "--device", "vda", "--idle-samples", "3", stdin=sequence)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["reason"], "progress-then-quiescence")

    def test_no_progress_at_baseline_completes_but_missing_statistics_fail(self):
        result = run_helper(
            "progress-sequence", "--device", "vda",
            stdin=(FIXTURES / "domstats-no-progress.json").read_text(encoding="utf-8"),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["reason"], "pre-quiescent-at-baseline")

        result = run_helper(
            "progress-sequence", "--device", "vda",
            stdin=(FIXTURES / "domstats-missing.json").read_text(encoding="utf-8"),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["reason"], "statistics-unavailable")

    def test_structural_artifact_validation(self):
        samples = {"screenshot": png_bytes(), "memory": elf_bytes(), "dump": pagedu64_bytes(), "evtx": evtx_bytes()}
        with tempfile.TemporaryDirectory() as temporary:
            for kind, data in samples.items():
                path = Path(temporary) / kind
                path.write_bytes(data)
                result = run_helper("validate-artifact", "--type", kind, "--path", str(path))
                self.assertEqual(result.returncode, 0, (kind, result.stdout, result.stderr))
            mini = Path(temporary) / "mini.dmp"
            mini.write_bytes(minidump_bytes())
            self.assertEqual(run_helper("validate-artifact", "--type", "dump", "--path", str(mini)).returncode, 0)

    def test_truncated_and_malformed_artifacts_fail(self):
        malformed = {
            "screenshot": b"\x89PNG\r\n\x1a\nfixture",
            "memory": b"\x7fELFfixture",
            "dump": b"PAGEDU64" + bytes(8),
            "evtx": b"ElfFile\x00fixture",
        }
        with tempfile.TemporaryDirectory() as temporary:
            for kind, data in malformed.items():
                path = Path(temporary) / kind
                path.write_bytes(data)
                self.assertNotEqual(run_helper("validate-artifact", "--type", kind, "--path", str(path)).returncode, 0, kind)
            bad_mini = Path(temporary) / "bad-mini"
            bad_mini.write_bytes(b"MDMP" + bytes(40))
            self.assertNotEqual(run_helper("validate-artifact", "--type", "dump", "--path", str(bad_mini)).returncode, 0)
            trailing = Path(temporary) / "memory-with-status"
            trailing.write_bytes(elf_bytes() + b"Domain dumped successfully\n")
            self.assertNotEqual(run_helper("validate-artifact", "--type", "memory", "--path", str(trailing)).returncode, 0)

    def test_summary_modes_and_semantic_stage_results(self):
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary)
            (out / "MEMORY.DMP").write_bytes(pagedu64_bytes())
            (out / "vm-memory.elf").write_bytes(elf_bytes())
            (out / "System.evtx").write_bytes(evtx_bytes())
            (out / "recovery.log").write_text("fixture\n", encoding="utf-8")
            (out / "parse-dump-header.json").write_text('{"ok":true}\n', encoding="utf-8")
            (out / "events.json").write_text('{"ok":true}\n', encoding="utf-8")
            artifact_names = ("MEMORY.DMP", "vm-memory.elf", "System.evtx", "parse-dump-header.json", "events.json")

            def write_manifest():
                rows = [f"{hashlib.sha256((out / name).read_bytes()).hexdigest()}  {name}\n" for name in artifact_names]
                (out / "checksums.sha256").write_text("".join(rows), encoding="utf-8")

            write_manifest()
            errors = out / "stage-errors.jsonl"
            errors.write_text("", encoding="utf-8")
            result = run_helper(
                "write-summary", "--out", str(out), "--stage-errors", str(errors),
                "--mode", "rhov-snapshot-recovery", "--vm", "fixture-vm", "--namespace", "fixture-ns", "--run-id", "fixture-run",
            )
            self.assertEqual(result.returncode, 0, result.stdout)
            summary = json.loads((out / "evidence-summary.json").read_text(encoding="utf-8"))
            self.assertTrue(summary["ok"])
            self.assertNotIn("screenshot", summary["missingRequiredArtifactTypes"])
            (out / "events.json").write_text('{"ok":true,"extra":1}\n', encoding="utf-8")
            tampered = run_helper(
                "write-summary", "--out", str(out), "--stage-errors", str(errors),
                "--mode", "rhov-snapshot-recovery", "--vm", "fixture-vm", "--namespace", "fixture-ns",
            )
            self.assertNotEqual(tampered.returncode, 0)
            self.assertIn("manifest-hash-mismatch", tampered.stdout)
            (out / "events.json").write_text('{"ok":true}\n', encoding="utf-8")
            (out / "parse-dump-header.json").write_text('{"ok":false}\n', encoding="utf-8")
            write_manifest()
            failed = run_helper(
                "write-summary", "--out", str(out), "--stage-errors", str(errors),
                "--mode", "rhov-snapshot-recovery", "--vm", "fixture-vm", "--namespace", "fixture-ns",
            )
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("stage-result-reports-failure", failed.stdout)

    def test_summary_requires_named_parser_results_not_arbitrary_json(self):
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary)
            (out / "MEMORY.DMP").write_bytes(pagedu64_bytes())
            (out / "System.evtx").write_bytes(evtx_bytes())
            (out / "recovery.log").write_text("fixture\n", encoding="utf-8")
            (out / "recovery-metadata.json").write_text('{"ok":true}\n', encoding="utf-8")
            (out / "checksums.sha256").write_text("fixture\n", encoding="utf-8")
            errors = out / "stage-errors.jsonl"
            errors.write_text("", encoding="utf-8")
            result = run_helper(
                "write-summary", "--out", str(out), "--stage-errors", str(errors),
                "--mode", "rhov-snapshot-recovery", "--vm", "fixture", "--namespace", "fixture",
            )
            self.assertNotEqual(result.returncode, 0)
            body = json.loads(result.stdout)
            self.assertIn("json:events.json", body["missingRequiredArtifactTypes"])
            self.assertIn("json:parse-dump-header.json", body["missingRequiredArtifactTypes"])

    def test_disk_target_maps_to_exact_vmi_pvc(self):
        vmi = {
            "spec": {"volumes": [
                {"name": "rootdisk", "persistentVolumeClaim": {"claimName": "root-pvc"}},
                {"name": "tools", "containerDisk": {"image": "example.invalid/tools"}},
                {"name": "data", "dataVolume": {"name": "data-pvc"}},
            ]}
        }
        xml = """<domain><devices>
          <disk><target dev='vda'/><alias name='ua-rootdisk'/></disk>
          <disk><target dev='vdb'/><alias name='ua-tools'/></disk>
          <disk><target dev='vdc'/><alias name='ua-data'/></disk>
        </devices></domain>"""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "vmi.json").write_text(json.dumps(vmi), encoding="utf-8")
            (root / "domain.xml").write_text(xml, encoding="utf-8")
            selected = run_helper("map-disk", "--vmi-json", str(root / "vmi.json"), "--domain-xml", str(root / "domain.xml"), "--target", "vda")
            self.assertEqual(selected.returncode, 0, selected.stdout)
            self.assertEqual(json.loads(selected.stdout)["guestPvc"], "root-pvc")
            ambiguous = run_helper("map-disk", "--vmi-json", str(root / "vmi.json"), "--domain-xml", str(root / "domain.xml"))
            self.assertNotEqual(ambiguous.returncode, 0)
            wrong = run_helper("map-disk", "--vmi-json", str(root / "vmi.json"), "--domain-xml", str(root / "domain.xml"), "--target", "vdb")
            self.assertNotEqual(wrong.returncode, 0)


class GuestAgentExitTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("guest_agent", HOST / "guest-agent.py")
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def test_guest_nonzero_exit_is_propagated(self):
        with mock.patch.object(self.module, "guest_exec", return_value={"exitcode": 7, "stdout": "out", "stderr": "err"}), \
                mock.patch.object(sys, "argv", ["guest-agent.py", "exec", "fixture.exe"]), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            status = self.module.main()
        self.assertEqual(status, 7)

    def test_crash_command_immediate_exit_is_propagated(self):
        launched = {"pid": 42}
        exited = {"exited": True, "exitcode": 9, "err-data": base64.b64encode(b"failed").decode()}
        with mock.patch.object(self.module, "agent", side_effect=[launched, exited]), \
                mock.patch.object(sys, "argv", ["guest-agent.py", "exec-crash", "fixture.exe"]), \
                mock.patch.dict(os.environ, {"BSOD_TRIGGER_CONFIRM_TIMEOUT": "2"}), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            status = self.module.main()
        self.assertEqual(status, 9)

    def test_crash_command_confirmed_launch_then_disconnect_succeeds(self):
        with mock.patch.object(self.module, "agent", side_effect=[{"pid": 42}, RuntimeError("transport lost")]), \
                mock.patch.object(sys, "argv", ["guest-agent.py", "exec-crash", "fixture.exe"]), \
                mock.patch.dict(os.environ, {"BSOD_TRIGGER_CONFIRM_TIMEOUT": "2"}), \
                contextlib.redirect_stdout(io.StringIO()) as stdout:
            status = self.module.main()
        self.assertEqual(status, 0)
        self.assertTrue(json.loads(stdout.getvalue())["disconnected"])

    def test_psfile_companion_contract(self):
        companions, arguments = self.module._psfile_args(["--companion", "local.json", r"C:\Windows\Temp\local.json", "--", "-VerifyOnly"])
        self.assertEqual(companions, [("local.json", r"C:\Windows\Temp\local.json")])
        self.assertEqual(arguments, ["-VerifyOnly"])


if __name__ == "__main__":
    unittest.main()
