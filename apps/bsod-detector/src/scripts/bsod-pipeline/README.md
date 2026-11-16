# bsod-runner.sh

A guided crash-test and evidence-collection runner for a disposable Windows VM on OpenShift Virtualization (RHOV).

This README describes the newly uploaded runner supplied in this conversation: SHA-256 `391c3ded7d30fa8d2943974e0e7657607f7e02a68d0e82f8b465c329795cc56d` (198 lines; 10,857 bytes). This supersedes the README for the earlier 205-line runner. Dependency behavior was checked against the referenced `feat/add-bsod-detector` branch. Different helper versions can change prerequisites, artifacts, and timeouts.


### What changed from the previous README

- No local `notmyfaultc64.exe` file is required next to the runner.
- Intentional mode does not upload, replace, unblock, or compare the guest binary with a host copy.
- The guest hash result is checked only for nonemptiness; it is not compared to an expected trusted digest.
- Guest download during preflight is an expectation in comments, not a behavior implemented by this runner. The deployed helper combination must satisfy it.
- All examples and validation statements below describe this upload; earlier test counts have been removed.

## 1. Purpose and boundaries

The runner orchestrates preflight, watcher readiness, optional intentional crash injection, and offline evidence extraction. It is not a standalone dump parser and does not contain the entire recovery implementation.

It supports two modes:

- **intentional:** require a readable NotMyFault executable already present in the Windows guest, clear old Windows dump files, arm the watcher, and deliberately crash the selected VM.
- **watch:** arm the watcher and wait for a crash caused externally, such as a manually executed or scheduled NotMyFault test. The runner does not hash-check, stage, or execute NotMyFault or delete existing guest dump files in this mode.

Both modes pass `--no-restart` to the watcher. A successful run requires the VM to report `Stopped` after extraction. The runner never starts the VM.

> **Danger:** intentional mode crashes Windows and deletes existing `C:\Windows\MEMORY.DMP` and `C:\Windows\Minidump\*.dmp` before injection. Use only an explicitly authorized disposable test VM. Save work and preserve older evidence before starting.

> **Watch does not mean read-only:** both modes run preflight and attempt a live domain configuration patch. The referenced preflight can configure guest dump settings, create missing storage, and create a recovery-image probe pod. When a crash is detected, the watcher collects evidence and stops the VM for offline extraction.

## 2. Important current limitations

- **The recovery-image default is not usable with the referenced preflight.** The runner defaults to `quay.io/konveyor/oadp-vmfr-access:latest`, but preflight requires a reference ending in `@sha256:` followed by a 64-character hexadecimal digest. Set `BSOD_DET__RECOVERY__IMAGE` to a known-good digest-pinned image before running. A syntactically valid digest alone does not prove the image exists or is compatible.

> **NotMyFault provisioning compatibility:** the uploaded runner comments assume that `configure-dumps.ps1` downloads NotMyFault during preflight. However, the previously supplied PowerShell script defaults to `-Mode watch` and stages NotMyFault only for `-Mode intentional`; the referenced preflight invokes it with `-DataFile` but does not pass `-Mode intentional`. This newly uploaded runner also does not forward its mode to preflight. If those helpers are still in use and the guest executable is absent, intentional mode will stop at the guest hash check. A new matching PowerShell/preflight pair was not supplied with this upload, so automatic download cannot be confirmed. Provision the reviewed guest executable separately or verify a compatible helper combination before running intentional mode.

- **Watch mode is not unlimited.** The unchanged watcher defaults to 3,600 seconds of armed observation. Zero is rejected, not interpreted as infinity.
- **Artifact completeness is not guaranteed.** Screenshot, memory capture, host capture, dump generation, and extraction can fail. The final evidence summary and process status determine whether the runner reports success; directory existence alone is insufficient.
- **Documentation review only for this upload.** The new runner was read in full but was not executed or revalidated. Earlier syntax/lint/mock results belong to the earlier runner, not this version.

## 3. Required layout and prerequisites

The runner resolves its own directory as `scrDir` and helpers as `${scrDir}/../host`. Keep it within a compatible project layout; copying only the runner into an arbitrary directory is not sufficient.

