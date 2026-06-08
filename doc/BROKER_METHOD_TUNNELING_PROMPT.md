# Prompt: Tunnel all BrokerInterface method calls through the broker path

> Hand-off prompt for a later Claude Code session. Plan first (use the `Plan`
> subagent), present the plan, and wait for explicit "execute and implement"
> before writing code. Keep memory-model (`--mm:refc` / `--mm:orc`) and
> single-thread vs `--threads:on` (MT) implications explicit at every step.

## Context

`BrokerInterface` (`brokers/broker_interface.nim`) generates an abstract
`ref object of RootObj` interface carrying a hidden `brokerCtx`, plus event/
request sugar. `BrokerImplement` (`brokers/broker_implement.nim`) emits the
concrete impl: it allocates a per-instance `brokerCtx` (`new()`) or adopts one
(`bindToContext(ctx)`), registers one **request-broker provider closure per
method** (keyed by `self.brokerCtx`) in `<Impl>SetupProviders`, re-emits each
user `method` **verbatim**, and emits `close()` to tear the instance's
providers/listeners down.

Two ways to invoke a request method exist today and they behave differently:

- `Broker.request(self.brokerCtx, args)` — goes through the registered provider
  closure. With MT brokers (`--threads:on`) this auto-detects same-thread vs
  cross-thread and **tunnels cross-thread calls via `Channel[T]`** to the
  provider's owning thread (`brokers/internal/mt_request_broker.nim`).
- `instance.method(args)` / `IFace(instance).method(args)` — **plain Nim
  virtual dispatch.** No `brokerCtx`, no channel, no thread check. Runs the
  method body inline on the *calling* thread.

The broker type backing a method is `capitalizeAscii(verb)` (e.g. `greet` →
`Greet`); see `methods.add((verb, capitalizeAscii(verb), ...))` in
`broker_implement.nim`.

## Problems found (this is what we must fix)

1. **Mocking only intercepts broker calls, never direct method calls.**
   Swapping a provider (`Greet.clearProvider(ctx)` → `Greet.setProvider(ctx,
   mock)`) only changes `Greet.request(ctx, …)`. A direct `g.greet(…)` (or via a
   base-typed `IGreeter` ref) bypasses the broker and still runs the real impl.
   So test mocks are silently ignored whenever production code calls the method
   directly. Verified empirically in `/tmp/mock_demo.nim`:
   `Greet.request → MOCK<bob>` but `g.greet direct → real:bob`.

2. **MT thread-affinity violation on direct method calls.** Calling
   `instance.method(...)` from a thread other than the one that owns
   `instance.brokerCtx` runs the body on the wrong thread. Brokers are keyed by
   `(brokerCtx, threadId, threadGen)`, so any `self.emit` / `self.listen` /
   nested `Some.request(self.brokerCtx, …)` inside the body resolves against the
   *calling* thread's bucket — which doesn't exist — producing no-ops, stray
   buckets, or `err(no provider)`. The instance's single-thread affinity is
   broken with no diagnostic.

3. **refc heap ownership hazard.** Under `--mm:refc` the instance ref lives on
   its creating thread's thread-local heap. Reading/calling it from another
   thread is a cross-heap access → refcount races, use-after-free, corruption.
   Under `--mm:orc` the ref itself survives (shared heap, atomic RC) but
   problem (2) still makes results wrong and races any non-atomic `self` state.

Root cause of all three: the public method is a *direct* call that bypasses the
broker's dispatch/affinity/interception layer.

## Goal

**Every interface/instance method that is derived from a `RequestBroker` (and
the event surface from `EventBroker`) must route through the broker execution
path — never a direct vtable call.** A call to `instance.method(args)` should be
equivalent to `Broker.request(instance.brokerCtx, args)`: it must honor
cross-thread tunneling (MT), thread affinity, and provider interception
(mocks). Direct dispatch to the raw implementation body should only happen
*inside* the provider closure, on the owning thread.

Plus two capabilities the user explicitly wants:

- **First-class per-broker mock.** Make "replace the provider for one broker on
  one ctx" an ergonomic, supported testing operation (not a manual
  clear-then-set dance), ideally with save/restore.
- **`getCurrentProvider` for `RequestBroker`.** A way to read the currently
  installed provider closure (per ctx, per slot: zero-arg and with-arg) so a
  mocker can capture the original and restore it after the test. Likely paired
  with a `setProvider`-that-replaces or a scoped `withMockProvider` template.

## Design considerations / open questions for the plan

