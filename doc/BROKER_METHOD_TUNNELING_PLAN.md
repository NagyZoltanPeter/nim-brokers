# Plan: brokerDebug for interface/implement + tunnel all method calls through the broker

Branch: current (`refine-broker-interface-and-implementation`).
Status: **PLAN — awaiting "execute and implement"**. No code written yet.

This plan covers the two-part request:

- **Part 0 (do first):** extend the `brokerDebug` AST-dump machinery to
  `BrokerInterface` / `BrokerImplement` so we can review what they generate
  *before and after* the refactor.
- **Parts 1–3:** route every interface/instance request method through the
  broker dispatch path (fix mock-bypass, MT thread-affinity, refc UAF), add
  `getCurrentProvider`, and a first-class `withMockProvider`.

---

## Current solution — what was reviewed

### brokerDebug machinery (`brokers/internal/broker_debug.nim`)
- `writeBrokerDebug(role: string, typeName: string, generated: NimNode, header = "")`
  (`broker_debug.nim:54`) writes `build/broker_debug/<typeName>__<role>.gen.nim`
  with a 7-line header. Dir override via `-d:brokerDebugDir`.
- All six brokers + the two API-cbor brokers already call it
  (`event_broker.nim:561`, `request_broker.nim:957`,
  `multi_request_broker.nim:743`, `mt_event_broker.nim:932`,
  `mt_request_broker.nim:1653`, `api_event_broker_cbor.nim:66`,
  `api_request_broker_cbor.nim:580`), each guarded by
  `when defined(brokerDebug)`, with an extra `when defined(brokerDebugStdout)`
  echo.
- **`broker_interface.nim` has NO debug hook.** **`broker_implement.nim` has
  only a raw `echo result.repr`** under `when defined(brokerDebug)`
  (`broker_implement.nim:267-268`) — it does not use `writeBrokerDebug`, so it
  pollutes the build log and writes no file.

### The tunneling defect (root cause)
In `broker_implement.nim`:
- The user `method` is re-emitted **verbatim** as a `method` override
  (`:93-96`) → reachable by plain virtual dispatch.
- The per-method provider closure calls **`self.<verb>(args)`** (`:156`) — i.e.
  it calls that same public method.

So both `Broker.request(ctx,…)` and `instance.method(…)` terminate at the same
method body. Swapping the provider (a mock) only re-points `request`; the
direct/virtual call still runs the real body. Same gap causes the MT
thread-affinity violation and the refc cross-heap hazard (prompt §Problems 1–3).

The abstract base method (`broker_interface.nim` `renderAbstractMethod`,
`:46-66`) is currently a pure-virtual `raiseAssert` stub.

### Provider storage (for `getCurrentProvider`)
- **Single-thread** (`request_broker.nim`): per-broker object held in threadvar
  `g<Type>Broker`, with two seq fields `providersNoArgs` /
  `providersWithArgs`, each `(brokerCtx, handler)`; linear search by ctx.
  Provider types `<Type>ProviderNoArgs` / `<Type>ProviderWithArgs`.
- **MT** (`mt_request_broker.nim`): per-thread threadvar seqs
  `g<Type>TvNoArg{Ctxs,Handlers}` / `g<Type>TvWithArg{Ctxs,Handlers}`;
  `request` uses same-thread → direct handler from threadvar, cross-thread →
  `Channel[T]` tunnel to the owning thread's bucket. No `getCurrentProvider`
  exists in either.

### Impact (gitnexus, repo=nim-brokers)
- `BrokerImplement` upstream: 0 (macro; only user code calls it). **LOW.**
- `renderAbstractMethod` upstream: 1 (`BrokerInterface`). **LOW.**
- Real regression surface = generated-code shape → exercised by
  `test/test_broker_oop.nim`, `test/test_broker_interface_mt.nim`,
  `test/test_broker_interface_api.nim`. These are the guardrails.

---

## Part 0 — brokerDebug for BrokerInterface / BrokerImplement