Intentional mode requires `notmyfaultc64.exe` to be present and readable at `C:\Temp\nmf\notmyfaultc64.exe` inside the Windows guest. No host-side copy is required: this runner no longer uploads or replaces the executable. The source comments expect `configure-dumps.ps1` to download it during preflight, but that expectation depends on the actual helper versions deployed; see the compatibility warning below.

Key dependencies:

- `preflight-rhov.sh`: validates target, storage, permissions, recovery image, and guest dump configuration; writes recovery metadata.
- `guest-agent.py`: guest connectivity, file upload, PowerShell execution, and intentional crash command execution.
- `watch-crash.sh`: arms detection, evaluates crash evidence, coordinates capture, stops the VM, invokes extraction, and writes the evidence summary.
- `reliability.py`: detection decisions and summary-related processing used by the helpers.
- `extract--guest-os--crash-info.sh`: offline recovery/extraction called by the watcher.
- `collect-host-signals.sh` and `parse-dump-header.sh`: additional collection/analysis helpers required by preflight.
- `configure-dumps.ps1` and `crash-control.json`: guest dump configuration inputs consumed by preflight.

The referenced preflight checks for `oc`, `virtctl`, `jq`, `python3`, `sha256sum`, `findmnt`, `timeout`, `realpath`, and `sync`; it also checks Python imports for `Evtx.Evtx` and `volatility3`. The watcher requires `setsid`. These are project execution prerequisites, not a complete installation guide.

The environment must have access and permissions for the target namespace and recovery operations. The referenced preflight requires a running VMI, VM `runStrategy: Manual`, a Block-mode guest PVC with a storage class and requested size, a suitable snapshot class, and a usable persistent evidence mount. It checks these rather than assuming the defaults suit every cluster.

The evidence root must already exist: the runner creates a unique child directory with `mkdir`, not the parent mount. Preflight checks that the evidence path is a distinct mount point outside its explicit test path. Do not substitute an arbitrary local directory and assume it is equivalent to persistent evidence storage.

## 4. Command-line inputs

```sh
bash ./bsod-runner.sh --mode watch
bash ./bsod-runner.sh --mode intentional 0x01
bash ./bsod-runner.sh --help
```

- `--mode intentional|watch`: selects the workflow. Values are case-sensitive.
- `crashType`: one of the exact strings `0x01` through `0x09`; required only in intentional mode. There is no default crash type.
- `-h` or `--help`: prints usage and exits successfully.

When standard input is a terminal, omitted mode is prompted for. Intentional mode also prompts for an omitted crash type. In noninteractive execution, supply both explicitly where required. An omitted or unsupported mode, unsupported crash type, extra positional argument, or crash type in watch mode causes a usage error.

`BSOD_DET__CONFIRM_TARGET` is an environment safeguard, not a command-line option. It must exactly equal the selected VM name for intentional mode.

## 5. Environment inputs and defaults

### Target and authorization

- `BSOD_DET__NAMESPACE`: required target namespace; no default.
- `BSOD_DET__VM__NAME`: required VM name; no default.
- `BSOD_DET__CONFIRM_TARGET`: intentional mode only; must exactly equal `BSOD_DET__VM__NAME`. Not needed for watch mode.

### Storage and image selection

- `BSOD_DET__EVIDENCE__DIR`: evidence root; default `/mnt/persistent-bsod-evidence`.
- `BSOD_EVIDENCE_VOLUME_KIND`: evidence backing kind; default `pvc`. Referenced preflight accepts `pvc`, `network`, or `csi`.
- `BSOD_DET__EVIDENCE__STORAGE_ID`: stable evidence storage identifier; default `shared-bsod-evidence`.
- `BSOD_DET__MEMORY__DUMP_PVC`: dedicated memory-dump PVC name; default `${VM_NAME}-memdump`, where `VM_NAME` is the selected VM name.
- `BSOD_DET__SNAPSHOT__CLASS`: snapshot class; default `ocs-storagecluster-rbdplugin-snapclass`. Set a class suitable for the actual storage.
- `BSOD_DET__RECOVERY__IMAGE`: recovery image; runner default `quay.io/konveyor/oadp-vmfr-access:latest`. **Override with a known-good digest-pinned reference to pass the referenced preflight.**

### Timeouts and advanced overrides

