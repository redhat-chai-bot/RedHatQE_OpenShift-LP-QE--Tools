# Windows Golden-Image and Crash-Dump Scripts

This README documents only these three PowerShell scripts:

- `golden-image-pre-reboot.ps1` — prepares the Windows guest and forces a reboot.
- `golden-image-post-reboot.ps1` — checks the guest after reboot, before image sealing.
- `validate-crash-settings.ps1` — compares the guest's crash-dump settings with configuration, read-only, and stages the latest NotMyFault for intentional runs.

The descriptions below document what the scripts in this directory do; they do not constitute a successful Windows execution or crash-dump test.

## Requirements and Execution Order

- Run the golden-image pair inside the Windows guest from an elevated PowerShell session, in the order shown below.
- `validate-crash-settings.ps1` changes no settings. Only the golden-image pair configures (pre-reboot) and verifies (post-reboot) them.
- The pre-reboot script uses Windows disk-image, driver-management, service, registry, and CIM operations. Its preferred VirtIO driver paths are for Windows 11 AMD64; it falls back to a recursive AMD64 INF search.
- The pre-reboot script reads the guest's physical memory size first and stops with exit code 1, before any change, if it cannot be read or is not positive.
- The pre-reboot script needs network access to resolve and download the latest VirtIO ISO (a cached copy is reused only when it is that same latest release and matches its recorded SHA-256). It stops with exit code 1, before installing anything or changing registry settings, if the latest ISO cannot be resolved, downloaded and recorded.
- `validate-crash-settings.ps1` requires a readable configuration JSON file. It downloads NotMyFault (network access) only with `-StageNotMyFault`, and then always fetches the current release; normal validation never downloads or stages anything.
- The pre-reboot script configures a pagefile sized to the RAM of the VM it runs on plus 257 MB. Ensure the guest's C: volume has room for it; the script does not check free disk space.
- VMs cloned from the golden image must not have more RAM than the VM that prepared it: `validate-crash-settings.ps1` computes the requirement from the RAM of the VM it runs on and then reports the page file as not adequate, which the host preflight rejects. Images prepared by older versions of these scripts (a 4096 MB page file and a `DedicatedDumpFile`) are not adequate either and must be rebuilt.
- The intended test flow does not restart a VM after a simulated crash, so the golden image is meant for disposable test VMs. The current `src/scripts/host/watch-crash.sh` still starts the VM again after extracting evidence unless it runs with `--no-restart`; aligning the watcher with the intended flow is a separate, planned change.

```powershell
# Step 1: Run as Administrator. This script forces a reboot at the end.
.\golden-image-pre-reboot.ps1

# Step 2: After reboot, run as Administrator before sealing the image.
.\golden-image-post-reboot.ps1
```

Do not seal if the post-reboot script reports `FAIL` or exits with code 1. It prints a sealing command after its checks pass and its cleanup succeeds, but does not execute that command itself.

`validate-crash-settings.ps1` is the run-time check the host preflight runs before arming a crash test, not a step of the golden-image pair; it never repairs a mismatch. Its desired values come from its configuration, so they can differ from the fixed golden-image settings.

## 1. golden-image-pre-reboot.ps1

### Purpose and interface

Part 1 of golden-image preparation. It has no declared parameters. Run it as Administrator before sealing the guest. Elevation is stated in the script instructions but is not checked explicitly by the script; a registry write that is denied stops the script with exit code 1.

**Warning:** On reaching the end, the script waits five seconds and calls `Restart-Computer -Force`. Save work before running it; there is no confirmation prompt or no-reboot switch.

### Actions, in order

