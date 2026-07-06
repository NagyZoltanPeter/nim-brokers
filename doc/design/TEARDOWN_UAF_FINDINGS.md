# The win+refc MT-broker crash: investigation findings & fix record

Status: **fixed & merged** (PR #38, 2026-07-03). Sanitizer-harness tail in PR #39.
This document is the compact record of the investigation (2026-07-02 … 07-03);
normative docs live in `doc/LIMITATION.md` §2.2.

## 1. Symptom (as reported)

Since ~v3.1.1, the `win-amd64 / Nim 2.2.4` CI cell crashed `nimble test` in
`test_multi_thread_request_broker` (refc + release) — hard process death
(0xC0000005, no assert, no traceback), seemingly always at test
"cross-thread request to keyed context", usually passing on re-run. Windows +
Nim 2.2.10 and all other platforms looked permanently green.

**Every element of that pattern turned out to be a sampling artifact.**

## 2. Investigation: four falsification rounds

Method: a repeated-run harness (`nimble testAllocRace`) executing the test
binary N times per scenario with piped stdout (`gorgeEx`), which widens the
race window far beyond what one console-attached CI execution samples.
Experiments ran on throwaway branch `experiment/usemalloc-25513`.

| Round | Hypothesis | Test | Result |
|---|---|---|---|
| 1 | Nim MT-allocator race (nim-lang/Nim#25513, fixed in 2.2.8) | `-d:useMalloc` A/B, 10 trials each | **FALSIFIED** — control 7/10 crashed, useMalloc **9/10** |
| 2 | Fixed in newer Nim | same config on 2.2.4 / 2.2.6 / 2.2.8 / 2.2.10 | **FALSIFIED** — all four crash 3–8/10; the "2.2.4-only" CI pattern was single-shot sampling + output-mode timing |
| 3 | Which test & config arms it | unittest2 positional-glob subsets (solo run = no prior thread churn) × {refc-rel, orc-rel, refc-dbg} | Test 18 ("two contexts on different threads…") **solo crashes 4/10 on both Nim versions**; test 19 solo 0/20 (CI blamed it only due to buffering); **orc 0/20**; refc-debug 1/10 → refc-specific, not release-specific |
| 4 | Which ingredient of test 18 | single-ingredient variants (`test_alloc_race_variants.nim`) | Every crashing variant contains the **worker-thread-hosted provider**; V3 (provider on worker, requester = main thread, zero requester threads) still crashes; pure requester concurrency (V2) and error-path (V4) 0/20. One crash fired **after** `[Summary] … 1 OK` — detonation at teardown |

## 3. Root cause (two mechanisms, one teardown-ordering root)

**A — Windows-only, the crash.** chronos `ThreadSignalPtr.wait()` on Windows
goes `waitForSingleObject → registerWaitable`, handing a **GC-heap
`ref PostCallbackData`** to Win32 `RegisterWaitForSingleObject`; the completion
callback runs on an **OS thread-pool wait thread** and dereferences it. A
worker thread exiting with `brokerDispatchLoop` suspended in `signal.wait()`
leaves that OS wait armed; refc then frees the whole thread heap
(`deallocOsPages()` in `threadimpl.nim`) → a later `setEvent`/handle-reuse
touches unmapped pages. All Nim 2.2.x affected. **POSIX is immune by design**
(eventfd continuation runs inside the owner's own poll loop). **ORC survives
by accident** (`usesDestructors` skips `deallocOsPages` — it leaks instead).

**B — general, all platforms, latent.** Raw `ThreadSignalPtr` pointers stored
in shared buckets / request messages could be fired by other threads after the
owner closed + `deallocShared`'d the signal (`clearProvider` after bucket
removal, `sendReply` to a timed-out-and-exited requester, emit snapshots vs
listener teardown). On POSIX: silent stray `write()` to a possibly-reused fd.
Linux/macOS refc users were latently exposed to B.

## 4. The fix (PR #38)

1. **`BrokerSignalShared`** (`brokers/internal/mt_broker_common.nim`) — every
   cross-thread signal now goes through a type-stable shared wrapper: one
   `Atomic[uint64]` packs a closed-bit + in-flight-firer count;
   `fireBrokerSignal` CAS-acquires a slot (no-op after close); the owner's
   close waits out in-flight firers, closes the inner `ThreadSignalPtr`, and
   **recycles** the wrapper on a process freelist — wrapper memory is never
   unmapped, so stale pointers are permanently safe (worst case: one spurious
   dispatcher wake). Fixes B on all platforms, both memory managers.
2. **`teardownBrokerThread()`** — ordered, latched teardown (stop dispatch
   loop → close signal wrapper → `drainPendingRingFrees` → close chronos
   dispatcher handle) running **before** the refc heap dies. Registered
   automatically via `onThreadDestruction` for Nim-created threads (handlers
   run in the thread wrapper's `finally`, before `deallocOsPages`); **explicit
   call required for foreign/FFI threads and the main thread** (project
   decision: explicit teardown; Nim destruction handlers never run for them).
   Fixes A. `api_library` processing/delivery threads switched to it.
3. `skipRefcOnWindows` carve-out **removed entirely**; refc and orc run the
   identical matrix on every platform.

### Cost

| Point | Overhead |
|---|---|
| Cross-thread fire (hot path) | ~3 uncontended atomics around a ~µs syscall (<1 %) |
| Same-thread dispatch | zero |
| Steady-state memory | 24 B × peak concurrent broker threads (recycled) |
| Thread exit | typically +1–3 ms (+50 ms only with undrained `clearProvider` ring frees) |

### Verification

- Regression gate `nimble testAllocRace` (40 trials × 6 variants, refc+release,
  fail-on-any-crash) as a Windows step in `ci.yml` + dispatch-only
  `teardown_verify.yml`. Pre-fix rate ~30 %/trial; post-fix **0/240 per cell,
  repeatedly** (probability of that under the pre-fix rate ≈ 10⁻¹⁵ per run).
- Full CI matrix green (4 platforms × 2.2.4/2.2.10/devel, orc+refc,
  debug+release); local ASAN+refc+useMalloc 0/20.

## 5. Sanitizer CI greening (first-ever full `all × all × all` rounds)

The full rounds surfaced **pre-existing** issues (A/B-confirmed on master,
runs 28654935204 / 28654936328):

- **Windows**: unquoted suppression paths — `UBSAN_OPTIONS=…:suppressions=D:\…`
  aborts the sanitizer flag parser on the drive-letter colon *before any test
  runs* ("expected '=' in UBSAN_OPTIONS"). Fixed by single-quoting the paths
  (parser-portable). Windows ASan cells green for the first time.
- **windows × devel** matrix cell could never pass (setup-nim-action can't
  install devel on Windows) — excluded, matching `ci.yml`.
- **Linux LSan**: a family of *by-design, thread/process-lifetime* allocations
  reported at worker-thread exit because **orc never frees thread heaps** and
  **chronos 4.2.2 has no `PDispatcher` teardown**: the dispatcher object graph
  (~36 KB/thread; we reclaim only the OS handle), the ORC cycle-collector's
  lazy 16 KB per-thread roots buffer (`registerCycle`), and registration-path
  threadvar seq growth (generated `*MtImpl`/`setProvider`/`makePollFn`,
  `onThreadDestruction` handler list, `ensureBrokerDispatchStarted`). Each is
  suppressed in `tools/sanitizers/lsan.supp` with rationale and an explicit
  masking-trade-off note; dispatch/decode and FFI courier lanes remain fully
  leak-checked. (The fix branch leaked *less* than master: 39/71,912 B vs
  49/73,080 B before suppressions.)
- macOS ASan+UBSan and TSan: green throughout — TSan directly validates the
  `BrokerSignalShared` happens-before edges and teardown ordering.

## 6. Remaining caveats (documented, not bugs in broker code)

1. **Upstream chronos**: the Windows waitable path itself (GC-heap `ref` on an
   OS wait thread; no unregister-at-exit; no `PDispatcher` destructor). Issue
   draft with minimal repro prepared (session scratchpad `chronos_issue.md`);
   consider `WT_EXECUTEINWAITTHREAD` / unregister-at-exit upstream.
2. **App-level refc hazard**: user code allocating Nim memory inside its own
   `RegisterWaitForSingleObject` callback still crashes under refc
   (`nimble probeWinTlsUninitRefc` reproduces) — structural, upstream.
3. **Contract**: foreign/FFI threads that used broker APIs must call
   `teardownBrokerThread()` before their final return; same for the main
   thread if it needs handle reclamation before process exit.

## 7. Artifacts

- Fix + gate: PR #38 (merged); harness tail: PR #39.
- Reproducer: `test/test_alloc_race_variants.nim` (+ in the normal MT matrix).
- Workflows: `ci.yml` (Windows gate step), `teardown_verify.yml`,
  `memcheck_ci.yml` (full sanitizer matrix, windows×devel excluded).
- Investigation experiments preserved in branch history of
  `experiment/usemalloc-25513` (branch deleted; see PR #38 discussion).
