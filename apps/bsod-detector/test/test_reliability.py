#!/usr/bin/env python3
from __future__ import annotations

import base64
import hashlib
import json
import os
import shlex
import struct
import subprocess
import sys
import tempfile
import typing
import unittest
from pathlib import Path

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


fakeOCprogram = r'''
import json
import os
import sys

stateDir = os.environ['BSOD_DET__TEST__FAKE_OC_DIR']
ocArgs = sys.argv[1:]
with open(os.path.join(stateDir, 'calls.jsonl'), 'a') as callLog:
    callLog.write(json.dumps(ocArgs) + '\n')
with open(os.path.join(stateDir, 'scenario.json')) as scenarioFile:
    scenario = json.load(scenarioFile)


def Reply(reply):
    if 'fail' in reply:
        sys.stderr.write(reply['fail'] + '\n')
        sys.exit(1)
    sys.stdout.write(reply['stdout'] if 'stdout' in reply else json.dumps({'return': reply['return']}) + '\n')
    sys.exit(0)


if 'qemu-agent-command' in ocArgs:
    agentCommand = json.loads(ocArgs[-1])['execute']
    agentReplies = scenario['agent'].get(agentCommand)
    if agentReplies:
        countPath = os.path.join(stateDir, 'count-' + agentCommand)
        replyIndex = 0
        if os.path.exists(countPath):
            with open(countPath) as countFile:
                replyIndex = int(countFile.read())
        with open(countPath, 'w') as countFile:
            countFile.write(str(replyIndex + 1))
        Reply(agentReplies[min(replyIndex, len(agentReplies) - 1)])
elif 'get' in ocArgs and ocArgs.index('get') + 1 < len(ocArgs):
    getReply = scenario['get'].get(ocArgs[ocArgs.index('get') + 1])
    if getReply:
        Reply(getReply)
sys.stderr.write('fake oc: unscripted call: ' + ' '.join(ocArgs) + '\n')
sys.exit(97)
'''

virtualClockBootstrap = '''
import runpy
import subprocess
import sys
import threading
import time
import types

# subprocess and threading are imported first and keep the real time module (their waits
# must not advance the virtual clock); the script's own `import time` gets the virtual one.
virtualNow = [1000.0]


def VirtualSleep(seconds):
    virtualNow[0] += seconds


virtualTime = types.ModuleType('time')
vars(virtualTime).update(vars(time))
virtualTime.time = virtualTime.monotonic = lambda: virtualNow[0]
virtualTime.sleep = VirtualSleep
sys.modules['time'] = virtualTime
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name='__main__')
'''

explicitTargetEnv = {'BSOD_DET__NAMESPACE': 'ns', 'BSOD_DET__VM__NAME': 'vm', 'BSOD_DET__POD__NAME': 'pod'}
podlessTargetEnv = {'BSOD_DET__NAMESPACE': 'ns', 'BSOD_DET__VM__NAME': 'vm'}  # Resolving it needs `oc get pod`.
guestFileHandle = 7
powerShellFileArgs = ('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File')


class CLIresult(typing.NamedTuple):
    '''Outcome of one guest-agent.py run: exit status, captured streams and every `oc` argv (without "oc").'''

    status: int
    stdOut: str
    stdErr: str
    ocCalls: list[list[str]]


