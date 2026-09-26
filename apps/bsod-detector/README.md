# BSOD Detector

Host-side Windows crash evidence capture for OpenShift Virtualization
(RHOV/KubeVirt), plus separate local-libvirt test helpers.

The RHOV path is offline-first and fail-closed. It does not change the user's
`VirtualMachine` spec, write evidence into `virt-launcher` storage, or write to
an OpenShift node host filesystem. Runtime behavior still requires validation
on the target RHOV, CSI, Windows, and storage versions; local tests use fakes.

## Required RHOV contract

Before either natural watch or intentional trigger can arm:

- the exact `VirtualMachine` exists in the named namespace;
- `.spec.runStrategy` is exactly `Manual`;
- the corresponding VMI is `Running`;
- exactly one Running launcher pod exists;
- exactly one persistent OS disk is identifiable. Set `bootOrder: 1` on the OS
  disk when the VM has multiple persistent disks, or pass `--pvc` explicitly;
- Windows CrashControl uses `AutoReboot=0`. The intentional path additionally
  verifies `CrashDumpEnabled=7` and the `MEMORY.DMP` destination;
- `oc`, a compatible `virtctl`, `jq`, and Python 3 are available.

Violations return nonzero. The scripts never patch `runStrategy`,
`.spec.running`, or another VM field.

## Execution boundaries

```text
orchestration host                    OpenShift Virtualization
------------------                    ------------------------
watch/trigger scripts -- oc/virtctl -> VirtualMachine/VMI APIs
        |                                      |
        |                               virt-launcher/QGA
        |                                      |
        +-- local private evidence       Windows crash target
            and JSON reports             (AutoReboot=0)

stopped OS PVC -> CSI snapshot -> restored read-only Block PVC
                                      |
                               recovery extractor pod
                                      |
                          Filesystem work/artifact PVC
                                      |
                              oc cp to orchestration host
```

The orchestration host needs cluster credentials that can read the target VM,
VMI, launcher pod, PVC, StorageClass, and VolumeSnapshotClass; use the VNC and
memory-dump subresources; stop/start the VM; create namespace-scoped snapshot,
PVC, and Pod resources; and copy pod output. The recovery pod receives no
service-account token. The Windows guest needs QGA only for preflight,
intentional triggering, and post-restart readiness—not for evidence transfer.

## RHOV lifecycle

`src/scripts/host/watch-crash.sh` executes one ordered state machine:

1. Validate the exact Manual VM, Running VMI, launcher, and OS PVC/disk target.
2. Arm at a recorded timestamp. Natural collection requires a fresh `Panicked`
   event for that VMI. QGA loss alone does not authorize destructive work.
3. Before stop, capture:
   - PNG display evidence with
     `virtctl vnc screenshot VM -n NS -f FILE`;
   - raw VM memory with
     `virtctl memory-dump get VM --claim-name=PVC --create-claim --format=raw --output=FILE`;
   - launcher-dependent domain XML through stdout.
4. Poll the exact OS-disk `virsh domstats` counter. Completion requires valid
   samples, a positive write delta after the crash signal, then a valid idle
   window. Missing/malformed data and timeout fail without stop.
5. Request `virtctl stop`, then prove VMI and launcher disappearance.
6. `recover-natural-crash.sh` snapshots the OS PVC, restores an equivalent
   Block PVC, provisions a Filesystem work/artifact PVC, runs a digest-pinned
   recovery image with all temporary/output paths on that PVC, and copies every nonempty
   `MEMORY.DMP`, minidump, and EVTX file to the host output directory under
   `offline/`. A nonempty pre-existing `offline/` directory is rejected so
   stale evidence cannot satisfy the run.
7. Parse dump and EVTX metadata when the packaged tools support the artifacts.
   Otherwise preserve raw files and report `failed` or `unavailable`.
8. Only after successful extraction, start the VM and prove VMI `Running` plus
   the `AgentConnected=True` condition.

Any required failure returns nonzero. An extraction failure leaves the VM
stopped and recovery resources retained for inspection. There is no implicit
restart-on-failure mode.

## Supported memory and screenshot capabilities

The commands above are taken from current upstream KubeVirt code:

- `pkg/virtctl/vnc/screenshot/screenshot.go` defines
  `virtctl vnc screenshot VMI -f FILE` and returns PNG data.
- `pkg/virtctl/memorydump/memorydump.go` defines `memory-dump get`, waits for
  `MemoryDumpCompleted`, and downloads through VMExport. `--format=raw`
  decompresses the exported artifact.

The target RHOV installation must expose these subresources and memory-dump
feature gates. If not, capture fails before stop. There is no launcher-
filesystem or invented `virsh` fallback.