1. Reads physical RAM through `Win32_ComputerSystem.TotalPhysicalMemory` and computes the page file size. A failed query or a missing, non-numeric or non-positive size reports `FAIL` and exits with code 1 before any of the following steps.
2. Creates `C:\Temp` if needed and adds TLS 1.2 to the protocols the process allows. `C:\Temp` is fixed on purpose: the ISO cache must survive the reboot and be found by the post-reboot script, which may run under another account than this one (a per-user `$env:TEMP` would differ).
3. Resolves the official alias `https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso` to the current release hop by hop over HTTPS on fedorapeople.org. The alias redirects to plain `http://`; only the host and path of such a location are used and they are requested over HTTPS. A redirect to another host or an error stops the script with exit code 1. No version or digest is hardcoded.
4. Reuses the cached `C:\Temp\virtio-win.iso` only when the record `C:\ProgramData\bsod-detector\virtio-win-iso.json` names that same resolved URL and the cache still matches the SHA-256 recorded there. Otherwise it downloads the latest ISO.
5. Removes the old record, then downloads the resolved HTTPS URL to `C:\Temp\virtio-win.iso.download` without following redirects (`Save-HTTPSdownload`, shared with `validate-crash-settings.ps1`; a redirect or any status other than 200 fails), calculates its SHA-256, dismounts an older cache that is still mounted, moves the download over the cache and writes the record (see "Latest virtio-win ISO and its record"). A failed download, hash, move or record write exits with code 1 before anything is installed; a partial download is deleted (best effort), and without a record the next run downloads again.
6. Mounts the ISO (an ISO still mounted by an interrupted run is reused); a failed mount or a missing drive letter reports `FAIL` and exits with code 1 before anything is installed. Runs the x86_64 QEMU Guest Agent MSI quietly, waiting for completion and requesting no installer-initiated restart. Exit codes 0, 1641 and 3010 are reported as success; any other code (or none) is reported as a warning, and the guest-agent service check in step 10 decides.
7. Attempts to install both VirtIO storage drivers with `pnputil /add-driver ... /install`:
   - VirtIO block: preferred relative path `viostor\w11\amd64\viostor.inf`.
   - VirtIO SCSI: preferred relative path `vioscsi\w11\amd64\vioscsi.inf`.
   - If a preferred path is missing, searches the ISO recursively for that INF filename and takes the first match whose full path contains `amd64`.
   - Exit codes 0, 1641 and 3010 are accepted as success (pnputil normally returns 0 or 3010); other codes are reported as warnings (the post-reboot script checks the driver store).
   - If no INF is found, prints a warning and skips that driver.
8. Notes that SATA uses the Windows inbox `storahci` driver; it does not install it.
9. Unmounts the ISO and keeps it in `C:\Temp` for re-runs, where it is reused only while it is the latest release and matches its recorded SHA-256. The post-reboot script removes it once all of its checks pass.
10. Checks for the `QEMU-GA` service, requests Automatic startup, and attempts to start it if it is not Running. After a start attempt, waits three seconds and queries the service again. A missing service or a service still not Running causes an explicit exit with code 1.
11. Writes the CrashControl settings listed below and removes the `DedicatedDumpFile` registry value if present (an absent value is left alone). A failed write reports `FAIL` and exits with code 1 before the page file change and the reboot. If an old `C:\DedicatedDump.sys` file exists, prints a warning without deleting it; the post-reboot script refuses to seal while it exists.
12. Writes the pagefile registry configuration listed below.
13. Waits five seconds and forces a reboot.

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
| `DedicatedDumpFile` | Removed | No dedicated-dump value is retained by this script |

### Pagefile configuration

Dumps are written through the page file only (no `DedicatedDumpFile`). Any system-managed or other page file configuration is replaced by one fixed page file:

- Uses the physical RAM read in step 1 (`Win32_ComputerSystem.TotalPhysicalMemory`).
- Calculates the size once with `Get-PagefileSizeMB`: `Round((RAM bytes + 257MB) / 1MB, 0)`. The post-reboot script and `validate-crash-settings.ps1` use the identical function with the RAM of the VM they run on: on the VM that prepared the image their minimum equals the configured size, while a VM with more RAM gets a larger requirement.
- If Windows manages the page file automatically, turns that off through the documented read/write `Win32_ComputerSystem.AutomaticManagedPagefile` property (`Set-CimInstance`).
- Replaces `PagingFiles` under `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management` with exactly one MultiString entry, `C:\pagefile.sys <sizeMB> <sizeMB>`, dropping any other entries.
- Uses equal initial and maximum sizes.
- Does not delete or create page files directly: Windows applies the configuration on reboot. The post-reboot script checks the running system.
- If the CIM change or the registry write fails, the script reports `FAIL` and exits with code 1 before the reboot.

### Latest virtio-win ISO and its record

