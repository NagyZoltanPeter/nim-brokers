# Plan — Uniform broker shapes: `drop*` async all-round, `emit` sync all-round

## Goal

Eliminate the user-facing async/sync shape change that happens today when a
broker's tag flips between *(none)* ↔ `mt` ↔ `API`:

| Op | Single-thread (today) | MT / API (today) | Target (all lanes) |
|----|----------------------|------------------|--------------------|
| `dropListener` / `dropAllListeners` | **async** `Future[void]` | **sync** `void` | **async** `Future[void]` |
| EventBroker `emit` (+ ctor overloads) | **sync** `void` | **async** `Future[void]` | **sync** `void` (Option B refined) |
| `clearProvider` / `clearProviders` | sync | sync | **unchanged — stays sync** |

**Unifying principle:** match the public shape to whether the op *actually
suspends*. Single-thread `drop` genuinely awaits in-flight listener
cancellation → async is honest → unify on async. No `emit` in any lane ever
suspends (all fire-and-forget) → sync is honest → unify on sync.

The `Future`/`void` bodies that change stay **suspension-free**, so chronos
runs them eagerly and no work is deferred.

---

## Phase 0 — AST-dump verification harness (DO FIRST)

Capture the generated Nim **before** touching codegen, so every later phase is
diffable.

1. Build representative brokers with `-d:brokerDebug` into a **baseline** dir:
   - MT event broker (drop + emit both live here):
     ```
     nim c -d:brokerDebug --threads:on --path:. --outdir:build \
       --nimMainPrefix:mtdbg test/test_multi_thread_event_broker.nim
     ```
   - API/CBOR lane (drop teardown + emit reuse):
     ```
     nim c -d:BrokerFfiApi -d:brokerDebug --threads:on --app:lib --path:. \
       --outdir:examples/ffiapi/nimlib/build --nimMainPrefix:mylib \
       examples/ffiapi/nimlib/mylib.nim
     ```
   - Single-thread event broker (must stay byte-identical for emit; drop
     already async — no change):
     ```
     nim c -d:brokerDebug --path:. --outdir:build \
       --nimMainPrefix:stdbg test/test_event_broker.nim
     ```
