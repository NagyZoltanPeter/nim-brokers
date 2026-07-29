# Security Test Plan — reproducing the 2026-07 audit findings

Companion to [`SECURITY_AUDIT_2026-07.md`](SECURITY_AUDIT_2026-07.md). Each entry gives a
**reproduction test** whose purpose is to _demonstrate the bug exists on the current tree_ and
then serve as a **regression gate** once the fix (see [`SECURITY_FIX_PLAN.md`](SECURITY_FIX_PLAN.md))
lands. A test "passes" only after the fix; on today's tree the memory-safety tests are expected
to **fail loudly** (sanitizer abort / crash / hang), which is the proof-of-existence.

## Tooling & harness

- **Nim unit layer:** `testutils/unittests` (as the rest of `test/` uses). New files go under
  `test/security/` and are wired into new nimble tasks `securityTest` (single-thread + mt) and
  `securityTestApi` (FFI, `-d:BrokerFfiApi --threads:on`), mirroring the existing `test` /
  `testApi` task shape in `brokers.nimble`.
- **Sanitizers:** reuse the existing `memcheck_ci.yml` infrastructure and
  `tools/sanitizers/{asan,lsan,tsan,ubsan}.supp`. Memory-safety findings are gated under
  AddressSanitizer (`--passC:-fsanitize=address --passL:-fsanitize=address -d:useMalloc`) and
  ThreadSanitizer (`--passC:-fsanitize=thread --passL:-fsanitize=thread`). Run under both
  `--mm:orc` and `--mm:refc`.
- **Determinism:** race/UAF repros are wrapped in an N-trial loop (reuse the `testAllocRace`
  pattern: 40 trials, refc + release) so a probabilistic UAF is caught reliably in CI rather
  than flaking green.
- **Foreign-wrapper findings** (M1, M2, S12) are exercised through the generated example/parity
  harnesses (`runFfiExample{Cpp,Py,Rust,Go}`, `runTypeMapTestLib*`) with a deliberately
  faulty callback added to a dedicated `security_example`.

| Finding | Layer | Primary detector | New/756 task |
|---|---|---|---|
| H1 | FFI | ASan (UAF) + hang watchdog | `securityTestApi` |
| H2 | FFI | wall-clock watchdog | `securityTestApi` |
| H3 | mt | ASan (UAF) + delivery-integrity assert | `securityTest` (mt) |
| M1 | C++/Rust/Go wrappers | process-survives assert | `runFfiExampleCpp/Rust/Go` variant |
| M2 | wrappers | ASan (UAF) | `securityTestApi` + wrapper |
| M3 | CBOR | decode-rejects assert | `securityTest` |
| M4 | FFI | reject-oversize assert | `securityTestApi` |
| M5 | FFI | ASan (heap OOB read) | `securityTestApi` |
| M6 | FFI | process-survives assert | `securityTestApi` |
| M7 | FFI | ASan (bad free) | `securityTestApi` |
| M8 | FFI | TSan (data race) | `securityTestApi` (TSan) |
| M9 | mt | TSan + code assertion | `securityTest` (TSan) |
| S2,S3,S5,S8 | mixed | targeted asserts | `securityTest`/`securityTestApi` |
| B1–B6 | CI/policy | static policy check script | `securityPolicyCheck` |

---

## HIGH

### H1 — `_shutdown` UAF with a slow provider
**File:** `test/security/test_h1_shutdown_uaf.nim` (FFI, ASan).
1. Build a minimal API library with one `RequestBroker(API)` whose provider does
   `await sleepAsync(6000)` then returns `ok(...)`.
2. `initialize()`; `ctx = createContext()`.
3. Thread A: `_call(ctx, "slowReq", buf, len)` (sync path → parks in `waitSlot`).
4. Thread B: after 200 ms, `_shutdown(ctx)`.
5. **Bug signature (today):** after the 5 s drain, `freeCborCourier` deallocs the slot's
   `Cond`/`Lock`; thread A is either (a) killed by ASan with a `heap-use-after-free` on
   `wait(s.cond, s.lock)`, or (b) hangs forever on a freed primitive → the **30 s wall-clock
   watchdog** fails the test.
6. **Pass after fix:** thread A returns a well-defined status (e.g. `ApiStatusShutdown` /
   `ApiStatusAgain`) within the drain budget; no ASan report; watchdog not tripped.

### H2 — Sync `_call` never times out
**File:** `test/security/test_h2_sync_call_timeout.nim` (FFI).
1. Same library, provider that **never** completes (`await newFuture[void]()` — pending forever).
2. Thread A: `_call(ctx, "hangReq", …)` inside a 3 s watchdog.
3. **Bug signature:** the watchdog fires (call never returns).
4. **Pass after fix:** the call returns a timeout status within the configured sync deadline.
   *(This test also guards that `_callAsync` still honors its existing `timeoutMs`.)*

### H3 — Request-timeout poller leak → slot double-release
**File:** `test/security/test_h3_slot_double_release.nim` (mt `RequestBroker`, ASan, N-trial).
Deterministic construction of the leaked-poller interleaving described in the finding:
1. `RequestBroker(mt)` with `responseSlots = 1` (forces slot-index reuse on the *same* index).
2. Install a provider whose completion is gated by a test-controlled `AsyncEvent` so timing is
   deterministic, not `sleep`-based.