class GuestAgentCLItestCase(unittest.TestCase):
    '''Run the real guest-agent.py as a subprocess against a scripted fake `oc`.

    `oc` is the script's only external command, so the fake is the whole cluster boundary:
    it logs every argv and answers `get vmi`/`get pod` and each QMP command from a scenario
    (one reply list per command; the last reply repeats). PATH holds only the fake, so no
    real cluster client is reachable. The tests assert the CLI contract the shell callers
    rely on; they never import the script or patch its code, so they apply to any
    implementation.
    '''

    def setUp(self) -> None:
        tmpDir = tempfile.TemporaryDirectory()
        self.addCleanup(tmpDir.cleanup)
        self.workDir = Path(tmpDir.name)
        self.binDir = self.workDir / 'bin'
        self.binDir.mkdir()
        fakeOCpath = self.workDir / 'fake_oc.py'
        fakeOCpath.write_text(fakeOCprogram)
        ocShim = self.binDir / 'oc'
        ocShim.write_text(f'#!/bin/sh\nexec {shlex.quote(sys.executable)} -I -S {shlex.quote(str(fakeOCpath))} "$@"\n')
        ocShim.chmod(0o755)
        self.Script()

    def Script(self, get: dict[str, typing.Any] | None = None, **agentReplies: list[dict[str, typing.Any]]) -> None:
        '''Set the fake cluster replies: `get` maps 'vmi'/'pod' to a reply; keywords map QMP commands (with _ for -) to replies.

        A reply is {'return': payload}, {'stdout': rawText} or {'fail': stdErrText} (exit 1).
        '''
        scenario = {'get': get or {}, 'agent': {command.replace('_', '-'): replies for command, replies in agentReplies.items()}}
        (self.workDir / 'scenario.json').write_text(json.dumps(scenario))

    def ScriptUploads(self, get: dict[str, typing.Any] | None = None, **agentReplies: list[dict[str, typing.Any]]) -> None:
        '''Script successful guest file open/write/close replies (handle guestFileHandle); keywords add or override replies.'''
        uploadReplies: dict[str, list[dict[str, typing.Any]]] = {
            'guest_file_open': [{'return': guestFileHandle}], 'guest_file_write': [{'return': {}}],
            'guest_file_close': [{'return': {}}]}
        self.Script(get, **{**uploadReplies, **agentReplies})

    def RunCLI(self, *cliArgs: str, environ: dict[str, str] | None = None) -> CLIresult:
        '''Run guest-agent.py isolated (-I) with `environ` (no BSOD_* variables are inherited) and return its CLIresult.

        The script runs as __main__ under a bootstrap that gives it a `time` module whose sleep()
        advances time()/monotonic() instantly, so wait windows elapse deterministically without
        sleeping and no result depends on the real clock.
        '''
        runEnv = {envName: envValue for envName, envValue in os.environ.items() if not envName.startswith('BSOD_')}
        runEnv.update({'PATH': str(self.binDir), 'BSOD_DET__TEST__FAKE_OC_DIR': str(self.workDir)})
        runEnv.update(environ or {})
        callLog = self.workDir / 'calls.jsonl'
        callLog.write_text('')
        for countFile in self.workDir.glob('count-*'):
            countFile.unlink()
        completed = subprocess.run(
            [sys.executable, '-I', '-c', virtualClockBootstrap, str(HOST / 'guest-agent.py'), *cliArgs],
            env=runEnv, cwd=self.workDir, stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False, timeout=300)
        ocCalls = [json.loads(callLine) for callLine in callLog.read_text().splitlines()]
        return CLIresult(completed.returncode, completed.stdout, completed.stderr, ocCalls)

    def AgentCalls(self, cliResult: CLIresult) -> list[tuple[dict[str, typing.Any], int]]:
        '''Return (QMP command, agent timeout) per `oc exec ... virsh qemu-agent-command` call.

        Also checks that each call's oc request timeout equals its virsh agent timeout.
        '''
        agentCalls = []
        for ocCall in cliResult.ocCalls:
            if 'qemu-agent-command' in ocCall:
                agentTimeout = int(ocCall[ocCall.index('--timeout') + 1])
                self.assertEqual(ocCall[0], f'--request-timeout={agentTimeout}s', ocCall[:2])
                agentCalls.append((json.loads(ocCall[-1]), agentTimeout))
        return agentCalls

    @staticmethod
    def ExecTargets(cliResult: CLIresult) -> list[tuple[str, str, str]]:
        '''Return (namespace, Pod, libvirt domain) per `oc exec -n <ns> <pod> -- virsh ... <domain> <qmp>` call.'''
        return [(ocCall[3], ocCall[4], ocCall[-2]) for ocCall in cliResult.ocCalls if ocCall[1:3] == ['exec', '-n']]

    @staticmethod
    def Exited(exitCode: int | None, stdOut: bytes = b'', stdErr: bytes = b'') -> dict[str, typing.Any]:
        '''Build a guest-exec-status reply for an exited guest program.'''
        execStatus: dict[str, typing.Any] = {'exited': True}
        if exitCode is not None:
            execStatus['exitcode'] = exitCode
        if stdOut:
            execStatus['out-data'] = base64.b64encode(stdOut).decode()
        if stdErr:
            execStatus['err-data'] = base64.b64encode(stdErr).decode()
        return {'return': execStatus}


