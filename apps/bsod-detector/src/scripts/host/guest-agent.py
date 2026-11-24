#!/usr/bin/env python3
"""guest-agent.py -- drive a KubeVirt Windows guest via the qemu-guest-agent.

WHY
    On a KubeVirt/OpenShift cluster there is no direct SSH to the VM without additional
    network configuration. The guest is reachable through the qemu-guest-agent, which
    is spoken by `virsh` inside the VM's virt-launcher pod. This wraps that RPC so the
    BSOD pipeline (stage toolkit, trigger a crash, collect dumps, pull evidence) can
    run with no SSH and no credentials -- guest-exec runs as `nt authority\\system`
    (fully elevated).

HOW IT REACHES THE GUEST
    oc exec -n <ns> <virt-launcher-pod> -- \\
        virsh qemu-agent-command <domain> '<qmp-json>'
    where <domain> is "<namespace>_<vmname>" (e.g. windows-bsod_hjoshi-win2022).

SUBCOMMANDS
    ping                          guest-ping (liveness)
    exec  <program> [args...]     run a command, wait, print stdout/stderr/exit
    psfile <local.ps1> [args...]  upload a local .ps1 and run it (powershell -File)
    put   <local> <guestpath>     upload a local file to the guest
    get   <guestpath> <local>     download a guest file (seek-based, retriable)

TRANSFER NOTES (learned the hard way)
    - guest-file-read count is capped by the QMP payload limit: 2MB works, 4MB
      returns "Unable to encode message payload". Default read chunk here is 1MB.
    - A truncated oc-exec/QMP response would otherwise desync the file position, so
      get() seeks to an explicit offset before every read and retries the chunk.
    - For a large MEMORY.DMP, compress in-guest first (see compress-dump.ps1);
      kernel dumps shrink to ~14% and the transfer runs at ~0.5 MB/s.

CONFIG (required for target identification)
    BSOD_DET__VM__NAME          VM (VirtualMachineInstance) name
    BSOD_DET__NAMESPACE         namespace containing the VM
    BSOD_DET__DOMAIN__NAME      (optional) libvirt domain name. Defaults to "<BSOD_DET__NAMESPACE>_<BSOD_DET__VM__NAME>".
    BSOD_DET__POD__NAME         (optional) virt-launcher pod name. Auto-resolved from cluster if unset.
"""
import base64
import gzip
import json
import os
import shutil
import subprocess
import sys
import time

NS  = os.environ.get("BSOD_DET__NAMESPACE")
VM  = os.environ.get("BSOD_DET__VM__NAME")
POD = os.environ.get("BSOD_DET__POD__NAME")
DOM = os.environ.get("BSOD_DET__DOMAIN__NAME")

_resolved = False


