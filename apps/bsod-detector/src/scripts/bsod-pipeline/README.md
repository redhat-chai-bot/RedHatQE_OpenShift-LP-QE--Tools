# bsod-runner.sh

Runs the RHOV BSOD evidence pipeline against one explicitly disposable Windows test VM on OpenShift
Virtualization: preflight, an armed crash watcher, an optional intentional crash, and offline evidence
extraction. The helpers it calls live in `../host/` (see [`../host/README.md`](../host/README.md)); this
README covers only the runner.

## Safety

- **Intentional mode crashes Windows** and deletes the guest's existing `C:\Windows\MEMORY.DMP` and
  `C:\Windows\Minidump\*.dmp` first. Use it only on a disposable test VM.
- Both modes change the VM: preflight configures guest dump settings and may create PVCs, the runner
  hot-adds a pvpanic device (best effort), and after a detected crash the watcher stops the VM for offline
  extraction.
- The watcher runs with `--no-restart`. A successful run leaves the VM **Stopped**; the runner never starts it.

## Prerequisites

- Run from a checkout of this repository: the runner resolves helpers as `<script dir>/../host`.
- The tools and cluster access that `preflight-rhov.sh` checks (for example `oc`, `virtctl`, `jq`,
  `python3`, `timeout`) and a mounted evidence volume.
- A digest-pinned recovery image (`<image>@sha256:<64 hex>`). There is no default; the runner stops
  before creating anything if it is missing or not digest-pinned.
- Intentional mode only: NotMyFault at `C:\Temp\nmf\notmyfaultc64.exe` in the guest. Preflight runs with
  `--require-trigger` and requires the file to exist. When `preflight-rhov.sh` and `configure-dumps.ps1`
  support `-StageNotMyFault`, preflight first downloads it on the guest if missing (the guest needs access
  to download.sysinternals.com); otherwise place the binary there before the run.

## Quickstart

```sh
export BSOD_DET__NAMESPACE='<namespace>' BSOD_DET__VM__NAME='<vm-name>'
export BSOD_DET__RECOVERY__IMAGE='<image>@sha256:<64-hex-digest>'

# Wait for a natural or externally triggered crash.
bash ./bsod-runner.sh --mode watch

# Crash the VM on purpose with NotMyFault crash type 0x01: name the VM again to confirm.
export BSOD_DET__CONFIRM_TARGET='<vm-name>'
bash ./bsod-runner.sh --mode intentional 0x01
```

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `BSOD_DET__NAMESPACE`, `BSOD_DET__VM__NAME` | required | Target VM. |
| `BSOD_DET__RECOVERY__IMAGE` | required | Digest-pinned recovery image passed to preflight and the watcher. |
| `BSOD_DET__CONFIRM_TARGET` | required for intentional | Must equal `BSOD_DET__VM__NAME`. |
| `BSOD_DET__EVIDENCE__DIR` | `/mnt/persistent-bsod-evidence` | Evidence mount; each run gets its own directory. |
| `BSOD_EVIDENCE_VOLUME_KIND` | `pvc` | `pvc`, `network` or `csi` (validated by preflight). |
| `BSOD_DET__EVIDENCE__STORAGE_ID` | `shared-bsod-evidence` | Evidence storage identity. |
| `BSOD_DET__MEMORY__DUMP_PVC` | `<vm>-memdump` | KubeVirt memory-dump PVC. |
| `BSOD_DET__SNAPSHOT__CLASS` | `ocs-storagecluster-rbdplugin-snapclass` | Snapshot class for recovery. |
| `BSOD_DET__READY__TIMEOUT` | `300` | Seconds to wait for watcher readiness. |
| `BSOD_DET__PREFLIGHT__TIMEOUT` | `1800` | Seconds allowed for preflight. |
| `BSOD_DET__GUEST_AGENT__BIN` | `python3 ../host/guest-agent.py` | Replacement guest-agent command (for tests). |

The watcher's own settings, such as `BSOD_DET__ARMED__TIMEOUT` (default 3600 seconds), still apply. Fixed
timeouts bound the runner's own guest and cluster calls: 30 s for the domain patch, `domain.xml` capture and
NotMyFault readability check, 15 s for the VMI spec, 60 s for the dump cleanup and 90 s for the injection.

## Modes

| | `--mode watch` | `--mode intentional <0x01-0x09>` |
|---|---|---|
| Confirmation | none | `BSOD_DET__CONFIRM_TARGET` must name the VM |
| Preflight | without `--require-trigger` (never stages NotMyFault) | with `--require-trigger` |
| Guest changes before arming | none beyond preflight | NotMyFault must be readable; old dumps deleted and the cleanup verified |
| Crash | caused externally | NotMyFault `/crash <type>` after the watcher is ready |

Without `--mode` the runner prompts only on a terminal; otherwise it exits with a usage error. There is no
default crash type.

## Run flow

1. Validate mode, crash type, VM, timeouts, recovery image and (intentional) confirmation. Nothing is created
   if any check fails.
2. Create a unique run directory `<evidence dir>/<UTC time>-<mode>-<pid>-<random>`.
3. Run `preflight-rhov.sh` and read the launcher Pod and domain from `recovery-metadata.json`.
4. Best effort: hot-add pvpanic and set `on_crash=preserve`; capture `domain.xml` and `vmi-spec.json`.
5. Intentional: verify NotMyFault is readable on the guest, delete old dumps and prove they are gone.
6. Start `watch-crash.sh` with `--no-restart` and wait until its ready file contains **this run's ID**.
7. Intentional: inject the crash. Watch: wait for the crash.
8. Wait for the watcher, then require `evidence-summary.json` with `ok == true` for this run and the VM in
   `Stopped`.

## Status and artifacts

- Exit 0 means the watcher succeeded, the current run's summary reports success and the VM is Stopped.
- Usage errors exit 2. Most failures print `bsod-runner: ERROR: ...` and exit non-zero; a failing helper
  (for example preflight) exits with its own status and message, and a watcher failure keeps the watcher's
  status. `SIGINT`/`SIGTERM` exit 130/143 after stopping the watcher.
- The run directory is never deleted by the runner. Inspect `evidence-summary.json`, the watcher logs and
  the extracted archives there; see `../host/README.md` for their contents.

## Troubleshooting

| Message | Action |
|---|---|
| `BSOD_DET__RECOVERY__IMAGE must be a digest-pinned image` | Export a reviewed `<image>@sha256:<digest>` reference. |
| `BSOD_DET__CONFIRM_TARGET must be set to '<vm>'` | Set it to the exact VM name for intentional runs. |
| Preflight: `NotMyFault binary ... is missing` | Staging failed or is unsupported: read the `configure-dumps.ps1` warning on stderr, check guest access to download.sysinternals.com, or place the binary at `C:\Temp\nmf\notmyfaultc64.exe`. |
| `NotMyFault ... is not available and readable on the guest` | The file disappeared, cannot be opened, or the guest agent failed after preflight; check the guest and rerun. |
| `watcher readiness timed out` / `watcher exited ... before publishing readiness` | Inspect the watcher log in the run directory; increase `BSOD_DET__READY__TIMEOUT` if arming is slow. |
| `current-run evidence summary is absent or reports failure` | Read `evidence-summary.json` and the stage logs in the run directory. |
| `... expected Stopped` | Check VM/VMI state and the watcher's stop and recovery logs; do not restart the VM before reviewing them. |