## Recovery image requirement

Pass an image by immutable digest:

```text
--recovery-image REGISTRY/PROJECT/bsod-detector@sha256:<64-hex-digest>
```

The image must contain `/usr/local/bin/extract-dump`, libguestfs, qemu-img, and
`tar`. The supplied Dockerfile provides that layout, but this repository cannot
name the final registry digest until an image is built and published. Mutable
tags are rejected. The recovery pod disables service-account token mounting,
drops all Linux capabilities, disallows privilege escalation, makes the root
filesystem read-only, reads a restored Block PVC, places libguestfs
temporary/cache/output data on a CSI-backed Filesystem PVC rather than the
container layer, and uses libguestfs direct/TCG. This profile is locally tested;
live RHOV execution is not claimed.

## Natural watch

```bash
apps/bsod-detector/src/scripts/host/watch-crash.sh \
  --ns windows-vms \
  --vm win2022 \
  --out ./evidence/win2022 \
  --recovery-image quay.example/bsod-detector@sha256:<digest>
```

Use `--snap-class` only when more than one VolumeSnapshotClass matches the OS
PVC CSI driver. Use `--pvc` only to disambiguate persistent disks owned by the
VMI.

Natural mode deliberately does not equate QGA loss with a BSOD. A fresh
`Panicked` Event for the exact VMI UID is authoritative. If QGA reaches
`--miss` consecutive failures without that Event or an intentional-run token,
the watcher exits explicitly with `failedStage=signal-correlation`; it does not
stop the VM or loop until an outer job timeout. `domstate=unknown` is treated as
an unavailable diagnostic, not proof of a crash.

Useful tuning options are `--interval`, `--miss`, `--quiesce-wait`,
`--stop-timeout`, and `--ready-timeout`. Increasing `--miss` tolerates longer
transient QGA/control-plane interruptions but never turns them into crash proof.

## Intentional trigger

The wrapper accepts only NotMyFault's `0x01` through `0x09` crash types and
passes executable and arguments directly through QGA; it does not interpolate
a `cmd.exe /C` string.

```bash
apps/bsod-detector/src/scripts/crash-injector/trigger-bsod-intentional.sh \
  --ns windows-vms \
  --vm win2022 \
  --out ./evidence/intentional \
  --crash-type 0x01 \
  --recovery-image quay.example/bsod-detector@sha256:<digest>
```

Install and accept NotMyFault's license separately under an approved software-
supply process. `setup-notmyfault.ps1` is a legacy convenience helper; the RHOV
automation does not download mutable tooling.

For the convenience helper, independently obtain and approve the current
NotMyFault archive SHA-256, then run it inside the guest with the required
parameter:

```powershell
.\setup-notmyfault.ps1 -Sha256 '<approved-64-hex-sha256>'
C:\Temp\nmf\notmyfaultc64.exe /accepteula
```

Do not combine EULA acceptance with `/crash`. The wrapper accepts only crash
types `0x01` through `0x09`, creates a random 256-bit expected-crash token,
passes that token to the watcher, writes it immediately before invoking
NotMyFault, and preserves the watcher status with `wait`. Thus an intentional
run can enter evidence capture after QGA loss even if the launcher-side domain
state query returns `unknown`, while an unrelated QGA outage cannot.

## Windows dump configuration

`src/data/crash-control.json` is the executable source of truth:

- `CrashDumpEnabled=7` selects an automatic dump at `MEMORY.DMP`;
- `AutoReboot=0` keeps the guest at the crash screen;
- `AlwaysKeepMemoryDump=1`, `Overwrite=1`, and `LogEvent=1` are enabled.

Automatic dump selection does not independently guarantee a minidump. Recovery
reports one only when a nonempty file actually exists.

## Container

Build context is the repository root:

```bash
make -C image/container/bsod-detector validate-layout
make -C image/container/bsod-detector build IMAGE_TAG=<immutable-build-tag>
```

The Dockerfile pins/checksum-verifies `oc` 4.18.23 and `virtctl` v1.6.6, and
pins `python-evtx`. Runtime modes are:

- `MODE=watch`: requires `GA_NS`, `GA_VM`, and digest-pinned
  `BSOD_RECOVERY_IMAGE`;
- `MODE=recover`: additionally requires `GA_PVC` and a stopped Manual VM;
- `MODE=extract`: reads a local disk file/block device offline.

`host-tools/run.sh` sets `MODE=extract` and forwards arguments without a stray
`--`.

Example container watch invocation:

