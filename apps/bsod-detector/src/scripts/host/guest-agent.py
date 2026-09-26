#!/usr/bin/env python3
"""guest-agent.py -- drive a KubeVirt Windows guest via the qemu-guest-agent.

WHY
    On a KubeVirt/OpenShift cluster there is no passt SSH to the VM. The guest is
    reachable through the qemu-guest-agent, which is spoken by `virsh` inside the
    VM's virt-launcher pod. This wraps that RPC so the BSOD pipeline (stage toolkit,
    trigger a crash, collect dumps, pull evidence) can run with no SSH and no
    credentials -- guest-exec runs as `nt authority\\system` (fully elevated).

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

CONFIG (all optional -- the target is auto-resolved from the cluster)
    GA_VM   VM (VirtualMachineInstance) name. If unset, and exactly one VMI is
            found (in GA_NS if set, else cluster-wide), it is used automatically.
    GA_NS   namespace. If unset, taken from the auto-detected VMI (or from GA_DOM).
    GA_DOM  libvirt domain name. Defaults to "<GA_NS>_<GA_VM>".
    GA_POD  virt-launcher pod. Defaults to the running virt-launcher-<vm>-* pod
            resolved from the cluster (no more stale hardcoded pod suffixes).
    Nothing is hardcoded to a particular VM: with a single VMI you can run with no
    env vars at all; otherwise set GA_VM (and GA_NS if it is ambiguous).
"""
import base64
import gzip
import json
import os
import shutil
import subprocess
import sys
import time

NS  = os.environ.get("GA_NS")
VM  = os.environ.get("GA_VM")
POD = os.environ.get("GA_POD")
DOM = os.environ.get("GA_DOM")

_resolved = False


def _oc(args):
    """Run `oc <args>` and return stripped stdout, or '' on failure."""
    r = subprocess.run(["oc"] + args, capture_output=True, text=True, check=False)
    return r.stdout.strip() if r.returncode == 0 else ""


def _resolve_pod(ns, vm):
    for line in _oc(["get", "pod", "-n", ns, "-o", "name"]).splitlines():
        name = line.split("/", 1)[-1]
        if name.startswith(f"virt-launcher-{vm}-"):
            return name
    return ""


def resolve_target():
    """Fill in NS/VM/DOM/POD from the cluster so nothing has to be hardcoded.
    Explicit env vars always win; only the missing pieces are looked up."""
    global NS, VM, POD, DOM, _resolved
    if _resolved:
        return
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
            sys.exit("guest-agent: no VirtualMachineInstance found; set GA_VM (and GA_NS)")
        else:
            sys.exit("guest-agent: multiple VMs found -- set GA_VM (and GA_NS):\n  " + "\n  ".join(rows))
    if not NS:
        sys.exit("guest-agent: namespace unknown; set GA_NS (or GA_DOM=<ns>_<vm>)")
    if not DOM:
        DOM = f"{NS}_{VM}"
    if not POD:
        POD = _resolve_pod(NS, VM)
        if not POD:
            sys.exit(f"guest-agent: no running virt-launcher pod for VM '{VM}' in ns '{NS}'")
    _resolved = True


def agent(cmd_obj, timeout=300):
    """Send one qemu-agent-command and return its 'return' payload."""
    resolve_target()
    payload = json.dumps(cmd_obj)
    try:
        out = subprocess.run(
            ["oc", "exec", "-n", NS, POD, "--",
             "virsh", "qemu-agent-command", "--timeout", str(timeout), DOM, payload],
            capture_output=True, text=True, check=False, timeout=timeout+30)
    except subprocess.TimeoutExpired as e:
        raise RuntimeError(f"oc exec timed out after {timeout+30}s: {e}")
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
    """Run a program in the guest. wait=False returns immediately (use when the
    command is expected to crash the guest, e.g. a BSOD trigger)."""
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


def guest_put(local, guestpath):
    """Upload a local file to the guest via guest-file-write (1.5MB base64 chunks).
    Supports files up to 2GB+ with optimized chunk sizing for QMP limits."""
    with open(local, "rb") as fh:
        data = fh.read()
    file_size = len(data)
    handle = agent({"execute": "guest-file-open",
                    "arguments": {"path": guestpath, "mode": "wb"}}, timeout=300)
    try:
        CH = 1536 * 1024  # 1.5MB chunks (base64 expands to ~2MB in QMP)
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
    """Download a guest file with intelligent compression for large files.

    Uses 3.5MB chunks (safe margin from 4MB QMP limit). For files >100MB,
    automatically compresses on guest using gzip, transfers compressed file,
    then decompresses on host. This reduces transfer time by ~7x for typical
    MEMORY.DMP files (555MB → 77MB).

    Seek-based + per-chunk retries ensure truncated responses don't desync."""

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
            if r.get("timeout") or r.get("exitcode") != 0:
                raise RuntimeError(
                    f"guest compression failed: exit={r.get('exitcode')} timeout={r.get('timeout', False)} "
                    f"stderr={r.get('stderr', '')}"
                )
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


def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(2)
    cmd = sys.argv[1]
    if cmd == "ping":
        print(agent({"execute": "guest-ping"}, timeout=10)); return
    if cmd == "exec":
        r = guest_exec(sys.argv[2], sys.argv[3:])
        print(f"[exit {r.get('exitcode')}]")
        if r.get("stdout"): sys.stdout.write(r["stdout"] + ("" if r["stdout"].endswith("\n") else "\n"))
        if r.get("stderr"): sys.stderr.write("STDERR:\n" + r["stderr"] + "\n")
        if r.get("timeout"):
            sys.exit(124)
        sys.exit(r.get("exitcode") if r.get("exitcode") is not None else 1)
    if cmd == "put":
        n = guest_put(sys.argv[2], sys.argv[3]); print(f"wrote {n} bytes -> {sys.argv[3]}"); return
    if cmd == "get":
        n = guest_get(sys.argv[2], sys.argv[3]); print(f"read {n} bytes -> {sys.argv[3]}"); return
    if cmd == "psfile":
        local = sys.argv[2]
        guestpath = "C:\\Windows\\Temp\\" + local.replace("\\", "/").split("/")[-1]
        n = guest_put(local, guestpath); print(f"[uploaded {n}B -> {guestpath}]")
        r = guest_exec("powershell.exe",
                       ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", guestpath] + sys.argv[3:],
                       poll_timeout=600)
        print(f"[exit {r.get('exitcode')}]")
        if r.get("stdout"): sys.stdout.write(r["stdout"])
        if r.get("stderr"): sys.stderr.write("STDERR:\n" + r["stderr"])
        if r.get("timeout"):
            sys.exit(124)
        sys.exit(r.get("exitcode") if r.get("exitcode") is not None else 1)
    print("unknown cmd", cmd); sys.exit(2)


if __name__ == "__main__":
    main()
