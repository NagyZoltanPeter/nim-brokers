# Security Fix Implementation Plan — 2026-07 audit

Companion to [`SECURITY_AUDIT_2026-07.md`](SECURITY_AUDIT_2026-07.md) and
[`SECURITY_TEST_PLAN.md`](SECURITY_TEST_PLAN.md). Each fix lists **root cause**, **change**
(files/functions), **ABI/API impact**, **risk & blast radius**, and the **verifying test**.

> Per repo convention (`CLAUDE.md`): run `gitnexus_impact({target, direction:"upstream"})` on
> each symbol before editing and report HIGH/CRITICAL blast radius; run
> `gitnexus_detect_changes()` before committing; format with `nimble nphall`; compile every test
> with `--outdir:build`. The order below is dependency-aware: **H1/H2 first** (they also close M2),
> then H3, then the cheap correctness fixes, then hardening, then CI.

Suggested landing sequence (one focused PR per group keeps review + bisect clean):

| PR | Findings | Theme |
|---|---|---|
| 1 | H1, H2, M2 | Sync-call timeout + quiescent courier teardown |
| 2 | H3, S5 | Response-slot ownership on timeout |
| 3 | M1 | Callback fault isolation in 3 wrappers |
| 4 | M3 | Enum membership validation on decode |
| 5 | M4, M5, M6, M7 | FFI input/ownership hardening |
| 6 | M8, M9, S2, S8 | Init races + overflow guards |
| 7 | S3, S9, S10, S11, S12 | Remaining robustness |
| 8 | B1–B6 | Supply-chain / CI |

---

## PR 1 — H1 + H2 + M2: bounded sync call, quiescent teardown

**Root cause.** `waitSlot` (`api_cbor_courier.nim:468-479`) blocks unconditionally; `_shutdown`
(`api_library.nim:1748-1800`) frees the courier after a *best-effort* 5 s drain even if
`inFlight > 0`. A caller parked in `waitSlot` is then operating on freed `Cond`/`Lock`.

**Change.**
1. **Bounded `waitSlot`** — add a deadline parameter and switch to a timed wait:
   ```nim
   proc waitSlot*(c: ptr CborCourier, idx: int, timeoutMs: int):
       tuple[respBuf: pointer, respLen: int32, status: int32, timedOut: bool]
   ```
   Use `Cond` timed wait (chronos-free, foreign-thread-safe). On timeout, transition the slot to
   an **`Abandoned`-equivalent** state under `s.lock` so a late `completeSlot` becomes a no-op that
   releases the slot rather than writing into a slot the caller has left. Mirror the
   `ResponseSlotPool` `Empty→Abandoned` vs `Writing→Ready` mutual-exclusion already proven correct
   in `mt_queue.nim`.
2. **Sync `_call` timeout** — thread the configured sync deadline (reuse `_callAsync`'s
   `timeoutMs` config; default e.g. 30 s) into the sync path (`api_library.nim` `_call` body) and
   return a defined status (`ApiStatusAgain`/a new `ApiStatusTimeout`) on expiry. Closes **H2**.
3. **Quiescent teardown** — make courier free **conditional on genuine quiescence**. Two options;
   prefer (a):
   - **(a) Ref-count the courier keep-alive.** `waitSlot` holds a courier "in-use" reservation
     (atomic increment on entry, decrement on exit). `_shutdown` sets `shutdownFlag`, wakes all
     waiters (broadcast on every slot `Cond`), then blocks on `inUse == 0` **without an unbounded
     free** — only after the last waiter leaves does it call `freeCborCourier`. Because waiters now
     have a bounded `waitSlot` timeout, `inUse` reaches 0 in bounded time; there is no
     free-under-a-live-waiter window.
   - **(b)** If a hard bound is required, keep the timer but **broadcast-wake every slot `Cond`
     before joining**, and gate `freeCborCourier` behind `inUse == 0` with the waiters guaranteed
     to exit via their own `waitSlot` timeout. (Same invariant, expressed via the timeout.)
4. **M2 falls out of this**: once `_shutdown` provably blocks until in-flight sync **and**
   delivery-thread callbacks have returned (the delivery join at `:1761` already exists; ensure the
   event-courier drain waits for the current callback to return, not just for the ring to look
   empty), the wrappers' "free after shutdown" assumption becomes true. Add an explicit comment at
   each wrapper free site referencing this guarantee.

**ABI/API impact.** No change to the exported symbol set. Behavior change: a hung/slow sync call
now returns a status instead of blocking forever; a new status code may be added (document in the
generated headers and `FFI_API.md`). Wrappers gain a documented timeout error on the sync path.

