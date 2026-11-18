#!/usr/bin/env python3
'''guest-agent.py -- drive a KubeVirt Windows guest through the qemu-guest-agent.

WHY
    A KubeVirt/OpenShift VM is not reachable over SSH without additional network
    configuration. The guest is reachable through the qemu-guest-agent (QGA), which
    `virsh` speaks inside the VM's virt-launcher Pod. This CLI wraps that RPC so the
    BSOD pipeline (preflight, toolkit staging, crash trigger and watcher liveness)
    runs without SSH or guest credentials -- guest-exec runs as
    `nt authority\\system` (fully elevated).

HOW IT REACHES THE GUEST
    oc exec -n <namespace> <virt-launcher-pod> -- \\
        virsh qemu-agent-command --timeout <seconds> <domain> '<qmp-json>'
    where <domain> is "<namespace>_<vmName>" (e.g. windows-bsod_win2022).

USAGE
    guest-agent.py ping
    guest-agent.py exec <program> [args...]
    guest-agent.py exec-crash <program> [args...]
    guest-agent.py put <localPath> <guestPath>
    guest-agent.py psfile <local.ps1> [<psArgs...>]
    guest-agent.py psfile <local.ps1> [--companion <localPath> <guestPath>]... [-- <psArgs...>]

SUBCOMMANDS
    ping        guest-ping liveness check; prints the agent reply ({}).
    exec        Run a program, wait up to 600s for it to exit, relay its
                stdout/stderr and exit with the guest exit code.
    exec-crash  Launch a crash-inducing program and confirm the outcome. Losing the
                agent after a confirmed launch is the expected crash signal: print a
                JSON record ("disconnected": true) and exit 0. A program that exits
                first relays its output and exit code.
    put         Upload a local file in 64 KiB chunks.
    psfile      Upload a PowerShell script to C:\\Windows\\Temp\\ (plus optional
                companion files to explicit guest paths) and run it with
                `powershell.exe -File`, waiting up to 600s. Script arguments follow the
                script directly; after --companion entries, `--` separates them.

EXIT STATUS
    exec, exec-crash and psfile relay the guest exit code (as its low 8 bits, so it
    can coincide with the statuses below). Other statuses:
    0    ping/put succeeded, or exec-crash observed the expected agent loss.
    1    Target resolution failed, an agent call raised an error, or another unhandled
         error occurred (e.g. missing put arguments, unreadable local file, non-integer
         BSOD_TRIGGER_CONFIRM_TIMEOUT); unhandled errors print a traceback.
    2    Usage error.
    124  The guest command did not exit within its wait window.
    125  The guest reported an exit without an exit code.

CONFIG (environment; explicit values take precedence over discovery)
    BSOD_DET__VM__NAME            VirtualMachineInstance name. When unset (and not derivable
                                  from the domain), the only VMI in scope is used; zero or
                                  several VMIs are an error.
    BSOD_DET__NAMESPACE           Namespace containing the VM.
    BSOD_DET__DOMAIN__NAME        (optional) libvirt domain name. Defaults to "<namespace>_<vmName>";
                                  when the namespace or VM name is unset it is derived from this.
    BSOD_DET__POD__NAME           (optional) virt-launcher Pod name. Auto-resolved when unset.
    BSOD_TRIGGER_CONFIRM_TIMEOUT  (optional) exec-crash confirmation window in seconds (default 45).
                                  Predates the BSOD_DET__ naming convention; renaming it needs a
                                  caller compatibility plan.
'''
from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import time
import typing
from collections.abc import Mapping


class TargetError(Exception):
    '''The guest target cannot be identified unambiguously.

    Deliberately not a RuntimeError: the exec polling loops treat RuntimeError as a
    transient (or, for exec-crash, crash-signalling) agent failure, and a
    configuration error must never be mistaken for either.
    '''


class GuestTarget(typing.NamedTuple):
    '''Immutable resolved coordinates of one guest: namespace, VM, virt-launcher Pod and libvirt domain.'''

    namespace: str
    vmName: str
    podName: str
    domainName: str


