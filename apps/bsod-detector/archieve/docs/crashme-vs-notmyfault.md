# CrashMe Driver vs NotMyFault (Sysinternals) — Tradeoff Analysis

Why bsod-detector uses a custom KeBugCheckEx driver instead of
Microsoft's NotMyFault for BSOD trigger testing.

## Comparison

| Criterion | CrashMe (custom driver) | NotMyFault (Sysinternals) |
|---|---|---|
| **Arbitrary bug-check code** | ✅ Caller specifies any stop code + 4 parameters | ❌ Limited to ~8 predefined crash types |
| **EULA / license** | ✅ No EULA; project-owned code | ⚠️ Sysinternals EULA; `/accepteula` required on first run |
| **Unattended automation** | ✅ Single command, no prompts | ❌ `/accepteula` and `/crash` cannot be combined in one invocation; requires a two-step workaround |
| **UAC handling** | ✅ Kernel service — runs as SYSTEM, no UAC prompt | ❌ `-Verb RunAs` pops a UAC dialog that blocks in unattended/SSH sessions |
| **32/64-bit confusion** | ✅ Single cross-compiled binary | ❌ 32-bit `notmyfault.exe` silently fails on 64-bit Windows with no error |
| **Build dependency** | ⚠️ Requires mingw64 cross-compiler | ✅ Pre-built binaries available from Microsoft |
| **Signed driver** | ❌ Unsigned; requires test signing or Driver Verifier config | ✅ Microsoft-signed (myfault.sys) |
| **Ecosystem trust** | ⚠️ Custom code — needs review | ✅ Sysinternals is widely trusted |
| **Observed crash code** | ✅ Exact code specified | ❌ Crash type 0x01 always produces 0xD1 (DRIVER_IRQL_NOT_LESS_OR_EQUAL) |
| **Parameter control** | ✅ All 4 bug-check parameters specified | ❌ Parameters determined by the fault path |

## Decision rationale

The **strongest justification** for the custom driver is **arbitrary bug-check code
control**. The bsod-detector must verify its collection pipeline against all 19
stop codes in `data/trigger-methods.json`, each with specific parameters. NotMyFault
cannot produce most of these codes.

The EULA and UAC arguments are **valid but solvable** — the two-step `/accepteula`
workaround and running as Administrator over SSH both work. The 32/64-bit issue
is a one-time discovery cost. These are inconveniences, not blockers.

The custom driver's **downsides** (unsigned, needs cross-compiler, custom code to
maintain) are acceptable in a test-only context where the VM is always snapshotted
and disposable.

## When to prefer NotMyFault

- Quick ad-hoc testing where a specific stop code is not needed
- Environments where loading unsigned drivers is prohibited
- One-off demonstrations to stakeholders familiar with Sysinternals

## References

- NotMyFault: https://learn.microsoft.com/en-us/sysinternals/downloads/notmyfault
- CrashMe driver source: `src/scripts/crash-injector/test-driver/`
- Development notes: [`development-notes.md`](development-notes.md) §"Why a custom kernel driver"
