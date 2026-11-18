# Windows Golden-Image and Crash-Dump Scripts

This README documents only these three PowerShell scripts:

- `golden-image-pre-reboot.ps1` — prepares the Windows guest and forces a reboot.
- `golden-image-post-reboot.ps1` — checks the guest after reboot, before image sealing.
- `configure-dumps.ps1` — applies or reports configuration-driven crash-dump settings.

The descriptions below reflect the supplied script versions. They document what the scripts do; they do not constitute a successful Windows execution or crash-dump test.

## Requirements and Execution Order

- Run the golden-image pair inside the Windows guest from an elevated PowerShell session, in the order shown below.
- Applying settings with `configure-dumps.ps1` also requires Administrator privileges. Its `-VerifyOnly` mode does not enforce elevation.
- The pre-reboot script uses Windows disk-image, driver-management, service, registry, and CIM operations. Its preferred VirtIO driver paths are for Windows 11 AMD64; it falls back to a recursive AMD64 INF search.
- The pre-reboot script needs network access to check the remote VirtIO ISO metadata, even when a local ISO already exists. It downloads the ISO when needed.
- `configure-dumps.ps1` requires a readable configuration JSON file. In apply mode it also attempts a network download of NotMyFault if the executable is missing; that download is best effort.
- The pre-reboot script configures a pagefile sized to guest RAM plus 257 MB. Ensure the guest's C: volume has room for it; the script does not check free disk space.

```powershell
# Step 1: Run as Administrator. This script forces a reboot at the end.
.\golden-image-pre-reboot.ps1

# Step 2: After reboot, run as Administrator before sealing the image.
.\golden-image-post-reboot.ps1
```

Do not seal if the post-reboot script reports `FAIL` or exits with code 1. It prints a sealing command after its checks pass, but does not execute that command itself.

`configure-dumps.ps1` is a separate apply/verify operation, not an additional mandatory step in the golden-image pair. Its desired values come from its configuration, so they can differ from the fixed golden-image settings.

## 1. golden-image-pre-reboot.ps1

### Purpose and interface

Part 1 of golden-image preparation. It has no declared parameters. Run it as Administrator before sealing the guest. Elevation is stated in the script instructions but is not checked explicitly by the script.

**Warning:** On reaching the end, the script waits five seconds and calls `Restart-Computer -Force`. Save work before running it; there is no confirmation prompt or no-reboot switch.

### Actions, in order

1. Creates `C:\Temp` if needed and selects TLS 1.2 for downloads.
2. Sends an HTTP HEAD request to the VirtIO ISO endpoint:
   `https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso`.
3. Compares the remote `Last-Modified` timestamp against the local `C:\Temp\virtio-win.iso` timestamp. A local timestamp at least as recent skips the download; a missing or older local copy is downloaded with `.NET WebClient`. This is a timestamp comparison, not a checksum or driver-version check.
4. Mounts the ISO and runs the x86_64 QEMU Guest Agent MSI quietly, waiting for completion and requesting no installer-initiated restart.
5. Attempts to install both VirtIO storage drivers with `pnputil /add-driver ... /install`:
   - VirtIO block: preferred relative path `viostor\w11\amd64\viostor.inf`.
   - VirtIO SCSI: preferred relative path `vioscsi\w11\amd64\vioscsi.inf`.
   - If a preferred path is missing, searches the ISO recursively for that INF filename and takes the first match whose full path contains `amd64`.
   - If no match is found, prints a warning and skips that driver.
6. Notes that SATA uses the Windows inbox `storahci` driver; it does not install it.
7. Unmounts the ISO, retaining the local ISO for the next timestamp check.
8. Checks for the `QEMU-GA` service, requests Automatic startup, and attempts to start it if stopped. After a start attempt, waits three seconds and refreshes the service status. A missing service or a service still not Running causes an explicit exit with code 1.
9. Writes the CrashControl settings listed below and removes the `DedicatedDumpFile` registry value if present.
10. Writes the pagefile registry configuration listed below.
11. Waits five seconds and forces a reboot.

### CrashControl settings

Registry path: `HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl`.

| Value | Registry type | Written value |
|---|---|---|
| `CrashDumpEnabled` | DWORD | `7` — Automatic memory dump |
| `AutoReboot` | DWORD | `0` |
| `AlwaysKeepMemoryDump` | DWORD | `1` |
| `Overwrite` | DWORD | `1` |
| `LogEvent` | DWORD | `1` |
| `DumpFile` | ExpandString | `%SystemRoot%\MEMORY.DMP` |
| `MinidumpDir` | ExpandString | `%SystemRoot%\Minidump` |
| `DedicatedDumpFile` | Removed | No dedicated-dump value is retained by this script |

