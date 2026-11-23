# Data — source-of-truth lookups

Shared lookup tables. Scripts **read** these; they never inline or duplicate the
values. If a table is wrong, fix it here once and every consumer picks it up.

## Consumer context

| File | Consumed by |
|---|---|
| `crash-control.json` | Guest crash-settings validation; copied to the guest by preflight-rhov.sh |
| `event-sources.json` | Reference data only (no active script consumer) |
| `host-signals.json` | **Host-only** (collect-host-signals.sh) |

## Files

### `crash-control.json`
Crash-dump registry configuration under `CrashControl`, dump-type semantics, and
page-file requirements.
- **Consumers:** the guest crash-settings validation that preflight runs before arming; preflight fails unless
  the guest reports settings matching `recommended.values`. The golden-image scripts are where these values should be set.

### `event-sources.json`
Crash-relevant event log `log` / `source` / `eventId` entries with meaning.
Covers traditional BugCheck events (System/1001), dirty shutdowns (6008),
boot markers (6009, 12, 13), Kernel-Power (41), WER buckets (Application/1001
including LiveKernelEvent), WHEA (18), and Kernel-LiveDump (System/1).
- **Consumers:** none in the active scripts; kept as reference for manual
  EventLog analysis (BugCheck, LiveKernelEvent, dirty shutdown).

### `host-signals.json`
Linux/KVM **host-side** crash-correlation signals invisible from inside the
guest: kernel-log grep patterns (e.g. Intel split-lock `#AC` traps) and the
Hyper-V enlightenment features (`tlbflush`, `ipi`, ...) to read from the libvirt
domain XML.
- **Consumers:** `src/scripts/collect-host-signals.sh` reads both `kernelLogSignals` and
  `hypervEnlightenments`. Each signal's `relatedBugCheck` must be listed in the repository's bug-check
  code table in `src/data/` (checked by `test/test-cross-references.bats`).

## Validation

Keep JSON valid; `test/test-cross-references.bats` checks the cross-references:

```bash
for f in src/data/*.json; do python3 -c "import json;json.load(open('$f'))" \
  && echo "OK  $f" || echo "BAD $f"; done
```
