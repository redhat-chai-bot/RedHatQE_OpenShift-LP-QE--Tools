# BSOD Detector Toolkit — Architecture Overview (CGQE-801)

> The current automated reliability path is RHOV/KubeVirt-only and fail closed.
> It is documented in [`rhov-reliability.md`](rhov-reliability.md). The older KVM
> tools described below remain standalone development utilities and are not
> runtime fallbacks for the RHOV watcher. Current reliability behavior is proven
> with fixtures/mocks, not a live cluster.

**One line:** An automatic crash investigator for Windows VMs — it **detects** a BSOD/freeze,
**captures** a screenshot + crash dumps, and **analyzes** the cause, saving everything as
structured JSON. ~5,000 lines. Author: hjoshi · 2026-08-25.

---

## 1. The big picture

A crashing or frozen Windows VM often **can't report on itself**, so the toolkit is split
across two locations — some tools run *inside* the guest, some run *outside* on the host/node.
Both write into one shared evidence folder.

```
                    ┌──────────────────────────────────────────────┐
                    │   SHARED SOURCE-OF-TRUTH  (src/data/*.json)    │
                    │   bugcheck codes · trigger methods ·           │
                    │   crash-dump settings · host signals           │
                    └──────────────────────────────────────────────┘
                         ▲  every script reads its tables here (no hard-coding)
                         │
      ┌──────────────────┴───────────────────────────────────┐
      │  HOST-SIDE ONLY — runs on the Test Host, which is any   │
      │  machine that can reach the VM:                         │
      │  • The local KVM/libvirt host (QEMU VM)                 │
      │  • Any system / CI runner with oc / virtctl access      │
      │  (Bash + Python)  src/scripts/host/                    │
      │                                                        │
      │ • collect-offline.sh      offline evidence orchestrator │
      │ • capture-host-dump.sh    raw VM memory (ELF backup)   │
      │ • capture-vm-screen.sh    BSOD screenshot              │
      │ • collect-host-signals.sh TLB-flush / split-lock #AC   │
      │ • parse-dump-header.sh    dump header (no debugger)     │
      │ • extract-evtx.py        offline .evtx event parsing   │
      │ • host-tools/ (libguestfs) disk extraction              │
      │ • backends/dispatch.sh    KVM ↔ KubeVirt abstraction   │
      └────────────────────────────────────────────────────────┘
                         │
                         ▼
                ONE EVIDENCE FOLDER
      screenshot.png · *.dmp · *.evtx · *.json (structured)
```

**Offline-first:** the guest is a pure crash target. After a BSOD, the host
stops the VM, mounts the disk via guestfs, and extracts dumps + event logs
offline. No guest-side scripts, SSH, or staging needed for evidence collection.

**Design choices:**
- **One job per script**, each emits **exactly one JSON object**.
- **All lookup tables live in `data/`** → adding a new crash code is a *data* change.
- **Backend-abstracted:** `BSOD_DET__HYP_PROV=kvm|kubevirt` selects virsh vs virtctl.
- **AutoReboot=0:** Windows stays at the crash screen so the dump is fully written before the host stops the VM.

---

## 2. What each stage delivers

| Stage | Tool | Output |
|-------|------|--------|
| BSOD / freeze **detection** | `collect-from-host.sh`, `watch-crash.sh` | guest state: crashed / hung / running |
| **Screenshot** capture | `capture-vm-screen.sh` | `bsod-screenshot.png` |
| **Raw memory** backup | `capture-host-dump.sh` | `guest-memory.elf` (ELF) |
| **Offline dump** extraction | `host-tools/extract-dump.sh` (guestfs) | `MEMORY.DMP` + `Minidump/*.dmp` |
| **Offline event log** parsing | `extract-evtx.py` | crash detection from `.evtx` files |
| Dump header **analysis** | `parse-dump-header.sh` | stop code + parameters (no debugger) |
| Host-only **TLB-flush** signal | `collect-host-signals.sh` | split-lock `#AC` → HYPERVISOR_ERROR |
| **Evidence orchestration** | `collect-offline.sh` | `evidence-summary.json` |

---

## 3. Three questions people always ask

**Q: Where does it run?**
Both sides. Guest-side (PowerShell) *inside* Windows; host-side (Bash) *outside* — on the KVM
host, or on OpenShift via `oc debug node` / `oc exec` into the virt-launcher pod. The TLB-flush
tool is host-side because that signal **only exists on the host**, never in the guest dump.

**Q: Is the analysis post-mortem?**
**Mostly yes** — it investigates the evidence left behind *after* the crash (dumps, event log,
stop code). The two **live** parts are freeze/BSOD *detection* and the *screenshot*, which happen
at crash time.

**Q: Can we collect the dump WITHOUT restarting the VM?**
Three cases:
1. **Normal BSOD** — Windows itself reboots as it writes the dump (that reboot is *Windows'* behavior,
   not ours); we read the dump after it's back up.
2. **VM powered off (no Windows boot)** — Yes: `host-tools/` read `MEMORY.DMP` straight off the disk
   image offline. Good for an unbootable guest.
3. **Live, no restart** — Yes, for a *frozen/hung* guest: snapshot running memory via
   `virsh dump --memory-only` (or LiveKd). Caveat: that's a **raw QEMU/ELF image, not a native
   Windows dump** — needs different tooling (Volatility), used as a last resort.

> **Bottom line:** we can grab memory without a restart, but a *native Windows crash dump* is
> inherently tied to the BSOD-and-reboot that Windows performs itself.