def RunOC(args: list[str]) -> str:
    '''Run a bounded `oc` read and return its stripped stdout, or '' on any failure.

    Failures (missing client, timeout or nonzero exit) are folded into '' so that
    discovery reports one actionable target error instead of a client traceback.
    '''
    try:
        completed = subprocess.run(
            ['oc', '--request-timeout=20s'] + args,
            capture_output=True, text=True, check=False, timeout=25,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ''
    return completed.stdout.strip() if completed.returncode == 0 else ''


def FindLauncherPod(namespace: str, vmName: str) -> str:
    '''Return the name of the virt-launcher Pod serving `vmName` in `namespace`, or '' if none.'''
    podPrefix = f'virt-launcher-{vmName}-'
    for podRef in RunOC(['get', 'pod', '-n', namespace, '-o', 'name']).splitlines():
        podName = podRef.split('/', 1)[-1]
        if podName.startswith(podPrefix):
            return podName
    return ''


def Log(message: str) -> None:
    '''Write one diagnostic line to STDERR immediately, keeping STDOUT for command results.'''
    sys.stderr.write(message + '\n')
    sys.stderr.flush()


def ExitedResult(pid: int, status: dict[str, typing.Any]) -> dict[str, typing.Any]:
    '''Convert an exited guest-exec-status reply into a result record with decoded output.

    The QGA reply carries base64 `out-data`/`err-data`; undecodable bytes are replaced
    rather than raised so that a crash tool's partial output is still reported.
    '''
    return {
        'pid':      pid,
        'exitcode': status.get('exitcode'),
        'stdout':   base64.b64decode(status['out-data']).decode('utf-8', 'replace') if status.get('out-data') else '',
        'stderr':   base64.b64decode(status['err-data']).decode('utf-8', 'replace') if status.get('err-data') else '',
    }


class GuestAgent:
    '''qemu-guest-agent client bound to one KubeVirt guest.

    The requested target is supplied per instance and resolved lazily by the first
    agent command, so subcommands rejected for usage reasons never reach the cluster.
    The resolved GuestTarget is cached on the instance only: separate instances never
    share target or cache state. The requested target is fixed at construction; create
    a new instance to address a different guest.
    '''

    def __init__(self, namespace: str = '', vmName: str = '', podName: str = '', domainName: str = '') -> None:
        '''Record the requested target; empty values are resolved by ResolveTarget().'''
        self.namespace = namespace
        self.vmName = vmName
        self.podName = podName
        self.domainName = domainName
        self.target: GuestTarget | None = None

    @classmethod
    def FromEnvironment(cls, environ: Mapping[str, str] | None = None) -> GuestAgent:
        '''Create a client from the BSOD_DET__* target variables (os.environ by default).'''
        environ = os.environ if environ is None else environ
        return cls(
            namespace=environ.get('BSOD_DET__NAMESPACE', ''),
            vmName=environ.get('BSOD_DET__VM__NAME', ''),
            podName=environ.get('BSOD_DET__POD__NAME', ''),
            domainName=environ.get('BSOD_DET__DOMAIN__NAME', ''),
        )

    def ResolveTarget(self) -> GuestTarget:
        '''Return the guest target, resolving it on first use and caching it on this instance.

        Requested values take precedence. A "<namespace>_<vmName>" domain supplies a
        missing namespace or VM name; a still-missing VM name is discovered only when
        exactly one VirtualMachineInstance is in scope. The domain defaults to
        "<namespace>_<vmName>" and the Pod to the VM's virt-launcher Pod. Only a fully
        resolved target is cached, so a failed resolution is retried on the next call.

        Raises:
            TargetError: no unambiguous VM, namespace or virt-launcher Pod is found.
        '''
        if self.target is not None:
            return self.target
        namespace, vmName, podName, domainName = self.namespace, self.vmName, self.podName, self.domainName

        # Kubernetes names never contain '_', so the domain name splits unambiguously.
        if domainName and '_' in domainName and not (namespace and vmName):
            domainNamespace, domainVM = domainName.split('_', 1)
            namespace, vmName = namespace or domainNamespace, vmName or domainVM

        if not vmName:
            jsonPath = '{range .items[*]}{.metadata.namespace} {.metadata.name}{"\\n"}{end}'
            vmiScope = ['-n', namespace] if namespace else ['-A']
            vmiRows = [row for row in RunOC(['get', 'vmi'] + vmiScope + ['-o', 'jsonpath=' + jsonPath]).splitlines()
                       if row.strip()]
            if not vmiRows:
                raise TargetError('no VirtualMachineInstance found; set BSOD_DET__VM__NAME (and BSOD_DET__NAMESPACE)')
            if len(vmiRows) > 1:
                raise TargetError('multiple VMs found -- set BSOD_DET__VM__NAME (and BSOD_DET__NAMESPACE):\n  '
                                  + '\n  '.join(vmiRows))
            vmiNamespace, vmName = vmiRows[0].split()[:2]
            namespace = namespace or vmiNamespace

        if not namespace:
            raise TargetError('namespace unknown; set BSOD_DET__NAMESPACE (or BSOD_DET__DOMAIN__NAME=<ns>_<vm>)')

        domainName = domainName or f'{namespace}_{vmName}'
        podName = podName or FindLauncherPod(namespace, vmName)
        if not podName:
            raise TargetError(f"no running virt-launcher pod for VM '{vmName}' in ns '{namespace}'")
        self.target = GuestTarget(namespace=namespace, vmName=vmName, podName=podName, domainName=domainName)
        return self.target

    def SendCommand(self, qmpCommand: dict[str, typing.Any], timeout: int = 300) -> typing.Any:
        '''Send one QMP command to the guest agent and return the reply's `return` payload.

        `timeout` bounds the oc request and the virsh agent wait; the local subprocess
        gets 5 extra seconds so that virsh reports its own timeout first.

        Raises:
            TargetError: the guest target cannot be resolved.
            RuntimeError: the transport failed, virsh exited nonzero or the reply is invalid.
        '''
        target = self.ResolveTarget()
        payload = json.dumps(qmpCommand)
        try:
            completed = subprocess.run(
                ['oc', f'--request-timeout={timeout}s', 'exec', '-n', target.namespace, target.podName, '--',
                 'virsh', 'qemu-agent-command', '--timeout', str(timeout), target.domainName, payload],
                capture_output=True, text=True, check=False, timeout=timeout + 5)
        except subprocess.TimeoutExpired as err:
            raise RuntimeError(f'oc exec timed out after {timeout + 5}s: {err}') from err
        except Exception as err:
            raise RuntimeError(f'oc exec failed: {err}') from err
        if completed.returncode != 0:
            raise RuntimeError(f'virsh failed (timeout={timeout}): '
                               + (completed.stderr.strip() or completed.stdout.strip() or 'unknown error'))
        try:
            return json.loads(completed.stdout)['return']
        except (json.JSONDecodeError, KeyError) as err:
            raise RuntimeError(f'invalid response from virsh: {completed.stdout}: {err}') from err

    def LaunchProgram(self, path: str, args: list[str] | None, timeout: int) -> int:
        '''Start a guest program with captured output and return its guest PID.'''
        return self.SendCommand({'execute': 'guest-exec', 'arguments': {
            'path': path, 'arg': args or [], 'capture-output': True}}, timeout=timeout)['pid']

    def GetExecStatus(self, pid: int, timeout: int) -> dict[str, typing.Any]:
        '''Return the raw guest-exec-status reply for a guest PID.'''
        return self.SendCommand({'execute': 'guest-exec-status', 'arguments': {'pid': pid}}, timeout=timeout)

    def GuestExec(self, path: str, args: list[str] | None = None, pollTimeout: int = 600) -> dict[str, typing.Any]:
        '''Run a guest program and wait for it to exit.

        Status polls run every 3s. Transient agent errors are retried until 10s or less of the
        `pollTimeout` window remain, then raised as RuntimeError.

        Returns:
            ExitedResult() record, or {'pid', 'timeout': True, 'message'} when the program
            has not exited within `pollTimeout` seconds.
        '''
        pid = self.LaunchProgram(path, args, timeout=300)
        deadline = time.time() + pollTimeout
        while time.time() < deadline:
            try:
                status = self.GetExecStatus(pid, timeout=300)
                if status.get('exited'):
                    return ExitedResult(pid, status)
            except RuntimeError as err:
                if deadline - time.time() <= 10:
                    raise RuntimeError(f'guest-exec timed out waiting for pid {pid}: {err}') from err
            time.sleep(3)
        return {'pid': pid, 'timeout': True, 'message': f'waited {pollTimeout}s without exit'}

    def GuestExecCrash(self, path: str, args: list[str] | None = None, pollTimeout: int = 45) -> dict[str, typing.Any]:
        '''Launch a crash-inducing guest program and report how it ended.

        The launch must be acknowledged with a PID (20s agent timeout). After that, any
        agent error on a 5s status poll means the guest stopped answering, which is the
        crash signal.

        Returns:
            {'pid', 'disconnected': True, 'message'} on agent loss; ExitedResult() when the
            program exits first; {'pid', 'timeout': True, 'message'} when it is still
            observable after `pollTimeout` seconds.
        '''
        pid = self.LaunchProgram(path, args, timeout=20)
        deadline = time.monotonic() + pollTimeout
        while time.monotonic() < deadline:
            try:
                status = self.GetExecStatus(pid, timeout=5)
            except RuntimeError as err:
                return {'pid': pid, 'disconnected': True, 'message': str(err)}
            if status.get('exited'):
                return ExitedResult(pid, status)
            time.sleep(1)
        return {'pid': pid, 'timeout': True, 'message': f'crash command remained observable for {pollTimeout}s'}

    def GuestPut(self, localPath: str, guestPath: str) -> int:
        '''Upload a local file to `guestPath` and return the number of bytes written.

        Data is sent in 64 KiB chunks (about 85 KiB base64), which keeps each oc exec
        argument within ARG_MAX; progress is logged every 50 MiB. The guest handle is
        always closed, even when a write fails.
        '''
        with open(localPath, 'rb') as localFile:
            fileData = localFile.read()
        fileSize = len(fileData)
        chunkSize = 64 * 1024
        progressStep = 50 * 1024 * 1024
        handle = self.SendCommand({'execute': 'guest-file-open', 'arguments': {'path': guestPath, 'mode': 'wb'}},
                                  timeout=300)
        try:
            for offset in range(0, fileSize, chunkSize):
                self.SendCommand({'execute': 'guest-file-write', 'arguments': {
                    'handle': handle,
                    'buf-b64': base64.b64encode(fileData[offset:offset + chunkSize]).decode(),
                }}, timeout=600)
                if (offset + chunkSize) // progressStep > offset // progressStep:
                    Log(f'  uploaded {(offset + chunkSize) // (1024 * 1024)}MB...')
        finally:
            self.SendCommand({'execute': 'guest-file-close', 'arguments': {'handle': handle}}, timeout=300)
        Log(f'wrote {fileSize} bytes -> {guestPath} ({fileSize // (1024 * 1024)}MB)')
        return fileSize


def PrintExecResult(result: dict[str, typing.Any]) -> int:
    '''Relay a guest command's stdout/stderr and return the CLI exit status.

    Returns the guest exit code, 124 when the command did not exit in time, or 125
    when the guest reported no exit code.
    '''
    for stream, streamKey in ((sys.stdout, 'stdout'), (sys.stderr, 'stderr')):
        if result.get(streamKey):
            stream.write(result[streamKey] + ('' if result[streamKey].endswith('\n') else '\n'))
    if result.get('timeout'):
        Log(result.get('message', 'guest command timed out'))
        return 124
    exitCode = result.get('exitcode')
    if exitCode is None:
        Log('guest command did not report an exit code')
        return 125
    return int(exitCode)


def ParsePSfileArgs(arguments: list[str]) -> tuple[list[tuple[str, str]], list[str]]:
    '''Split psfile arguments into companion uploads and PowerShell script arguments.

    Without a leading `--companion` or `--`, every argument belongs to the script.
    Otherwise `--companion <localPath> <guestPath>` entries repeat until `--`, after
    which the remaining arguments belong to the script.

    Raises:
        ValueError: a companion entry is malformed or incomplete.
    '''
    if arguments and arguments[0] not in {'--companion', '--'}:
        return [], arguments
    companions: list[tuple[str, str]] = []
    index = 0
    while index < len(arguments):
        if arguments[index] == '--':
            return companions, arguments[index + 1:]
        if arguments[index] != '--companion' or index + 2 >= len(arguments):
            raise ValueError('psfile expects --companion <local> <guest-path> entries followed by -- and PowerShell args')
        companions.append((arguments[index + 1], arguments[index + 2]))
        index += 3
    return companions, []


def Main(argv: list[str] | None = None, environ: Mapping[str, str] | None = None) -> int:
    '''Run one guest-agent.py subcommand and return its exit status (see module EXIT STATUS).

    `argv` (default sys.argv) includes the program name; `environ` (default os.environ)
    supplies the target and exec-crash configuration. Each call builds its own
    GuestAgent, so no target state outlives the call.
    '''
    cliArgs = list(sys.argv if argv is None else argv)
    environ = os.environ if environ is None else environ
    if len(cliArgs) < 2:
        print(__doc__)
        return 2
    subCmd = cliArgs[1]
    requiredArg = {'exec': 'a program', 'exec-crash': 'a program', 'psfile': 'a local PowerShell file'}
    if subCmd in requiredArg and len(cliArgs) < 3:
        print(f'{subCmd} requires {requiredArg[subCmd]}', file=sys.stderr)
        return 2
    guestAgent = GuestAgent.FromEnvironment(environ)
    try:
        if subCmd == 'ping':
            print(guestAgent.SendCommand({'execute': 'guest-ping'}, timeout=10))
            return 0
        if subCmd == 'exec':
            return PrintExecResult(guestAgent.GuestExec(cliArgs[2], cliArgs[3:]))
        if subCmd == 'exec-crash':
            result = guestAgent.GuestExecCrash(
                cliArgs[2], cliArgs[3:], pollTimeout=int(environ.get('BSOD_TRIGGER_CONFIRM_TIMEOUT', '45')))
            if result.get('disconnected'):
                print(json.dumps(result, sort_keys=True))
                return 0
            return PrintExecResult(result)
        if subCmd == 'put':
            fileSize = guestAgent.GuestPut(cliArgs[2], cliArgs[3])
            print(f'wrote {fileSize} bytes -> {cliArgs[3]}')
            return 0
        if subCmd == 'psfile':
            localPath = cliArgs[2]
            guestPath = 'C:\\Windows\\Temp\\' + localPath.replace('\\', '/').split('/')[-1]
            try:
                companions, psArgs = ParsePSfileArgs(cliArgs[3:])
            except ValueError as err:
                print(str(err), file=sys.stderr)
                return 2
            for uploadLocal, uploadGuest in [(localPath, guestPath)] + companions:
                Log(f'uploaded {guestAgent.GuestPut(uploadLocal, uploadGuest)} bytes -> {uploadGuest}')
            return PrintExecResult(guestAgent.GuestExec(
                'powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', guestPath] + psArgs,
                pollTimeout=600))
    except TargetError as err:
        Log(f'guest-agent: {err}')
        return 1
    print('unknown cmd', subCmd)
    return 2


if __name__ == '__main__':
    sys.exit(Main())
