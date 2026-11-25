# Windows Golden-Image and Crash-Dump Scripts

This README documents three guest PowerShell scripts as implemented in open, unmerged pull requests (see "Status"):

- `golden-image-pre-reboot.ps1` — prepares the Windows guest and forces a reboot.
- `golden-image-post-reboot.ps1` — checks the guest after reboot, before image sealing.
- `validate-crash-settings.ps1` — compares the guest's crash-dump settings with configuration, read-only, and stages the latest NotMyFault for intentional runs.

The descriptions were checked against the code; they do not constitute a successful Windows execution or crash-dump test.

## Status: pending pull requests and the scripts in this directory

Everything after this section describes these revisions, not the files currently in this directory:

| Script | Documented revision | In this directory (`feat/add-bsod-detector`) |
|---|---|---|
| `golden-image-pre-reboot.ps1` | [#10][pr10] at [`cd6ecbe`][pre10] | Older version, see below |
| `golden-image-post-reboot.ps1` | [#9][pr9] at [`6a82282`][post9] | Older version, see below |
| `validate-crash-settings.ps1` | [#8][pr8] at [`524927b`][val8] | Not present; `configure-dumps.ps1` instead |

Until those pull requests merge, the scripts here behave as follows (the sections below do not apply to them):

- `golden-image-pre-reboot.ps1` downloads the latest virtio-win ISO with `WebClient` to `C:\Temp` and deletes it after use, installs the guest agent and storage drivers without checking exit codes, installs the pvpanic driver if the ISO has one, disables boot recovery (`bcdedit`, `reagentc /disable`), writes `MinidumpDir` and `DedicatedDumpFile` = `C:\DedicatedDump.sys` with the other CrashControl values, only then reads RAM to pre-allocate `C:\DedicatedDump.sys` (RAM + 1 MB), registers a fixed 4096 MB `C:\pagefile.sys` unless a setting for it already exists, and reboots after five seconds.
- `golden-image-post-reboot.ps1` runs nine checks, which fail without `DedicatedDumpFile` = `C:\DedicatedDump.sys`, a non-empty `C:\DedicatedDump.sys` or the `bootstatuspolicy` and `recoveryenabled` settings (missing pvpanic or storage drivers only warn). On success it prints that the image is safe to seal; it prints no sealing command and cleans up nothing.
- `configure-dumps.ps1` writes `recommended.values` from `crash-control.json` (including `MinidumpDir` and `DedicatedDumpFile`, whose file it pre-allocates) unless run with `-VerifyOnly`. Its parameters are `-DumpType`, `-VerifyOnly` and `-DataFile`. Its JSON holds `ok`, `action` (`applied` or `verified`), `requestedDumpType`, `applied`, `current`, `matchesRecommended`, `rebootRequired` and `pageFile` (`configured`, `adequate`); it emits `ok: false` with exit code 2 for an unknown dump type and 3 when it would write without elevation.
- `src/scripts/host/preflight-rhov.sh` uploads `configure-dumps.ps1` with `crash-control.json`, runs it with `-DataFile` (so it applies the settings) and requires `ok`, `matchesRecommended`, `current.AutoReboot` = 0, `pageFile.adequate` and `rebootRequired` = false. No host script calls `validate-crash-settings.ps1`.

### Merge dependencies

- #10 and #9 must land together: the current post-reboot script fails an image prepared by #10 (it requires `DedicatedDumpFile`, its file and the boot-recovery settings, which #10 no longer sets), and #9 fails an image prepared by the current pre-reboot script (it requires `DedicatedDumpFile` to be absent).
- #8 and a host caller migration must land together: #8 deletes `configure-dumps.ps1`, which the current preflight runs (and its JSON has no `rebootRequired`), while open pull request [#39][pr39], which has not landed, moves the preflight to `validate-crash-settings.ps1`, which only #8 adds.
- The validator rejects images prepared by the current pre-reboot script (it requires `DedicatedDumpFile` to be absent), so validated runs also need images rebuilt with #10 and #9.
- The current `crash-control.json` still lists `MinidumpDir` and `DedicatedDumpFile` in `recommended.values` and has no `recommended.absentValues`. Open pull request [#57][pr57] proposes removing both and adding `absentValues: ["DedicatedDumpFile"]`; without it the validator still compares `MinidumpDir` (see section 3).

[pr8]: https://github.com/redhat-chai-bot/RedHatQE_OpenShift-LP-QE--Tools/pull/8
[pr9]: https://github.com/redhat-chai-bot/RedHatQE_OpenShift-LP-QE--Tools/pull/9
[pr10]: https://github.com/redhat-chai-bot/RedHatQE_OpenShift-LP-QE--Tools/pull/10
[pr39]: https://github.com/redhat-chai-bot/RedHatQE_OpenShift-LP-QE--Tools/pull/39
[pr57]: https://github.com/redhat-chai-bot/RedHatQE_OpenShift-LP-QE--Tools/pull/57
[pre10]: https://github.com/redhat-chai-bot/RedHatQE_OpenShift-LP-QE--Tools/blob/cd6ecbee4af9c27874e1fc16d066b063fda05ce7/apps/bsod-detector/src/scripts/guest/golden-image-pre-reboot.ps1
[post9]: https://github.com/redhat-chai-bot/RedHatQE_OpenShift-LP-QE--Tools/blob/6a82282ef8160444b20fd23a024c51a55be22135/apps/bsod-detector/src/scripts/guest/golden-image-post-reboot.ps1
[val8]: https://github.com/redhat-chai-bot/RedHatQE_OpenShift-LP-QE--Tools/blob/524927b7ca684e8d6cddadd32e4c2dcd4176652b/apps/bsod-detector/src/scripts/guest/validate-crash-settings.ps1

## Requirements and Execution Order

- Run the golden-image pair inside the Windows guest from an elevated PowerShell session, in the order shown below.
- `validate-crash-settings.ps1` changes no settings. Only the golden-image pair configures (pre-reboot) and verifies (post-reboot) them.
- The pre-reboot script uses Windows disk-image, driver-management, service, registry, and CIM operations. Its preferred VirtIO driver paths are for Windows 11 AMD64; it falls back to a recursive AMD64 INF search.
- The pre-reboot script reads the guest's physical memory size first and stops with exit code 1, before any change, if it cannot be read or is not positive.
- The pre-reboot script needs network access to resolve and download the latest VirtIO ISO on every run; no earlier copy is reused. It stops with exit code 1, before any CrashControl or page file change, if the ISO cannot be resolved, downloaded or mounted, or if its download directory cannot be removed afterwards.
- `validate-crash-settings.ps1` requires a readable configuration JSON file. It downloads NotMyFault (network access) only with `-stageNotMyFault`, and then always fetches the current release; normal validation never downloads or stages anything.
- The pre-reboot script configures a pagefile sized to the RAM of the VM it runs on plus 257 MB. Ensure the guest's C: volume has room for it; the script does not check free disk space.
- VMs cloned from the golden image must not have more RAM than the VM that prepared it: `validate-crash-settings.ps1` computes the requirement from the RAM of the VM it runs on and then reports the page file as not adequate (`pageFile.adequate` is false), which callers should treat as a failure. Images prepared by the current scripts in this directory fail it too: `DedicatedDumpFile` is reported as `must be absent`, and the 4096 MB page file they configure is smaller than RAM + 257 MB on any VM with 4 GB of RAM or more. Such images must be rebuilt.
- The intended test flow does not restart a VM after a simulated crash, so the golden image is meant for disposable test VMs. The current `src/scripts/host/watch-crash.sh` still starts the VM again after extracting evidence unless it runs with `--no-restart`; aligning the watcher with the intended flow is a separate, planned change.

```powershell
# Step 1: Run as Administrator. This script forces a reboot at the end.
.\golden-image-pre-reboot.ps1

# Step 2: After reboot, run as Administrator before sealing the image.
.\golden-image-post-reboot.ps1
```

Do not seal if the post-reboot script reports `FAIL` or exits with code 1. It prints a sealing command after all of its checks pass, but does not execute that command itself.

`validate-crash-settings.ps1` is a run-time check meant for a host caller to run before arming a crash test, not a step of the golden-image pair; it never repairs a mismatch. Its desired values come from its configuration, so they can differ from the fixed golden-image settings (see section 3).

## 1. golden-image-pre-reboot.ps1

### Purpose and interface

Part 1 of golden-image preparation. It has no declared parameters. Run it as Administrator before sealing the guest. Elevation is stated in the script instructions but is not checked explicitly by the script; a registry write that is denied stops the script with exit code 1.

**Warning:** On reaching the end, the script calls `Restart-Computer -Force` without a delay. Save work before running it; there is no confirmation prompt or no-reboot switch.

### Actions, in order

1. Reads physical RAM through `Win32_ComputerSystem.TotalPhysicalMemory` and computes the page file size. A failed query or a missing, non-numeric or non-positive size reports `FAIL` and exits with code 1 before any of the following steps.
2. Adds TLS 1.2 to the protocols the process allows.
3. Resolves the official alias `https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso` to the current release hop by hop (at most five) over HTTPS on fedorapeople.org. The alias redirects to plain `http://`; only the path and query of such a location are reused over HTTPS, and a location with another host, scheme or port is refused. Any failure exits with code 1. No version or digest is hardcoded; the version shown comes from the release file name.
4. Creates a new directory `bsod-virtio-win-<GUID>` under the administrator's `$env:TEMP` (an unset or missing TEMP or a failed creation exits with code 1) and downloads the resolved HTTPS URL into it as `virtio-win.iso` without following redirects (`Save-HTTPSdownload`; a redirect or any status other than 200 fails). The script checks no checksum or signature, so authenticity rests on HTTPS to fedorapeople.org.
5. Mounts the ISO. Runs the x86_64 QEMU Guest Agent MSI quietly, waiting for completion and requesting no installer-initiated restart. Exit codes 0, 1641 and 3010 are reported as success; any other code (or none) is reported as a warning, and the guest-agent service check in step 9 decides.
6. Attempts to install both VirtIO storage drivers with `pnputil /add-driver ... /install`:
   - VirtIO block: preferred relative path `viostor\w11\amd64\viostor.inf`.
   - VirtIO SCSI: preferred relative path `vioscsi\w11\amd64\vioscsi.inf`.
   - If a preferred path is missing, searches the ISO recursively for that INF filename and takes the first match whose full path contains `amd64`.
   - Exit codes 0, 1641 and 3010 are accepted as success (pnputil normally returns 0 or 3010); other codes are reported as warnings (the post-reboot script checks the driver store).
   - If no INF is found, prints a warning and skips that driver.
7. Notes that SATA uses the Windows inbox `storahci` driver; it does not install it.
8. Always unmounts and deletes the ISO and removes its directory, also after a failure; a directory that still holds anything else is left in place. A failed download or mount (including a missing drive letter), or a cleanup that leaves anything behind, reports `FAIL` and exits with code 1 before any CrashControl or page file change (the installers in steps 5 and 6 may already have run). Nothing of the ISO remains for the post-reboot script or the sealed image.
9. Checks for the `QEMU-GA` service, requests Automatic startup, and attempts to start it if it is not Running. After a start attempt, waits three seconds and queries the service again. A missing service or a service still not Running causes an explicit exit with code 1.
10. Writes the CrashControl settings listed below and removes the `DedicatedDumpFile` registry value if present (an absent value is left alone). A failed write reports `FAIL` and exits with code 1 before the page file change and the reboot. It then deletes a `C:\DedicatedDump.sys` left by older preparations, but only when `DedicatedDumpFile` is no longer set and the path is a plain file (not a directory or reparse point); if the file stays (for example locked until the reboot), it prints a warning and the post-reboot script handles it.
11. Writes the pagefile configuration listed below.
12. Reboots with `Restart-Computer -Force`.

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

### Settings not managed by these scripts

- **pvpanic:** #10 and #9 neither install nor check a guest pvpanic driver (the current scripts in this directory do). The pipeline entry script attempts, best effort and non-fatal, to hot-add the pvpanic device to the running VM through the QEMU monitor (`virsh qemu-monitor-command --hmp 'device_add pvpanic,id=pvpanic0'`): `src/scripts/crash-injector/trigger-bsod-intentional.sh` (a separately proposed pipeline runner may take over that step). Adding the device does not install a guest driver, and whether the KubeVirt Panicked event is raised without one has not been verified.
- **Boot recovery settings:** #10 and #9 neither change nor check Windows boot recovery behavior (`bcdedit` boot-status policy, recovery and boot-menu options, `reagentc /disable`), which the current pre-reboot script in this directory changes (its post-reboot script checks `bootstatuspolicy` and `recoveryenabled`). They leave these settings as they are on purpose (Windows defaults on a fresh install), because the intended test flow does not restart a VM after a simulated crash. The current `src/scripts/host/watch-crash.sh` still starts the VM again after extracting evidence unless it runs with `--no-restart` (a watcher change is planned separately), and how a restarted VM behaves without these settings has not been verified.

### Validation limits

- The script reports installer exit codes but treats non-success codes as warnings; its final reboot is not proof that every operation succeeded. Use the post-reboot checks.
- It emits human-readable progress and errors, not a structured JSON report.

## 2. golden-image-post-reboot.ps1

### Purpose and interface

Part 2 of golden-image preparation. It has no declared parameters. Run it as Administrator after the reboot from part 1 and before sealing.

This is primarily a verification script. It also requests Automatic startup for the QEMU Guest Agent service and deletes a `C:\DedicatedDump.sys` left by older preparations (check 5). It does not attempt to start a stopped service, resize the pagefile, reinstall drivers, or fix CrashControl values. It sets `$ErrorActionPreference` to `Continue`, so every check runs and reports even when the caller prefers `Stop`.

### Active checks

1. **QEMU Guest Agent:** Requests Automatic startup and checks whether the service is Running. A missing (`not installed`) or stopped service marks failure. The startup-type update suppresses errors; there is no separate read-back verification of startup type.
2. **Storage drivers:** Checks the online driver store for entries whose original filenames contain `viostor` and `vioscsi`. Checks whether the inbox SATA driver exists. Missing drivers generate `WARN` messages rather than marking failure. The warnings note that the matching disk bus may not boot without its driver; a warning is not assurance that every disk bus is supported.
3. **CrashControl DWORDs:** Compares these five values against the golden-image expectations: `CrashDumpEnabled=7`, `AutoReboot=0`, `AlwaysKeepMemoryDump=1`, `Overwrite=1`, and `LogEvent=1`. Any mismatch marks failure.
4. **Dedicated dump setting:** Reads `DedicatedDumpFile`. A nonempty value marks failure; a missing or empty value follows the success branch. The stated golden-image policy is for the value to be absent.
5. **Old dedicated dump file:** If `C:\DedicatedDump.sys`, created by older preparation scripts, exists, deletes it when `DedicatedDumpFile` is not set and the path is a plain file (not a directory or reparse point). If it remains (the value is set, it is not a plain file, or it is still locked), marks failure: the file is unused but would be sealed into the image.
6. **Pagefile management:** Reads `Win32_ComputerSystem` with `-ErrorAction Stop`. A failed query or a missing or non-positive `TotalPhysicalMemory` marks failure, and neither pagefile check can then pass. Otherwise automatic management still enabled marks failure. This reads the same CIM property the pre-reboot script sets.
7. **Active pagefile:** Reads `Win32_PageFileUsage` for C: entries and checks that `AllocatedBaseSize` is at least `Get-PagefileSizeMB` of the RAM — the same `Round((RAM bytes + 257MB) / 1MB, 0)` the pre-reboot script configured. Reports allocation and current usage on success. An undersized or missing active pagefile marks failure.

### Result and sealing

- `OK` lines describe checks that passed.
- `WARN` lines do not set the script's failure flag.
- If any active check sets that flag, the script prints `DO NOT SEAL` and explicitly exits with code 1, instructing the operator to fix the issues (re-running part 1 if needed) and re-run this script.
- Otherwise it prints `=== All checks passed - safe to seal the golden image. ===` and a line naming the following command:

```powershell
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /quiet
```

The command is printed only. Sealing remains a separate operator action. There is no ISO cleanup: part 1 already removed the ISO.

### Verification boundaries

- No pvpanic or boot recovery check is performed (see "Settings not managed by these scripts").
- `DumpFile` is written by part 1 but is not checked by this script.
- It does not verify that configured pagefile initial and maximum sizes match; it checks automatic-management state and the active allocation threshold.
- It does not trigger a BSOD, verify a generated dump, or produce JSON. Passing these checks is not an end-to-end crash-dump validation.

## 3. validate-crash-settings.ps1

### Purpose

Read-only run-time check of the guest's crash-dump settings, meant to be run by a host caller before a crash test is armed. It compares `crash-control.json` with the live registry and reports every difference. It never writes the registry, CIM or page file, never repairs a mismatch, and never reboots or crashes the guest. The golden-image pair owns the configuration: part 1 writes it and part 2 verifies it before sealing.

### Parameters

| Parameter | Meaning |
|---|---|
| `-dumpType <string>` | Validates against another key of the configuration's `crashDumpTypes`. Defaults to `recommended.crashDumpType`. |
| `-stageNotMyFault` | For an intentional crash run only: downloads and stages the current NotMyFault (see below). Off by default; normal validation never downloads or stages anything. |
| `-dataFile <string>` | Path to the required configuration JSON. Supply it when running outside the expected repository layout. |

PowerShell binds parameter names case-insensitively, so `-DataFile`, `-StageNotMyFault` and `-DumpType` also work.

**Configuration dependency:** The script expects `crash-control.json`. Without `-dataFile`, it resolves three levels above its script directory and looks for `src\data\crash-control.json`. It reads `registryPath`, `recommended.crashDumpType`, `recommended.values`, `crashDumpTypes.<selected type>.CrashDumpEnabled`, `pageFile.path` / `pageFile.value` and, when present, the optional `recommended.absentValues`. The configuration file is [`src/data/crash-control.json`](../../data/crash-control.json); it is data, not an additional script.

The current configuration has no `recommended.absentValues` and still lists `DedicatedDumpFile` and `MinidumpDir` in `recommended.values`. `DedicatedDumpFile` is checked as a required absence instead. `MinidumpDir`, which #10 and #9 neither write nor check, is compared like any other desired value, so it is reported unless the guest already has it as an ExpandString that expands to `%SystemRoot%\Minidump`.

### Usage

These examples use a placeholder path that must be replaced with the actual configuration location:

```powershell
# Compare the live settings with the configuration's recommendation (read-only).
.\validate-crash-settings.ps1 -dataFile '<path-to-configuration-json>'

# Compare against another dump type present in the configuration.
.\validate-crash-settings.ps1 -dumpType '<configured-dump-type-key>' -dataFile '<path-to-configuration-json>'

# Intentional crash run: also stage the latest NotMyFault.
.\validate-crash-settings.ps1 -stageNotMyFault -dataFile '<path-to-configuration-json>'
```

### Checks

1. Reads and parses the configuration and validates the selected dump-type name.
2. Builds the desired values from `recommended.values`, replacing `CrashDumpEnabled` with the selected type's value. A `DedicatedDumpFile` entry is not a desired value; it is checked as a required absence and a `WARN` line goes to stderr.
3. Reports the registry key as `key missing` if `registryPath` does not exist.
4. For every desired value, reports `missing`, `wrong type` (strings must be ExpandString and numbers DWord, as the golden image writes them) or `wrong value` (environment variables are expanded on both sides before comparing).
5. Reports `DedicatedDumpFile`, and every name in `recommended.absentValues` if that list exists, as `must be absent` when the value is present.
6. Reports page file adequacy (below).

A mismatch does not change the exit code: the JSON reports it, and a caller should stop when `matchesRecommended` is false, `current.AutoReboot` is not 0 or `pageFile.adequate` is false. The fix is to rebuild or correct the golden image; nothing is changed at run time.

### NotMyFault staging (`-stageNotMyFault`)

- Removes any earlier `C:\Temp\nmf\notmyfaultc64.exe`, archive and extraction folder first; an existing copy is never reused.
- Resolves `https://download.sysinternals.com/files/NotMyFault.zip` over HTTPS (a redirect may only stay on that host), downloads it and extracts it.
- Requires a valid Authenticode signature on `notmyfaultc64.exe` whose signer's organization is exactly `Microsoft Corporation`. An untrusted or missing executable is never staged.
- Moves the verified executable to `C:\Temp\nmf\notmyfaultc64.exe` and removes the archive and extraction folder.
- Reports `status` (`staged` or `failed`), `source`, `resolvedSource`, `archiveSHA256`, `sha256` (of the executable), `version` (file version), `signer`, `stagedPath` and `problem`. No hash is published for NotMyFault: the SHA-256 values record what was downloaded; the signature is the publisher check.
- Never runs NotMyFault, crashes or reboots the guest. A staging failure exits with code 4 and still emits the full result (settings mismatches, page file, the failed `notMyFault` record) with `ok` set to `false` and an `error`; callers should stop and report it.

Callers should pass `-stageNotMyFault` only for intentional crash runs; normal validation never stages anything. The reported fields are the record a caller can keep. The current `src/scripts/crash-injector/trigger-bsod-intentional.sh` still uploads its own `notmyfaultc64.exe` to the same path when the guest copy is missing or differs in size from it.

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
| `notMyFault` | `{ "status": "not requested" }` without `-stageNotMyFault`; otherwise the staging record above. |

An unknown dump type emits `{ "ok": false, "error": "...", "script": "validate-crash-settings.ps1" }` and exits with code 2; a failed NotMyFault staging emits the normal result with `ok: false` and `error` added (so settings mismatches stay visible) and exits with code 4. A missing configuration is a terminating error.
