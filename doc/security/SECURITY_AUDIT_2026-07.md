# Security & Vulnerability Audit — nim-brokers

- **Date:** 2026-07-29
- **Commit audited:** `2b0732e` (master)
- **Method:** Five parallel focused review passes (FFI C-ABI boundary ×2 independent,
  CBOR decode of untrusted input, multi-thread shared-memory internals, foreign-language
  wrapper code-generation, build/CI/supply-chain), plus manual source verification of every
  HIGH finding and the top MEDIUM findings.
- **Result of this pass:** findings only. No library code was changed.

Companion documents:
- [`SECURITY_TEST_PLAN.md`](SECURITY_TEST_PLAN.md) — reproduction tests for each finding.
- [`SECURITY_FIX_PLAN.md`](SECURITY_FIX_PLAN.md) — detailed implementation plan for the fixes.

---

## Threat model

The primary attack surface is the **FFI boundary**: a compiled broker library
(`-d:BrokerFfiApi`) is loaded into a C/C++/Python/Rust/Go host and receives raw pointers,
lengths, and attacker-influenced **CBOR** buffers through the fixed 12-function C ABI. The
multi-thread internals (`(mt)` brokers) are a secondary surface: same-process, but exposed
to lifecycle/teardown races. Single-thread brokers are pure threadvar code with no shared
heap and are out of scope for memory-safety concerns.

**Key caveat that colours several findings:** the actual CBOR length-prefix parsing
(array/map/string counts, nesting depth) lives in the external `cbor_serialization`
dependency, which is **not vendored in this checkout** and is pinned only as `>= 0.3.0`.
Decode-side defenses against count-amplification OOM and nesting-depth stack overflow depend
entirely on that library and could not be audited here (see **S1**).

**Severity legend:** HIGH = reachable memory-safety or exploitable defect · MEDIUM =
memory-safety bug requiring specific-but-plausible conditions, or a security-relevant design
gap · LOW/smell = latent, narrow-window, config-only, or hardening · `[verifiable]` = confirmed
against source · `[smell]` = latent/robustness · `[known]` = already documented in
`doc/LIMITATION.md`.

---

## HIGH

### H1 — Use-after-free in `<lib>_shutdown` when a provider outlives the 5 s drain `[verifiable]`
**`brokers/api_library.nim:1748-1800`, `brokers/internal/api_cbor_courier.nim:468-479`**
*(Found independently by both FFI passes; verified in source.)*

`<lib>_shutdown` drains in-flight sync calls **best-effort** for 5 s
(`while inFlight > 0 and waitedMs < 5000: sleep(1)`), then **unconditionally** joins both
threads and calls `freeCborCourier`, which `deinitCond`/`deinitLock`/`deallocShared`s every
response slot. A foreign `_call` thread meanwhile blocks in `waitSlot` with **no timeout**
(`while s.ready == 0: wait(s.cond, s.lock)`). A provider that takes >5 s (a slow DB/network
call — not necessarily malicious) leaves the foreign thread parked on a `Cond`/`Lock` that
shutdown then frees: undefined behaviour / crash on the host thread, and the caller can never
wake.

**Repro:** register a provider that `await`s ~6 s; issue a sync `_call` on thread A; call
`_shutdown(ctx)` on thread B. After 5 s, thread A operates on freed synchronization primitives.

### H2 — Sync `_call` has no dispatch timeout `[verifiable]`
**`brokers/internal/api_cbor_courier.nim:468-479`**

Unlike `_callAsync` (which races a chronos timer), the sync path blocks unconditionally. A
provider that never resolves parks the foreign caller's thread forever (liveness/DoS). It is
also the **precondition for H1** — the missing timeout is what leaves a caller blocked across
the courier free.

### H3 — Request-timeout leaks its response-slot poller → slot double-release / pool corruption / UAF `[verifiable]`
**`brokers/internal/mt_request_broker.nim:1003-1045`** (multi-thread `RequestBroker`, independent of FFI)

