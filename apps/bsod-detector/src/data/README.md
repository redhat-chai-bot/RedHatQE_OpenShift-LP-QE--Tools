# Data — source-of-truth lookups

Shared lookup tables. Scripts **read** these; they never inline or duplicate the
values. If a table is wrong, fix it here once and every consumer picks it up.

## Consumer context

| File | Consumed by |
|---|---|
| `bugcheck-codes.json` | Host-side scripts (parse-dump-header.sh, extract-evtx.py) |
| `crash-control.json` | Guest-side (configure-dumps.ps1, prep-guest.ps1) |
| `event-sources.json` | Host-side (extract-evtx.py offline parser) |
| `trigger-methods.json` | **Host-only** (sweep-crashme.sh, sweep-chaos.sh) |
| `chaos-triggers.json` | **Host-only** (sweep-chaos.sh) |
| `host-signals.json` | **Host-only** (collect-host-signals.sh) |
| `blkdebug-read-errors.conf` | **Host-only** (QEMU blkdebug chaos trigger) |

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

### `trigger-methods.json`
How each bug-check code is triggered in the test harness: method, parameters,
and verification status. All 19 codes use the KeBugCheckEx driver
(`src/scripts/crash-injector/test-driver/crashme.sys`).
- **Consumers:** `src/scripts/crash-injector/sweep-crashme.sh` reads trigger parameters. Any reporting
  step can check `verified` status.

### `event-sources.json`
Crash-relevant event log `log` / `source` / `eventId` entries with meaning.
Covers traditional BugCheck events (System/1001), dirty shutdowns (6008),
boot markers (6009, 12, 13), Kernel-Power (41), WER buckets (Application/1001
including LiveKernelEvent), WHEA (18), and Kernel-LiveDump (System/1).
- **Consumers:** the guest collector to build the crash timeline and for
  fallback detection (LiveKernelEvent, dirty shutdown).

### `host-signals.json`
Linux/KVM **host-side** crash-correlation signals invisible from inside the
guest: kernel-log grep patterns (e.g. Intel split-lock `#AC` traps) and the
Hyper-V enlightenment features (`tlbflush`, `ipi`, ...) to read from the libvirt
domain XML.
- **Consumers:** `src/scripts/collect-host-signals.sh` reads both `kernelLogSignals` and
  `hypervEnlightenments`. Each signal's `relatedBugCheck` must resolve in
  `bugcheck-codes.json`.

### `chaos-triggers.json`

Organic (non-KeBugCheckEx) fault injection trigger definitions for chaos
testing. Each trigger defines a host-side or guest-side scenario that may
produce a real BSOD through actual failure conditions.
- **Consumers:** `vm/sweep-chaos.sh` reads trigger parameters, method type,
  snapshot name, guest workload, expected codes, and timeout.
- 12 triggers across 4 tiers: host-side fault injection (NMI, balloon,
  device hot-remove, network toggle, vCPU hot-remove), Driver Verifier
  stress (low resources, forced pending I/O), block I/O throttle/error
  injection, and Hyper-V enlightenment permutation.

### `blkdebug-read-errors.conf`

QEMU blkdebug configuration for injecting EIO on read operations. Used
with the `blkdebug-config` chaos trigger (requires manual domain XML
setup with `qemu:commandline` namespace).
- **Consumers:** manual QEMU configuration for advanced chaos testing.

## Validation

Keep JSON valid and cross-references intact:

```bash
for f in src/data/*.json; do python3 -c "import json;json.load(open('$f'))" \
  && echo "OK  $f" || echo "BAD $f"; done

# every trigger-methods code should exist in bugcheck-codes.json
python3 - <<'EOF'
import json
tm=json.load(open('src/data/trigger-methods.json'))['codes']
bc=set(json.load(open('src/data/bugcheck-codes.json'))['codes'])
bad=[k for k in tm if k not in bc]
print("MISSING:",bad) if bad else print("all trigger-methods codes resolve")
EOF

# every host-signals relatedBugCheck should exist in bugcheck-codes.json
python3 - <<'EOF'
import json
hs=json.load(open('src/data/host-signals.json'))['kernelLogSignals']
bc=set(json.load(open('src/data/bugcheck-codes.json'))['codes'])
bad=[s['id']+':'+s['relatedBugCheck'] for s in hs if s.get('relatedBugCheck') and s['relatedBugCheck'] not in bc]
print("MISSING:",bad) if bad else print("all host-signals relatedBugCheck values resolve")
EOF
```
