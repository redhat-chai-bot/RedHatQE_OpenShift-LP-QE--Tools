# Data — source-of-truth lookups

Shared lookup tables. Scripts **read** these; they never inline or duplicate the
values. If a table is wrong, fix it here once and every consumer picks it up.

## Consumer context

| File | Consumed by |
|---|---|
| `bugcheck-codes.json` | Host-side scripts (parse-dump-header.sh) |
| `crash-control.json` | Guest-side (configure-dumps.ps1); copied to the guest by preflight-rhov.sh |
| `event-sources.json` | Reference data only (no active script consumer) |
| `host-signals.json` | **Host-only** (collect-host-signals.sh) |

## Files

### `bugcheck-codes.json`
Bug-check (stop) code -> name + description. Keyed by canonical `0x`-prefixed
8-digit hex string.
- **Consumers:** dump parser, collector, any reporting step.
- Curated subset (test-harness codes + common real-world crashes). Extend as needed.

### `crash-control.json`
Crash-dump registry configuration under `CrashControl`, dump-type semantics, and
page-file requirements.
- **Consumers:** `configure-dumps.ps1` applies `recommended.values`; the
  collector verifies live settings match before trusting a dump exists.

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
  `hypervEnlightenments`. Each signal's `relatedBugCheck` must resolve in
  `bugcheck-codes.json`.

## Validation

Keep JSON valid and cross-references intact:

```bash
for f in src/data/*.json; do python3 -c "import json;json.load(open('$f'))" \
  && echo "OK  $f" || echo "BAD $f"; done

# every host-signals relatedBugCheck should exist in bugcheck-codes.json
python3 - <<'EOF'
import json
hs=json.load(open('src/data/host-signals.json'))['kernelLogSignals']
bc=set(json.load(open('src/data/bugcheck-codes.json'))['codes'])
bad=[s['id']+':'+s['relatedBugCheck'] for s in hs if s.get('relatedBugCheck') and s['relatedBugCheck'] not in bc]
print("MISSING:",bad) if bad else print("all host-signals relatedBugCheck values resolve")
EOF
```
