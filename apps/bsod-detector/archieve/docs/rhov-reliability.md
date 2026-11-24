# RHOV reliability contract

The automated watcher/snapshot-recovery pipeline supports OpenShift
Virtualization/KubeVirt only. KVM scripts are separate development tools, not
fallbacks. This contract is covered by fixtures and command mocks; this change
does not claim live-cluster validation.

## Required preflight state

`preflight-rhov.sh` does not alter VM lifecycle/configuration. It writes its
unique evidence directory, stages QGA diagnostics, and creates/deletes one
short-lived recovery-image probe pod. It fails before the watcher arms unless:

- Required local helpers and clients exist, including `python-evtx`.
- The named VM uses `runStrategy: Manual`; preflight never patches it.
- Exactly one running VMI and launcher match the explicit namespace/VM.
- Domain XML maps the selected libvirt target through its KubeVirt disk alias to
  exactly one VMI volume and Block-mode PVC/DataVolume. An explicit target must
  pass the same mapping and cannot select an unrelated disk.
- Snapshot class/provisioner, snapshot API, and every required RBAC verb match.
- A distinct Bound Filesystem PVC is supplied for KubeVirt's supported
  `virtctl memory-dump` API, and that API exists in the pinned client.
- The recovery image is digest-pinned. A safe pre-arm pod proves Bash and
  `guestfish` execute. Recovery later rechecks `guestfish` and block readability.
- `--evidence-mount` is the exact non-root mount target, its kind is explicitly
  `pvc`, `network`, or `csi`, and it has a stable identity. `hostPath`,
  `emptyDir`, local-node, overlay/tmpfs/ramfs, ordinary unmounted directories,
  and output outside the mount are forbidden. PVC/CSI identities must resolve to
  a Bound Filesystem PVC; network identities require a network filesystem. The
  mount must also contain a pre-provisioned `.bsod-storage-identity` marker that
  exactly matches the declared ID and is rechecked during recovery.
- QGA responds; CrashControl matches the reviewed data; `AutoReboot=0`; page-file
  adequacy is explicitly `true`; and Windows dump paths exist. Intentional mode
  additionally verifies the reviewed NotMyFault executable.

Guest process exit codes are authoritative. Intentional crash launch uses
`exec-crash`: an immediate guest exit is propagated, while transport loss after
QGA confirms process creation delegates the final verdict to watcher evidence.

## Bounded state machine

Every remote operation has a wall-clock timeout, request timeout where
applicable, and kill-after bound. Preflight, capture, armed observation,
quiescence, stop, recovery, and restart also have overall deadlines with
stage-specific errors.

The watcher publishes its atomic readiness marker only after preflight, an
initial QGA ping, and the event watch are active. The intentional trigger waits
for that marker with a bound before issuing any guest action.

At the QGA miss threshold, a current watch-only pvpanic event corroborates a
crash. Otherwise a running VMI, present launcher, and domain state `paused`,
`crashed`, or `pmsuspended` corroborate it. `running`, `unknown`, unavailable
state, missing VMI, or missing launcher fail closed; they are not crash proof.

Before any long screenshot or memory capture, the watcher records the mapped
disk's `wr.bytes` baseline and samples concurrently. It requires progress and
then the configured number of idle samples. Missing/regressed statistics, no
progress, and quiescence timeout preserve diagnostics but never stop the VM.

## Durable capture and recovery

Every attempt gets a new run ID and previously nonexistent direct child of the
validated mount. Metadata binds that run/output identity, full mount identity,
disk/PVC mapping, pre-crash dump inventory, arm time, snapshot fields,
memory-dump PVC, and proven recovery-image contract. Recovery revalidates the
same mount and output and rejects any pre-existing recovery artifact.

Screenshots use `virtctl vnc screenshot --file`. Raw memory uses KubeVirt's
memory-dump PVC API and client download; daemon-side `virsh ... /dev/stdout` is
forbidden. After verified disk progress/quiescence, `virtctl stop` must confirm
the VMI is offline. Recovery snapshots only the mapped system-disk PVC and uses
a read-only block-mode clone. Guestfish client output streams directly into a
temporary file on validated storage.

Signal handlers exit 130/143. One idempotent EXIT cleanup deletes the recovery
pod before its PVC and snapshot. No patch/delete lifecycle fallback exists.

| Artifact | Publication gate |
|---|---|
| Screenshot | bounded command plus structurally valid PNG IHDR or PPM |
| Raw VM memory | supported KubeVirt API plus structurally valid ELF header |
| Windows dump | post-arm timestamp, differs from pre-crash inventory, and valid PAGEDU64/minidump structure |
| EVTX | complete EVTX header and successful semantic parser result |
| Parser JSON | parseable and `.ok == true` |

Checksums and summaries are atomic. Summary predicates are mode-specific:
standalone recovery requires only dump/EVTX/parser/log/checksum artifacts that it
owns; the full watcher additionally requires screenshot, raw memory, and watcher
diagnostics. Any parser failure, stage error, invalid artifact, or missing
required class returns nonzero.

## Safe fixture validation

These commands contact no cluster, VM, guest, or external failure generator:

```bash
python3 -m unittest -v \
  apps/bsod-detector/test/test_reliability.py \
  apps/bsod-detector/test/test_evtx.py \
  apps/bsod-detector/test/test_container_contract.py
bats apps/bsod-detector/test/test-rhov-reliability.bats
```