class GuestAgentCLItargetTests(GuestAgentCLItestCase):
    '''Target configuration and discovery as seen at the `oc` boundary.'''

    vmiQuery = ('-o', 'jsonpath={range .items[*]}{.metadata.namespace} {.metadata.name}{"\\n"}{end}')

    def testExplicitTargetIsUsedWithoutDiscovery(self) -> None:
        self.Script(guest_ping=[{'return': {}}])
        cliResult = self.RunCLI('ping', environ=explicitTargetEnv)
        self.assertEqual(cliResult[:3], (0, '{}\n', ''))
        self.assertEqual(cliResult.ocCalls, [[
            '--request-timeout=10s', 'exec', '-n', 'ns', 'pod', '--',
            'virsh', 'qemu-agent-command', '--timeout', '10', 'ns_vm', '{"execute": "guest-ping"}']])

    def testDomainSuppliesNamespaceAndVM(self) -> None:
        self.Script(guest_ping=[{'return': {}}])
        cliResult = self.RunCLI('ping', environ={'BSOD_DET__DOMAIN__NAME': 'ns-a_vm-a', 'BSOD_DET__POD__NAME': 'pod-a'})
        self.assertEqual(cliResult.status, 0)
        self.assertEqual((self.ExecTargets(cliResult), len(cliResult.ocCalls)), ([('ns-a', 'pod-a', 'ns-a_vm-a')], 1))

    def testExplicitValuesTakePrecedenceOverDomain(self) -> None:
        self.Script(guest_ping=[{'return': {}}])
        cliResult = self.RunCLI('ping', environ={'BSOD_DET__NAMESPACE': 'explicit', 'BSOD_DET__POD__NAME': 'pod',
                                                 'BSOD_DET__DOMAIN__NAME': 'ns_vm'})
        self.assertEqual(cliResult.status, 0)
        self.assertEqual((self.ExecTargets(cliResult), len(cliResult.ocCalls)), ([('explicit', 'pod', 'ns_vm')], 1))

    def testSingleVMIisDiscovered(self) -> None:
        self.Script(get={'vmi': {'stdout': 'ns-1 vm-1\n'}, 'pod': {'stdout': 'pod/other\npod/virt-launcher-vm-1-xyz\n'}},
                    guest_ping=[{'return': {}}])
        cliResult = self.RunCLI('ping')
        self.assertEqual(cliResult.status, 0)
        self.assertEqual(cliResult.ocCalls[:2], [['--request-timeout=20s', 'get', 'vmi', '-A', *self.vmiQuery],
                                                 ['--request-timeout=20s', 'get', 'pod', '-n', 'ns-1', '-o', 'name']])
        self.assertEqual((self.ExecTargets(cliResult), len(cliResult.ocCalls)),
                         ([('ns-1', 'virt-launcher-vm-1-xyz', 'ns-1_vm-1')], 3))

    def testNamespaceScopedDiscoveryKeepsNamespace(self) -> None:
        self.Script(get={'vmi': {'stdout': 'other vm-1'}, 'pod': {'stdout': 'pod/virt-launcher-vm-1-xyz'}},
                    guest_ping=[{'return': {}}])
        cliResult = self.RunCLI('ping', environ={'BSOD_DET__NAMESPACE': 'ns-1'})
        self.assertEqual(cliResult.status, 0)
        self.assertEqual(cliResult.ocCalls[:2], [['--request-timeout=20s', 'get', 'vmi', '-n', 'ns-1', *self.vmiQuery],
                                                 ['--request-timeout=20s', 'get', 'pod', '-n', 'ns-1', '-o', 'name']])
        self.assertEqual(self.ExecTargets(cliResult), [('ns-1', 'virt-launcher-vm-1-xyz', 'ns-1_vm-1')])

    def testTargetIsResolvedOncePerInvocation(self) -> None:
        (self.workDir / 'payload.bin').write_bytes(b'data')
        self.ScriptUploads(get={'pod': {'stdout': 'pod/virt-launcher-vm-abcde'}})
        cliResult = self.RunCLI('put', 'payload.bin', r'C:\Temp\payload.bin', environ=podlessTargetEnv)
        self.assertEqual(cliResult.status, 0)
        self.assertEqual([ocCall for ocCall in cliResult.ocCalls if 'get' in ocCall],
                         [['--request-timeout=20s', 'get', 'pod', '-n', 'ns', '-o', 'name']])
        self.assertEqual(self.ExecTargets(cliResult), [('ns', 'virt-launcher-vm-abcde', 'ns_vm')] * 3)

    def testUnresolvableTargetsExitOneBeforeAnyAgentCall(self) -> None:
        for getReplies, targetEnv, expectedText in (
                ({'vmi': {'stdout': ''}}, {}, 'guest-agent: no VirtualMachineInstance found'),
                ({'vmi': {'fail': 'error: You must be logged in to the server (Unauthorized)'}}, {},
                 'guest-agent: no VirtualMachineInstance found'),
                ({'vmi': {'stdout': 'ns-1 vm-1\nns-2 vm-2'}}, {}, 'guest-agent: multiple VMs found'),
                ({'vmi': {'stdout': 'ns-1 vm-1'}, 'pod': {'stdout': 'pod/other'}}, {},
                 "guest-agent: no running virt-launcher pod for VM 'vm-1' in ns 'ns-1'"),
                ({}, {'BSOD_DET__VM__NAME': 'vm-1'}, 'guest-agent: namespace unknown')):
            with self.subTest(expectedText=expectedText, getReplies=getReplies):
                self.Script(get=getReplies)
                cliResult = self.RunCLI('exec-crash', 'fixture.exe', environ=targetEnv)
                self.assertEqual((cliResult.status, cliResult.stdOut), (1, ''))
                self.assertIn(expectedText, cliResult.stdErr)
                self.assertEqual(self.AgentCalls(cliResult), [])


