# RHOV BSOD evidence architecture

The RHOV path is one fail-closed state machine:

```text
exact Manual VM + Running VMI
        |
fresh Panicked event (or armed intentional signal plus QGA loss)
        |
live capture: VNC PNG + KubeVirt memory-dump + domain XML
        |
valid OS-disk writes observed, then valid idle window
        |
virtctl stop -> VMI absent -> launcher absent
        |
OS PVC snapshot ready -> restored Block PVC + Filesystem work PVC -> recovery pod succeeded
        |
copy and validate dumps/EVTX -> parse where supported
        |
virtctl start -> VMI Running + AgentConnected=True
        |
truthful success summary
```

Every edge is required. A failed edge returns nonzero. Dump-completion failure
leaves the VM running; extraction failure leaves it stopped and retains recovery
resources.

Host and guest responsibilities are separate:

- Windows has `AutoReboot=0` and writes its native dump to the OS disk.
  Intentional triggering is the only guest-side runtime action.
- The orchestration host runs `oc`, `virtctl`, parsers, and receives evidence.
- KubeVirt memory uses the supported memory-dump PVC/VMExport API.
- The recovery pod reads a snapshot-derived PVC and writes libguestfs
  temporary/cache/output data to a CSI-backed Filesystem PVC. It has no
  service-account token, privileged mode, container-layer evidence, or
  node-host mount.

No live RHOV validation is claimed. Contracts were checked against upstream
KubeVirt source and local command fakes. Target-cluster feature gates, CSI
behavior, Windows dump production, and the published recovery-image digest are
deployment prerequisites.