- `BSOD_DET__READY__TIMEOUT`: runner wait for the watcher's matching readiness file; default `300` seconds.
- `BSOD_DET__PREFLIGHT__TIMEOUT`: runner preflight timeout; default `1800` seconds.
- `BSOD_DET__GUEST_AGENT__BIN`: optional replacement executable for the guest-agent interface. When set, it replaces the complete default `python3 <hostDir>/guest-agent.py` command prefix. Normal users should leave this unset.
- `BSOD_DET__ARMED__TIMEOUT`: inherited by the watcher; default `3600` seconds. Must be positive; does not support unlimited waiting.

Other helper-specific settings remain governed by those helpers. Runner CLI options are not a generic pass-through for watcher options.

## 6. Quick start: watch an externally triggered crash

Replace every placeholder below. The image placeholder is deliberately not runnable: supply a real, reviewed image digest.

```sh
export BSOD_DET__NAMESPACE='your-namespace'
export BSOD_DET__VM__NAME='your-disposable-vm'
export BSOD_DET__RECOVERY__IMAGE='quay.io/konveyor/oadp-vmfr-access@sha256:<REPLACE_WITH_REAL_64_HEX_DIGEST>'
bash ./bsod-runner.sh --mode watch
```

Wait for the runner message:

```text
bsod-runner: watcher armed for <namespace>/<vm> (run <run-id>).
```

The watcher also logs:

```text
qemu guest agent and event watch healthy; watcher armed
```

Only then execute the external crash test. For manual NotMyFault testing, prepare the binary separately in Windows; watch mode will not install it. With the reviewed console binary at the documented path, use an elevated PowerShell window:

```powershell
& 'C:\Temp\nmf\notmyfaultc64.exe' /accepteula /crash 0x01
```

This command matches the intentional runner's argument sequence and deliberately crashes the VM. It was not runtime-tested on Windows during this change. Use straight quotes and a literal `&`, not HTML-escaped text.

For scheduled tests, schedule the actual crash after readiness and before the armed observation deadline. The watcher observes the resulting signals, not the act of scheduling a task. Do not manually restart the VM during collection.

## 7. Quick start: intentional crash

Prepare the same namespace, VM, image, and storage settings as watch mode. Ensure a reviewed `notmyfaultc64.exe` is installed at `C:\Temp\nmf\notmyfaultc64.exe` inside the guest, either by a verified compatible preflight/configuration flow or by separate preparation. No binary beside the runner is needed. Explicitly confirm the target:

```sh
export BSOD_DET__CONFIRM_TARGET="${BSOD_DET__VM__NAME}"
bash ./bsod-runner.sh --mode intentional 0x01
```

The runner calls `GuestNmfHash` and requires only a nonempty result. The helper runs PowerShell `Get-FileHash -Algorithm SHA256`, removes whitespace, and lowercases its output. If the guest command fails, it discards the result. There is no comparison with a local binary, allowlisted checksum, or expected digest, and the caller does not validate a 64-character hash format. This is a guest availability/readability check, not binary integrity or provenance verification. If the executable is missing or the hash result is empty, the run aborts before clearing old dumps and before launching the watcher. The diagnostic is `notmyfaultc64.exe not found on guest — configure-dumps.ps1 download may have failed`; guest-command failure can produce the same diagnostic.

It then deletes old Windows full/minidump files and checks that cleanup succeeded. Injection happens only after the watcher publishes a readiness marker containing this run's ID. The crash command is `/accepteula /crash <crashType>`.

## 8. Execution flow, step by step

1. Enable strict shell behavior and restrictive file-creation permissions (`umask 077`); resolve paths and defaults.
2. Parse arguments, prompt when appropriate, validate target and timeout inputs, and enforce intentional-mode target authorization.
3. Generate a run ID using UTC time, mode, process ID, and a random component; create a unique evidence directory.
4. Run shared preflight and load `launcherPod` and `domain` from `recovery-metadata.json`. The runner does not pass `--require-trigger` or propagate its `--mode` value to preflight. It relies on guest provisioning having made NotMyFault available when intentional mode reaches the later hash check. The nearby staging comment in the uploaded source is stale; the staging implementation has been removed.
5. Attempt to hot-add `pvpanic` and redefine domain `on_crash` as `preserve`. This is best effort, not guaranteed persistent KubeVirt configuration. Failure is nonfatal and may limit capture.
6. Attempt pre-crash `domain.xml` and `vmi-spec.json` fallback copies; remove a failed copy rather than leave a misleading partial file.
7. In intentional mode only, require a nonempty guest NotMyFault hash, then clear/verify old guest dumps. No executable upload, replacement, host hash comparison, or `Unblock-File` is performed by this runner.
8. Launch the watcher with the shared run metadata, a readiness-file path, and `--no-restart`. Intentional mode additionally passes `--intentional`.
9. Wait for a nonempty readiness marker matching this run. Abort if the watcher exits early or readiness expires. A stale marker from another run is not sufficient.
10. Inject the intentional crash, or instruct the watch-mode operator to trigger/wait for the external crash.
11. Wait for the watcher and propagate a nonzero watcher status.
12. Require `evidence-summary.json` to satisfy `.ok == true` and `.runId == <this run ID>`.
13. Read the VM's `.status.printableStatus`; require the exact value `Stopped` before printing success.