3. **R1:** `request(...)` with a short `timeout`; do **not** release the provider gate → R1 times
   out (`abandon` succeeds on the still-`Empty` slot; poller P1 leaks).
4. Release the gate so R1's provider now runs `sendReply` on slot idx 0 (`beginWrite` CAS fails →
   `release(0)` pushes idx 0 to the free-list).
5. **R2:** `request(...)`; it claims idx 0 again, registers P2; gate its provider to write `Ready`.
6. Drive the dispatch loop. **Bug signature:** P1 (leaked) also polls idx 0, sees `Ready`, calls
   `release(0)` on **R2's** live slot → double free-list push. Detect via either:
   - an instrumented `release` counter (assert exactly one release per `(slotIdx, generation)`), or
   - a follow-on **R3** that must receive its *own* response — assert no cross-delivery /
     corrupted bytes; and
   - run the whole file under ASan after a `clearProvider` + `drainPendingRingFrees` to catch the
     escalated **pool UAF** (leaked poller dereferences freed `(ring,slab,pool)`).
7. **Pass after fix:** each request gets exactly its own response; instrumented release count is
   1 per slot lifetime; no ASan report over 40 trials.

---

## MEDIUM

### M1 — Callback exception/panic across the C ABI (C++, Rust, Go)
**Files:** `examples/ffiapi/security_example/` variants + `test/security/test_m1_callback_faults.*`.
- **C++:** register an async completion callback (`fooAsync`) that `throw std::runtime_error`. Today
  the exception unwinds `asyncResponseTrampoline` → `std::terminate`. Test asserts the process is
  still alive and a subsequent call succeeds.
- **Rust:** an `on_<event>` closure that `panic!()`. Today aborts the process. Same survive-assert.
- **Go:** an `On<Event>` handler that `panic(...)`. Today UB/crash. Same survive-assert.
- **Pass after fix:** the faulting callback is isolated (logged/dropped), process survives, later
  calls/events still work. Run each under its language's normal `run*` task; the survive-assert is
  the harness exiting 0.

### M2 — In-flight event callback during shutdown (UAF)
**File:** `test/security/test_m2_callback_vs_shutdown.nim` + wrapper (ASan).
1. Subscribe an event whose foreign callback blocks on a test barrier when invoked.
2. Emit the event (delivery thread enters the callback, waits on the barrier).
3. Call `_unsubscribe` then `_shutdown(ctx)` from the main thread; then release the barrier.
4. **Bug signature (today, contingent on H1):** callback storage is freed while the delivery
   thread is still inside it → ASan `heap-use-after-free` (Rust `Box`, C++ `*owner_`), Python
   frees the live `CFUNCTYPE` thunk, Go's `cgo.Handle.Value()` panics on a deleted handle.
5. **Pass after fix:** shutdown blocks until the in-flight callback returns (H1 fix); no UAF.

### M3 — Holey-enum invalid value accepted on decode
**File:** `test/security/test_m3_holey_enum.nim` (CBOR decode, pure).
1. Declare `type Gappy = enum A = 0, B = 2, C = 5`.
2. Hand-encode a CBOR request whose enum-typed field is the integer `3` (in `[low,high]` but not a
   member). Use the raw codec (`cborEncode` of a byte payload, or emit the 1-byte CBOR `0x03`).
3. `cborDecode[...]` the buffer.
4. **Bug signature:** decode **succeeds** and yields an invalid enum; a follow-up
   `case decoded of A/B/C` or `array[Gappy, int][decoded]` crashes (build with bound checks on,
   not `-d:danger`).
5. **Pass after fix:** decode raises/`err`s ("out of set") for `3`, matching the Table-key path.
   Parametrize over enum-as-arg, enum-as-object-field, and enum map-value.

### M4 — `maxPayloadBytes` not enforced on decode
**File:** `test/security/test_m4_maxpayload.nim` (FFI).
1. `RequestBroker(API, maxPayloadBytes = 256)`.
2. `_call` with a well-formed CBOR buffer of, say, 4 KiB (< 64 MiB, > 256).
3. **Bug signature:** the call is accepted and the 4 KiB buffer allocated/decoded.
4. **Pass after fix:** `_call` returns the size-reject status (`-3`) when `reqLen` exceeds the
   broker's configured `maxPayloadBytes`.

### M5 — `reqLen` OOB read
**File:** `test/security/test_m5_reqlen_oob.nim` (FFI, ASan).
1. `alloc`/`_allocBuffer` a 16-byte buffer; write 16 valid bytes.
2. `_call(ctx, api, buf, reqLen = 1_000_000)` (still < 64 MiB).
3. **Bug signature:** ASan `heap-buffer-overflow` on the `copyMem(addr nimReq[0], reqBuf, reqLen)`.
4. **Pass after fix:** rejected before copy, or copy bounded to the real allocation (requires a
   length the ABI can trust — see fix plan; at minimum document + tighten the cap).