class GuestAgentCLIcommandTests(GuestAgentCLItestCase):
    '''Agent transport failures, exec status polling and file upload as seen at the `oc` boundary.'''

    def testAgentFailuresExitOne(self) -> None:
        for pingReply, expectedText in (
                ({'fail': 'error: boom'}, 'virsh failed (timeout=10): error: boom'),
                ({'stdout': 'not json'}, 'invalid response from virsh'),
                ({'stdout': '{"error": {}}'}, 'invalid response from virsh')):
            with self.subTest(expectedText=expectedText):
                self.Script(guest_ping=[pingReply])
                cliResult = self.RunCLI('ping', environ=explicitTargetEnv)
                self.assertEqual((cliResult.status, cliResult.stdOut), (1, ''))
                self.assertIn(expectedText, cliResult.stdErr)
        cliResult = self.RunCLI('ping', environ=dict(explicitTargetEnv, PATH=str(self.workDir / 'no-oc')))
        self.assertEqual((cliResult.status, cliResult.stdOut, cliResult.ocCalls), (1, '', []))
        self.assertIn('oc exec failed', cliResult.stdErr)

    def testExecRetriesTransientStatusErrors(self) -> None:
        self.Script(guest_exec=[{'return': {'pid': 3}}],
                    guest_exec_status=[{'fail': 'error: blip'}, self.Exited(0, stdOut=b'ok')])
        cliResult = self.RunCLI('exec', 'fixture.exe', environ=explicitTargetEnv)
        self.assertEqual(cliResult[:3], (0, 'ok\n', ''))
        self.assertEqual([qmpCommand['execute'] for qmpCommand, _ in self.AgentCalls(cliResult)],
                         ['guest-exec', 'guest-exec-status', 'guest-exec-status'])

    def testPutWritesChunksAndClosesHandle(self) -> None:
        fileData = bytes(range(256)) * 256 + b'!'  # 64 KiB + 1 byte -> two chunks.
        (self.workDir / 'payload.bin').write_bytes(fileData)
        self.ScriptUploads()
        cliResult = self.RunCLI('put', 'payload.bin', r'C:\Temp\payload.bin', environ=explicitTargetEnv)
        self.assertEqual((cliResult.status, cliResult.stdOut), (0, 'wrote 65537 bytes -> C:\\Temp\\payload.bin\n'))
        agentCalls = self.AgentCalls(cliResult)
        self.assertEqual([(qmpCommand['execute'], agentTimeout) for qmpCommand, agentTimeout in agentCalls], [
            ('guest-file-open', 300), ('guest-file-write', 600), ('guest-file-write', 600), ('guest-file-close', 300)])
        self.assertEqual(agentCalls[0][0]['arguments'], {'path': r'C:\Temp\payload.bin', 'mode': 'wb'})
        writtenChunks = [base64.b64decode(qmpCommand['arguments']['buf-b64']) for qmpCommand, _ in agentCalls[1:3]]
        self.assertEqual((b''.join(writtenChunks), len(writtenChunks[0])), (fileData, 64 * 1024))
        self.assertTrue(all(qmpCommand['arguments']['handle'] == guestFileHandle for qmpCommand, _ in agentCalls[1:]))

    def testPutClosesHandleWhenWriteFails(self) -> None:
        (self.workDir / 'payload.bin').write_bytes(b'data')
        self.ScriptUploads(guest_file_write=[{'fail': 'error: write failed'}])
        cliResult = self.RunCLI('put', 'payload.bin', r'C:\Temp\payload.bin', environ=explicitTargetEnv)
        self.assertEqual((cliResult.status, cliResult.stdOut), (1, ''))
        self.assertIn('write failed', cliResult.stdErr)
        self.assertEqual(self.AgentCalls(cliResult)[-1],
                         ({'execute': 'guest-file-close', 'arguments': {'handle': guestFileHandle}}, 300))