def _oc(args):
    """Execute OpenShift CLI command and return output or empty string on failure."""
    try:
        r = subprocess.run(
            ["oc", "--request-timeout=20s"] + args,
            capture_output=True, text=True, check=False, timeout=25,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return r.stdout.strip() if r.returncode == 0 else ""


def _resolve_pod(ns, vm):
    """Find the virt-launcher pod for a given VM in a namespace."""
    for line in _oc(["get", "pod", "-n", ns, "-o", "name"]).splitlines():
        name = line.split("/", 1)[-1]
        if name.startswith(f"virt-launcher-{vm}-"):
            return name
    return ""


def resolve_target():
    """Auto-detect and populate namespace, VM, domain name, and pod from the cluster; explicit env vars take precedence."""
    global NS, VM, POD, DOM, _resolved
    if _resolved:
        return

    # CRITICAL: Re-read environment variables in case they were set after module import
    # This handles cases where variables are exported by parent shell after Python starts
    NS = NS or os.environ.get("BSOD_DET__NAMESPACE")
    VM = VM or os.environ.get("BSOD_DET__VM__NAME")
    POD = POD or os.environ.get("BSOD_DET__POD__NAME")
    DOM = DOM or os.environ.get("BSOD_DET__DOMAIN__NAME")

    # A domain name is "<ns>_<vm>" (k8s names never contain '_') -> back it out.
    if DOM and (not NS or not VM) and "_" in DOM:
        n, v = DOM.split("_", 1)
        NS = NS or n
        VM = VM or v
    # Auto-detect the VM when not told: unambiguous only if exactly one VMI exists.
    if not VM:
        jp = '{range .items[*]}{.metadata.namespace} {.metadata.name}{"\\n"}{end}'
        scope = ["-n", NS] if NS else ["-A"]
        rows = [r for r in _oc(["get", "vmi"] + scope + ["-o", "jsonpath=" + jp]).splitlines() if r.strip()]
        if len(rows) == 1:
            n, v = rows[0].split()[:2]
            NS = NS or n
            VM = v
        elif not rows:
            sys.exit("guest-agent: no VirtualMachineInstance found; set BSOD_DET__VM__NAME (and BSOD_DET__NAMESPACE)")
        else:
            sys.exit("guest-agent: multiple VMs found -- set BSOD_DET__VM__NAME (and BSOD_DET__NAMESPACE):\n  " + "\n  ".join(rows))
    if not NS:
        sys.exit("guest-agent: namespace unknown; set BSOD_DET__NAMESPACE (or BSOD_DET__DOMAIN__NAME=<ns>_<vm>)")
    if not DOM:
        DOM = f"{NS}_{VM}"
    if not POD:
        POD = _resolve_pod(NS, VM)
        if not POD:
            sys.exit(f"guest-agent: no running virt-launcher pod for VM '{VM}' in ns '{NS}'")
    _resolved = True


def agent(cmd_obj, timeout=300):
    """Send a QEMU agent command via virsh and return the response payload."""
    resolve_target()
    payload = json.dumps(cmd_obj)
    try:
        out = subprocess.run(
            ["oc", "--request-timeout=" + str(timeout) + "s", "exec", "-n", NS, POD, "--",
             "virsh", "qemu-agent-command", "--timeout", str(timeout), DOM, payload],
            capture_output=True, text=True, check=False, timeout=timeout + 5)
    except subprocess.TimeoutExpired as e:
        raise RuntimeError(f"oc exec timed out after {timeout + 5}s: {e}")
    except Exception as e:
        raise RuntimeError(f"oc exec failed: {e}")

    if out.returncode != 0:
        err_msg = out.stderr.strip() or out.stdout.strip() or "unknown error"
        raise RuntimeError(f"virsh failed (timeout={timeout}): {err_msg}")
    try:
        return json.loads(out.stdout)["return"]
    except (json.JSONDecodeError, KeyError) as e:
        raise RuntimeError(f"invalid response from virsh: {out.stdout}: {e}")


def guest_exec(path, args=None, wait=True, poll_timeout=600):
    """Execute a program in the guest VM and optionally wait for completion; returns PID, exit code, stdout, and stderr."""
    r = agent({"execute": "guest-exec", "arguments": {
        "path": path, "arg": args or [], "capture-output": True}}, timeout=300)
    pid = r["pid"]
    if not wait:
        return {"pid": pid}
    deadline = time.time() + poll_timeout
    poll_interval = 3
    while time.time() < deadline:
        try:
            st = agent({"execute": "guest-exec-status", "arguments": {"pid": pid}}, timeout=300)
            if st.get("exited"):
                out = base64.b64decode(st["out-data"]).decode("utf-8", "replace") if st.get("out-data") else ""
                err = base64.b64decode(st["err-data"]).decode("utf-8", "replace") if st.get("err-data") else ""
                return {"pid": pid, "exitcode": st.get("exitcode"), "stdout": out, "stderr": err}
            time.sleep(poll_interval)
        except RuntimeError as e:
            remaining = deadline - time.time()
            if remaining > 10:
                time.sleep(poll_interval)
                continue
            raise RuntimeError(f"guest-exec timed out waiting for pid {pid}: {e}")
    return {"pid": pid, "timeout": True, "message": f"waited {poll_timeout}s without exit"}


def guest_exec_crash(path, args=None, poll_timeout=45):
    """Execute a crash-inducing program and capture its outcome (exit, timeout, or transport loss indicating crash)."""
    launched = agent({"execute": "guest-exec", "arguments": {
        "path": path, "arg": args or [], "capture-output": True,
    }}, timeout=20)
    pid = launched["pid"]
    deadline = time.monotonic() + poll_timeout
    while time.monotonic() < deadline:
        try:
            status = agent(
                {"execute": "guest-exec-status", "arguments": {"pid": pid}},
                timeout=5,
            )
        except RuntimeError as exc:
            return {"pid": pid, "disconnected": True, "message": str(exc)}
        if status.get("exited"):
            out = base64.b64decode(status["out-data"]).decode("utf-8", "replace") if status.get("out-data") else ""
            err = base64.b64decode(status["err-data"]).decode("utf-8", "replace") if status.get("err-data") else ""
            return {"pid": pid, "exitcode": status.get("exitcode"), "stdout": out, "stderr": err}
        time.sleep(1)
    return {"pid": pid, "timeout": True, "message": f"crash command remained observable for {poll_timeout}s"}


def guest_put(local, guestpath):
    """Upload a local file to the guest VM using optimized base64-encoded chunks."""
    with open(local, "rb") as fh:
        data = fh.read()
    file_size = len(data)
    handle = agent({"execute": "guest-file-open",
                    "arguments": {"path": guestpath, "mode": "wb"}}, timeout=300)
    try:
        CH = 64 * 1024  # 64KB chunks (base64 ~85KB; stays within oc exec ARG_MAX on restricted clusters)
        for i in range(0, len(data), CH):
            chunk = base64.b64encode(data[i:i + CH]).decode()
            agent({"execute": "guest-file-write",
                   "arguments": {"handle": handle, "buf-b64": chunk}}, timeout=600)
            if (i + CH) // (50 * 1024 * 1024) > i // (50 * 1024 * 1024):  # Progress every 50MB
                mb = (i + CH) // (1024 * 1024)
                sys.stderr.write(f"  uploaded {mb}MB...\n")
                sys.stderr.flush()
    finally:
        agent({"execute": "guest-file-close", "arguments": {"handle": handle}}, timeout=300)
    sys.stderr.write(f"wrote {file_size} bytes -> {guestpath} ({file_size // (1024*1024)}MB)\n")
    sys.stderr.flush()
    return file_size


def guest_get(guestpath, local, chunk=3500 * 1024, auto_compress=True):
    """Download a guest VM file with automatic compression for large files; uses seek-based retries for reliability."""

    # For large files, compress on guest first
    compressed_on_guest = False
    if auto_compress and guestpath.endswith('MEMORY.DMP'):
        compressed_path = guestpath + '.gz'
        sys.stderr.write(f"Compressing {guestpath} on guest (may take 2-3 min)...\n")
        sys.stderr.flush()
        try:
            # Use PowerShell's built-in compression on Windows
            r = guest_exec("powershell.exe",
                          ["-NoProfile", "-Command",
                           f"$in = [System.IO.File]::OpenRead('{guestpath}'); "
                           f"$out = [System.IO.File]::Create('{compressed_path}'); "
                           f"$gz = New-Object System.IO.Compression.GZipStream($out, [System.IO.Compression.CompressionMode]::Compress); "
                           f"$in.CopyTo($gz); $gz.Dispose(); $in.Dispose(); $out.Dispose(); "
                           f"Write-Host ('compressed to ' + (Get-Item {compressed_path}).Length + ' bytes')"],
                          poll_timeout=600)
            sys.stderr.write("✓ Compression complete\n")
            sys.stderr.flush()
            guestpath = compressed_path
            local = local + '.gz'
            compressed_on_guest = True
        except Exception as e:
            sys.stderr.write(f"⚠ Compression failed: {e}, proceeding uncompressed\n")
            sys.stderr.flush()

    handle = agent({"execute": "guest-file-open", "arguments": {"path": guestpath, "mode": "rb"}}, timeout=300)
    total = 0
    try:
        offset = 0
        while True:
            last = None
            for retry in range(5):
                try:
                    agent({"execute": "guest-file-seek",
                           "arguments": {"handle": handle, "offset": offset, "whence": 0}}, timeout=600)
                    r = agent({"execute": "guest-file-read",
                               "arguments": {"handle": handle, "count": chunk}}, timeout=600)
                    break
                except Exception as e:  # noqa: BLE001  # retry any transient agent error
                    last = e
                    if retry < 4:
                        time.sleep(2)
            else:
                raise RuntimeError(f"chunk at offset {offset} failed after retries: {last}")
            b = base64.b64decode(r["buf-b64"]) if r.get("buf-b64") else b""
            if b:
                with open(local, "r+b" if offset else "wb") as f:
                    f.seek(offset); f.write(b)
                offset += len(b); total = offset
                if total // (25 * 1024 * 1024) > (total - len(b)) // (25 * 1024 * 1024):  # Progress every 25MB
                    mb = total // (1024 * 1024)
                    sys.stderr.write(f"  {mb}MB...\n")
                    sys.stderr.flush()
            if r.get("eof") or not b:
                break
    finally:
        agent({"execute": "guest-file-close", "arguments": {"handle": handle}}, timeout=300)

    mb = total // (1024 * 1024)
    sys.stderr.write(f"read {total} bytes -> {local} ({mb}MB)\n")
    sys.stderr.flush()

    # Auto-decompress if we compressed on guest
    if compressed_on_guest and local.endswith('.gz'):
        sys.stderr.write(f"Decompressing {local}...\n")
        sys.stderr.flush()
        local_uncompressed = local[:-3]
        try:
            with gzip.open(local, 'rb') as f_in:
                with open(local_uncompressed, 'wb') as f_out:
                    shutil.copyfileobj(f_in, f_out)
            os.remove(local)
            local = local_uncompressed
            sys.stderr.write(f"✓ Decompressed to {local}\n")
            sys.stderr.flush()
        except Exception as e:
            sys.stderr.write(f"⚠ Decompression failed: {e}\n")
            sys.stderr.flush()

    return total


def _print_exec_result(result):
    """Output guest command results (stdout, stderr) and return the process exit code."""
    if result.get("stdout"):
        sys.stdout.write(result["stdout"] + ("" if result["stdout"].endswith("\n") else "\n"))
    if result.get("stderr"):
        sys.stderr.write(result["stderr"] + ("" if result["stderr"].endswith("\n") else "\n"))
    if result.get("timeout"):
        sys.stderr.write(result.get("message", "guest command timed out") + "\n")
        return 124
    exit_code = result.get("exitcode")
    if exit_code is None:
        sys.stderr.write("guest command did not report an exit code\n")
        return 125
    return int(exit_code)


def _psfile_args(arguments):
    """Parse and separate companion file uploads from PowerShell script arguments."""
    if arguments and arguments[0] not in {"--companion", "--"}:
        return [], arguments
    companions = []
    powershell_args = []
    index = 0
    while index < len(arguments):
        if arguments[index] == "--":
            powershell_args.extend(arguments[index + 1:])
            break
        if arguments[index] != "--companion" or index + 2 >= len(arguments):
            raise ValueError("psfile expects --companion <local> <guest-path> entries followed by -- and PowerShell args")
        companions.append((arguments[index + 1], arguments[index + 2]))
        index += 3
    return companions, powershell_args


def main():
    """Parse and dispatch commands to interact with the guest VM.

    Commands:
      ping                                - Test guest connectivity
      exec <program> [args...]            - Run a program and wait for output
      exec-nowait <program> [args...]     - Run a program without waiting
      exec-crash <program> [args...]      - Run a crash-inducing program
      put <local> <guestpath>             - Upload a file to the guest
      get <guestpath> <local>             - Download a file from the guest
      psfile <script> [--companion ...]   - Upload and run a PowerShell script
    """
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(2)
    cmd = sys.argv[1]
    if cmd == "ping":
        print(agent({"execute": "guest-ping"}, timeout=10)); return 0
    if cmd == "exec":
        if len(sys.argv) < 3:
            print("exec requires a program", file=sys.stderr); return 2
        r = guest_exec(sys.argv[2], sys.argv[3:])
        return _print_exec_result(r)
    if cmd == "exec-nowait":
        if len(sys.argv) < 3:
            print("exec-nowait requires a program", file=sys.stderr); return 2
        print(json.dumps(guest_exec(sys.argv[2], sys.argv[3:], wait=False), sort_keys=True))
        return 0
    if cmd == "exec-crash":
        if len(sys.argv) < 3:
            print("exec-crash requires a program", file=sys.stderr); return 2
        timeout = int(os.environ.get("BSOD_TRIGGER_CONFIRM_TIMEOUT", "45"))
        result = guest_exec_crash(sys.argv[2], sys.argv[3:], poll_timeout=timeout)
        if result.get("disconnected"):
            print(json.dumps(result, sort_keys=True))
            return 0
        return _print_exec_result(result)
    if cmd == "put":
        n = guest_put(sys.argv[2], sys.argv[3]); print(f"wrote {n} bytes -> {sys.argv[3]}"); return 0
    if cmd == "get":
        n = guest_get(sys.argv[2], sys.argv[3]); print(f"read {n} bytes -> {sys.argv[3]}"); return 0
    if cmd == "psfile":
        if len(sys.argv) < 3:
            print("psfile requires a local PowerShell file", file=sys.stderr); return 2
        local = sys.argv[2]
        guestpath = "C:\\Windows\\Temp\\" + local.replace("\\", "/").split("/")[-1]
        try:
            companions, powershell_args = _psfile_args(sys.argv[3:])
        except ValueError as exc:
            print(str(exc), file=sys.stderr); return 2
        n = guest_put(local, guestpath)
        sys.stderr.write(f"uploaded {n} bytes -> {guestpath}\n")
        for companion_local, companion_guest in companions:
            size = guest_put(companion_local, companion_guest)
            sys.stderr.write(f"uploaded {size} bytes -> {companion_guest}\n")
        r = guest_exec("powershell.exe",
                       ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", guestpath] + powershell_args,
                       poll_timeout=600)
        return _print_exec_result(r)
    print("unknown cmd", cmd); return 2


if __name__ == "__main__":
    sys.exit(main())