**Risk / blast radius.** Touches the hottest FFI path. Run `gitnexus_impact` on `waitSlot`,
`completeSlot`, `freeCborCourier`, `_call`, `_shutdown` (expect HIGH — call this out). The timed
`Cond` wait must be correct on Windows (`api_cbor_courier` primitives) — validate under
`memcheck_ci.yml` on the Windows cells.

**Verifies:** `test_h1_shutdown_uaf.nim`, `test_h2_sync_call_timeout.nim`,
`test_m2_callback_vs_shutdown.nim` (all pass; no ASan report; watchdog not tripped).

---

## PR 2 — H3 + S5: response-slot ownership on timeout

**Root cause.** The async request poller (`mt_request_broker.nim:1003-1029`) self-unregisters only
on `Ready`; the timeout path (`:1039-1045`) abandons the slot but leaves the poller registered, so
a leaked poller can `release()` a *reused* slot (double free-list push → cross-delivery / pool
UAF). S5 is the blocking-path sibling (a slot stuck `Ready` after an abandon-race → leak).

**Change.**
1. **Unregister on every exit.** Give `registerBrokerPoller` a handle and explicitly deregister the
   poller on the timeout/error paths (`:1032-1045`), not only via the `return 2` self-unregister.
   If the poller API is fire-and-forget, add a cancellation token the timeout path sets, checked at
   poller entry (`return 2` immediately if cancelled — and crucially **do not** `release`).