The one-shot poller self-unregisters (`return 2`) **only** when it observes the slot `Ready`
(`:1006-1028`). On timeout (`:1039-1045`) the code `cancelSoon` + `abandon`s the slot but
**never unregisters the poller**. After the slot index is recycled to a later request, the
leaked poller can call `release()` on a *different* request's live slot → the free-list hands
the same index out twice → cross-delivered/garbage responses; and if the provider's
`(ring,slab,pool)` triple is later freed (`drainPendingRingFrees`), the leaked poller
dereferences freed memory. Fires on the **common** timeout path (provider hasn't started
writing yet).

---

## MEDIUM

### M1 — Callback exceptions/panics unwind across the C ABI in three wrappers `[verifiable]`
Same root cause emitted into three languages; the C++ **event** path and both Python paths
already guard, so these are parity gaps too:
- **C++ async response** — `asyncResponseTrampoline` emitted as plain `inline void`, not
  `noexcept`, invoker call not wrapped in try/catch — `brokers/internal/api_codegen_cbor_hpp.nim:1681-1688`.
  A throwing completion callback → `std::terminate` / UB.
- **Rust event** — `cbor_trampoline` calls the user closure with no `catch_unwind` —
  `brokers/internal/api_codegen_cbor_rust.nim:1523-1536`. A panicking `on_<event>` aborts the host.
- **Go event** — `goCborEventTrampoline` calls the handler with no `defer/recover` —
  `brokers/internal/api_codegen_cbor_go.nim:1025-1040`. A panic escaping an `//export` fn is UB.

### M2 — In-flight event callback vs shutdown/unsubscribe: cross-language UAF, contingent on H1 `[verifiable, contingent]`
Each wrapper frees callback storage (C++ dispatcher/`*owner_`, Python `CFUNCTYPE` thunk, Rust
`Box<Arc>`, Go `cgo.Handle`) **after** `<lib>_shutdown`, on the assumption that shutdown
quiesces the delivery thread. H1 shows that drain is only best-effort (5 s timeout), so the
assumption does not hold: Python frees executable thunk memory in use, Go's deleted
`cgo.Handle.Value()` panics, Rust/C++ dereference freed storage. Tightening H1 closes M2.
*(Wrapper-generator sites: `api_codegen_cbor_hpp.nim:1954-1959`, `_py.nim:900-914`,
`_rust.nim:902-909`, `_go.nim:588-595`.)*

### M3 — Holey enum: range-only check admits an invalid enum value `[verifiable]`
**`brokers/internal/api_cbor_codec.nim:98-107`**

Decode validates only `ord(T.low) <= i <= ord(T.high)`, not membership. For a holey enum
(`A = 0, B = 2, C = 5`) an attacker sends the wire int `3`: it passes and `value = T(3)`
constructs an invalid enum value — UB downstream (`case value of`, array indexing on a jump
table → OOB/crash). The Table-**key** enum path already does the correct membership walk
(`api_cbor_tables.nim:86-93`), so this is an internal inconsistency.

### M4 — `maxPayloadBytes` does not bound untrusted decode; a fixed 64 MiB cap does `[verifiable design gap]`
**`brokers/api_library.nim:374`** (and the `_call`/`_allocBuffer` gates)

`RequestBroker(API, maxPayloadBytes = …)` sizes internal MT slab cells; it does **not** limit
the incoming CBOR request buffer, which is gated only by a hard-coded 64 MiB. An operator who
sets `maxPayloadBytes = 256` to cap memory still allows a 64 MiB attacker buffer per call, ×
concurrent calls.

### M5 — `reqLen` trusted as the `copyMem` size → OOB read up to 64 MiB `[verifiable]`
**`brokers/api_library.nim:1391-1393`, `:1451-1453`**

`_call`/`_callAsync` validate `reqLen` only for sign and the 64 MiB cap, then
`copyMem(addr nimReq[0], reqBuf, reqLen)`. A 16-byte buffer passed with `reqLen = 64 MiB`
triggers a large OOB read (crash/DoS; garbage only reaches the decoder, which errors). Inherent
to `(ptr,len)`, but the cap is very permissive. *(Good: `reqBuf == nil && reqLen > 0` is defended.)*