Goal: `nim c -d:brokerDebug …` emits
`build/broker_debug/<IFace>__BrokerInterface.gen.nim` and
`<Impl>__BrokerImplement.gen.nim`, consistent with every other broker.

1. `broker_interface.nim`: `import ./internal/broker_debug`; at the end of the
   macro (after `:243`) add
   ```nim
   when defined(brokerDebug):
     writeBrokerDebug("BrokerInterface", ifaceNameStr, result)
     when defined(brokerDebugStdout):
       echo result.repr
   ```
2. `broker_implement.nim`: `import ./internal/broker_debug`; replace the raw
   echo (`:267-268`) with
   ```nim
   when defined(brokerDebug):
     writeBrokerDebug("BrokerImplement", implStr, result, header = "of " & ifaceStr)
     when defined(brokerDebugStdout):
       echo result.repr
   ```
   (Note: the re-emitted inner Event/Request brokers already self-dump under
   their own `<Type>__RequestBroker[...].gen.nim` names, so the interface file
   shows the wrapper layer and the broker files show the lanes.)

**Verify:** compile `test/test_broker_oop.nim` with
`-d:brokerDebug --outdir:build`; confirm the two new `.gen.nim` files appear and
render. Capture the *pre-refactor* generated code as the baseline to diff
against after Parts 1–3.

Memory model: compile-time only; no refc/orc/MT runtime effect.

---

## Part 1 — Tunnel request methods through the broker

Principle (prompt §Goal): `instance.method(args)` ≡ `IFace(instance).method(args)`
≡ `Broker.request(instance.brokerCtx, args)`. The raw body runs **only inside
the provider closure, on the owning thread.**

### 1a. `broker_interface.nim` — entry point becomes a plain proc tunnel
**DECISION (user):** the public entry point is a **plain `proc` on `IFace`**, not
a `{.base.}` method. Routing is by ctx, so virtual dispatch is not needed; a
proc is cheaper (no vtable) and conceptually correct. `IFace(x).method()` and
`impl.method()` both resolve to this proc (Impl is a subtype of IFace, so a
concrete instance binds to the `self: IFace` param).

Change `renderAbstractMethod` so it emits, instead of the `raiseAssert` stub,
a proc delegating to the broker handle (`capitalizeAscii(verb)` ==
`sg.typeIdent`, confirmed in `broker_utils.nim:355,369`):

```nim
# async:
proc <verb>*(self: IFace, <args>): Future[Result[T, string]]
    {.async: (raises: []), gcsafe.} =
  <Broker>.request(self.brokerCtx, <argNames>)
# sync:
proc <verb>*(self: IFace, <args>): Result[T, string] {.gcsafe, raises: [].} =
  <Broker>.request(self.brokerCtx, <argNames>)
```

- The broker type + its `request` are generated in the same macro output
  (the sub-block is re-emitted at `:131/:133`) → in scope.
- No `{.base.}` ⇒ no canonical-override-pragma matching burden either.
- Zero-arg slot → no `<argNames>`; with-arg slot → forward names.

### 1b. `broker_implement.nim` — no override at all, expose only a raw impl
- The impl no longer participates in dispatch via a virtual override — the
  `IFace` proc is the sole entry point and the impl supplies only the body.
- Do **not** re-emit the user `method`. Instead emit the body as a private proc
  `proc <verb>Impl(self: Impl, <args>): <ret> = <body>` (replace `:93-96`); drop
  `canonPragma` (no longer needed). Keep the exact return type and an equivalent
  pragma (`{.async.}` / `{.gcsafe, raises: [CatchableError].}`) so it composes
  with the provider closure.
- The provider closure (`setupSrc`, `:156`) calls **`self.<verb>Impl(args)`**
  instead of `self.<verb>(args)`. This is the *only* site that runs the raw
  body. **No recursion:** public method → `request` → provider → `…Impl`.