class GuestAgentCLIexitTests(GuestAgentCLItestCase):
    '''CLI dispatch, output relay and exit statuses relied on by the shell callers.'''

    def testGuestExitCodeIsRelayed(self) -> None:
        for guestExitCode, expectedStatus in ((7, 7), (0xC0000005, 5)):  # An NTSTATUS keeps its low 8 bits.
            with self.subTest(guestExitCode=guestExitCode):
                self.Script(guest_exec=[{'return': {'pid': 1}}],
                            guest_exec_status=[self.Exited(guestExitCode, stdOut=b'out', stdErr=b'err')])
                cliResult = self.RunCLI('exec', 'fixture.exe', environ=explicitTargetEnv)
                self.assertEqual(cliResult[:3], (expectedStatus, 'out\n', 'err\n'))

    def testExecSendsProgramArguments(self) -> None:
        self.Script(guest_exec=[{'return': {'pid': 1}}], guest_exec_status=[self.Exited(0)])
        cliResult = self.RunCLI('exec', 'cmd.exe', '/c', 'ver', environ=explicitTargetEnv)
        self.assertEqual(cliResult.status, 0)
        self.assertEqual(self.AgentCalls(cliResult), [
            ({'execute': 'guest-exec', 'arguments': {'path': 'cmd.exe', 'arg': ['/c', 'ver'], 'capture-output': True}}, 300),
            ({'execute': 'guest-exec-status', 'arguments': {'pid': 1}}, 300)])

    def testExecTimeoutReturns124(self) -> None:
        self.Script(guest_exec=[{'return': {'pid': 1}}], guest_exec_status=[{'return': {'exited': False}}])
        cliResult = self.RunCLI('exec', 'fixture.exe', environ=explicitTargetEnv)
        self.assertEqual((cliResult.status, cliResult.stdOut), (124, ''))
        self.assertIn('waited 600s without exit', cliResult.stdErr)
        # The launch, then one status poll every 3s of the 600s window.
        self.assertEqual(len(self.AgentCalls(cliResult)), 1 + 200)

    def testMissingExitCodeReturns125(self) -> None:
        self.Script(guest_exec=[{'return': {'pid': 1}}], guest_exec_status=[self.Exited(None)])
        cliResult = self.RunCLI('exec', 'fixture.exe', environ=explicitTargetEnv)
        self.assertEqual((cliResult.status, cliResult.stdOut), (125, ''))
        self.assertIn('did not report an exit code', cliResult.stdErr)

    def testExecLaunchFailureExitsOne(self) -> None:
        self.Script(guest_exec=[{'fail': 'error: Guest agent is not responding'}])
        cliResult = self.RunCLI('exec', 'fixture.exe', environ=explicitTargetEnv)
        self.assertEqual((cliResult.status, cliResult.stdOut), (1, ''))
        self.assertIn('virsh failed (timeout=300): error: Guest agent is not responding', cliResult.stdErr)
        self.assertEqual(len(self.AgentCalls(cliResult)), 1)

    def testCrashCommandImmediateExitIsPropagated(self) -> None:
        self.Script(guest_exec=[{'return': {'pid': 42}}], guest_exec_status=[self.Exited(9, stdErr=b'failed')])
        cliResult = self.RunCLI('exec-crash', 'fixture.exe', environ=dict(explicitTargetEnv, BSOD_TRIGGER_CONFIRM_TIMEOUT='2'))
        self.assertEqual(cliResult[:3], (9, '', 'failed\n'))

    def testCrashCommandConfirmedLaunchThenDisconnectSucceeds(self) -> None:
        self.Script(guest_exec=[{'return': {'pid': 42}}], guest_exec_status=[{'fail': 'transport lost'}])
        cliResult = self.RunCLI('exec-crash', 'nmf.exe', '/crash', 'stack',
                                environ=dict(explicitTargetEnv, BSOD_TRIGGER_CONFIRM_TIMEOUT='2'))
        self.assertEqual(cliResult.status, 0)
        self.assertEqual(json.loads(cliResult.stdOut),
                         {'disconnected': True, 'message': 'virsh failed (timeout=5): transport lost', 'pid': 42})
        self.assertEqual(self.AgentCalls(cliResult), [
            ({'execute': 'guest-exec', 'arguments': {'path': 'nmf.exe', 'arg': ['/crash', 'stack'], 'capture-output': True}}, 20),
            ({'execute': 'guest-exec-status', 'arguments': {'pid': 42}}, 5)])

    def testCrashLaunchFailureIsNotReportedAsDisconnect(self) -> None:
        self.Script(guest_exec=[{'fail': 'error: Guest agent is not responding'}])
        cliResult = self.RunCLI('exec-crash', 'nmf.exe', environ=explicitTargetEnv)
        self.assertEqual((cliResult.status, cliResult.stdOut), (1, ''))
        self.assertIn('virsh failed (timeout=20)', cliResult.stdErr)
        self.assertEqual([qmpCommand['execute'] for qmpCommand, _ in self.AgentCalls(cliResult)], ['guest-exec'])

    def testCrashCommandStillRunningTimesOut(self) -> None:
        self.Script(guest_exec=[{'return': {'pid': 42}}], guest_exec_status=[{'return': {'exited': False}}])
        cliResult = self.RunCLI('exec-crash', 'fixture.exe', environ=dict(explicitTargetEnv, BSOD_TRIGGER_CONFIRM_TIMEOUT='1'))
        self.assertEqual((cliResult.status, cliResult.stdOut), (124, ''))
        self.assertIn('remained observable for 1s', cliResult.stdErr)
        self.assertEqual([qmpCommand['execute'] for qmpCommand, _ in self.AgentCalls(cliResult)],
                         ['guest-exec', 'guest-exec-status'])

    def testCrashConfirmationWindowComesFromEnvironment(self) -> None:
        self.Script(guest_exec=[{'return': {'pid': 1}}], guest_exec_status=[{'return': {'exited': False}}])
        for crashEnv, expectedWindow in (({}, 45), ({'BSOD_TRIGGER_CONFIRM_TIMEOUT': '7'}, 7)):
            with self.subTest(expectedWindow=expectedWindow):
                cliResult = self.RunCLI('exec-crash', 'fixture.exe', environ=dict(explicitTargetEnv, **crashEnv))
                self.assertEqual(cliResult.status, 124)
                self.assertIn(f'remained observable for {expectedWindow}s', cliResult.stdErr)
                # The launch, then one status poll per second of the window.
                self.assertEqual(len(self.AgentCalls(cliResult)), 1 + expectedWindow)

    def testUsageErrorsReturnTwoWithoutClusterCalls(self) -> None:
        cliResult = self.RunCLI()
        self.assertEqual((cliResult.status, cliResult.ocCalls), (2, []))
        self.assertTrue(cliResult.stdOut.startswith('guest-agent.py -- drive a KubeVirt'), cliResult.stdOut[:80])
        for cliArgs in (('exec',), ('exec-crash',), ('psfile',), ('bogus',),
                        ('psfile', 'script.ps1', '--companion', 'only-local')):
            with self.subTest(cliArgs=cliArgs):
                cliResult = self.RunCLI(*cliArgs, environ=podlessTargetEnv)
                self.assertEqual((cliResult.status, cliResult.ocCalls), (2, []))

    def testInvalidInputExitsOneWithoutClusterCalls(self) -> None:
        for cliArgs, crashEnv, expectedError in (
                (('put', 'payload.bin'), {}, 'IndexError'),
                (('put', 'missing.bin', r'C:\Temp\missing.bin'), {}, 'FileNotFoundError'),
                (('exec-crash', 'fixture.exe'), {'BSOD_TRIGGER_CONFIRM_TIMEOUT': 'soon'}, 'ValueError')):
            with self.subTest(cliArgs=cliArgs):
                cliResult = self.RunCLI(*cliArgs, environ=dict(podlessTargetEnv, **crashEnv))
                self.assertEqual((cliResult.status, cliResult.stdOut, cliResult.ocCalls), (1, '', []))
                self.assertIn(expectedError, cliResult.stdErr)