Inside the referenced watcher, missed guest-agent pings are evaluated together with domain/VMI state and available panic evidence by `reliability.py`. A single missed ping is not by itself the whole detection rule. The watcher attempts crash-time domain XML, screenshot, memory and host captures, stops the VM before offline extraction, and skips restart because this runner supplies `--no-restart`.

Memory-capture failure can be nonfatal and lead to disk recovery. Other capture failures can abort before stop/extraction; therefore a failed run does not guarantee the VM is stopped or that every artifact exists.

## 9. Outputs and success criteria

Output root:

```text
${BSOD_DET__EVIDENCE__DIR}/<UTC-timestamp>-<mode>-<PID>-<random>/
```

Important files, produced by the runner or its helpers:

- `recovery-metadata.json`: validated run/target/storage metadata from preflight.
- `watcher-ready`: readiness marker containing the current run ID; not a success result.
- `watcher.log`: watcher's progress/error log, including recovery output redirected by the watcher.
- `stage-errors.jsonl`: helper stage-error records; inspect alongside the final summary.
- `domain.xml`: best-effort pre-crash domain fallback.
- `vmi-spec.json`: best-effort pre-crash VMI fallback.
- `domain-bsod.xml`: best-effort crash-time domain XML from the watcher.
- `evidence-summary.json`: final evidence assessment checked by the runner.

Additional dump, screenshot, event-log, and host artifacts depend on the capture/extraction helpers and their success. Do not treat this list as a promise that every file will exist.

The final runner success message is:

```text
bsod-runner: evidence verified in <run-directory>; VM <namespace>/<vm> left Stopped.
```

Success requires a zero watcher exit, a current-run successful evidence summary, and a final observed `Stopped` VM status. This is an observation at completion, not protection against a later external start operation.

The runner does not redirect its entire shell trace into `watcher.log`. It enables `set -x`, so terminal output includes detailed command tracing. Protect logs and dumps as sensitive diagnostic material; do not put secrets into configuration values that can appear in tracing.

## 10. Timeouts explained

- Runner preflight: default 1,800 seconds.
- Runner readiness wait: default 300 seconds; begins after the watcher is launched, not at overall script startup.
- Watcher armed observation: default 3,600 seconds; enforced by both a timed event-watch process and a monitoring deadline.
- Individual watcher guest-agent ping: 15 seconds; not the armed observation duration.
- Intentional crash command wrapper: 90 seconds.
- Final VM-state API request: 30 seconds.
- Referenced watcher offline extraction wrapper: 3,600 seconds; separate from armed observation.

These are not a single total-runtime limit. Captures and helper stages have additional timeouts. `watchDeadline=3604` in a trace means a deadline expressed in elapsed shell seconds, not a wall-clock timestamp or a new 3,604-second configuration.

You may set a longer positive `BSOD_DET__ARMED__TIMEOUT` if appropriate for the test. Neither `0` nor an omitted value means unlimited watching. This README does not change `watch-crash.sh`.

## 11. Functions and why they remain

- `Usage`: print usage/error context and exit `2`.
- `Die`: report an operational error and exit with the supplied status, or `1` by default.
- `RunTimed`: centralize bounded command execution.
- `GuestPs`: invoke guest PowerShell through the selected guest-agent interface with a timeout.
- `GuestNmfHash`: obtain a normalized guest SHA-256 value; any guest-command failure makes the result unverified, even if output was printed before failure.
- `Cleanup`: terminate/wait for a still-running watcher on runner exit without deleting the evidence storage.

