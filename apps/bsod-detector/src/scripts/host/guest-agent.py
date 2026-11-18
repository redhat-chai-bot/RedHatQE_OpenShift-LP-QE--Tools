#!/usr/bin/env python3
'''guest-agent.py -- drive a KubeVirt Windows guest through the qemu-guest-agent.

USAGE
    guest-agent.py ping                            agent liveness check
    guest-agent.py exec <program> [args...]        run, wait up to 600s, relay output and exit code
    guest-agent.py exec-crash <program> [args...]  launch a crash trigger; agent loss after launch = success
    guest-agent.py put <localPath> <guestPath>     upload a file
    guest-agent.py psfile <local.ps1> [args...]    upload a PowerShell script and run it
    guest-agent.py psfile <local.ps1> [--companion <localPath> <guestPath>]... [-- args...]

ENVIRONMENT
    BSOD_DET__VM__NAME, BSOD_DET__NAMESPACE, BSOD_DET__DOMAIN__NAME, BSOD_DET__POD__NAME
        guest target; unset values are derived or discovered from the cluster.
    BSOD_TRIGGER_CONFIRM_TIMEOUT
        exec-crash confirmation window in seconds (default 45).

EXIT STATUS
    exec, exec-crash and psfile exit with the low 8 bits of the guest exit code (256 becomes 0).
    Otherwise: 0 success (exec-crash: the expected agent loss), 1 error, 2 usage,
    124 not exited in time, 125 no exit code.

Details: apps/bsod-detector/src/scripts/host/README.md
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

    Not a RuntimeError on purpose: exec polling treats RuntimeError as a transient (exec) or
    crash-signalling (exec-crash) agent failure, which a configuration error must never be.
    '''


class GuestTarget(typing.NamedTuple):
    '''Immutable resolved coordinates of one guest: namespace, VM, virt-launcher Pod and libvirt domain.'''

    namespace: str
    vmName: str
    podName: str
    domainName: str


def RunOC(args: list[str]) -> str:
    '''Run a bounded `oc` read; return its stripped stdout, or '' on any failure (missing client, timeout, error).'''
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
    '''Convert an exited guest-exec-status reply into {pid, exitcode, stdout, stderr}; undecodable bytes are replaced.'''
    return {
        'pid':      pid,
        'exitcode': status.get('exitcode'),
        'stdout':   base64.b64decode(status['out-data']).decode('utf-8', 'replace') if status.get('out-data') else '',
        'stderr':   base64.b64decode(status['err-data']).decode('utf-8', 'replace') if status.get('err-data') else '',
    }


class GuestAgent:
    '''qemu-guest-agent client for one guest.

    The target is resolved lazily by the first agent command and cached on this instance
    only; create a new instance to address a different guest.
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
        '''Return the guest target, resolving it on first use (rules: see the README).

        Only a fully resolved target is cached. Raises TargetError if no unambiguous VM,
        namespace or virt-launcher Pod is found.
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
        '''Send one QMP command and return the reply's `return` payload.

        `timeout` bounds the oc request and the virsh wait (the subprocess gets 5s more).
        Raises TargetError if the target cannot be resolved, and RuntimeError on any
        transport, virsh or reply failure.
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
        '''Run a guest program and wait up to `pollTimeout` seconds for it to exit.

        Returns ExitedResult() or a {'pid', 'timeout': True, 'message'} record. Status-poll
        errors are retried until 10s or less of the window remain, then raised as RuntimeError.
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

        After the launch is acknowledged, any agent error is the crash signal and returns
        {'pid', 'disconnected': True, 'message'}; otherwise ExitedResult() or a timeout record.
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
        '''Upload a local file to `guestPath` in 64 KiB chunks and return its size; the handle is always closed.'''
        with open(localPath, 'rb') as localFile:
            fileData = localFile.read()
        fileSize = len(fileData)
        chunkSize = 64 * 1024  # About 85 KiB of base64 keeps each `oc exec` argument under Linux's 128 KiB per-argument limit.
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
    '''Relay a guest command's output; return its exit code, 124 on timeout or 125 without an exit code.

    The process exit status keeps only the low 8 bits of the returned guest code.
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
    '''Split psfile arguments into (companion uploads, script arguments).

    Without a leading `--companion` or `--` every argument belongs to the script; otherwise
    `--companion <localPath> <guestPath>` entries repeat until `--`. Raises ValueError on a
    malformed companion entry.
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
    '''Run one subcommand and return its exit status (see EXIT STATUS above).

    `argv` (default sys.argv) includes the program name; `environ` defaults to os.environ.
    Each call builds its own GuestAgent, so no target state outlives the call.
    '''
    cliArgs = list(sys.argv if argv is None else argv)
    environ = os.environ if environ is None else environ
    if len(cliArgs) < 2:
        print(__doc__)
        return 2
    subCmd = cliArgs[1]
    requiredArgs = {'exec': (1, 'a program'), 'exec-crash': (1, 'a program'), 'psfile': (1, 'a local PowerShell file'),
                    'put': (2, 'a local path and a guest path')}
    argCount, argText = requiredArgs.get(subCmd, (0, ''))
    if len(cliArgs) < 2 + argCount:
        print(f'{subCmd} requires {argText}', file=sys.stderr)
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
