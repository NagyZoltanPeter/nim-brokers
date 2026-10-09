# BrokerScope — Plan (Design option B)

Status: IMPLEMENTED on branch `feat-broker-scope`.

## 1. Goal

A component that registers several listeners / signal handlers / providers
should be able to tear all of them down with one call, without carrying a
`BrokerContext` plus a bag of handles around.

```nim
let scope = newBrokerScope()              # owns a fresh ctx (or adopts one)
?VolumeChanged.listenIt(scope): self.volume = it.level
?GetVolume.provideIt(scope):    return ok(GetVolume(level: self.volume))
?Mute.onSignalIt(scope):        self.volume = 0
...
await scope.close()                       # LIFO; scope is open again after
```

Purely additive. Every existing ctx-based overload is unchanged.

## 2. Semantics (the contract)

| # | Rule |
|---|------|
| S1 | Registration through a scope = the ctx overload on `scope.ctx`. The undo is recorded **only on `ok`**. While a close is running → `err("BrokerScope is closing")`, nothing registered. |
| S2 | `close()` runs undos in **reverse registration order**. Concurrent callers wait on the **same** teardown. The undo list is detached (`move`) before the first `await`, so a handler that closes its own scope is safe. When the teardown finishes, the scope is empty and **open again (re-openable)**; registrations are rejected only *during* the teardown, since they would otherwise land in neither batch. The rejection starts at the first undo (a `tearingDown` flag, set before the synchronous walk). Callers `join` the teardown instead of awaiting it, so cancelling a caller cannot cancel undos; the teardown resets its own state. A re-entrant `close()` from the synchronous phase returns immediately. |
| S3 | **Release, not clear.** Each undo removes *exactly the closure this scope installed*, only if it is still installed **and** still owned here. Anything else is a **logged no-op** (`alreadyGone` → `debug`, `takenOver` / `ownerChanged` → `warn`): dropped already, replaced by a mock or another owner, or cleared from another thread and re-provided by someone else. Out-of-scope lifecycle management always wins and is never an error, but it is never silent. The warn carries `brokerType`, `kind` (listener / signalHandler / provider / provider slot), `brokerCtx` and `outcome` (`alreadyGone` / `takenOver` / `ownerChanged`; see §4.2). |
| S4 | Ownership identity = closure identity (`==`, fn ptr + env). For MT lanes it is additionally the bucket's `(threadId, threadGen)`, checked **under the global lock in the same critical section as the removal**. |
| S5 | **Dual-slot RequestBroker:** release touches **only the slot the scope registered**. The bucket is torn down only when both slots are empty. |
| S6 | `replaceProvider(scope, p)` / `reprovideIt(scope)` / `replaceSignalHandler(scope, h)`: replace-or-insert, then track release-of-`p`. `close()` **does not restore** the displaced provider or handler (that is `withMockProvider`'s job). Undos are unkeyed. A slot registered twice through one scope records two undos; run newest-first, the older one finds its closure gone (`alreadyGone`, debug) and is a no-op. A keyed overwrite was implemented first and then removed as not worth its string allocations. |
| S7 | Thread affinity: a scope belongs to the thread that created it. Misuse from another thread is logged with chronicles `error` and nothing happens, with no assert. **Registration** → `err("BrokerScope used off its owning thread")`, nothing registered. **`close()`** → returns an already-completed `Future`; the scope is **not** marked closed and the undo list is kept, so the owning thread can still close it properly. Under `--threads:off` there is no check. |
| S8 | `close()` returns `Future[void]`, with no `Result`. Every release is `raises: []` and infallible by S3. |

### Accepted edge cases (documented, not "fixed")

- A `withMockProvider` block that spans `close()`: close is a no-op for that
  slot (mock installed). The template's `finally` then **restores our
  provider after the scope closed**. That is the mock owner's lifecycle; S3 applies.
- The same top-level (nimcall) proc registered by two owners is
  indistinguishable (env = nil): the first scope to close removes it. The same
  holds for MultiRequestBroker, which already **dedups** identical handlers into one handle.

## 3. Hazards found in the current code that S3/S4 must defend against

| Hazard | Where | Consequence for a naive `drop*`/`clear*` undo | Defence |
|---|---|---|---|
| H1 Listener id reuse (ABA) | `event_broker.nim:244-253` (per-bucket `nextId`, bucket deleted on last drop → restarts at 1); MT `tvNextIds` deleted in `dropListenerImpl` (`mt_event_broker.nim:737-740`) | After an external `dropAllListeners` + someone else's `listen` on the same ctx, our stale handle `id=1` drops **their** listener | Release checks `table[id] == ourHandler` before dropping |
| H2 Stale MT provider threadvar | `mt_request_broker.nim` clearBody: `tvCleanup` runs only `if isProviderThread` | A foreign-thread `clearProvider` leaves the owner's tv entry. If thread B then provides the same ctx, our `getCurrentProvider` still returns *our* closure, so a naive check would `clearProvider` **B's** provider | Owner check `(threadId, threadGen)` under lock, atomically with removal. A stale tv entry is just purged locally |
| H3 Stale MT signal threadvar | `mt_signal_broker.nim:510-516` (`if isOwner`) | Same as H2 for signal handlers | Same as H2 |
| H4 Check-then-drop race (MT) | any "getCurrent… then drop…" pair | Between the check and the (re-locking) drop, another thread can drop and re-register | Owner check inside the **same** lock section as the bucket removal (parameterised impl, §4.2) |
| H5 Multi handle index reuse | `multi_request_broker.nim` (index = `id-1`, non-default bucket deleted when empty) | A stale handle can null out another owner's provider | Release checks `slot[idx] == ourHandler` |
| H6 `clearProvider` clears both slots | `request_broker.nim:903`, MT clearBody | A scope owning only one slot wipes the other owner's slot | Per-slot release (S5) |

H2/H3 are **pre-existing** bugs for `getCurrentProvider` / `withMockProvider`
too (owner-thread introspection returns a closure that is no longer
installed). Out of scope here. Track separately.

## 4. Design

### 4.1 `brokers/broker_scope.nim` (new)

```nim
type
  BrokerUndo* = proc(): Future[void] {.async: (raises: []), gcsafe.}
  BrokerScope* = ref object
    ctx: BrokerContext
    when compileOption("threads"): owner: pointer
    undo: seq[BrokerUndo]
    closing: Future[void]           # non-nil only while a close runs

proc newBrokerScope*(ctx = NewBrokerContext()): BrokerScope
func ctx*(s: BrokerScope): BrokerContext
func isOpen*(s: BrokerScope): bool
proc onOwningThread*(s: BrokerScope, op: string): bool  # false → chronicles error logged (S7)
proc track*(s: BrokerScope, u: BrokerUndo)      # exported: generated code expands in user modules
proc close*(s: BrokerScope): Future[void]       # S2; scope re-opens when done
```

- `ref object`, so no accidental copies (a value copy would duplicate the undo list).
- `track` is necessarily exported (macro output lives in the user's module).
  Document it as "low-level; prefer the scope overloads". This gives the
  escape hatch for free, with no extra API.
- `event_broker`, `request_broker`, `multi_request_broker`, `signal_broker`
  (and their MT internals) `import` + `export` `broker_scope`, so the user needs
  no extra import.

### 4.2 Per-broker release procs (generated, **not exported**)

One `release…` impl per broker per lane. These are unexported procs in the macro
output; the scope overloads (same output) are their only callers. A release is
the undo body a scope's closure calls. It means "remove *this exact closure*
if it is still installed and still owned by this thread", and it is the
ownership-checked counterpart of `dropListener` / `dropSignalHandler` /
`clearProvider` / `removeProvider`, which remove whatever is installed.

Each release reports an outcome. Anything but `released` produces the S3 `warn`:

| Outcome | Meaning |
|---|---|
| `released` | ours, removed |
| `alreadyGone` | nothing installed for this ctx/slot/handle (dropped or cleared out of scope) |
| `takenOver` | something else is installed (mock, `replace*` by another owner, ABA re-registration) |
| `ownerChanged` | MT only: our threadvar entry is stale; the shared bucket is gone or owned by another (thread, gen). The stale entry is purged locally. |

| Broker / lane | Release proc | Identity / ownership check | Action |
|---|---|---|---|
| EventBroker ST | `releaseListener<T>(ctx, h, handler)` | bucket(ctx).table[h.id] == handler | existing drop logic |
| EventBroker MT | same | `tvHandlers[ctx][h.id] == handler` (tv is thread-local; thread asserted by scope) | `dropListenerImpl` (suspension-free, unchanged) |
| SignalBroker ST | `releaseSignalHandler<T>(ctx, handler)` | slot(ctx) == handler | existing drop logic |
| SignalBroker MT | same | tv(ctx) == handler **and**, under lock, bucket owner == (me, gen) | `dropImpl(ctx, requireOwner = true)`, extended so the owner check and the bucket removal share one critical section. If it is not the owner: purge the stale tv entry only. |
| RequestBroker ST (async + sync) | `releaseProvider<T>(ctx, handler)`, overloaded on the slot's handler type (as `replaceProvider` is) | slot entry(ctx) == handler | remove that slot's entry. If both slots are empty for ctx → existing clear path |
| RequestBroker MT | same | tv slot(ctx) == handler **and**, under lock, bucket owner == (me, gen) | remove the tv slot entry. If the other slot is empty too → `clearBody(requireOwner = true)` (fails in-flight requests with `ProviderGone`, as today). If the other slot is still set → the bucket stays; requests to the cleared slot already get "no provider registered for input signature" (`mt_request_broker.nim:793`). If it is not the owner: purge the stale tv entry only. |
| MultiRequestBroker (ST only) | `releaseProvider<T>(ctx, h, handler)` | bucket(ctx).slots[h.id-1] == handler | existing `removeProvider` |

The existing `dropImpl` / `clearBody` keep their current behaviour for all
existing callers (`requireOwner = false` path is byte-for-byte today's).

### 4.3 Scope overloads (generated, exported)

| Broker | New overload | Returns | Undo captured |
|---|---|---|---|
| EventBroker (ST, MT) | `listen(T, scope, handler)` | `Result[<T>Listener, string]` (caller may still drop early) | `releaseListener(ctx, h, handler)` |
| SignalBroker (ST, MT) | `onSignal(T, scope, handler)` | `Result[void, string]` | `releaseSignalHandler(ctx, handler)` |
| SignalBroker (ST, MT) | `replaceSignalHandler(T, scope, handler)` | `Result[void, string]` | `releaseSignalHandler(ctx, handler)`. When ours, this is a **full** drop (bucket + ring + present counter), not replace-with-`default`, because `replaceSignalHandler(ctx, default)` keeps the bucket alive (`mt_signal_broker.nim:688-694`). No `It` sugar exists for replace, so none is added. |
| RequestBroker (ST async/sync, MT), per slot | `setProvider(T, scope, handler)` | `Result[void, string]` | `releaseProvider(ctx, handler)` |
| RequestBroker (ST async/sync, MT), per slot | `replaceProvider(T, scope, handler)` | `Result[void, string]` | `releaseProvider(ctx, handler)` |
| MultiRequestBroker, per slot | `setProvider(T, scope, handler)` | `Result[<T>ProviderHandle, string]` | `releaseProvider(ctx, h, handler)` |

Body shape (all identical):

```nim
if not scope.onOwningThread("<verb>"): return err("BrokerScope used off its owning thread")
if not scope.isOpen: return err("BrokerScope is closing")
let r = <T>.<verb>(scope.ctx, handler)        # existing ctx overload
if r.isOk:
  let ctx = scope.ctx                          # capture values, never the scope
  scope.track(proc() {.async: (raises: []), gcsafe.} =
    <release>(ctx, [h,] handler))
r
```

### 4.4 Sugar comes for free

`bindTemplateDef` declares the sugar's `brokerCtx` as `untyped`
(`broker_utils.nim:298-308`). `buildItSugarTemplates` / `buildProvideTemplates`
forward `verb(T, brokerCtx, λ)` (`broker_utils.nim:556`). So these need **no
template changes**:

- `listenIt(scope)`, `onSignalIt(scope)`
- `provideIt(scope)`, `provideItNoArgs(scope)`
- `reprovideIt(scope)`, `reprovideItNoArgs(scope)`
- MultiRequest `provideIt(scope)`

To verify in phase 0: `bindListener` / `bindProvider` / `rebindProvider`
(issue #42) use the same `bindTemplateDef` path, so they should also work for free.

### 4.5 Out of scope (v1)

- `(API)` lane: rides MT, so the overloads exist there automatically. **No FFI
  surface, header, or wrapper change.** The C / C++ / Python / Rust / Go binding
  rule does not apply, because this is a Nim-side registration API with nothing on the wire.
- `BrokerInterface` / `BrokerImplement` (hierarchical brokers) integration.
- `=destroy`-driven auto-close (async undos; refc destructors unreliable;
  ORC cycle through self ↔ registry).

## 5. Memory model

| Aspect | refc | ORC | Why |
|---|---|---|---|
| Undo closure env | thread-local GC heap | thread-local, RC'd | Created and run on the scope's owning thread only (S7); never crosses threads |
| Scope ↔ component | self → scope → undo → handler → self (cycle) | same cycle | The registry is a root while registered. `close()` moves out the undo seq and removes the handlers, which breaks the cycle: ORC frees deterministically, refc at the next thread-local GC |
| Never closed | leak (same as a forgotten `dropListener` today) | leak; the cycle collector cannot help (registry root) | Documented; no implicit RAII |
| Shared memory | none added | none added | Releases use existing lock + bucket paths |

Platforms: no platform-specific code. The MT thread identity reuses
`currentMtThreadId` / `currentMtThreadGen` (`mt_broker_common.nim:111`).

## 6. Phases

1. **Pre-flight.** `gitnexus_impact` (upstream) on each generator touched:
   `EventBroker`/`generateEventBroker*`, `RequestBroker` gen, MT clearBody owner
   (`mt_request_broker` generator), `mt_signal_broker` dropImpl generator,
   `MultiRequestBroker` gen. Report the blast radius. Confirm the §4.4 bind-sugar
   claim by reading `buildBindTemplates`.
   → verify: impact report posted. (Memory note: `gitnexus analyze` crashed on
   this machine before; if the index is stale, report it rather than block.)
2. **`broker_scope.nim` + core test** (`test/test_broker_scope.nim`, part 1):
   LIFO via `track`, idempotent/concurrent `close` (same Future),
   self-close from inside an undo, rejection while closing, re-open.
   → verify: `nim c -r --path:. --outdir:build test/test_broker_scope.nim`, refc + orc.
3. **Release procs (§4.2)**, ST then MT, including the `requireOwner` parameter on
   MT `dropImpl` / `clearBody`.
   → verify: existing suites unchanged, green (`nimble test`). Especially
   `test_mt_provider_mock`, `test_mt_request_slot_lifecycle`,
   `test_mt_drop_async_eager`, `test_multi_thread_signal_broker`.
4. **Scope overloads (§4.3)** in every lane.
   → verify: `test_broker_scope.nim` part 2 (§7 ST matrix) + new
   `test/test_multi_thread_broker_scope.nim` (§7 MT matrix).
5. **Wire tests into `brokers.nimble`** (`test` task, ORC/refc × debug/release),
   then run the full gate: `nimble test`, `nimble testApi`, plus one ASAN + refc
   run of the MT scope test (lifetime-touching change).
   → verify: all green, with real output reported.
6. **Docs:** `USAGEGUIDE.md` section "Scoped registrations (BrokerScope)",
   AGENTS.md paragraph per broker specifics, `doc/FFI_API.md` one-liner (API
   lane: available, no FFI impact). No CHANGELOG, no version bump (release
   process owns them). `nimble nphall`.

## 7. Test matrix

| Case | ST | MT |
|---|---|---|
| listen/onSignal/setProvider/replaceProvider/multi + every `It` sugar through scope, then close → `emit` not delivered, `hasSignalHandler`/`isProvided` false, multi returns empty | ✓ | ✓ |
| Registration error (provider already set / handler already set) → nothing tracked; close leaves the other owner intact | ✓ | ✓ |
| Externally `dropListener` / `dropSignalHandler` / `clearProvider` before close → close is a no-op, outcome `alreadyGone` | ✓ | ✓ |
| Outcome classification: the test module declares its own brokers, so the unexported `release*` procs are callable there. Assert `released` / `alreadyGone` / `takenOver` / `ownerChanged` directly; warn emission itself is checked by eye in the test log | ✓ | ✓ |
| `replaceSignalHandler(scope)` → close does a full drop (`hasSignalHandler` false, `signal()` → `"no signal handler installed"`); another owner's replace → survives, `takenOver` | ✓ | ✓ |
| **H1** external `dropAllListeners` + another listener on the same ctx → survives close | ✓ | ✓ |
| `withMockProvider` active at close → mock survives; documented post-close restore | ✓ | ✓ |
| Another owner `replaceProvider` → survives close | ✓ | ✓ |
| **S5/H6** dual-slot: scope owns NoArgs only, other owner owns Args → after close, Args requests still succeed and NoArgs requests get "no provider" | ✓ | ✓ |
| **H2/H3** thread B `clearProvider`/`dropSignalHandler` on the scope's ctx, then B provides/handles the same ctx → A's close leaves B's intact; A's stale tv purged | — | ✓ |
| MT per-slot release with the other slot set → bucket kept, in-flight requests on the other slot unaffected | — | ✓ |
| Last-slot release → in-flight requests resolve `ProviderGone` immediately | — | ✓ |
| `reprovideIt(scope)` twice → close clears; the older undo is an `alreadyGone` no-op | ✓ | ✓ |
| Off-thread registration → `err`, nothing registered; off-thread `close()` → completed Future, scope still open; owner-thread `close()` afterwards releases everything | — | ✓ |
| **H5** multi: external `removeProvider` + new provider at a reused index → survives close | ✓ | — |

## 8. Open questions

Resolved:

- **Q2** `replaceSignalHandler(scope, …)`: **added** (§4.3).
- **Q3** Name: **`BrokerScope`**.
- **Q4** Off-thread misuse: chronicles **`error` + no-op**, no assert (S7).
- **Not-ours at close**: **`warn`**, never silent (S3).

- **Q1** `release*` procs: **not exported**. They stay enclosed in the macro
  output; the scope overloads are their only callers (§4.2).

- **Q5** `alreadyGone` is logged at **`debug`** (a legitimate early manual drop
  must not spam). `takenOver` / `ownerChanged` stay at `warn`.