The pre-reboot script always uses the release that the official `latest-virtio` alias currently points to. The virtio-win download site publishes no checksum or signature for the ISO (its `CHECKSUM` file lists only MD5 sums of the RPMs, and its yum repository uses `gpgcheck=0`). The SHA-256 is therefore calculated from the downloaded file and kept as an audit record of what was installed; it is not a publisher attestation, and authenticity rests on HTTPS to fedorapeople.org.

The record `C:\ProgramData\bsod-detector\virtio-win-iso.json` (schema 1) holds `artifact`, `source` (the alias), `resolvedSource` (the HTTPS release URL), `version` (from the release file name), `sha256`, `sizeBytes`, `verification` and `recordedUTC`. It stays in the image when the post-reboot script removes the ISO cache. The script assumes a single trusted operator on the guest during preparation (`C:\Temp` is writable by local users).

### Settings not managed by these scripts

- **pvpanic:** no guest pvpanic driver is installed or checked by the golden-image scripts. The pipeline entry script attempts, best effort and non-fatal, to hot-add the pvpanic device to the running VM through the QEMU monitor (`virsh qemu-monitor-command --hmp 'device_add pvpanic,id=pvpanic0'`): `src/scripts/crash-injector/trigger-bsod-intentional.sh` (a separately proposed pipeline runner may take over that step). Adding the device does not install a guest driver, and whether the KubeVirt Panicked event is raised without one has not been verified.
- **Boot recovery settings:** earlier proof-of-concept versions changed Windows boot recovery behavior (`bcdedit` boot-status policy, recovery and boot-menu options, `reagentc /disable`) and checked it after reboot. The scripts no longer change or check them and intentionally leave the Windows defaults, because the intended test flow does not restart a VM after a simulated crash. The current `src/scripts/host/watch-crash.sh` still starts the VM again after extracting evidence unless it runs with `--no-restart` (a watcher change is planned separately), and how a restarted VM behaves without these settings has not been verified.

### Validation limits

- The script reports installer exit codes but treats non-success codes as warnings; its final reboot is not proof that every operation succeeded. Use the post-reboot checks.
- It emits human-readable progress and errors, not a structured JSON report.

## 2. golden-image-post-reboot.ps1

### Purpose and interface

Part 2 of golden-image preparation. It has no declared parameters. Run it as Administrator after the reboot from part 1 and before sealing.

This is primarily a verification script. It also requests Automatic startup for the QEMU Guest Agent service and, only after every check passes, removes the pre-reboot ISO cache files. It does not attempt to start a stopped service, resize the pagefile, reinstall drivers, fix CrashControl values, or delete an old `C:\DedicatedDump.sys`. It sets `$ErrorActionPreference` to `Continue`, so every check runs and reports even when the caller prefers `Stop`.

### Active checks

1. **QEMU Guest Agent:** Requests Automatic startup and checks whether the service is Running. A missing (`not installed`) or stopped service marks failure. The startup-type update suppresses errors; there is no separate read-back verification of startup type.
2. **Storage drivers:** Checks the online driver store for entries whose original filenames contain `viostor` and `vioscsi`. Checks whether the inbox SATA driver exists. Missing drivers generate `WARN` messages rather than marking failure. The warnings note that the matching disk bus may not boot without its driver; a warning is not assurance that every disk bus is supported.
3. **CrashControl DWORDs:** Compares these five values against the golden-image expectations: `CrashDumpEnabled=7`, `AutoReboot=0`, `AlwaysKeepMemoryDump=1`, `Overwrite=1`, and `LogEvent=1`. Any mismatch marks failure.
4. **Dedicated dump setting:** Reads `DedicatedDumpFile`. A nonempty value marks failure; a missing or empty value follows the success branch. The stated golden-image policy is for the value to be absent.
5. **Old dedicated dump file:** If `C:\DedicatedDump.sys`, created by older preparation scripts, still exists, marks failure: the file is unused but would be sealed into the image. The script does not delete it; remove it manually once the `DedicatedDumpFile` value is gone and the VM has rebooted (Windows can hold the file open until then), and re-run.
6. **virtio-win ISO record:** Reads `C:\ProgramData\bsod-detector\virtio-win-iso.json`. A missing record, or one without an HTTPS `resolvedSource` and a SHA-256, marks failure; otherwise prints the source, version and SHA-256. The record is not removed by the cleanup.
7. **Pagefile management:** Reads `Win32_ComputerSystem` with `-ErrorAction Stop`. A failed query or a missing or non-positive `TotalPhysicalMemory` marks failure, and neither pagefile check can then pass. Otherwise automatic management still enabled marks failure. This reads the same CIM property the pre-reboot script sets.
8. **Active pagefile:** Reads `Win32_PageFileUsage` for C: entries and checks that `AllocatedBaseSize` is at least `Get-PagefileSizeMB` of the RAM — the same `Round((RAM bytes + 257MB) / 1MB, 0)` the pre-reboot script configured. Reports allocation and current usage on success. An undersized or missing active pagefile marks failure.