### Pagefile configuration

Registry path: `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management`.

- Writes `AutomaticManagedPagefile=0` as a DWORD.
- Reads physical RAM through `Win32_ComputerSystem.TotalPhysicalMemory`.
- Calculates the configured size as `Round((RAM bytes + 257MB) / 1MB, 0)`.
- Replaces `PagingFiles` with one MultiString entry: `C:\pagefile.sys <sizeMB> <sizeMB>`.
- Uses equal initial and maximum sizes. This replaces the configured list rather than preserving additional pagefile entries.
- Does not create the active pagefile directly: Windows applies the configuration on reboot. The post-reboot script checks the running system.

### Disabled code and validation limits

- The Windows `pvpanic` driver installation and service-key setup are commented out and do not execute.
- The boot-status policy, recovery, boot-menu, and Windows Recovery Environment modification commands are commented out and do not execute.
- The script prints installation messages but does not explicitly inspect the MSI process exit code or the storage-driver command exit codes. Its final reboot is not proof that every operation succeeded; use the post-reboot checks.
- It emits human-readable progress and errors, not a structured JSON report.

## 2. golden-image-post-reboot.ps1

### Purpose and interface

Part 2 of golden-image preparation. It has no declared parameters. Run it as Administrator after the reboot from part 1 and before sealing.

This is primarily a verification script, but it also requests Automatic startup for the QEMU Guest Agent service. It does not attempt to start a stopped service, resize the pagefile, reinstall drivers, or fix CrashControl values.

### Active checks

1. **QEMU Guest Agent:** Requests Automatic startup and checks whether the service is Running. A missing or stopped service marks failure. The startup-type update suppresses errors; there is no separate read-back verification of startup type.
2. **Storage drivers:** Checks the online driver store for entries whose original filenames contain `viostor` and `vioscsi`. Checks whether the inbox SATA driver exists. Missing drivers generate `WARN` messages rather than marking failure. The warnings note that the matching disk bus may not boot without its driver; a warning is not assurance that every disk bus is supported.
3. **CrashControl DWORDs:** Compares these five values against the golden-image expectations: `CrashDumpEnabled=7`, `AutoReboot=0`, `AlwaysKeepMemoryDump=1`, `Overwrite=1`, and `LogEvent=1`. Any mismatch marks failure.
4. **Dedicated dump setting:** Reads `DedicatedDumpFile`. A nonempty value marks failure; a missing or empty value follows the success branch. The stated golden-image policy is for the value to be absent.
5. **Pagefile management:** Reads `Win32_ComputerSystem.AutomaticManagedPagefile`. Automatic management still enabled marks failure. This checks CIM state, not just the registry value written before reboot.
6. **Active pagefile:** Reads `Win32_PageFileUsage` for C: entries and checks that `AllocatedBaseSize` is at least `Round(RAM bytes / 1MB, 0) + 257` MB. Reports allocation and current usage on success. An undersized or missing active pagefile marks failure.

### Result and sealing

- `OK` lines describe checks that passed.
- `WARN` lines do not set the script's failure flag.
- If any active check sets that flag, the script prints `DO NOT SEAL` and explicitly exits with code 1, instructing the operator to fix issues and rerun part 1.
- If no check sets the flag, it prints `All checks passed` and the following command:

```powershell
sysprep /generalize /oobe /shutdown /quiet
```

The command is printed only. Sealing remains a separate operator action.

### Verification boundaries

- The `pvpanic` and recovery-setting checks are commented out.
- `DumpFile` and `MinidumpDir` are written by part 1 but are not checked by this script.
- It does not verify that configured pagefile initial and maximum sizes match; it checks automatic-management state and the active allocation threshold.
- It does not trigger a BSOD, verify a generated dump, or produce JSON. Passing these checks is not an end-to-end crash-dump validation.

## 3. configure-dumps.ps1

### Purpose

Applies recommended crash-dump registry settings from configuration, or reports current values with `-VerifyOnly`. It runs in the Windows guest and uses strict mode with terminating error preference.

Unlike the golden-image pair, its registry path, recommended values, dump-type mapping, and pagefile registry lookup come from configuration rather than a fixed built-in settings table.

### Parameters

| Parameter | Meaning |
|---|---|
| `-DumpType <string>` | Selects a key from the configuration's `crashDumpTypes`. Defaults to `recommended.crashDumpType`. Valid names depend on the supplied configuration; they are not hard-coded in the script. |
| `-VerifyOnly` | Reads and compares current settings without registry changes or NotMyFault staging. |
| `-DataFile <string>` | Path to the required configuration JSON. Supply it when running outside the expected repository layout. |

