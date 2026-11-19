# Data — source-of-truth lookups

Shared lookup tables. Host scripts and `validate-crash-settings.ps1` **read** these at run time.
The golden-image scripts run standalone on the guest, so they carry the CrashControl values of
`crash-control.json` inline; `test_golden_image_pre_reboot.py` and `test_golden_image_post_reboot.py`
fail when those copies drift from the table. If a table is wrong, fix it here and in any inline copy.

## Consumer context

| File | Consumed by |
|---|---|
| `bugcheck-codes.json` | Host-side scripts (parse-dump-header.sh) |
| `crash-control.json` | Guest-side (golden-image-pre-reboot.ps1 writes the same values; validate-crash-settings.ps1 compares them read-only); preflight-rhov.sh still copies it to the guest for the former configuration script |
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
- **Consumers:** `validate-crash-settings.ps1` compares the live registry with `recommended.values` (value and
  registry type) and `recommended.absentValues` and reports mismatches; it never writes or reboots. No host script
  calls it yet: `preflight-rhov.sh` still copies this file to the guest for the former configuration script until the
  preflight moves to the validator in pull request #39. `golden-image-pre-reboot.ps1` configures the same settings
  in the golden image.

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
