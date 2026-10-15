# EXTAPI review fixes — plan

**Status (2026-10-15): implemented** on `feat-extapi-design` — F1 `63e71dd`,
F2 `f6a7ecb`, F3 `869e376`, F4 `0206d53`, F5 `3ed2729`, F6 `4106e3d`,
F7 `dc6443d`, F8 `04a3b5d`, F9 (this commit). Deviations from the plan below:
W4 is unreachable (non-object payloads are rejected for foreign plugins) and
was not changed; the Windows CI cells for the EXTAPI example steps stay gated
until a push lets them run; K2 schema comparison is structural (shapes)
rather than via `api_schema_hash` directly.

Source: `build/EXTAPI_REVIEW.md` (peer review of `feat-extapi-design`, HEAD
`099a391`). This plan covers every finding: R1–R2, H1–H4, M1–M14, W1–W8, the
Low items and the doc drift. Each finding is either fixed here or explicitly
routed to a follow-up.

Verification of the review (re-read on HEAD, not trusted blindly):

| Finding | Status | Evidence |
|---|---|---|
| R1 | confirmed | `failPending` completes the future (`ext_runtime.nim:675`), so `extCall` sees `completed` and never runs `abandon()` (`:996-1003`). The worker then wins `0→1` (`:561`) and calls `invoke`. |
| R2.1 | confirmed | `postCtl` checks `hostRunning()` (`:1061`), then pushes and waits with no bound (`:1080-1085`). `extHostStop`'s final ctl drain (`:1849`) can run between the check and the push. |
| R2.2 | confirmed | `extHostStop` joins the bridge and worker threads (`:1810`, `:1827`) with no current-thread guard. |
| R2.3 | confirmed | The peer port has `release: nil` (`:1634`). `shutdownPeers` frees `user` (`:1673`) *before* pools are stopped, and `workerProc` drains its whole queue before honouring `stop` (`:547-555`). |
| R2.4 | confirmed | `extHostStart` has no start guard (`:1743`). A worker `createThread` failure returns with the bridge alive and `running = false` (`:1788`). |
| H1 | confirmed | The uninstall stub goes in via `replaceProvider` (`ext_brokers.nim:663`); the next install calls `setProvider` (`:653`), gets "already set", and that is only logged (`ext_runtime.nim:725`). |
| H2 | confirmed | `extImportLoad` / `extPeerLoad` have no per-(plugin, ctx) guard; each call opens a new port and, for K2, subscribes again. |
| H3 | confirmed | `isRawPtrType` (`ext_brokers.nim:140`) only flags pointers; `string` / `seq` / object short-form params reach `cdecl` as Nim types. |
| H4 | confirmed | The `Responder` is moved into a by-value parameter (`ext_codegen_hpp.nim:326`). It is destroyed during unwinding, so `~Responder` replies "dropped" before the `catch` runs. |
| M6, M7, M9, M10, Low "re-export" | confirmed by spot check | `ext_brokers.nim:559`; `mt_request_broker.nim:194` vs `:1661`; `idxRead` placed before `result = proc`; `ext_runtime.nim:460-465`; `request_broker.nim:166-170`. |
| Other M / W / Low | taken as stated | Each gets a regression test below, so any misreading surfaces in the test first. |

Additional (from the 2026-10-15 K1 reprovide check): with `autoWire = true`,
the bridge thread owns the public slot, so `replaceProvider` /
`setProvider(extFallback)` / `withMockProvider` fail from user threads. The
inplace bypass keys on `wired`, not on which provider is installed. This is
folded into M12.

---

## Principles

- Every fix lands with a regression test that fails on HEAD (TDD).
- One commit per group below, gated by: `nimble testApi`, the
  `testExt*Asan{Orc,Refc}` tasks, `nimble test` (for the gating change), and
  `runExtExample{Cpp,Rust,Go,Py}` when wrappers change.
- Memory-model statement per group (refc / ORC). Foreign-thread code stays
  libc-only.
- The `<lib>` / plugin ABI (`broker_ext.h`) stays at version 1 unless a
  decision below changes it. The status-code set is unchanged.

---

## F1 — lifecycle and at-most-once (R1, R2.1–R2.4)

New test file: `test/test_ext_lifecycle.nim`, with a raw C plugin
`test/ext/raw_life_plugin.c` (parks calls, counts invokes and cancels, can
call back into the host).

