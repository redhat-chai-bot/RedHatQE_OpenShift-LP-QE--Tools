#!/usr/bin/env python3
"""Write Model-Specific Registers to a KVM guest vCPU.

Bypasses QEMU/QMP (which has no upstream MSR write command) by duplicating
the KVM vCPU file descriptor from the QEMU process via pidfd_getfd, then
issuing a KVM_SET_MSRS ioctl directly.

Requires root (or CAP_SYS_PTRACE) because QEMU runs as the 'qemu' user.

Usage:
    sudo python3 kvm-msr-write.py --vm bsod-test --msr 0x277 --value 0x0101010101010101
    sudo python3 kvm-msr-write.py --pid 12345 --vcpu 0 --msr 0x3b --value 0x1000000000
"""

import argparse
import ctypes
import ctypes.util
import fcntl
import json
import os
import struct
import subprocess
import sys

KVM_SET_MSRS = 0x4008AE89

SYS_PIDFD_OPEN = 434
SYS_PIDFD_GETFD = 438


def parse_int(value: str) -> int:
    """Accept hex (0x…), octal (0o…), binary (0b…), or decimal strings."""
    return int(value, 0)


def find_qemu_pid(vm_name: str) -> int:
    """Resolve a libvirt VM name to the PID of its QEMU process via /proc scan."""
    result = subprocess.run(
        ["virsh", "qemu-monitor-command", vm_name,
         '{"execute":"query-status"}'],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"VM '{vm_name}' not found or not running: {result.stderr.strip()}")

    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/cmdline", "rb") as fh:
                cmdline = fh.read().decode("utf-8", errors="replace")
        except (PermissionError, FileNotFoundError):
            continue
        if "qemu-system" in cmdline and f"guest={vm_name}" in cmdline:
            return int(entry)

    raise RuntimeError(f"could not find QEMU process for VM '{vm_name}'")


def find_vcpu_fd(pid: int, vcpu_index: int) -> int:
    """Return the fd number for the given vCPU inside the QEMU process."""
    fd_dir = f"/proc/{pid}/fd"
    target_name = f"anon_inode:kvm-vcpu:{vcpu_index}"

    for fd_name in os.listdir(fd_dir):
        try:
            link = os.readlink(f"{fd_dir}/{fd_name}")
        except (PermissionError, FileNotFoundError):
            continue
        if link == target_name:
            return int(fd_name)

    raise RuntimeError(
        f"could not find kvm-vcpu:{vcpu_index} fd in /proc/{pid}/fd/. "
        f"Is vCPU {vcpu_index} valid for this VM?"
    )


def pidfd_open(pid: int) -> int:
    """Obtain a pidfd for the process; caller must os.close() the result."""
    libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    result = libc.syscall(SYS_PIDFD_OPEN, pid, 0)
    if result < 0:
        errno = ctypes.get_errno()
        raise OSError(errno, f"pidfd_open({pid}) failed: {os.strerror(errno)}")
    return result


def pidfd_getfd(pidfd: int, target_fd: int) -> int:
    """Duplicate target_fd from the foreign process into this process's fd table."""
    libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    result = libc.syscall(SYS_PIDFD_GETFD, pidfd, target_fd, 0)
    if result < 0:
        errno = ctypes.get_errno()
        raise OSError(errno, f"pidfd_getfd(pidfd={pidfd}, target_fd={target_fd}) failed: {os.strerror(errno)}")
    return result


def kvm_set_msr(vcpu_fd: int, msr_index: int, value: int) -> int:
    """Issue KVM_SET_MSRS ioctl. Returns the number of MSRs successfully written."""
    nmsrs = 1
    pad = 0
    reserved = 0
    buf = struct.pack("=IIIIQ", nmsrs, pad, msr_index, reserved, value)

    buf_array = (ctypes.c_char * len(buf)).from_buffer_copy(buf)
    result = fcntl.ioctl(vcpu_fd, KVM_SET_MSRS, buf_array)
    return result


def main():
    """CLI entry point; exits 0 on success, 1 if the MSR write failed."""
    parser = argparse.ArgumentParser(description="Write MSRs to a KVM guest vCPU")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--vm", help="libvirt VM name (finds QEMU PID automatically)")
    group.add_argument("--pid", type=int, help="QEMU process PID")
    parser.add_argument("--vcpu", type=int, default=0, help="vCPU index (default: 0)")
    parser.add_argument("--msr", required=True, type=parse_int, help="MSR register index (hex or decimal)")
    parser.add_argument("--value", required=True, type=parse_int, help="value to write (hex or decimal)")
    parser.add_argument("--json", action="store_true", help="output result as JSON")
    args = parser.parse_args()

    pid = args.pid if args.pid else find_qemu_pid(args.vm)
    vcpu_fd_num = find_vcpu_fd(pid, args.vcpu)

    pidfd = pidfd_open(pid)
    try:
        local_vcpu_fd = pidfd_getfd(pidfd, vcpu_fd_num)
    finally:
        os.close(pidfd)

    try:
        written = kvm_set_msr(local_vcpu_fd, args.msr, args.value)
    finally:
        os.close(local_vcpu_fd)

    success = written >= 1

    if args.json:
        print(json.dumps({
            "ok": success,
            "pid": pid,
            "vcpu": args.vcpu,
            "msr": f"0x{args.msr:x}",
            "value": f"0x{args.value:x}",
            "msrs_written": written,
        }))
    else:
        status = "ok" if success else "FAILED"
        print(f"[{status}] MSR 0x{args.msr:x} = 0x{args.value:x} on vCPU {args.vcpu} (pid {pid}, wrote {written})")

    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