2. **Slot generation tag (defense in depth).** Add a monotonic `generation` to each response slot,
   captured by the poller at registration. `release`/completion act only if
   `slot.generation == capturedGeneration`; a reused slot has a bumped generation, so a stale poller
   is a no-op. This makes the correctness independent of perfect deregistration timing and also
   fixes the escalated pool-UAF (stale poller can't touch a recycled slot).
3. **S5:** on the blocking timeout (`:1124-1148`), after `abandon` fails (provider already wrote
   `Ready`), the requester must **still reclaim** the slot: read-and-`release` the now-`Ready` slot
   instead of leaving it. Make the abandon/reclaim a single decision under the slot state machine so
   there is exactly one owner of the terminal transition.

**ABI/API impact.** None (internal mt machinery). `ResponseSlotPool` gains a `generation` field.

**Risk / blast radius.** `gitnexus_impact` on `registerBrokerPoller`, `ResponseSlotPool.release`,
`abandon`, `claim`, `sendAndAwait`, `blockingSendAndAwait`. Medium: the slot state machine is
proven correct today; the change adds a field and tightens caller obligations without altering the
CAS transitions.

**Verifies:** `test_h3_slot_double_release.nim` (single release per slot lifetime; no cross-delivery;
no ASan report over 40 trials), S5 slot-leak assert.

---

## PR 3 — M1: callback fault isolation (C++, Rust, Go)

**Root cause.** Three generated trampolines invoke user callbacks without a fault barrier while the
matching event/Python paths already have one.

**Change (generators emit the guard).**
- **C++** `api_codegen_cbor_hpp.nim:1681-1688`: emit `asyncResponseTrampoline` as `noexcept` and
  wrap the invoker call in `try { … } catch (...) { /* log-drop */ }`, matching the event path
  (`:1748-1761`).
- **Rust** `api_codegen_cbor_rust.nim:1523-1536`: wrap `arc(slice)` in
  `let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| arc(slice)));`. Ensure the
  closure bound allows `AssertUnwindSafe` (document why it is sound: the closure owns its state).
- **Go** `api_codegen_cbor_go.nim:1025-1040`: emit `defer func() { _ = recover() }()` at the top of
  `goCborEventTrampoline` (and inside `wrap` if user code runs there).
- Optionally surface a dropped-callback count / chronicles-style warn hook so faults are observable.

**ABI/API impact.** None; generated wrapper source only. Regenerate example outputs and the
typemappingtestlib bindings.

**Risk / blast radius.** Low, isolated to codegen templates; but a bug here ships to every generated
library, so validate the *emitted* code compiles and the survive-tests pass in all three languages
(`runFfiExampleCpp/Rust/Go`, `runTypeMapTestLib{Cpp,Rust,Go}`).

**Verifies:** `test_m1_callback_faults.*` (process survives a throwing/panicking callback; later
calls still work).

---

## PR 4 — M3: enum membership validation on decode

**Root cause.** `readValue[T: enum]` (`api_cbor_codec.nim:98-107`) range-checks but does not verify
set membership; holey enums admit invalid values.

**Change.** Replace the `[low,high]` range check with the same membership walk the Table-key path
uses (`api_cbor_tables.nim:86-93`):
```nim
proc readValue*[T: enum](r: var BrokerCbor.Reader, value: var T) {.raises: [IOError, SerializationError].} =
  var i: int
  read(r, i)
  for candidate in T:            # holey-enum-safe membership test
    if ord(candidate) == i:
      value = candidate
      return
  raise newException(CborReaderError, "CBOR enum value " & $i & " not a member of " & $T)
```
(For very large contiguous enums, keep a fast `low..high` pre-filter then confirm membership only
when the enum is holey — detectable at compile time via `ord(high) - ord(low) + 1 != <enum length>`.)

**ABI/API impact.** None; stricter decode. A previously-silently-accepted invalid value now returns
`err` at the FFI boundary (correct).

**Risk / blast radius.** Low. `gitnexus_impact` on `readValue`; used by every enum-typed
field/arg/map-value. Ensure contiguous enums (the common case) still decode unchanged.

**Verifies:** `test_m3_holey_enum.nim` (decode rejects `3`; contiguous enums unaffected).

---

## PR 5 — M4 + M5 + M6 + M7: FFI input & ownership hardening

- **M4** (`api_library.nim`, `_call`/`_callAsync` gates + `RequestBroker(API)` config plumbing):
  thread the broker's configured `maxPayloadBytes` into the `_call` `reqLen` gate so it is the
  effective cap (still ≤ the 64 MiB hard ceiling). When unset, keep 64 MiB. Update `FFI_API.md` to
  state that `maxPayloadBytes` bounds the incoming request buffer.
- **M5** (`api_library.nim:1391-1393,1451-1453`): the true fix requires a length the ABI can trust.
  Options, in order of preference: (a) lower the default `bufSizeCap` to a realistic bound and make
  it configurable; (b) require callers to obtain request buffers via `_allocBuffer`, which can
  record the size in a guard header (see M7) so `_call` validates `reqLen <= recordedSize` before
  `copyMem`. Document loudly in the generated header that `(reqBuf, reqLen)` must be consistent.
- **M6** (`api_library.nim:1134-1166`): guard `_subscribe`/`_unsubscribe` — if `subsRegIdent` is
  nil, either lazily run the same one-time init `_createContext` triggers, or return a defined
  "not initialized" status. Do **not** dereference a nil registry. Add the `ctxsLock`-before-init
  check similarly (the finding notes `_call` touches `ctxsLock` before `initLock` ran on Windows).
- **M7** (`api_library.nim:823-837`): tag library allocations. Have `_allocBuffer` prepend a small
  guard header (magic + size) and return the payload pointer; `_freeBuffer` steps back, validates
  the magic, and refuses (no-op + optional error) on a missing/again-freed tag or the static
  `_version` pointer. Keep the response/`respBuf` allocation path consistent with the same tagging
  so wrappers free correctly.

**ABI/API impact.** M7 changes the internal layout of library-allocated buffers but **not** the ABI
signatures; callers still pass the payload pointer. M4/M5 are stricter validation (may reject inputs
that previously slipped through). Update headers + `FFI_API.md`.

**Risk / blast radius.** M7 touches every alloc/free site — `gitnexus_impact` on `allocBufFunc`,
`freeBufFunc`, and every `deallocShared`/`allocShared0` in `api_library.nim` and the couriers.
Validate no double-tagging and that async `respBuf` ownership stays balanced (the audit confirmed it
is balanced today — keep it so).

**Verifies:** `test_m4_maxpayload.nim`, `test_m5_reqlen_oob.nim`, `test_m6_subscribe_uninit.nim`,
`test_m7_freebuffer.nim`.

---

## PR 6 — M8 + M9 + S2 + S8: init races & overflow guards

- **M8** (`api_library.nim:2250-2265`): replace the non-atomic check-then-set in
  `ensureDescriptor`/`ensureApiList` with the CAS/once pattern already used for `ctxsInit`
  (`:806-814`). Publish the built globals with `moRelease`; readers acquire.
- **M9** (`mt_event_broker.nim:223,239`, `mt_request_broker.nim:458`, `mt_signal_broker.nim:189,205`):
  change the fast-path init-flag load from `moRelaxed` to `moAcquire` (five sites). One line each.
- **S2** (`broker_context.nim:82-84,103-104`): replace the exhaustion `doAssert` with a returned
  failure — `NewBrokerContext`/`newInstanceCtx` should surface an error the FFI layer maps to a
  status code, rather than raising a `Defect` inside a shared library.
- **S8** (`mt_config.nim:247-252`, `mt_queue.nim:318-321,479-482`): add upper-bound validation for
  `maxPayloadBytes`, `slabCapacity`, `responseSlots` at config/compile time (`error` if the
  `uint32` cast would truncate or `alignUp`/`capacity*stride` would overflow). Mirror the existing
  `maxDynamicPayloadBytes` `1..high(uint32)` bound.

**ABI/API impact.** S2 turns an abort into a graceful FFI error (new/existing status). Others are
internal.

**Risk / blast radius.** Low–medium; M9 is trivial; M8/S2 change init/lifecycle. `gitnexus_impact`
on `ensureApiList`, `NewBrokerContext`, the three `init*` fast paths.

**Verifies:** `test_m8_discovery_race.nim` (TSan clean), `test_m9_init_fastpath.nim` (asserts
`moAcquire`), S2/S8 targeted asserts.

---

## PR 7 — S3, S9, S10, S11, S12: remaining robustness

- **S3** (`api_library.nim:1134-1166`): validate `ctx` against the live context list in
  `_subscribe` and/or cap total subscriptions per context; reject unknown/dead `ctx`.
- **S9** (`mt_codec.nim:85-90,201`): in the non-POD `mtUnmarshalSeq` branch, verify remaining-bytes
  bound **before** `newSeq(count)` (mirror the POD/string branches); guard the 32-bit length
  arithmetic against overflow.
- **S10** (`api_library.nim` cstring intake): document the `const char*` NUL-termination contract in
  the generated headers; optionally add a bounded `strnlen` with a sane max for event/api names.
- **S11** (`api_cbor_tables.nim:106`, tuple parser): reject duplicate map keys (RFC 8949 malformed)
  or document the last/first-wins behavior explicitly.
- **S12** (`api_codegen_cbor_go.nim:634-636`): add the `outLen > 0` guard before `C.GoBytes`,
  matching the async/event paths.

**ABI/API impact.** None (all internal or codegen). Regenerate Go bindings for S12.

**Verifies:** targeted asserts per finding; Go parity matrix for S12.

---

## PR 8 — B1–B6: supply chain / CI

- **B1:** `nimble lock` → commit `nimble.lock`; CI runs `nimble install --lock` (or equivalent) and
  fails on drift. Add `securityPolicyCheck` gate asserting the lockfile exists.
- **B2:** pin every `uses:` in `.github/workflows/*.yml` to a 40-hex commit SHA (comment the tag
  alongside); enable Dependabot for actions. Highest priority: `dtolnay/rust-toolchain@stable`.
- **B3:** pin `cbor2` to `==<version>` with `--require-hashes` from a `requirements.txt`.
- **B4:** make `vendor/jsoncons` a real submodule pinned to a commit SHA **or** commit a
  `vendor/jsoncons/UPSTREAM_SHA`, fix the `ci.yml:144` fallback to that SHA (drop `--branch v1.0.0`),
  and correct the AGENTS.md "submodule" claim + the no-op `fetchVendor` task.
- **B5:** `choco install llvm --version <x> -y`.
- **B6:** route `${{ inputs.tasks }}` in `manual_win_dbg.yml:69` through `env:` (as
  `memcheck_ci.yml` already does); scope `pages`/`id-token: write` to the `deploy` job in
  `pages.yml`.

**Verifies:** `tools/security/policy_check.sh` / `securityPolicyCheck` passes; CI green with pinned
refs and lockfile.

---

## Cross-cutting: S1 (dependency audit — external)

`cbor_serialization` is not in this tree. Before closing the decode-hardening story:
1. Vendor or pin `cbor_serialization` to an exact version (feeds B1).
2. Audit its array/map/string readers for **count-driven preallocation** (reject/stream when the
   claimed count exceeds remaining bytes) and add/confirm a **nesting-depth limit**.
3. If upstream lacks these, add a pre-decode guard at the broker boundary: a lightweight CBOR
   structural validator (major-type + length-prefix sanity + depth counter) run over the request
   buffer before handing it to the full decoder, so an OOM/stack-overflow cannot abort before the
   `try/except` can convert it to `err`.

This is the one item the broker layer cannot fully fix internally today; track it as its own issue.

---

## Definition of done (per PR)

- Repro test(s) from the test plan **fail on the pre-fix tree** and **pass after the change**.
- `nimble test`, `testApi`, and the affected `runFfiExample*`/`runTypeMapTestLib*` stay green on
  ORC + refc.
- Memory-safety PRs (1, 2, 5) green under ASan and (1, 6) under TSan in `memcheck_ci.yml`,
  N-trial-wrapped.
- `nimble nphall` clean; `gitnexus_detect_changes()` shows only the intended symbols/flows affected;
  HIGH/CRITICAL blast radius reported in the PR description.