| Fix | Change | Test |
|---|---|---|
| R1 | `PendingCall` gains borrowed `st` / `impl` (both outlive the pending entry: `extCall`'s frame holds the refs until its future completes). `failPending` CASes `st` `0→2`; if it loses (`1` = running), it sends `impl.cancel(id)`. `workerProc` skips `invoke` once `pool.stop` is set (drop, do not run). | withdraw / close with N calls queued behind a parked `workers(1)` call → caller gets the error, **invoke count stays at 1**. Same for `ExtHost.stop()`. |
| R2.1 | Add a host `ctlLock`. `postCtl` does `running`-check + push under it; `extHostStop` flips `running = false` under it before draining, so no push can land after the final drain. Wait policy: **decision D1**. | A thread hammers `provide` / `withdraw` while another runs `ExtHost.stop()`, ×200 iterations: no hang (test-level watchdog), every call returns `OK` or `SHUTDOWN`. |
| R2.2 | `extHostStop` refuses on the bridge thread (`onBridgeThread()`) and on worker threads (new `extIsWorker {.threadvar.}`). Return shape: **decision D2**. | `invoke` calls a host hook that triggers `ExtHost.stop()` → error, no deadlock; a later stop from main works. |
| R2.3 | Stop order becomes: bridge → **pools** (with R1's skip) → peers. The peer port gets a real `release` that frees `user`. `shutdownPeers` unsubscribes and calls `shutdown(peerCtx)` but no longer frees `user`. | K2 with a `workers` name: stop with queued peer calls under ASAN → no UAF, no invoke after stop. |
| R2.4 | Host state machine `Atomic[int]`: `stopped → starting → running → stopping`. Start and stop CAS into it; concurrent `start` callers wait until `running` (or return the starter's error). Partial failure rolls back: signal and join the bridge, stop and join any pools already created, back to `stopped`. | 8 threads call `<lib>_extHost()` (`extHostStart`) at once → one bridge thread (count via a hook), all get the same table. An injected worker-start failure (test-only `-d:extTestFailWorkerStart`) followed by start succeeds. |

Memory model: all new state is shared / atomic or c-allocated. `extIsWorker`
is a threadvar on Nim-created threads only. Same under refc and ORC.

## F2 — high (H1–H4)

| Fix | Change | Test |
|---|---|---|
| H1 | Install uses `replaceProvider` (replace-or-insert, owner-checked) instead of `setProvider`: it replaces the bridge-owned "withdrawn" stub, inserts when empty, and still refuses a user-owned slot (reported as not wired). The "not auto-wired" log goes from `info` to `warn` (M12). | dual-slot plugin: withdraw `_args`, re-provide → served; the `_zero` slot keeps serving throughout. |
| H2 | Per-(plugin, ctx) `loaded` record under `rt.lock`. A second `load` on the same ctx is idempotent (**decision D3**). `rt.peerFns` init moves under the lock. Provide failures are written into `loadError` (the error string is now written after the provide loop) and count toward the result. | eager load + explicit load → one port, events delivered once (K2), `loadError` empty; 4 threads `load` concurrently → peer `initialize` called once. |
| H3 | Compile-time ABI whitelist for K1 short-form params and return: `bool`, `char`, `intN` / `uintN` / `floatN`, `int` / `uint`, enums, `distinct` of those, `cstring`, `ptr T`, `pointer`. Anything else (including `openArray`) is a compile error pointing at the body form. | new reject test `test/reject/reject_ext_k1_managed_arg.nim` (`string` arg) and `…_managed_ret.nim`. |
| H4 | Approach: **decision D4**. Either way the C2 adapter inherits the fix. | C++ test plugin whose method throws `std::runtime_error("boom")` → Nim sees `err("boom")`; a throw after moving the `Responder` to another thread → exactly one reply. |

## F3 — memory and thread safety (M1, M2, M4, M5, M6, M7, M9)

| Fix | Change | Test |
|---|---|---|
| M1 | Inplace call ids become self-describing: `id = 1<<63 or slot<<32 or gen`. Each slot has one `Atomic[uint64]` `ctl = gen<<32 or state` (`Free / Claimed / Filling / Filled`), the same packed protocol as the MT response slots. `inplaceFill` decodes the slot and CASes `Claimed→Filling`; retire CASes to `Free` and bumps `gen`. A late or duplicate reply loses the CAS and is dropped. This also removes the 256-slot scan per `extReply` (Low perf item). | late reply from a foreign thread after `invoke` returned, raced with 10k inplace calls → never delivered to another call; two replies to one id → first wins, no tear (ASAN + TSAN-style stress). |
| M2 | `{.push checks: off, stackTrace: off.}` around every host-table proc and peer callback. Raw `acquire` / `release` instead of `withLock` / `defer` in those procs. Length math in `uint64` with explicit bounds (`peerRespCb` / `cborHeadAt` reject a peer length > remaining buffer). Fix the module header comment. | build check: the generated C for those procs contains no `nimErrorFlag` / `framePtr` (a nimble task greps `nimcache`); fuzzed peer lengths → `err`, no raise. |
| M4 | `ExtReplyMsg` carries `port`; `PendingCall` stores `(pluginIdx, slot, gen)`. The bridge drops a reply whose port does not match the call's source. Inplace slots store the port too. | plugin B replies to plugin A's call id → dropped, A's call times out / completes from A only. |
| M5 | `extEmit` reads `ctx` under `rt.lock` together with the generation check. `ExtEventMsg` carries `port`; the bridge drops events whose port is closed or re-generationed at delivery (matches §11 "STALE after close"). | emit then close before the bridge drains → not delivered; close + reopen on another ctx → no cross-ctx delivery. |
| M6 | Off-bridge forwarder: the lane timeout is set once at install to `InfiniteDuration` (the bridge's `extCall` already enforces the public broker's timeout). No per-call global write, no `+ seconds(1)` overflow. To verify during F3: MT treats `InfiniteDuration` / `0` as "no deadline". | public broker with `requestTimeoutMs = 0` / `InfiniteDuration` called from a non-bridge thread → no `OverflowDefect` (debug build). |
| M7 | The inplace hook in `blockingRequestCancellable` writes `idOut[] = 0` before returning. | canceller reads `idOut` after the call → `0`. |
| M9 | `extProvider` / `extFallback` / `extHandler` read the plugin / name index globals inside the closure, not at construction. | build the closure before `registerExtPlugin` runs (module order) → still reaches the plugin. |

## F4 — compile-time checks (M8, M10, M11, Low "event dynlib")

| Fix | Change | Test |
|---|---|---|
| M10 | `registerExtPlugin` errors at compile time when `n > ExtMaxNames`; a compile-time plugin counter errors past `ExtMaxPlugins`. | reject test with 65 names. |
| M11 | Body-form K1 also sets `rawPtr` from the signature params, so raw pointers outside `inplace` are rejected like the short form. | reject test. |
| M8 | `{.warning.}` when an `inplace` name sets `requestTimeoutMs`. Document: inplace ignores timeout / cancel, `requestCancellable` returns id `0`, and the call blocks the caller's loop. | compile-output check in `testSugarRejects`-style task. |
| Low | `EventBroker` / `SignalBroker(EXTAPI…, dynlib = …)` without `importLib` → clear compile error. | reject test. |

## F5 — schema (M13, M14)

| Fix | Change | Test |
|---|---|---|
| M13 | The EXTAPI schema hash walks the resolved type tree with `api_schema_hash` (nested / external object fields, enum ordinals), like the `(API)` lane. K2 `peerSig` compares the same canonical text instead of type names. | change a nested field → hash differs (golden test); K2 peer with a changed nested field → name refused at load. |
| M14 | Decision **D5**: implement `BROKERS_FFI_SKIP_SCHEMA_CHECK` / `<PLUGIN>_SKIP_SCHEMA_CHECK` in `extOpen` (libc `getenv`, same rule as `_verifySchema`: any value but `0`), or drop it from the plan. | env set → mismatching hash opens; unset → `SCHEMA_MISMATCH`. |

## F6 — semantics (M3, M12)

| Fix | Change | Test |
|---|---|---|
| M3 | Decision **D6**: route `bridge`-dispatch signals through the bridge (one ring hop; keeps "bridge = one thread" true), or document "`invoke` may run concurrently" in `broker_ext.h`. | signal from a thread ≠ bridge, `bridge` name → plugin records the bridge's thread id. |
| M12 | Document the ownership consequences of `autoWire = true` (bridge owns the slot: no user `replaceProvider` / `clearProvider` / mock; the dual-slot sibling also blocked) and the recommendation "`autoWire = false` for anything you reprovide, fall back or mock". Raise the not-wired log to `warn` (done in H1). Add the scratch K1 check as a test. | `test_ext_imports`: K1 `autoWire = false` reprovide / fallback / mock (today's scratch check), plus `autoWire = true` replace → `err`. |

## F7 — wrappers (W1–W8)

| Fix | Change | Test |
|---|---|---|
| W1 | C++ `Builder::open() &&` (consumes the builder). | compile-fail check not needed; the example builds. |
| W2 | Rust `Spawn` doc: capture `tokio::runtime::Handle::current()` up front and use `handle.spawn(f)`; same text in `EXTAPI_PLAN.md:1601`. | doc only. |
| W3 | Rust: a reply guard in `spawn_request` replies `err("dropped")` when the future is dropped by the executor without a reply and without a Nim cancel. Go: n/a (a goroutine always finishes; panics are already replied). | Rust test plugin that drops the future → Nim gets `err("dropped")` before the deadline. |
| W4 | Rust POD `seq[byte]` value (response / signal / event) uses `serde_bytes::ByteBuf`. | typed round trip in a Rust test plugin. |
| W5 | Python: `_NAMES` carries each name's dispatch. Sync handlers run inline for `inplace` names and on a small thread pool for `bridge` names. Caps become `NONBLOCKING | REPLY_INLINE`, which is now honest. | Python test: slow sync handler on a bridge name does not block a second plugin's call. |
| W6 | Python: missing args → error reply; detect async by awaiting the call's result (`inspect.isawaitable`) instead of `iscoroutinefunction`; an async signal without a loop → `warnings.warn` once; document the "loop thread making a blocking Nim request" deadlock. | unit tests in the Python example run. |
| W7 | Rust `tramp_cancel` / `tramp_release` wrapped in `catch_unwind`; lock poisoning tolerated (`lock().unwrap_or_else(|e| e.into_inner())`). | — |
| W8 | `FFI_API.md` EXTAPI chapter: two Go c-shared runtimes per process is unsupported by Go; recommend one c-shared library exporting both plugin and imports. | doc only. |

Runtime tests for the remaining wrapper failure paths (Rust R2, Python cancel,
Rust / Go panic) are added to the examples' assertions.

## F8 — hygiene (Low)

| Item | Change |
|---|---|
| Re-export gating | Split `ext_brokers` into compile-time parsing (always imported with threads, so EXTAPI still degrades to `(mt)` without the flag) and the runtime part (`ext_runtime`, `std/dynlib`, `std/json`, codec, globals), imported only under `-d:BrokerFfiApi`. Gate: `nimble test` (no FFI flag) still compiles every broker; `testApi` unchanged. |
| `setupForeignThreadGc` | Document that under refc the foreign thread stays registered; call it at most once per thread (threadvar flag). |
| Lost cancel before registration | Document: the cancel is a hint; worst case wasted work. |
| `c_malloc` results | Check them; return `AGAIN` (reply / emit) or drop with a log on the bridge side. |
| `peerRespCb` | Check `buf.isNil` before reading `b[0]`; `peerInvoke` rejects `len > int32.high` with an error reply. |
| `ExtTunnel.listen` | Return a handle plus `ExtTunnel.unlisten`. |
| Hot path | M1 removes the inplace scan. Collapse the up-to-3 `sharedFind` calls on the inplace path into one lookup returning everything. |

## F9 — docs and checklist

- Fix every row of the review's drift table: `broker_ext.h` header, the
  `FFI_API.md` tables, and `EXTAPI_PLAN.md` §5.1 (watchdog: implement a log
  line or drop it), §5.3, §6.4, §11 and §15.
- Turn the §11 failure table into a checklist in `test/test_ext_lifecycle.nim`,
  so each row maps to an assertion: ring full → `AGAIN`, reply twice, late
  inplace reply, undecodable reply, stale handle → `STALE`.
- Windows CI: remove the `runner.os != 'Windows'` gates on the EXTAPI steps
  **only after** a push lets the Windows cells run. That needs your go-ahead
  to push the branch; it is not done in this plan.
- Add an ASAN wrapper run to CI (`runExtExampleCppAsan` on Linux).

## Follow-ups (own sessions, not in this plan)

- Lib-mode module initialiser running twice — root cause, may affect `(API)`
  libraries too.
- Worker join timeout at stop when a worker is stuck in a foreign `invoke`.

## Decisions (settled 2026-10-15)

| # | Question | Decision |
|---|---|---|
| D1 | `postCtl` wait policy | **Unbounded but race-free**: ctl lock shared with stop; docs say "waits for the bridge". A stuck bridge means a plugin broke `CAP_NONBLOCKING`. |
| D2 | `ExtHost.stop()` from the bridge or a worker | **Return `Result[void, string]`** (`err` there); public signature change. |
| D3 | Repeated `ExtPlugin.load(name, ctx)` | **Idempotent `ok`** (default taken; eager + explicit is harmless). |
| D4 | C++ exception → `err(what())` | **`~Responder` skips "dropped" while unwinding** (`std::uncaught_exceptions()`); C1 signatures unchanged. |
| D5 | Skip-schema env vars | **Implement** (default taken; parity with `_verifySchema`). |
| D6 | `bridge`-dispatch signals | **Route through the bridge.** |