### Result, cleanup and sealing

- `OK` lines describe checks that passed.
- `WARN` lines do not set the script's failure flag.
- If any active check sets that flag, the script prints `DO NOT SEAL` and explicitly exits with code 1, instructing the operator to fix the issues (re-running part 1 if needed) and re-run this script. The ISO cache is kept for that re-run.
- If no check sets the flag, it removes the pre-reboot cache files, using only these literal paths: `C:\Temp\virtio-win.iso` and `C:\Temp\virtio-win.iso.download`.
  - A missing file is already clean, so running the script again is safe.
  - A still-mounted ISO is not removed and is reported as `FAIL`.
  - Any removal error (for example a file in use) is reported as `FAIL`.
  - If any file remains, the script prints `DO NOT SEAL` and exits with code 1; no sealing message is printed.
- Only when every check passed and the cleanup succeeded does it print `All checks passed` and the following command:

```powershell
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /quiet
```

The command is printed only. Sealing remains a separate operator action.

### Verification boundaries

- No pvpanic or boot recovery check is performed (see "Settings not managed by these scripts").
- `DumpFile` is written by part 1 but is not checked by this script.
- It does not verify that configured pagefile initial and maximum sizes match; it checks automatic-management state and the active allocation threshold.
- It does not trigger a BSOD, verify a generated dump, or produce JSON. Passing these checks is not an end-to-end crash-dump validation.

## 3. validate-crash-settings.ps1

### Purpose

Read-only run-time check of the guest's crash-dump settings, run by the host `preflight-rhov.sh` before a crash test is armed. It compares `crash-control.json` with the live registry and reports every difference. It never writes the registry, CIM or page file, never repairs a mismatch, and never reboots or crashes the guest. The golden-image pair owns the configuration: part 1 writes it and part 2 verifies it before sealing.

### Parameters

| Parameter | Meaning |
|---|---|
| `-DumpType <string>` | Validates against another key of the configuration's `crashDumpTypes`. Defaults to `recommended.crashDumpType`. |
| `-StageNotMyFault` | For an intentional crash run only: downloads and stages the current NotMyFault (see below). Off by default; normal validation never downloads or stages anything. |
| `-DataFile <string>` | Path to the required configuration JSON. Supply it when running outside the expected repository layout. |

**Configuration dependency:** The script expects `crash-control.json`. Without `-DataFile`, it resolves three levels above its script directory and looks for `src\data\crash-control.json`. The configuration supplies `registryPath`, `recommended.crashDumpType`, `recommended.values`, `recommended.absentValues`, `crashDumpTypes.<selected type>.CrashDumpEnabled`, and `pageFile.path` / `pageFile.value`. The configuration file is [`src/data/crash-control.json`](../../data/crash-control.json); it is data, not an additional script.

### Usage

These examples use a placeholder path that must be replaced with the actual configuration location:

```powershell
# Compare the live settings with the configuration's recommendation (read-only).
.\validate-crash-settings.ps1 -DataFile '<path-to-configuration-json>'

# Compare against another dump type present in the configuration.
.\validate-crash-settings.ps1 -DumpType '<configured-dump-type-key>' -DataFile '<path-to-configuration-json>'

# Intentional crash run: also stage the latest NotMyFault.
.\validate-crash-settings.ps1 -StageNotMyFault -DataFile '<path-to-configuration-json>'
```

### Checks