**Configuration dependency:** The script expects `crash-control.json`. Without `-DataFile`, it resolves three levels above its script directory and looks for `src\data\crash-control.json`. The configuration supplies `registryPath`, `recommended.crashDumpType`, `recommended.values`, `crashDumpTypes.<selected type>.CrashDumpEnabled`, and `pageFile.path` / `pageFile.value`. The configuration itself is not documented as an additional script here, and its exact contents were not included in the three script attachments.

### Usage

Run apply mode from an elevated PowerShell session. These examples use a placeholder path that must be replaced with the actual configuration location:

```powershell
# Apply the configuration's recommended dump type and registry values.
.\configure-dumps.ps1 -DataFile '<path-to-configuration-json>'

# Report current settings without changing them.
.\configure-dumps.ps1 -VerifyOnly -DataFile '<path-to-configuration-json>'

# Override the dump type with a key present in the configuration.
.\configure-dumps.ps1 -DumpType '<configured-dump-type-key>' -DataFile '<path-to-configuration-json>'
```

### Apply mode

1. Reads and parses the configuration and validates the selected dump-type name.
2. Builds the desired registry values from `recommended.values`, replacing `CrashDumpEnabled` with the selected type's numeric value.
3. Requires an Administrator token; otherwise emits failure JSON and exits with code 3.
4. Sets `rebootRequired` according to whether the current `CrashDumpEnabled` differs from the selected value before writing.
5. Creates the configured registry path if needed.
6. Removes any existing `DedicatedDumpFile` value, then writes all desired values. Strings use ExpandString and numeric values use DWORD. **If the recommendation includes `DedicatedDumpFile`, the write loop recreates it.** Keep the recommendation aligned with the golden-image policy if the post-reboot checks must pass.
7. If `C:\Temp\nmf\notmyfaultc64.exe` is missing, attempts to download the Sysinternals NotMyFault archive using TLS 1.2, extract it, delete the archive, and unblock the executable. Errors in this staging block are swallowed by design. The script does not execute NotMyFault or trigger a crash.
8. Reads the desired registry values back, compares them, reports pagefile configuration, and emits JSON.

### Verify-only mode

- Still requires the configuration and validates the dump-type name.
- Does not perform the Administrator check used by apply mode.
- Does not modify registry settings or stage NotMyFault.
- Sets `action` to `verified`, `applied` to `null`, and `rebootRequired` to `false`.
- Compares the live values against the selected desired configuration. Environment variables are expanded on both sides before comparison; missing values do not match.

### Pagefile reporting and reboot behavior

The script reads pagefile registry entries from the configured location and joins them with `; ` for reporting. For entries containing at least two numeric size fields, it keeps the last parsed maximum size. `pageFile.adequate` is true only when that maximum is greater than zero.

**This is not the golden-image size check.** It does not compare pagefile capacity to RAM plus 257 MB, check active kernel allocation, resize the pagefile, or verify free disk space. It does not reboot. `rebootRequired` tracks a change to `CrashDumpEnabled` in apply mode, not every change that could require a reboot; verify-only mode does not infer whether an earlier reboot is pending.

### JSON output and errors

The normal output is one JSON object with:

| Field | Meaning |
|---|---|
| `ok` | `true` when execution reaches the normal output block; not proof that settings match or a dump can be written. |
| `action` | `applied` or `verified`. |
| `requestedDumpType` | The selected configuration key. |
| `applied` | Desired values written in apply mode; `null` in verify-only mode. |
| `current` | Live registry values for the desired keys. |
| `matchesRecommended` | Whether all desired keys match, including the selected dump-type override. |
| `rebootRequired` | Whether apply mode detected a different `CrashDumpEnabled` before writing. |
| `pageFile.configured` | Configured pagefile entries joined by `; `, or `null`. |
| `pageFile.adequate` | Whether the pagefile parsing rule above found a positive maximum size. |

An unknown dump type emits `{ "ok": false, "error": "...", "script": "configure-dumps.ps1" }` and exits with code 2. A non-elevated apply attempt emits the same failure shape and exits with code 3. A missing configuration is a terminating error; other uncaught parsing or registry errors are not wrapped by the explicit failure-JSON helper.

A settings mismatch or inadequate pagefile does not itself cause an explicit failure exit: inspect `matchesRecommended` and `pageFile.adequate`, not only `ok`. Likewise, successful normal output does not establish that the best-effort NotMyFault staging succeeded.