class GuestAgentCLIpsfileTests(GuestAgentCLItestCase):
    '''psfile uploads (script, then companions) and the PowerShell command line.'''

    def ScriptPSfileRun(self) -> None:
        '''Script replies for uploads followed by a successful PowerShell run.'''
        self.ScriptUploads(guest_exec=[{'return': {'pid': 1}}], guest_exec_status=[self.Exited(0)])

    def testPSfileUploadsCompanionsThenRunsScript(self) -> None:
        (self.workDir / 'dir').mkdir()
        (self.workDir / 'local.json').write_text('{}')
        for scriptPath in ('dir/configure.ps1', 'dir\\configure.ps1'):  # Both separators name the guest file.
            with self.subTest(scriptPath=scriptPath):
                (self.workDir / scriptPath).write_text('Write-Output 1')
                self.ScriptPSfileRun()
                cliResult = self.RunCLI('psfile', scriptPath, '--companion', 'local.json', r'C:\Windows\Temp\local.json',
                                        '--', '-VerifyOnly', environ=explicitTargetEnv)
                self.assertEqual(cliResult.status, 0)
                agentCalls = self.AgentCalls(cliResult)
                self.assertEqual([qmpCommand['execute'] for qmpCommand, _ in agentCalls], [
                    'guest-file-open', 'guest-file-write', 'guest-file-close',
                    'guest-file-open', 'guest-file-write', 'guest-file-close', 'guest-exec', 'guest-exec-status'])
                self.assertEqual([agentCalls[index][0]['arguments']['path'] for index in (0, 3)],
                                 [r'C:\Windows\Temp\configure.ps1', r'C:\Windows\Temp\local.json'])
                self.assertEqual([base64.b64decode(agentCalls[index][0]['arguments']['buf-b64']) for index in (1, 4)],
                                 [b'Write-Output 1', b'{}'])
                self.assertEqual(agentCalls[6], ({'execute': 'guest-exec', 'arguments': {
                    'path': 'powershell.exe', 'capture-output': True,
                    'arg': [*powerShellFileArgs, r'C:\Windows\Temp\configure.ps1', '-VerifyOnly'],
                }}, 300))
                self.assertIn(r'uploaded 2 bytes -> C:\Windows\Temp\local.json', cliResult.stdErr)

    def testPSfileArgumentContract(self) -> None:
        (self.workDir / 's.ps1').write_text('Write-Output 1')
        (self.workDir / 'local.json').write_text('{}')
        companionArgs = ['--companion', 'local.json', r'C:\Windows\Temp\local.json']
        for psfileArgs, expectedUploads, expectedPSargs in (
                (companionArgs + ['--', '-VerifyOnly'], [r'C:\Windows\Temp\local.json'], ['-VerifyOnly']),
                (companionArgs, [r'C:\Windows\Temp\local.json'], []),
                (['-DataFile', 'x.json'], [], ['-DataFile', 'x.json']),
                (['--', '-X'], [], ['-X'])):
            with self.subTest(psfileArgs=psfileArgs):
                self.ScriptPSfileRun()
                cliResult = self.RunCLI('psfile', 's.ps1', *psfileArgs, environ=explicitTargetEnv)
                self.assertEqual(cliResult.status, 0)
                agentCalls = self.AgentCalls(cliResult)
                self.assertEqual([qmpCommand['arguments']['path'] for qmpCommand, _ in agentCalls
                                  if qmpCommand['execute'] == 'guest-file-open'],
                                 [r'C:\Windows\Temp\s.ps1', *expectedUploads])
                self.assertEqual([qmpCommand['arguments']['arg'] for qmpCommand, _ in agentCalls
                                  if qmpCommand['execute'] == 'guest-exec'],
                                 [[*powerShellFileArgs, r'C:\Windows\Temp\s.ps1', *expectedPSargs]])


class GuestAgentEntryPointTests(unittest.TestCase):
    '''Run the real script entry point; no cluster client is reachable (empty PATH).'''

    def testEntryPointReportsTargetFailure(self) -> None:
        with tempfile.TemporaryDirectory() as emptyPath:
            entryEnv = {envName: envValue for envName, envValue in os.environ.items() if not envName.startswith('BSOD_')}
            entryEnv['PATH'] = emptyPath
            completed = subprocess.run(
                [sys.executable, str(HOST / 'guest-agent.py'), 'exec-crash', 'fixture.exe'],
                env=entryEnv, capture_output=True, text=True, check=False, timeout=10)
        self.assertEqual((completed.returncode, completed.stdout), (1, ''))
        self.assertIn('guest-agent: no VirtualMachineInstance found', completed.stderr)


if __name__ == "__main__":
    unittest.main()