1. Reads and parses the configuration and validates the selected dump-type name.
2. Builds the desired values from `recommended.values`, replacing `CrashDumpEnabled` with the selected type's value. A `DedicatedDumpFile` entry, which an older configuration may still contain, is not a desired value; it is checked as a required absence and a `WARN` line goes to stderr.
3. Reports the registry key as `key missing` if `registryPath` does not exist.
4. For every desired value, reports `missing`, `wrong type` (strings must be ExpandString and numbers DWord, as the golden image writes them) or `wrong value` (environment variables are expanded on both sides before comparing).
5. Reports every name in `recommended.absentValues`, and always `DedicatedDumpFile`, as `must be absent` when it exists.
6. Reports page file adequacy (below).

A mismatch does not change the exit code: the JSON reports it, and `preflight-rhov.sh` stops the run when `matchesRecommended` is false, `AutoReboot` is not 0 or the page file is not adequate. The fix is to rebuild or correct the golden image; nothing is changed at run time.

### NotMyFault staging (`-StageNotMyFault`)

- Removes any earlier `C:\Temp\nmf\notmyfaultc64.exe` first; an existing copy is never reused.
- Resolves `https://download.sysinternals.com/files/NotMyFault.zip` over HTTPS (a redirect may only stay on that host), downloads it and extracts it.
- Requires a valid Authenticode signature on `notmyfaultc64.exe` whose signer's organization is exactly `Microsoft Corporation`. An untrusted or missing executable is deleted, never staged.
- Moves the verified executable to `C:\Temp\nmf\notmyfaultc64.exe` and removes the archive and extraction folder.
- Reports `source`, `resolvedSource`, `archiveSHA256`, `sha256` (of the executable), `version` (file version), `signer` and `stagedPath`. No hash is published for NotMyFault: the SHA-256 values record what was downloaded; the signature is the publisher check.
- Never runs NotMyFault, crashes or reboots the guest. A staging failure emits failure JSON and exits with code 4; the host preflight then stops the run.

The host `preflight-rhov.sh` passes `-StageNotMyFault` only with `--require-trigger` and records the reported values in `recovery-metadata.json` (`artifacts.notMyFault`). Watch runs do not pass it.

### Pagefile reporting

The script reads the pagefile registry entries from the configured location and joins them with `; ` for reporting. It reads physical RAM and computes `pageFile.requiredMB` with `Get-PagefileSizeMB`, the golden-image size. `pageFile.adequate` is true only when an entry on `C:` has initial and maximum sizes of at least `requiredMB`; system-managed (`?:\pagefile.sys` or `0 0` sizes), missing, smaller or other-drive page files, and an unreadable, missing or non-positive RAM size, report `false`. `requiredMB` follows the RAM of the VM being checked, so a VM with more RAM than the golden image was prepared with reports `false`. The script does not resize the pagefile or check the active kernel allocation.

### JSON output and errors

The normal output is one JSON object with:

| Field | Meaning |
|---|---|
| `ok` | `true` when execution reaches the normal output block; not proof that settings match. |
| `action` | Always `validated`. |
| `script` | `validate-crash-settings.ps1`. |
| `requestedDumpType` | The selected configuration key. |
| `registryPath` | The CrashControl key that was read. |
| `desired` | Values the configuration requires. |
| `current` | Live values for the desired keys and the required absences (`null` when missing). |
| `mismatches` | One entry per difference: `name`, `issue` (`key missing`, `missing`, `wrong type`, `wrong value`, `must be absent`), `expected`, `actual`, `expectedType`, `actualType`. |
| `matchesRecommended` | `true` when `mismatches` is empty. |
| `pageFile.configured` | Configured pagefile entries joined by `; `, or `null`. |
| `pageFile.adequate` | Boolean, see above. |
| `pageFile.requiredMB` | RAM + 257 MB in MB, or `null` when RAM cannot be read or is not positive. |
| `notMyFault` | `{ "status": "not requested" }` without `-StageNotMyFault`; otherwise the staging record above. |

An unknown dump type emits `{ "ok": false, "error": "...", "script": "validate-crash-settings.ps1" }` and exits with code 2; a failed NotMyFault staging emits the same failure shape and exits with code 4. A missing configuration is a terminating error.
