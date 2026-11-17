# Windows Golden-Image and Crash-Dump Scripts

This README documents only these three PowerShell scripts:

- `golden-image-pre-reboot.ps1` — prepares the Windows guest and forces a reboot.
- `golden-image-post-reboot.ps1` — checks the guest after reboot, before image sealing.
- `configure-dumps.ps1` — applies or reports configuration-driven crash-dump settings.

The descriptions below document what the scripts in this directory do; they do not constitute a successful Windows execution or crash-dump test.

## Requirements and Execution Order

- Run the golden-image pair inside the Windows guest from an elevated PowerShell session, in the order shown below.
- Applying settings with `configure-dumps.ps1` also requires Administrator privileges. Its `-VerifyOnly` mode does not enforce elevation.
- The pre-reboot script uses Windows disk-image, driver-management, service, registry, and CIM operations. Its preferred VirtIO driver paths are for Windows 11 AMD64; it falls back to a recursive AMD64 INF search.
- The pre-reboot script needs network access to download the VirtIO ISO unless a cached copy is already present in `C:\Temp`. It stops with exit code 1, before installing anything or changing registry settings, if no ISO can be obtained.
- `configure-dumps.ps1` requires a readable configuration JSON file. It downloads NotMyFault (network access, best effort) only in apply mode with `-StageNotMyFault` and only if the executable is missing; watch runs, default apply and `-VerifyOnly` never download.
- The pre-reboot script configures a pagefile sized to guest RAM plus 257 MB. Ensure the guest's C: volume has room for it; the script does not check free disk space.
- These scripts prepare the golden image for disposable test VMs: each pytest run tears down its VM, so a VM is not reused after a crash.

```powershell
# Step 1: Run as Administrator. This script forces a reboot at the end.
.\golden-image-pre-reboot.ps1

# Step 2: After reboot, run as Administrator before sealing the image.
.\golden-image-post-reboot.ps1
```

Do not seal if the post-reboot script reports `FAIL` or exits with code 1. It prints a sealing command after its checks pass and its cleanup succeeds, but does not execute that command itself.

`configure-dumps.ps1` is a separate apply/verify operation, not an additional mandatory step in the golden-image pair. Its desired values come from its configuration, so they can differ from the fixed golden-image settings.

## 1. golden-image-pre-reboot.ps1

### Purpose and interface

Part 1 of golden-image preparation. It has no declared parameters. Run it as Administrator before sealing the guest. Elevation is stated in the script instructions but is not checked explicitly by the script.

**Warning:** On reaching the end, the script waits five seconds and calls `Restart-Computer -Force`. Save work before running it; there is no confirmation prompt or no-reboot switch.

### Actions, in order

1. Creates `C:\Temp` if needed and adds TLS 1.2 to the protocols the process allows. `C:\Temp` is fixed on purpose: the ISO cache must survive the reboot and be found by the post-reboot script, which may run under another account than this one (a per-user `$env:TEMP` would differ).
2. Sends an HTTP HEAD request to the VirtIO ISO endpoint:
   `https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso`.
   If the request fails, it prints a warning and treats the remote timestamp as unknown.
3. Decides whether to download, using the cached `C:\Temp\virtio-win.iso`:
   - no cached copy: download;
   - remote `Last-Modified` newer than the cached copy: download;
   - cached copy at least as recent, or remote timestamp unknown: reuse the cache.

   This is a timestamp comparison, not a checksum or driver-version check.
4. Downloads with `.NET WebClient` to `C:\Temp\virtio-win.iso.download` and moves it over the cache only after a complete transfer. On a failed download, deletion of the partial file is attempted; the script then continues with the existing cache (warning) or, without a cache, exits with code 1 before any further change.
5. Mounts the ISO and runs the x86_64 QEMU Guest Agent MSI quietly, waiting for completion and requesting no installer-initiated restart. Exit codes 0, 1641 and 3010 are reported as success; any other code (or none) is reported as a warning, and the guest-agent service check in step 9 decides.
6. Attempts to install both VirtIO storage drivers with `pnputil /add-driver ... /install`:
   - VirtIO block: preferred relative path `viostor\w11\amd64\viostor.inf`.
   - VirtIO SCSI: preferred relative path `vioscsi\w11\amd64\vioscsi.inf`.
   - If a preferred path is missing, searches the ISO recursively for that INF filename and takes the first match whose full path contains `amd64`.
   - Exit codes 0, 1641 and 3010 are accepted as success (pnputil normally returns 0 or 3010); other codes are reported as warnings (the post-reboot script checks the driver store).
   - If no INF is found, prints a warning and skips that driver.
7. Notes that SATA uses the Windows inbox `storahci` driver; it does not install it.
8. Unmounts the ISO and keeps it in `C:\Temp` for the timestamp check if the script is re-run. The post-reboot script removes it once all of its checks pass.
9. Checks for the `QEMU-GA` service, requests Automatic startup, and attempts to start it if stopped. After a start attempt, waits three seconds and refreshes the service status. A missing service or a service still not Running causes an explicit exit with code 1.
10. Writes the CrashControl settings listed below and removes the `DedicatedDumpFile` registry value if present.
11. Writes the pagefile registry configuration listed below.
12. Waits five seconds and forces a reboot.

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