- **Avoid infinite recursion.** If the public method becomes a thin wrapper over
  `Broker.request(self.brokerCtx, args)`, the provider closure must call the
  *raw* implementation body — not the public method. Likely shape: rename the
  user's override to an internal `proc <verb>Impl(self, args)` (or keep the
  `method` but have the provider call a private body), and generate the public
  `method`/proc to delegate to `request`.
- **Async vs sync.** `request()` is async (`Future[Result[T,string]]`);
  `RequestBroker(sync)` providers are `{.gcsafe, raises:[CatchableError].}`.
  The public-method wrapper must match the broker mode. Confirm the method
  signature already returns `Future[Result[...]]` so delegation is type-clean.
- **Single-thread vs MT parity.** Tunneling must degrade cleanly without
  `--threads:on` (single-thread `request` just calls the thread-local provider).
  Confirm no regression to the existing `test_broker_oop.nim` single-thread
  suite.
- **Same-thread fast path / performance.** MT `request` already direct-dispatches
  on the owning thread, but it's still a `request` round-trip vs a raw vtable
  call. Quantify the per-call overhead (see `doc/bench_baseline.md`) and decide
  whether the same-thread path should keep a fast direct-to-provider shortcut.
- **Base-typed dispatch.** `IFace(instance).method(...)` must tunnel too, so the
  wrapper has to live on the abstract method surface, not only the concrete
  impl — coordinate `broker_interface.nim` (declares abstract methods) with
  `broker_implement.nim` (provides bodies).
- **EventBroker side.** `self.emit` / `self.listen` already route through the
  broker via templates injecting `self.brokerCtx`
  (`broker_interface.nim:180-186`). Audit whether any direct event entry point
  bypasses the broker and needs the same treatment.
- **`getCurrentProvider` semantics.** Two slots exist (zero-arg, with-arg) and
  state lives in threadvars (`tv*HandlerIdent`) for MT / a per-ctx table for
  single-thread. Define: returns `Option[providerProcType]`? Per ctx + slot.
  Must be callable on the provider's owning thread (MT). Pair with a restore
  path and document the thread constraint.
- **API/FFI lane.** `RequestBroker(API)` rides the MT lane. Ensure the FFI
  `_call` dispatch and `setupProviders` flow are unaffected (or benefit). The
  FFI path already only uses `request`, so it should be neutral or improved.

## Files in scope

| File | Why |
|------|-----|
| `brokers/broker_interface.nim` | abstract method generation, event sugar templates |
| `brokers/broker_implement.nim` | per-method provider wiring, verbatim method emission, `new`/`bindToContext`/`close` |
| `brokers/request_broker.nim` | single-thread `setProvider`/`clearProvider`/`request`; add `getCurrentProvider` |
| `brokers/internal/mt_request_broker.nim` | MT `setProvider`/`clearProvider`/`request` (channel tunnel); add `getCurrentProvider` |
| `brokers/event_broker.nim`, `brokers/internal/mt_event_broker.nim` | event-side audit / parity |

> Before editing any symbol, run `gitnexus_impact({target, direction:"upstream"})`
> and report blast radius (the project mandates this; method/`request`/
> `setProvider` are high-fan-in). Run `gitnexus_detect_changes()` before commit.

## Acceptance criteria (turn into tests, then make them pass)

1. **Mock honored on direct call.** Extend `/tmp/mock_demo.nim` (or a new
   `test/test_broker_method_tunneling.nim`): after mocking `Greet`'s provider,
   **`g.greet("bob")` returns `MOCK<bob>`** (today it returns `real:bob`).
2. **Cross-thread method call is safe + correct.** With `--threads:on`, an
   instance created on thread A, method invoked from thread B via
   `g.greet(...)`, executes the provider on thread A (channel tunnel) and
   returns the correct result — no UAF under refc, no wrong-thread bucket.
3. **`getCurrentProvider` round-trip.** Capture original provider → install mock
   → assert mock → restore original → assert original behavior, for both
   zero-arg and with-arg slots, single-thread and MT.
4. **No regression.** `nimble test`, `nimble testApi`, and the
   `test_broker_oop.nim` / `test_broker_interface_*` suites stay green on
   ORC+refc.
5. **Memory-model statement.** Document in the PR how the new path behaves under
   refc vs orc and single-thread vs MT, with the *reason* in a table (per the
   project's documentation preference). Run the ASAN/refc build if lifetimes
   change.

## Reference: reproducer from this session

`/tmp/mock_demo.nim` — single-thread, no FFI. Demonstrates the gap: provider
mock changes `Greet.request(ctx,…)` but not `g.greet(…)`. Use it as the seed
for criterion (1).