```bash
podman run --rm \
  -e MODE=watch -e GA_NS=windows-vms -e GA_VM=win2022 \
  -e BSOD_RECOVERY_IMAGE='quay.example/team/bsod-detector@sha256:<digest>' \
  -v "$KUBECONFIG:/tmp/kubeconfig:ro" -e KUBECONFIG=/tmp/kubeconfig \
  -v "$PWD/evidence:/evidence:Z" \
  quay.io/redhatqe/bsod-detector:<tag>
```

The image reference supplied through `BSOD_RECOVERY_IMAGE` must include a
registry, lowercase repository path, and lowercase `sha256` digest. URL-style,
tag-only, uppercase-repository, or malformed references are rejected before
cluster mutation.

## Evidence and reporting

Successful RHOV output may include:

- `bsod-screenshot.png`
- `vm-memory.raw`
- `dom.xml` and `host-signals.json`
- `offline/MEMORY.DMP` and `offline/Minidump/*.dmp` when present
- `offline/winevt/System.evtx` and `offline/winevt/Application.evtx` when present
- `parse-dump-header.json` and `evtx-events.json` when parsable
- `recovery-summary.json` and `evidence-summary.json`

Success JSON is produced only after extraction and restart/readiness succeed.
Failure JSON identifies the failed stage and retained recovery resources. Raw
artifacts are never converted, deleted, or replaced by runtime `elf2dmp`/PDB
downloads. Live memory must be at least 1 MiB, and recovery recognizes native
`PAGEDU64`, `MDMP`, and EVTX signatures before treating copied files as dump or
event artifacts.

Every run owns a private (`0700`) evidence directory and `0600` files. Watcher,
recovery, and intentional-trigger modes write their own logs and truthful JSON
summaries even on expected failures:

- `watch-crash.log` and `evidence-summary.json`
- `recovery.log` and `recovery-summary.json`
- `intentional-trigger.log`, `trigger.log`, and `intentional-summary.json`

Crash dumps and event logs can contain credentials, user data, and host
identifiers. Treat the whole evidence directory as sensitive and do not commit
it. The repository ignores its standard output directories, but external CI
artifact retention and access controls remain the operator's responsibility.

## Failure handling and recovery

- Failure before `virtctl stop` leaves the VM running.
- Stop failure does not begin snapshot recovery.
- Snapshot, restore, pod, transfer, or extraction failure leaves the VM stopped
  and records retained resource names in `recovery-summary.json`.
- Successful extraction is required before restart. Restart is not considered
  complete until the VMI is `Running` and `AgentConnected=True`.
- Cleanup happens only after nonempty dump evidence has been copied locally.

Inspect retained objects with `oc get volumesnapshot,pvc,pod -n NAMESPACE` and
the names in the failure summary. Preserve or debug them before manual cleanup;
the scripts intentionally avoid deleting the only remaining evidence after a
failed transfer.

## Troubleshooting

| Symptom | Meaning and action |
|---|---|
| `failedStage=signal-correlation`, QGA down, `domState=unknown` | No fresh exact-VMI Event or matching intentional token existed. The VM was not stopped. Check cluster/API and launcher connectivity, then start a new run rather than reusing evidence. |
| `failedStage=dump-completion` | No valid positive OS-disk write followed by the idle window was proven. Windows may still be writing or the disk target/counter is unavailable. |
| Existing memory-dump association | Preserve/remove the prior KubeVirt memory-dump request explicitly before arming another run. |
| Multiple persistent disks or snapshot classes | Set OS-disk `bootOrder: 1`, or pass one owned `--pvc`; pass the matching `--snap-class`. |
| Recovery resources retained | Read `recovery-summary.json`, pod logs, PVC and VolumeSnapshot status before manual cleanup. |
| Parser status `unavailable` or `failed` | Raw nonempty artifacts remain authoritative. Install/support the parser offline; do not reinterpret parser absence as extraction failure. |

The original reported hang—healthy QGA followed by 108 consecutive
`domstate=unknown` misses over roughly 30 minutes—is a required hermetic
regression. The contract suite proves both correlated intentional capture and
explicit rejection of the same uncorrelated condition.

## Tests

```bash
bash apps/bsod-detector/test/test-rhov-contracts.sh
bash apps/bsod-detector/test/run-tests.sh
```

The hermetic contract test covers Manual validation, scoped/malformed disk
statistics, no-data/no-write/write-then-stable/timeout traces, supported capture
syntax, pod-independent recovery, container layout, and guest exit propagation.
`run-tests.sh` also runs Bats when installed; it does not install unpinned tools.

## Local-libvirt code

Older KVM/libvirt helpers remain separate test tooling. Their behavior is not
evidence that the RHOV path works. Do not use launcher `/tmp`, node-local disk
paths, or local-libvirt instructions as an RHOV substitute.