2. Copy `build/broker_debug/` → `build/broker_debug_baseline/` (and the API
   dir's dump). These are the golden references.
3. Verification gate used in every later phase:
   `diff -ru build/broker_debug_baseline build/broker_debug` and inspect that
   **only** the intended procs changed signature/pragma. Single-thread
   `emit` and all `clearProvider*` must show **zero diff**.

Deliverable: a short note in this doc recording the baseline command lines +
where dumps live. No source changes in Phase 0.

---

## Phase 1 — `dropListener` / `dropAllListeners` async all-round

Single-thread is already async; **only the MT generators change**. Bodies stay
synchronous (await-free) — wrap as `{.async: (raises: []).}` returning
`Future[void]`.

### 1a. `brokers/internal/mt_event_broker.nim`
- **Impl procs** `dropListenerImpl` ([~:707](../../brokers/internal/mt_event_broker.nim))
  and `dropAllListenersImpl` ([~:753](../../brokers/internal/mt_event_broker.nim)):
  keep **sync** (plain `proc`). Prepend a loud guard comment:
  ```
  # ── NO async / NO await in this body. ──────────────────────────────
  # It must stay suspension-free: the public overload is async only for
  # cross-lane shape parity; chronos runs an await-free async body
  # eagerly, which is what keeps FFI teardown + the Part D-3 dropAll
  # hook correct even when the returned Future is discarded/unpolled.
  # Adding an await here reintroduces the SubsRegistry-orphan regression
  # (see doc/design/DROP_ASYNC_EMIT_SYNC_PLAN.md §Risks).
  ```
- **Public overloads** `dropListener*` / `dropAllListeners*`
  ([~:806-820](../../brokers/internal/mt_event_broker.nim)): change from sync to
  `{.async: (raises: []).}` returning `Future[void]`, body `await <impl>(…)`
  (mirrors the single-thread shape at [event_broker.nim:365](../../brokers/event_broker.nim)).
- The Part D-3 hook fire stays **inside the sync impl**, after listener
  clearing — unchanged. (It therefore still runs eagerly.)
- `setDropAll<Event>Hook` stays sync — unchanged.

### 1b. API/CBOR lane — DECIDED: leave the guards in place (no simplification)
- `brokers/api_library.nim` per-ctx release proc and `broker_implement.nim`
  `close()` keep their `when typeof(...dropAllListeners) is void` guards. Once
  MT is async the guard simply selects the `discard <Evt>.dropAllListeners(ctx)`
  branch, which is correct (release proc is `{.gcsafe.}` non-async; the
  suspension-free body runs eagerly so the discarded Future is already complete
  and the Part D-3 hook has fired). Simplifying the dead branch is churn on
  teardown codegen for zero behavioral gain and removes a defensive guard, so
  it is intentionally NOT done. Verified in the generated lib stub.

### STATUS: Phase 0 ✅  Phase 1 ✅ (drop async all-round)
- MT generators async + loud guard comments; ST unchanged.
- AST diff vs baseline: ONLY the four `drop*` overloads gained
  `Future[void] {.async.}`; emit + impls byte-identical.
- Call sites: 5 MT test files + torpedo (`discard`, sync ctx) + persistence
  (`await`, async ctx) updated.
- Tripwire `test/test_mt_drop_async_eager.nim` added + registered in `mtTests`;
  green on orc/refc × debug/release.
- `nimble test` + `nimble testApi` fully green. `detect_changes`: LOW risk.

### 1c. Decision — `{.discardable.}` → RESOLVED: non-discardable, both lanes
Both lanes stay **non-discardable**. The universal shape is
`await X.dropAllListeners()` / `await X.dropListener(h)` in **every** lane →
true uniformity (identical source compiles regardless of tag). Cost: update
~25 MT call sites (test/perf/probe) to add `await` — see §1d. This is the
honest, fully-uniform contract and preserves the "forgot to await in-flight
cancellation" safety on single-thread drop.

### 1d. Call-site updates (required — non-discardable per §1c)
- Tests: `test/test_multi_thread_event_broker.nim` (~25), `test_multi_thread_broker_configs.nim`,
  `test_mt_large_payload.nim`, `perf_test_multi_thread_event_broker.nim`,
  `probe_mt_uaf.nim`, `test_api_event_teardown_isolation.nim` → add `await`
  to `drop*` calls (all are already inside `asyncTest`/async procs).
- `brokers/broker_interface.nim:201` `dropListener` template forwards untyped —
  no change needed (propagates the new `Future`).

### 1e. Tripwire test (guards Risk #2)
Add to `test/test_api_event_teardown_isolation.nim` (or a new
`test/test_mt_drop_subscount.nim`): foreign-subscribe an API event, then call
`dropAllListeners(ctx)` **without awaiting**, and assert the per-event
`subsCount == 0` afterward. This fails the instant someone adds an `await` into
the MT drop impl body. Reference the memory note `project_mt_drop_async`.

---

## Phase 2 — EventBroker `emit` sync all-round (Option B refined)

Single-thread is already sync; **only the MT generators change**. Keep emit's
work synchronous (`emitImpl` is already await-free) — make `emitImpl` a plain
`proc` and call it directly (NOT via `asyncSpawn`), so no work is deferred and
the cross-thread cell is still enqueued before return.

### 2a. `brokers/internal/mt_event_broker.nim`
- **`emitImpl`** ([~:487](../../brokers/internal/mt_event_broker.nim)): drop
  `{.async: (raises: []).}`; make it `proc … {.gcsafe, raises: [].}`. Body is
  unchanged (lock, same-thread `asyncSpawn fut` for listener tasks, cross-thread
  marshal/spill/enqueue/`fireBrokerSignal`). **Verify** `gcsafe`/`raises: []`
  holds for a plain proc — `withLock`, chronicles `error`/`warn`, `asyncSpawn`,
  `marshal*`, `allocShared0`. This is the main compile risk of Phase 2.
- **Public `emit*`** ([~:601-610](../../brokers/internal/mt_event_broker.nim)):
  change from `{.async.}` `await emitImpl(…)` to sync `proc emit*(…) =`
  `emitImpl(…)` (mirrors [event_broker.nim:471](../../brokers/event_broker.nim)).
- **Inline-ctor `emit` overloads** ([~:614-690](../../brokers/internal/mt_event_broker.nim)):
  remove the `asyncPragma` and the `await` wrapper on `emitCtorCall*`; emit a
  plain proc calling `emitImpl(ctx, <ctorExpr>)` directly (mirror single-thread
  [event_broker.nim:484+](../../brokers/event_broker.nim)).
- Same-thread path requires a running loop for `asyncSpawn` — already true (emit
  runs on the event loop). Document; no new constraint vs single-thread.

### 2b. API/CBOR lane
- Reuses the MT emit → becomes sync automatically. Confirm via AST diff of the
  API dump that no generated `await …emit` remains. (Grep already confirms the
  macros generate no `await …emit` for the API lane; events come from user
  provider code.)
- `brokers/broker_interface.nim:196` `emit` template `t.emit(self.brokerCtx,
  args)` already returns whatever `emit` returns — now `void`. No change.

### 2c. Call-site updates
- ~55 `await <Event>.emit(…)` sites across `test/`, `examples/` (Nim libs:
  `mylib.nim`, torpedo, `typemappingtestlib.nim`) → drop the `await`. Purely
  mechanical (`await X.emit(a)` → `X.emit(a)`).
- Watch for `await X.emit()` used as the **only** await in an otherwise-sync
  region — removing it may make a proc no longer need `{.async.}`; leave such
  procs async (surgical: don't refactor signatures that still compile).

---

### STATUS: Phase 2 ✅ (emit sync all-round)
- MT `emitImpl` now `{.gcsafe, raises: [].}` (sync), public `emit*` + inline-ctor
  overloads sync void; impl bodies unchanged (marshal/enqueue still pre-return).
  Guard comments added.
- AST diff vs original baseline: every `emit*` overload async→sync, every
  `drop*` overload sync→async; nothing else.
- 58 call sites de-await'd across 14 files (tests + example libs).
- Full gate run all green: `nimble test`, `testApi`, `runFfiExampleCpp/Py`,
  `runTypeMapTestLib{Cpp=149, Py=101×2, Rust=148×2, Go=148×2}`, `perftest`
  (100% delivery), ASAN orc+refc on MT event (15/15) and API teardown (3/3).
- ABI/foreign wrappers needed NO regen (confirmed by parity matrices) — emit/
  drop are not foreign-exposed.

## Verification (run after each phase, all green before merge)

1. **AST diff** vs baseline (Phase 0 gate): only intended procs changed;
   single-thread `emit` + all `clearProvider*` show zero diff.
2. `nimble test` — core single + MT brokers, ORC/refc × debug/release.
3. `nimble testApi` — FFI codec/lifecycle/event/parity matrix.
4. `nimble runFfiExampleCpp` / `runFfiExamplePy` — wrapper smoke (ABI unchanged;
   drop/clear/emit are **not** foreign-exposed, so wrappers must need **no**
   regen — confirm).
5. Parity matrices: `runTypeMapTestLib{Py,Cpp,Rust,Go}` (both MMs).
6. `nimble perftest` — MT stress (emit hot path shape change).
7. **ASAN/refc** build for the MT event + API lanes (lifetime-sensitive: emit
   now synchronous, drop future discarded on teardown).
8. Tripwire test (§1e) passes.
9. `nimble nphall` formatting.

## Memory-model notes to assert in the PR
- **drop (MT, async-wrapped, await-free):** under both refc & orc the returned
  `Future[void]` is pre-completed by eager body execution; `discard` in FFI
  teardown is leak-free; no pending future survives shutdown. Cross-thread drop
  remains fire-and-forget (sentinel `CtrlClearListeners`); the future completes
  at *enqueue*, not remote-apply — document, do not "fix" with an await.
- **emit (MT, now sync):** marshal+enqueue happen before return (no widened
  teardown race vs today). Event value captured by the synchronous call; same
  ownership as today. Same-thread listener tasks still `asyncSpawn`'d.

## Risks (recap; full catalogue in memory `project_mt_drop_async`)
- **R1 discardable-vs-uniformity** (Phase 1c) — RESOLVED: non-discardable both
  lanes; `await` required everywhere (~25 MT call-site edits).
- **R2 latent Part D-3 hook deferral** — guarded by the §1e tripwire + the §1a
  loud comment; only fires if an `await` is added to the MT drop body.
- **R3 emit `gcsafe/raises:[]`** — verify plain-proc `emitImpl` still satisfies
  the effect annotations (main Phase 2 compile risk).
- **R4 call-site churn** — ~25 (drop, add await) + ~55 (emit, drop await),
  mechanical.
- **No ABI / foreign-wrapper impact** — none of the three ops are exported in
  the 11-function C ABI.

## Out of scope
- `clearProvider` / `clearProviders` — stay sync, untouched.
- `MultiRequestBroker` — no async/sync shape divergence in scope.
- Any synchronous-delivery/backpressure `emit` mode (would flip Phase 2 to
  async-all-round; none planned today).
