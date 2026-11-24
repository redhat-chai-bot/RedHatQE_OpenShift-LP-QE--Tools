# CrashMe Test Driver

Intentionally triggers `KeBugCheckEx` with arbitrary parameters for testing the BSOD collector against all possible bug-check codes.

**WARNING**: This driver will immediately BSOD the machine. Only use on disposable test VMs behind a snapshot.

## Prerequisites

- **Control program only**: `mingw64-x86_64-gcc` (Fedora: `mingw64-gcc`)
- **Driver + control program**: `mingw64-x86_64-gcc` + WDK headers providing `ntddk.h`

## Build

```bash
make ctl       # just crashme-ctl.exe (usermode)
make driver    # just crashme.sys (requires WDK headers)
make           # both
```

Set `WDK_INCLUDE` if your WDK headers are not at `/usr/share/mingw-w64/include/ddk`:

```bash
make WDK_INCLUDE=/path/to/wdk/include driver
```

## Install

Copy `crashme.sys` and `crashme-ctl.exe` to the guest VM, then run `install.ps1` as Administrator. The script enables test-signing (reboot required on first run), registers the driver service, and verifies the device is accessible.

## Usage

```
crashme-ctl.exe <hex-bugcheck-code> [p1] [p2] [p3] [p4]
```

Example (trigger bug check 0x1A with four parameters):

```
crashme-ctl.exe 0x1A 0x3F 0xF4EC 0x45C23B3D 0xEBC0C2B3
```

The machine will BSOD immediately. There is no confirmation prompt.