Dumps are written through the page file only (no `DedicatedDumpFile`). Any system-managed or other page file configuration is replaced by one fixed page file:

- Reads physical RAM through `Win32_ComputerSystem.TotalPhysicalMemory`.
- Calculates the size once with `Get-PagefileSizeMB`: `Round((RAM bytes + 257MB) / 1MB, 0)`. The post-reboot script and `configure-dumps.ps1` use the identical function, so the post-reboot minimum and the reported requirement always equal the configured size.
- If Windows manages the page file automatically, turns that off through the documented read/write `Win32_ComputerSystem.AutomaticManagedPagefile` property (`Set-CimInstance`).
- Replaces `PagingFiles` under `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management` with exactly one MultiString entry, `C:\pagefile.sys <sizeMB> <sizeMB>`, dropping any other entries.
- Uses equal initial and maximum sizes.
- Does not delete or create page files directly: Windows applies the configuration on reboot. The post-reboot script checks the running system.
- If either step fails, the script reports `FAIL` and exits with code 1 before the reboot.

### Settings not managed by these scripts

- **pvpanic:** no guest pvpanic driver is installed or checked by the golden-image scripts. The pipeline entry script attempts, best effort and non-fatal, to hot-add the pvpanic device to the running VM through the QEMU monitor (`virsh qemu-monitor-command --hmp 'device_add pvpanic,id=pvpanic0'`): `src/scripts/crash-injector/trigger-bsod-intentional.sh`, or `src/scripts/bsod-pipeline/bsod-runner.sh` after the pipeline rename. Adding the device does not install a guest driver, and whether the KubeVirt Panicked event is raised without one has not been verified.
- **Boot recovery settings:** earlier proof-of-concept versions changed Windows boot recovery behavior (`bcdedit` boot-status policy, recovery and boot-menu options, `reagentc /disable`) and checked it after reboot. These settings are no longer required in this disposable-VM workflow, because each pytest run tears down its VM; the scripts neither change nor check them.

### Validation limits

- The script reports installer exit codes but treats non-success codes as warnings; its final reboot is not proof that every operation succeeded. Use the post-reboot checks.
- It emits human-readable progress and errors, not a structured JSON report.

## 2. golden-image-post-reboot.ps1

### Purpose and interface

Part 2 of golden-image preparation. It has no declared parameters. Run it as Administrator after the reboot from part 1 and before sealing.

This is primarily a verification script. It also requests Automatic startup for the QEMU Guest Agent service and, only after every check passes, removes the pre-reboot ISO cache files. It does not attempt to start a stopped service, resize the pagefile, reinstall drivers, or fix CrashControl values.

### Active checks

1. **QEMU Guest Agent:** Requests Automatic startup and checks whether the service is Running. A missing (`not installed`) or stopped service marks failure. The startup-type update suppresses errors; there is no separate read-back verification of startup type.
2. **Storage drivers:** Checks the online driver store for entries whose original filenames contain `viostor` and `vioscsi`. Checks whether the inbox SATA driver exists. Missing drivers generate `WARN` messages rather than marking failure. The warnings note that the matching disk bus may not boot without its driver; a warning is not assurance that every disk bus is supported.
3. **CrashControl DWORDs:** Compares these five values against the golden-image expectations: `CrashDumpEnabled=7`, `AutoReboot=0`, `AlwaysKeepMemoryDump=1`, `Overwrite=1`, and `LogEvent=1`. Any mismatch marks failure.
4. **Dedicated dump setting:** Reads `DedicatedDumpFile`. A nonempty value marks failure; a missing or empty value follows the success branch. The stated golden-image policy is for the value to be absent.
5. **Pagefile management:** Reads `Win32_ComputerSystem.AutomaticManagedPagefile`. Automatic management still enabled marks failure. This reads the same CIM property the pre-reboot script sets.
6. **Active pagefile:** Reads `Win32_PageFileUsage` for C: entries and checks that `AllocatedBaseSize` is at least `Get-PagefileSizeMB` of the RAM — the same `Round((RAM bytes + 257MB) / 1MB, 0)` the pre-reboot script configured. Reports allocation and current usage on success. An undersized or missing active pagefile marks failure.

### Result, cleanup and sealing

- `OK` lines describe checks that passed.
- `WARN` lines do not set the script's failure flag.
- If any active check sets that flag, the script prints `DO NOT SEAL` and explicitly exits with code 1, instructing the operator to fix issues and rerun part 1. The ISO cache is kept for that re-run.
- If no check sets the flag, it removes the pre-reboot cache files, using only these literal paths: `C:\Temp\virtio-win.iso` and `C:\Temp\virtio-win.iso.download`.
  - A missing file is already clean, so running the script again is safe.
  - A still-mounted ISO is not removed and is reported as `FAIL`.
  - Any removal error (for example a file in use) is reported as `FAIL`.
  - If any file remains, the script prints `DO NOT SEAL` and exits with code 1; no sealing message is printed.