### M6 — `_subscribe` before `_createContext`
**File:** `test/security/test_m6_subscribe_uninit.nim` (FFI).
1. `initialize()` **only** (no `createContext`), or a fresh process; call
   `_subscribe(0, "knownEvent", cb, ud)`.
2. **Bug signature:** segfault in `withLock reg.lock` (nil registry).
3. **Pass after fix:** returns a defined error code (uninitialized) or lazily initializes; process
   survives. Also test `_unsubscribe` symmetrically.

### M7 — `_freeBuffer` frees arbitrary/static pointers
**File:** `test/security/test_m7_freebuffer.nim` (FFI, ASan).
- **7a:** `_freeBuffer(_version())` → ASan bad-free/`attempting free on address which was not
  malloc`ed`.
- **7b:** `p = _allocBuffer(32); _freeBuffer(p); _freeBuffer(p)` → ASan double-free.
- **Pass after fix:** with provenance tagging, `_freeBuffer` rejects the static and the
  already-freed pointer (no-op + optional error log); no ASan report.

### M8 — Discovery-API lazy-init data race
**File:** `test/security/test_m8_discovery_race.nim` (FFI, TSan, N-trial).
1. From a just-initialized library, spawn K=8 foreign threads that all call `_listApis` /
   `_getSchema` simultaneously (barrier-released).
2. **Bug signature:** TSan reports a data race on the descriptor/api-list globals (and under refc,
   cross-thread GC access).
3. **Pass after fix:** once-guarded init (CAS); no TSan report over the trials.

### M9 — `moRelaxed` init fast-path
**File:** `test/security/test_m9_init_fastpath.nim` (mt, TSan) + a static assertion.
- TSan on x86 will likely stay green (TSO), so this is primarily a **code-level regression guard**:
  a compile-time/`static` check (or a small unit that greps the generated AST under
  `-d:brokerDebug`) asserting the fast-path load uses `moAcquire`. Optionally run the multithread
  stress (`perftest`) under TSan on an ARM runner if available.
- **Pass after fix:** the assertion sees `moAcquire` at all five sites.

### Lower-tier targeted asserts
- **S2 (ctx exhaustion):** unit that calls the internal `NewBrokerContext` counter path to the
  wrap boundary via a test hook (or a shrunk counter type behind a `-d:brokerTestTinyCtx`) and
  asserts a returned error instead of a `Defect`/abort.
- **S3 (subs growth):** loop `_subscribe(ctx=i, "knownEvent", cb, ud)` for i in 0..<N with a
  fixed, live class ctx; assert the registry rejects unknown/dead `ctx` (after fix) rather than
  growing unbounded (measure RSS/node count today).
- **S5 (blocking-timeout slot leak):** `RequestBroker(mt, sync-blocking)` with `responseSlots`
  small; drive the provider to write `Ready` inside the abandon race window (test barrier);
  assert the pool's free-slot count returns to full after the timeout (today it decays).
- **S8 (sizing overflow):** a `static:` compile-time test that instantiates
  `RequestBroker(API, maxPayloadBytes = high(uint32))` (and near-boundary values) and asserts a
  compile-time `error` (after fix) instead of silently producing an undersized stride.

---

## Build / CI / supply chain (B1–B6)

**File:** `tools/security/policy_check.sh` wired as nimble task `securityPolicyCheck`, run in CI.
Static, no runtime:
- **B1:** assert `nimble.lock` exists and is non-empty; fail otherwise.
- **B2:** grep every `uses:` in `.github/workflows/*.yml`; fail on any ref not matching a 40-hex
  commit SHA (allowlist first-party `actions/*` only if policy chooses).
- **B3:** assert any `pip install` line pins `==<version>` and uses `--require-hashes`.
- **B4:** assert either a real `.gitmodules` entry for `vendor/jsoncons` pinned to a SHA, **or** a
  committed `vendor/jsoncons/UPSTREAM_SHA` file, and that the `ci.yml` fallback references that SHA
  (not `v1.0.0`); assert AGENTS.md no longer claims a submodule if there isn't one.
- **B5:** assert `choco install llvm` carries `--version`.
- **B6:** grep `manual_win_dbg.yml` for direct `${{ inputs.* }}` interpolation into `run:` blocks
  (should route via `env:`); assert `pages.yml` scopes `pages`/`id-token: write` to the `deploy`
  job.

---

## CI wiring summary

Add to `brokers.nimble`:
- `securityTest` — single-thread + mt repro files (H3, M3, M9, S2, S5, S8), ORC+refc.
- `securityTestApi` — FFI repro files (H1, H2, M2, M4, M5, M6, M7, M8, S3),
  `-d:BrokerFfiApi --threads:on`.
- `securityPolicyCheck` — B1–B6 static gate.
- Extend `memcheck_ci.yml` to run `securityTest`/`securityTestApi` under ASan and TSan
  (`--mm:orc` and `--mm:refc`), N-trial-wrapped for the UAF/race files.

Each memory-safety file must be demonstrated to **fail on `2b0732e`** (pre-fix) and **pass after
the corresponding fix**, so the gate has proven discriminating power.