- `setProvider`/`clearProvider`/`new`/`bindToContext`/`close` unchanged in
  shape (close still clears providers by `capitalizeAscii(verb)`).

### Why this fixes all three problems
| Problem | Before | After |
|---|---|---|
| Mock bypass | direct call hits real method body | direct call → IFace proc → `request` → (mocked) provider |
| MT affinity | body runs on caller thread | `request` tunnels cross-thread to owning thread's bucket |
| refc UAF | cross-heap `self` deref from wrong thread | body runs only in provider on owning thread; caller only passes args + ctx |

### Memory-model / threading matrix
| Mode | Same-thread | Cross-thread |
|---|---|---|
| single-thread (no `--threads:on`) | `request` → thread-local provider seq lookup → direct call. No channel. **No behavior change vs today besides the indirection.** | n/a |
| MT refc | `request` same-thread fast path = direct threadvar handler call (no channel) | `Channel[T]` tunnel; body + `self` stay on owning thread → no cross-heap access |
| MT orc | same as refc; shared heap means even mistaken cross-thread `self` would survive, but routing now also makes the *result* correct | same |

### Open design points (decide during execution, will surface in plan review)
- **Sync `request` raises:** base sync method declares `raises: []`; confirm the
  generated sync `request` is `raises: []`-compatible (it catches provider
  `CatchableError`). If not, adjust the base method pragma. *(verify against
  `request_broker.nim` sync path before claiming done.)*
- **Same-thread perf:** every same-thread call now pays a `request` lookup vs a
  vtable call. MT already direct-dispatches same-thread (no channel), so cost is
  a seq scan + closure call. Quantify with `doc/bench_baseline.md` harness;
  only add a fast path if measurably needed (keep correctness-first).
- **Event side:** `emit`/`listen`/`dropListener` already inject `self.brokerCtx`
  (`broker_interface.nim:179-186`) → already broker-routed. Audit confirms no
  direct event entry point bypasses; **no change planned**, just a noted check.

---

## Part 2 — `getCurrentProvider` for RequestBroker

Add generated `getCurrentProvider(_: typedesc[T], ctx): Option[<ProviderType>]`
per slot (zero-arg + with-arg), mirroring the keyed `request` lookup:

- **Single-thread** (`request_broker.nim`): scan `providersNoArgs` /
  `providersWithArgs` for `ctx`; return `some(handler)` / `none`.
- **MT** (`mt_request_broker.nim`): read the thread-local
  `g<Type>TvNoArgHandlers` / `g<Type>TvWithArgHandlers` for `ctx`. **Document:
  must be called on the provider's owning thread** (threadvar read); cross-thread
  introspection is out of scope (bucket holds a ring, not the closure).

Return type: `Option[<Type>ProviderNoArgs]` / `Option[<Type>ProviderWithArgs]`.

## Part 3 — first-class mock / `withMockProvider`

Provide an ergonomic save-set-restore. `setProvider` currently errs if one is
already installed, so provide a replace path:

- Add `replaceProvider(_: typedesc[T], ctx, handler)` (or a `replace=true` arg)
  that overwrites without the "already set" error, returning the previous via
  `getCurrentProvider`.
- Add a scoped template:
  ```nim
  template withMockProvider(T: typedesc, ctx, mock, body): untyped =
    let saved = T.getCurrentProvider(ctx)
    T.replaceProvider(ctx, mock)
    try: body
    finally:
      if saved.isSome: T.replaceProvider(ctx, saved.get)
      else: T.clearProvider(ctx)
  ```
  (zero-arg and with-arg overloads). MT: same-thread only — documented.

---

## Part 4 — Constructor ergonomics: user `proc new` + `createUnderContext`

**Motivation (user):** the `proc init(...)` form with magic `self` is unnatural.
Replace it with a user-authored `proc new(T: typedesc[Impl], …): Impl` ctor that
plainly builds and returns the instance; our machinery decorates it.

**Design (collision-free; `new` returns a bare instance):**