### M6 — `_subscribe`/`_unsubscribe` NULL-deref if called before `_createContext` `[verifiable]`
**`brokers/api_library.nim:1134-1166`, `brokers/internal/api_cbor_subs_registry.nim:217`**

The subs registry is nil until `_initialize` (reached only via `_createContext`).
`_subscribe`/`_unsubscribe` don't initialize it and go straight to `withLock reg.lock` →
segfault. A wrapper that probes support, or any out-of-order caller, hard-crashes the host.

### M7 — `_freeBuffer` frees any caller pointer, including the static version string `[verifiable]`
**`brokers/api_library.nim:831-837`**

Only a nil check; no provenance tag. Enables double-free of a response buffer, or freeing the
`_version()` return (documented "must NOT be freed", points into a Nim `const` string's static
storage) → static-memory corruption. Aggravated by the `_call` ownership model where `reqBuf`
transfers to the library on every path, so a caller that reflexively frees `reqBuf` double-frees.

### M8 — Data race in the discovery API lazy-init `[verifiable on weak-memory / refc]`
**`brokers/api_library.nim:2250-2265`** (`ensureDescriptor` / `ensureApiList`)

`_listApis`/`_getSchema` build GC-heap globals guarded by a non-atomic check-then-set. Two
foreign threads racing the init share GC'd seq/string globals across threads under refc — the
hazard the hand-rolled shared registry exists to avoid elsewhere. Needs a CAS/once guard (the
pattern already used for `ctxsInit` at `:806-814`).

### M9 — Double-checked init fast-path uses `moRelaxed`, missing the acquire edge `[verifiable on ARM/POWER]`
**`brokers/internal/mt_event_broker.nim:223,239`, `mt_request_broker.nim:458`,
`mt_signal_broker.nim:189,205`**

The slow path publishes with `moRelease`, but the fast path reads the init flag with
`moRelaxed` and then touches non-atomic guarded state (bucket array, `initLock`, slab pointers).
No happens-before is established → stale/garbage slab pointer or use of an uninitialized `Lock`
on weak memory. Benign on x86 (the CI cells); latent on ARM. One-line fix per site (`moAcquire`).

---

## LOW / smells

- **S1 — Untrusted CBOR robustness delegated to an unvendored, floating dependency** `[smell]` —
  `cbor_serialization >= 0.3.0`; no depth/size limits on the `BrokerCbor` flavor.
  Count-driven preallocation (a 10-byte input claiming "array of 4 billion") and unbounded
  nesting → stack overflow are **uncatchable** by the broker's `try/except` (they abort before
  an exception is raised). Cross-cut: CBOR Findings 3-4, FFI F8.
- **S2 — Context-ID exhaustion aborts the host process** `[verifiable]` —
  `brokers/broker_context.nim:82-84,103-104` `doAssert` on overflow → a `Defect` from inside a
  shared library after 65 534 create/shutdown cycles. Return an ABI failure code instead.
- **S3 — Unbounded subscription-registry growth (DoS)** `[verifiable]` — `_subscribe` never
  validates `ctx` and imposes no cap (`brokers/api_library.nim:1134-1166`); each accepted call
  `allocShared0`s a node. Loop over `ctx = i` → OOM.
- **S4 — Context handles are small, guessable, unvalidated integers** `[smell]` — routed by the
  low 16 bits (`brokers/api_library.nim:1865-1875`). Fine within one trust domain; a
  multi-tenant host over one loaded library has no isolation between contexts (confusion, not crash).
- **S5 — Blocking-request timeout can permanently leak a response slot** `[verifiable]` —
  `brokers/internal/mt_request_broker.nim:1124-1148`; narrow race (provider writes `Ready`
  between the last check and `abandon`) → gradual pool exhaustion, not corruption.
- **S6 — Time-based (50 ms) grace windows for freeing ring/slab/pool** `[known]` —
  `brokers/internal/mt_event_broker.nim:935-941`, `mt_broker_common.nim:388`; a producer stalled
  past the window writes to freed shared memory (low-probability UAF) plus a possible cell leak.
