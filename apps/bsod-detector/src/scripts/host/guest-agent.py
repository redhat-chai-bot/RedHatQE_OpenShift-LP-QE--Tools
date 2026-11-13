#!/usr/bin/env python3
import base64
import json
import os
import subprocess
import sys
import time

NS = VM = POD = DOM = ''
_resolved = False


def _oc(args):
    try:
        result = subprocess.run(
            ['oc', '--request-timeout=20s'] + args,
            capture_output=True, text=True, check=False, timeout=25,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ''
    return result.stdout.strip() if result.returncode == 0 else ''


def _resolve_pod(ns, vm):
    prefix = f'virt-launcher-{vm}-'
    for podRef in _oc(['get', 'pod', '-n', ns, '-o', 'name']).splitlines():
        name = podRef.split('/', 1)[-1]
        if name.startswith(prefix):
            return name
    return ''


def resolve_target():
    global NS, VM, POD, DOM, _resolved
    if _resolved:
        return

    # Preserve any values already set by an importing caller; fall back to env.
    NS  = NS  or os.environ.get('BSOD_DET__NAMESPACE',    '')
    VM  = VM  or os.environ.get('BSOD_DET__VM__NAME',     '')
    POD = POD or os.environ.get('BSOD_DET__POD__NAME',    '')
    DOM = DOM or os.environ.get('BSOD_DET__DOMAIN__NAME', '')

    # Derive NS+VM from DOM when format is "<ns>_<vm>".
    if DOM and '_' in DOM and not (NS and VM):
        n, v = DOM.split('_', 1)
        NS, VM = NS or n, VM or v

    # Auto-discover VM when not explicitly set.
    if not VM:
        jp = '{range .items[*]}{.metadata.namespace} {.metadata.name}{"\\n"}{end}'
        rows = [r for r in _oc(
            ['get', 'vmi'] + (['-n', NS] if NS else ['-A']) + ['-o', 'jsonpath=' + jp]
        ).splitlines() if r.strip()]
        if not rows:
            sys.exit('guest-agent: no VirtualMachineInstance found; set BSOD_DET__VM__NAME (and BSOD_DET__NAMESPACE)')
        elif len(rows) > 1:
            sys.exit('guest-agent: multiple VMs found — set BSOD_DET__VM__NAME (and BSOD_DET__NAMESPACE):\n  ' + '\n  '.join(rows))
        NS, VM = NS or rows[0].split()[0], rows[0].split()[1]

    if not NS:
        sys.exit('guest-agent: namespace unknown; set BSOD_DET__NAMESPACE (or BSOD_DET__DOMAIN__NAME=<ns>_<vm>)')

    DOM = DOM or f'{NS}_{VM}'
    POD = POD or _resolve_pod(NS, VM)
    if not POD:
        sys.exit(f"guest-agent: no running virt-launcher pod for VM '{VM}' in ns '{NS}'")
    _resolved = True


def agent(cmd_obj, timeout=300):
    resolve_target()
    payload = json.dumps(cmd_obj)
    try:
        out = subprocess.run(
            ['oc', f'--request-timeout={timeout}s', 'exec', '-n', NS, POD, '--',
             'virsh', 'qemu-agent-command', '--timeout', str(timeout), DOM, payload],
            capture_output=True, text=True, check=False, timeout=timeout + 5)
    except subprocess.TimeoutExpired as e:
        raise RuntimeError(f'oc exec timed out after {timeout + 5}s: {e}')
    except Exception as e:
        raise RuntimeError(f'oc exec failed: {e}')
    if out.returncode != 0:
        raise RuntimeError(f'virsh failed (timeout={timeout}): {out.stderr.strip() or out.stdout.strip() or "unknown error"}')
    try:
        return json.loads(out.stdout)['return']
    except (json.JSONDecodeError, KeyError) as e:
        raise RuntimeError(f'invalid response from virsh: {out.stdout}: {e}')


def Log(message):
    sys.stderr.write(message + '\n')
    sys.stderr.flush()


def ExitedResult(pid, status):
    return {
        'pid':      pid,
        'exitcode': status.get('exitcode'),
        'stdout':   base64.b64decode(status['out-data']).decode('utf-8', 'replace') if status.get('out-data') else '',
        'stderr':   base64.b64decode(status['err-data']).decode('utf-8', 'replace') if status.get('err-data') else '',
    }


def guest_exec(path, args=None, poll_timeout=600):
    pid = agent({'execute': 'guest-exec', 'arguments': {
        'path': path, 'arg': args or [], 'capture-output': True}}, timeout=300)['pid']
    deadline = time.time() + poll_timeout
    while time.time() < deadline:
        try:
            status = agent({'execute': 'guest-exec-status', 'arguments': {'pid': pid}}, timeout=300)
            if status.get('exited'):
                return ExitedResult(pid, status)
        except RuntimeError as e:
            # Retry transient agent errors; only raise when deadline is near.
            if deadline - time.time() <= 10:
                raise RuntimeError(f'guest-exec timed out waiting for pid {pid}: {e}')
        time.sleep(3)
    return {'pid': pid, 'timeout': True, 'message': f'waited {poll_timeout}s without exit'}


def guest_exec_crash(path, args=None, poll_timeout=45):
    pid = agent({'execute': 'guest-exec', 'arguments': {
        'path': path, 'arg': args or [], 'capture-output': True}}, timeout=20)['pid']
    deadline = time.monotonic() + poll_timeout
    while time.monotonic() < deadline:
        try:
            status = agent({'execute': 'guest-exec-status', 'arguments': {'pid': pid}}, timeout=5)
        except RuntimeError as exc:
            # Any agent error after launch means the guest is down — that is the crash signal.
            return {'pid': pid, 'disconnected': True, 'message': str(exc)}
        if status.get('exited'):
            return ExitedResult(pid, status)
        time.sleep(1)
    return {'pid': pid, 'timeout': True, 'message': f'crash command remained observable for {poll_timeout}s'}


def guest_put(local, guestpath):
    with open(local, 'rb') as fh:
        data = fh.read()
    fileSize = len(data)
    handle = agent({'execute': 'guest-file-open', 'arguments': {'path': guestpath, 'mode': 'wb'}}, timeout=300)
    try:
        CH = 64 * 1024  # 64KB; base64 ~85KB — stays within oc exec ARG_MAX
        for i in range(0, fileSize, CH):
            agent({'execute': 'guest-file-write',
                   'arguments': {'handle': handle, 'buf-b64': base64.b64encode(data[i:i + CH]).decode()}}, timeout=600)
            if (i + CH) // (50 * 1024 * 1024) > i // (50 * 1024 * 1024):
                Log(f'  uploaded {(i + CH) // (1024 * 1024)}MB...')
    finally:
        agent({'execute': 'guest-file-close', 'arguments': {'handle': handle}}, timeout=300)
    Log(f'wrote {fileSize} bytes -> {guestpath} ({fileSize // (1024*1024)}MB)')
    return fileSize


def _print_exec_result(result):
    for stream, key in ((sys.stdout, 'stdout'), (sys.stderr, 'stderr')):
        if result.get(key):
            stream.write(result[key] + ('' if result[key].endswith('\n') else '\n'))
    if result.get('timeout'):
        Log(result.get('message', 'guest command timed out'))
        return 124
    exitCode = result.get('exitcode')
    if exitCode is None:
        Log('guest command did not report an exit code')
        return 125
    return int(exitCode)


def _psfile_args(arguments):
    if arguments and arguments[0] not in {'--companion', '--'}:
        return [], arguments
    companions, index = [], 0
    while index < len(arguments):
        if arguments[index] == '--':
            return companions, arguments[index + 1:]
        if arguments[index] != '--companion' or index + 2 >= len(arguments):
            raise ValueError('psfile expects --companion <local> <guest-path> entries followed by -- and PowerShell args')
        companions.append((arguments[index + 1], arguments[index + 2]))
        index += 3
    return companions, []


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    cmd = sys.argv[1]
    requiredArg = {'exec': 'a program', 'exec-crash': 'a program', 'psfile': 'a local PowerShell file'}
    if cmd in requiredArg and len(sys.argv) < 3:
        print(f'{cmd} requires {requiredArg[cmd]}', file=sys.stderr)
        return 2
    if cmd == 'ping':
        print(agent({'execute': 'guest-ping'}, timeout=10))
        return 0
    if cmd == 'exec':
        return _print_exec_result(guest_exec(sys.argv[2], sys.argv[3:]))
    if cmd == 'exec-crash':
        # BSOD_TRIGGER_CONFIRM_TIMEOUT predates the naming convention; rename needs a compatibility plan.
        result = guest_exec_crash(sys.argv[2], sys.argv[3:],
                                  poll_timeout=int(os.environ.get('BSOD_TRIGGER_CONFIRM_TIMEOUT', '45')))
        if result.get('disconnected'):
            print(json.dumps(result, sort_keys=True))
            return 0
        return _print_exec_result(result)
    if cmd == 'put':
        size = guest_put(sys.argv[2], sys.argv[3])
        print(f'wrote {size} bytes -> {sys.argv[3]}')
        return 0
    if cmd == 'psfile':
        local = sys.argv[2]
        guestpath = 'C:\\Windows\\Temp\\' + local.replace('\\', '/').split('/')[-1]
        try:
            companions, powershellArgs = _psfile_args(sys.argv[3:])
        except ValueError as exc:
            print(str(exc), file=sys.stderr)
            return 2
        for uploadLocal, uploadGuest in [(local, guestpath)] + companions:
            Log(f'uploaded {guest_put(uploadLocal, uploadGuest)} bytes -> {uploadGuest}')
        return _print_exec_result(guest_exec('powershell.exe',
            ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', guestpath] + powershellArgs,
            poll_timeout=600))
    print('unknown cmd', cmd)
    return 2


if __name__ == '__main__':
    sys.exit(main())