| Entry | Author | Role |
|---|---|---|
| `Impl.new(args)` | **user**, re-emitted verbatim | allocate + set fields, return bare instance — no ctx, no providers |
| `Impl.createUnderContext(ctx, args)` | generated (renames `bindToContext`) | `let self = Impl.new(args); self.brokerCtx = ctx; setupProviders(self); self` |
| `Impl.create(args)` | generated | own fresh ctx → `createUnderContext(makeBrokerContext(classCtxVar, instCounter++), args)` |

- Macro parses `proc new` params after the `T: typedesc` (same machinery as the
  current `initParams` extraction, `broker_implement.nim:77-80`) and forwards
  them **by name** into both generated wrappers.
- Drop the `proc init` branch (`:73-80`) and the magic-`self` splicing in the
  old `new`/`bindToContext` bodies (`:163-242`); replace with the table above.
- If the user omits `proc new`, generate a default `new(T): Impl = Impl()`.
- `setupProviders` + compile-time fulfillment checks unchanged.
- **gcsafe:** the constraint that was on `init` moves to the user `proc new`
  (FFI runs `createUnderContext` on the processing thread → gcsafe).

**Migration (FFI rule: update tests + examples + docs):**
- `test_broker_oop.nim`: `GreeterImpl.new(prefix=…)` (wired standalone) →
  `GreeterImpl.create(prefix=…)`; `proc init` → `proc new`.
- `bindToContext` → `createUnderContext` in `test_broker_oop.nim`,
  `test_broker_interface_mt.nim`, `test_broker_interface_api.nim`,
  `examples/ffiapi/hierlib/nimlib/hierlib.nim`,
  `examples/persistence/nimlib/{IPersistenceLib,PersistenceFacade,FileBackend,PersistenceFactory}.nim`.
- Wherever `registerBrokerLibrary` wiring calls `bindToContext`.
- Update `AGENTS.md` / hierarchical-brokers doc references.

**Verify:** `gitnexus_impact` on `bindToContext` (upstream) before renaming;
re-dump generated code under `-d:brokerDebug` and diff against the Part-0
baseline; `nimble test` + `nimble testApi` green.

## Tests (write first, then make pass) — `test/test_broker_method_tunneling.nim`
1. **Mock honored on direct call** (single-thread): mock `Greet` → `g.greet("bob")`
   returns `MOCK<bob>` (today `real:bob`). Seed from `/tmp/mock_demo.nim`.
2. **Base-typed call tunnels**: `IGreeter(g).greet("bob")` → `MOCK<bob>`.
3. **Cross-thread (`--threads:on`)**: instance on thread A, `g.greet` from
   thread B → provider runs on A, correct result, no UAF under refc.
4. **`getCurrentProvider` round-trip**: capture → mock → assert → restore →
   assert original, both slots, single-thread + MT.
5. **`withMockProvider`** scoped restore.
6. **No regression**: `nimble test`, `nimble testApi`,
   `test_broker_oop.nim`, `test_broker_interface_{mt,api}.nim` green on ORC+refc.

## Verification gates
- Before editing each symbol: `gitnexus_impact(... direction:"upstream")`;
  before commit: `gitnexus_detect_changes()`.
- Build matrix: ORC + refc, single-thread + `--threads:on`.
- If lifetimes change, run the ASAN/refc build (prompt criterion 5).
- PR doc: the refc-vs-orc / single-vs-MT table above, with reasons.

## Execution order
0. Part 0 (brokerDebug) → capture baseline generated code.
1. Tests (failing) → 1a proc tunnel → 1b raw-impl + provider retarget →
   green criteria 1,2.
2. Part 4 constructor ergonomics (`proc new` + `create` / `createUnderContext`)
   → migrate tests + examples + docs → `nimble test`/`testApi` green.
3. Part 2 `getCurrentProvider` → criterion 4.
4. Part 3 `withMockProvider` → criterion 5.
5. MT cross-thread test (criterion 3) → full regression + ASAN.