- **S7 — Degenerate teardown ordering** `[smell]` — `brokers/internal/mt_broker_common.nim:451-460,522-525`;
  if `stopBrokerDispatchHere`'s 2 s wait expires, `teardownBrokerThread` closes the signal while
  the loop still awaits it → nil deref. Pathological path only.
- **S8 — Unchecked integer overflow in slab/pool sizing** `[verifiable, config-only]` —
  `brokers/internal/mt_queue.nim:318-321,479-482`; `maxPayloadBytes`/`slabCapacity`/`responseSlots`
  validated only `> 0` (`mt_config.nim:247-252`). A near-`high(uint32)` config truncates on the
  `uint32` cast and can overflow `alignUp` → undersized cell stride while full payloads are still
  written = heap overflow. `queueDepth` *is* correctly pow2-guarded.
- **S9 — `mtUnmarshalSeq` allocates `newSeq(count)` before bounds-checking (non-POD branch), +
  32-bit length overflow** `[verifiable, not FFI-reachable]` — `brokers/internal/mt_codec.nim:85-90,201`;
  internal cross-thread format (trusted producer), but the POD/string branches validate first
  and should be mirrored.
- **S10 — `cstring` args walked by `strlen` before validation** `[smell]` — `_call` apiName,
  `_subscribe` eventName; inherent `const char*` contract; a non-NUL-terminated pointer OOB-reads.
  State loudly in the generated header contract.
- **S11 — Duplicate CBOR map keys silently tolerated** `[smell]` — `api_cbor_tables.nim:106`
  last-wins, tuple first-wins; RFC 8949 calls these malformed. Parser-differential/smuggling
  concern, not memory-unsafe.
- **S12 — Go `internalCborCall` copies response with unguarded length** `[smell]` —
  `brokers/internal/api_codegen_cbor_go.nim:634-636` checks `outBuf != nil` but not `outLen > 0`;
  `C.GoBytes` with a negative length panics. Library-controlled today, latent.
- **S13 — teardown contract footgun** `[CLOSED — retrospective only; corrected 2026-07-30]` —
  the original entry claimed foreign/FFI threads must call `teardownBrokerThread()` or risk a
  Windows+refc UAF at thread exit. **Re-verification shows this does not apply to the CBOR FFI
  lane**, and `LIMITATION.md` §2.2 documents an already-fixed issue retained as a retrospective:
  - The teardown-sequence fix is in place: `BrokerSignalShared`
    (`brokers/internal/mt_broker_common.nim:190+`) and `teardownBrokerThread` (`:492`),
    auto-registered via `onThreadDestruction` for Nim-created threads (`:423-428`).
  - The FFI lane's own threads call it explicitly — delivery `api_library.nim:1300`,
    processing `:1580`.
  - Foreign caller threads call `ensureForeignThreadGc()` but **never**
    `ensureBrokerDispatchStarted()` (only `:1280` / `:1561`, both library-owned threads; the mt
    macro call sites run on the processing thread). With no per-thread dispatch loop started,
    a foreign thread has no teardown obligation.

  **Remaining real caveat, unchanged and by design:** a thread *not created by Nim* that drives
  `(mt)` brokers **directly** (outside the FFI lane) still must call `teardownBrokerThread()`;
  and app code must not call Nim allocators from its own `RegisterWaitForSingleObject` callbacks
  under refc. Neither is a CBOR-FFI-lane finding. **No action in this audit.**
- **S14 — foreign threads register with the GC and never unregister** `[smell — verify]` —
  `ensureForeignThreadGc()` (`brokers/internal/api_common.nim:305-322`) is latched per thread
  (`gForeignGcRegistered` threadvar) and calls `setupForeignThreadGc()`, but there is no paired
  `tearDownForeignThreadGc()` on any path. A foreign thread that calls into the library and then
  exits leaves a registered-but-dead thread entry; under refc the collector can retain/scan a
  dead thread's stack bottom. Bounded by the number of distinct foreign threads, so low impact —
  but worth confirming against Nim's current refc behaviour before dismissing. nim-ffi pairs the
  two around each call (`ffi/ffi_types.nim:22-29`, `foreignThreadGc` template).