- Only when every check passed and the cleanup succeeded does it print `All checks passed` and the following command:

```powershell
sysprep /generalize /oobe /shutdown /quiet
```

The command is printed only. Sealing remains a separate operator action.

### Verification boundaries

- No pvpanic or boot recovery check is performed (see "Settings not managed by these scripts").
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
| `-VerifyOnly` | Reads and compares current settings without registry changes or NotMyFault staging, even with `-StageNotMyFault`. |
| `-StageNotMyFault` | Apply mode only: stage NotMyFault in `C:\Temp\nmf` for an intentional crash run. Off by default. |
| `-DataFile <string>` | Path to the required configuration JSON. Supply it when running outside the expected repository layout. |

**Configuration dependency:** The script expects `crash-control.json`. Without `-DataFile`, it resolves three levels above its script directory and looks for `src\data\crash-control.json`. The configuration supplies `registryPath`, `recommended.crashDumpType`, `recommended.values`, `crashDumpTypes.<selected type>.CrashDumpEnabled`, and `pageFile.path` / `pageFile.value`. The configuration file is [`src/data/crash-control.json`](../../data/crash-control.json); it is data, not an additional script.

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
4. Sets `rebootRequired` when the current `CrashDumpEnabled` differs from the selected value or a `DedicatedDumpFile` value is present; both take effect only after a reboot.
5. Creates the configured registry path if needed.
6. Removes any existing `DedicatedDumpFile` value (dumps go through the page file only; `crash-control.json` no longer recommends it), then writes all desired values. Strings use ExpandString and numeric values use DWORD.
7. Only with `-StageNotMyFault`: if `C:\Temp\nmf\notmyfaultc64.exe` is missing, downloads the Sysinternals NotMyFault archive (adding TLS 1.2 to the allowed protocols), extracts it, deletes the archive, and unblocks the executable. `C:\Temp\nmf` is the fixed path the host preflight and pipeline scripts check through the guest agent. A failure is written to stderr as a `WARN` line and does not change the JSON on stdout. Without the switch nothing is downloaded. The script does not execute NotMyFault or trigger a crash.

   The host `preflight-rhov.sh` passes `-StageNotMyFault` only when it runs with `--require-trigger`, and then requires the binary to exist, so a failed staging stops an intentional run. An intentional run must therefore call preflight with `--require-trigger`; the new pipeline runner (`src/scripts/bsod-pipeline/bsod-runner.sh`) does not pass it yet, and its update is pending. Watch runs do not pass it, so nothing is staged.
8. Reads the desired registry values back, compares them, reports pagefile configuration, and emits JSON.

### Verify-only mode

- Still requires the configuration and validates the dump-type name.
- Does not perform the Administrator check used by apply mode.
- Does not modify registry settings, download anything, or stage NotMyFault.
- Sets `action` to `verified`, `applied` to `null`, and `rebootRequired` to `false`.
- Compares the live values against the selected desired configuration. Environment variables are expanded on both sides before comparison; missing values do not match.

### Pagefile reporting and reboot behavior

The script reads pagefile registry entries from the configured location and joins them with `; ` for reporting. It reads physical RAM (read-only) and computes `pageFile.requiredMB` with `Get-PagefileSizeMB`, the golden-image size. `pageFile.adequate` is true only when an entry on `C:` has initial and maximum sizes of at least `requiredMB` (a dump is written into the space allocated at boot); system-managed (`?:\pagefile.sys` or `0 0` sizes), missing, smaller or other-drive page files, and an unreadable RAM size, report `false` (never `null`; the host preflight requires `true`). `requiredMB` follows the RAM of the VM being checked, so a VM with more RAM than the golden image was prepared with reports `false`.

The script does not resize the pagefile (that belongs to `golden-image-pre-reboot.ps1`), check active kernel allocation, or verify free disk space. It does not reboot. Verify-only mode reports `rebootRequired` as `false` and does not infer whether an earlier reboot is pending.

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
| `rebootRequired` | Whether apply mode detected a different `CrashDumpEnabled` or removed a `DedicatedDumpFile` value. |
| `pageFile.configured` | Configured pagefile entries joined by `; `, or `null`. |
| `pageFile.adequate` | Boolean: a `C:` entry with initial and maximum sizes of at least `requiredMB` is configured (see above). |
| `pageFile.requiredMB` | RAM + 257 MB in MB (`Get-PagefileSizeMB`), or `null` when RAM cannot be read. |

An unknown dump type emits `{ "ok": false, "error": "...", "script": "configure-dumps.ps1" }` and exits with code 2. A non-elevated apply attempt emits the same failure shape and exits with code 3. A missing configuration is a terminating error; other uncaught parsing or registry errors are not wrapped by the explicit failure-JSON helper.

A settings mismatch or inadequate pagefile does not itself cause an explicit failure exit: inspect `matchesRecommended` and `pageFile.adequate`, not only `ok`. Likewise, successful normal output does not establish that the best-effort NotMyFault staging succeeded; check stderr for its `WARN` line.