These functions retain shared behavior or a safety boundary; they are not independent user commands. Signal handlers directly exit with the appropriate status and let the exit cleanup run.

## 12. Exit status and cancellation

- `0`: help requested, or the complete normal workflow passed all final checks.
- `2`: usage/argument errors reported by `Usage`.
- `1`: default operational validation failure; a helper may also return this.
- `130`: runner received interrupt (`Ctrl+C`).
- `143`: runner received termination (`TERM`).

Other helper/command statuses can propagate; nonzero values are not restricted to this list. On exit the runner attempts to terminate and wait for its active watcher. Cancellation is not a completed extraction, a VM stop guarantee, or a rollback of preflight/guest configuration changes. Inspect VM state and retained evidence after any interrupted or failed run.

The runner does not delete shared evidence PVCs or the memory-dump PVC as routine cleanup. Helpers have their own temporary-resource cleanup; do not assume every created cluster resource is removed automatically.

## 13. Troubleshooting

### `recovery image must be digest-pinned`

Set `BSOD_DET__RECOVERY__IMAGE` to a reviewed, available, compatible digest-pinned image. Removing the digest to use only `:latest` does not work with this preflight. Digest pinning and image availability are separate checks.

### Missing mode or invalid crash type

Supply `--mode watch` or `--mode intentional 0x01`. Do not supply a crash type in watch mode. Noninteractive runs cannot rely on prompts.

### Confirmation or guest NotMyFault error

For intentional mode, set `BSOD_DET__CONFIRM_TARGET` to the exact VM name. Verify that `C:\Temp\nmf\notmyfaultc64.exe` exists inside Windows and can be hashed, and inspect guest-agent failures. A local copy beside the runner does not satisfy this new check. The download-failed message is not proof that a download was actually attempted: verify the installed preflight and PowerShell mode behavior. Do not disable target authorization or the guest check to bypass the failure.

### Preflight fails before arming

Inspect terminal output first: `watcher.log` may not yet exist. Check the specific reported issue, such as permissions, persistent mount, guest agent, Block-mode disk, snapshot class, recovery image, or guest dump/pagefile prerequisites. If preflight reports a reboot is needed for dump settings, handle that before a new test; do not reboot during active collection.

### Watcher exits before readiness

The runner stops before injecting a crash. Inspect the run directory and watcher output. A readiness marker from another run is rejected intentionally.

### Armed but waiting

This is expected until detection criteria are met or the armed timeout expires. Confirm that the crash was actually triggered after readiness. Scheduling a task alone is not a crash signal. `+` and `++` trace lines are not errors by themselves.

### Missing artifacts or unsuccessful summary

Inspect `watcher.log`, `stage-errors.jsonl`, and `evidence-summary.json` where present. Do not declare success from a screenshot or directory alone. Capture can fail before offline extraction; memory failure can still allow disk recovery.

### VM is not `Stopped` after extraction

The runner deliberately fails its final status check. Inspect actual VM/VMI state and the watcher stop/recovery logs; do not remove the final check to conceal the mismatch. No automatic restart is requested by this runner.

## 14. Validation and maintenance notes

This README was reviewed against the complete new uploaded source. No syntax, ShellCheck, mock, Windows runtime, or live VM/crash execution was performed for this new upload while preparing the documentation. Test results from the earlier 205-line runner must not be treated as results for this version.

This task changed documentation only, not the runner, watcher, preflight, or PowerShell configuration. Helper compatibility remains an operational prerequisite. When updating helpers, recheck mode propagation, NotMyFault provisioning, metadata format, evidence-summary semantics, capture failure behavior, image validation, and timeouts.

## References

- [Reference extraction script](https://github.com/redhat-chai-bot/RedHatQE_OpenShift-LP-QE--Tools/blob/feat/add-bsod-detector/apps/bsod-detector/src/scripts/host/extract--guest-os--crash-info.sh)
- [Requested scripting best practices](https://edttjredhat.github.io/RHP-Wiki/Confluence/MPEXIENG/Test+Infrastructure/Best+Practises/Section0--Best_Practices.html)
- [Microsoft NotMyFault overview](https://learn.microsoft.com/en-us/sysinternals/downloads/notmyfault)