### Build / CI / supply chain
- **B1 [High] — No dependency lockfile; all nimble deps floating `>=`** — `brokers.nimble:12-17`;
  CI runs `nimble install -d -y` every build (`.github/workflows/ci.yml:89,129`). A compromised
  upstream runs arbitrary code in CI (holds `GITHUB_TOKEN`) and in every user build. Commit a
  `nimble.lock`.
- **B2 [High] — Third-party Actions pinned by mutable refs, not SHAs** — worst is
  `dtolnay/rust-toolchain@stable` (movable branch); also `jiro4989/setup-nim-action@v2` (handed
  `GITHUB_TOKEN` via `repo-token`), `arnetheduck/nph-action@v1`, `actions/*@v4/v5/v6`. Pin to SHAs.
- **B3 [Medium] — `pip install --user cbor2` unpinned** — `.github/workflows/ci.yml:139`; no
  version/hash pin; a malicious PyPI release executes at install time in CI.
- **B4 [Medium] — jsoncons "vendored submodule" claim is false** — 171 plain committed files at
  **v1.7.0**, no `.gitmodules`, `fetchVendor` is a silent no-op, and the dormant CI fallback clones
  a *different* version via a **mutable tag** (`--branch v1.0.0`, `ci.yml:144`). Reconcile.
- **B5 [Medium] — `choco install llvm -y` unpinned** — `ci.yml:73`, `memcheck_ci.yml:117`.
- **B6 [Low, smells]** — `getEnv("MM")`/etc. concatenated unquoted into `nim c` command strings
  (dev-controlled, not event-reachable); `${{ inputs.tasks }}` interpolated into a pwsh block in
  `manual_win_dbg.yml:69` (mitigated: `type: choice`, workflow_dispatch-only); `pages.yml` grants
  `pages/id-token: write` at workflow scope instead of the `deploy` job only.

**Checked and clean:** no committed secrets/keys/tokens (only the standard `GITHUB_TOKEN`); no
`pull_request_target`; no `${{ github.event.* }}` in `run:` blocks; no `curl|bash`; Go `go.sum`
and Rust `Cargo.lock` committed (transitive deps pinned).

---

## What is done well (verified, not re-flagged)

Consistent `{.push raises: [].}` + Result-based (no-exception) boundaries. The **core
lock-free primitives are correct**: Vyukov MPSC ring (proper acquire/release, pow2-asserted,
signed full/empty diff), ABA-tagged sharded Treiber free lists, the `ResponseSlotPool` state
machine, `BrokerSignalShared`'s close/recycle protocol (neutralizes the "fire an exited
thread's signal" hazard), and the refcounted emit fan-out (exactly-N decrements). Lock
discipline is clean (no OS lock held across `await`; `try/finally` release on every path).
Request-buffer ownership is balanced on every FFI error path; `_allocBuffer`/`reqLen` are
sign+cap checked; non-string CBOR map keys and both/neither-present envelopes are correctly
rejected; Python ctypes `argtypes`/`restype` widths are complete.

---

## Recommended fix order

1. **H1 + H2** together — bound `waitSlot`, and don't free the courier while a caller can still
   be blocked (also closes **M2**).
2. **H3** — unregister the timeout poller (or tag slots with a request generation checked before
   `release`).
3. **M1** (noexcept/`catch_unwind`/`recover`) and **M3** (enum membership walk) — cheap, high value.
4. **M6, M7, M8** — nil-guard/lazy-init subscribe; tag library allocations; once-guard discovery init.
5. **S1** — audit the `cbor_serialization` reader for count-preallocation and a depth cap.
6. **B1, B2** — lockfile + SHA-pin Actions.

The two findings to treat as genuine memory-safety threats rather than smells are **H1** (FFI
shutdown UAF, corroborated by two independent passes) and **H3** (MT request-timeout slot
double-release), both verified against source.
