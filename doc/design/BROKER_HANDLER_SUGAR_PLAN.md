# Broker handler sugar: `listenIt` / `onSignalIt` / `provideIt` / `reprovideIt`

Branch: `chore-broker-handler-sugar`

## Goal

Remove the handler-registration boilerplate — the hand-written
`proc(event: T): Future[void] {.async: (raises: []).} = ...` lambda — for the
three handler-taking brokers, while keeping the body a *real Nim proc body*
(`return`, `result =`, trailing expression all work) and making it
**impossible to silently register a provider that falls through** and answers
`err("")`.

```nim
let h = UserLoggedIn.listenIt:            # EventBroker
  echo "login: ", it.name

let s = IngestSample.onSignalIt:          # SignalBroker
  echo it.deviceId

let p = Transform.provideIt:              # RequestBroker -> setProvider
  if len <= 0:
    return err("len must be positive")
  return ok(process(input, len))

let q = Transform.reprovideIt:            # RequestBroker -> replaceProvider
  ok(newSeq[byte](len))
```

All four return exactly what the underlying registration proc returns
(`Result[<T>Listener, string]` / `Result[void, string]`).

## Constraints established by prototype (all compile-verified)

The prototypes live in the session scratchpad (`sugar_proto.nim`,
`provide_proto3.nim`); their findings:

1. **`do`-notation cannot replace this.** chronos' `async` macro rejects
   do-blocks (`invalid pragma: stackTrace: off`), so there is no zero-cost
   syntax today.
2. **The sugar cannot reuse the existing names** (`listen`, `setProvider`).
   Mixing a proc and a `body: untyped` template in one overload set makes Nim
   sem-check the untyped body during overload resolution → spurious
   `undeclared identifier` on the injected symbol. Same mechanism already
   documented for `bind<Noun>` at `broker_utils.nim:167-177`. Distinct names
   are mandatory.
3. **`{.inject.}` on a lambda parameter does not work** inside templates. The
   working, zero-cost pattern is an injected zero-arg alias template inside
   the lambda:
   `template it(): T {.inject, used.} = brokerEvent`. No copy, no new
   refc/ORC exposure — identical codegen to the hand-written lambda.
4. **In overloaded sugar templates, every parameter except the `typedesc`
   receiver must be `untyped`** (in particular `brokerCtx`), or constraint 2
   re-triggers. Typedesc-constrained per-type overloads of one sugar name
   across broker types are fine.
5. Alias-template injection is scope-safe even for hostile names: injecting
   `len` leaves `input.len` resolving to `system.len` (bare `len` = the arg).

## Surface specification

| Sugar | Broker | Underlying call | Injected symbols | Returns |
|-------|--------|-----------------|------------------|---------|
| `T.listenIt[(ctx)]: body` | EventBroker (ST/mt/API) | `listen` | `it: T` | `Result[<T>Listener, string]` |
| `T.onSignalIt[(ctx)]: body` | SignalBroker (ST/mt/API) | `onSignal` | `it: T` (nothing for `void` payload) | `Result[void, string]` |
| `T.provideIt[(ctx)]: body` | RequestBroker (async/sync/mt/API) | `setProvider` | declared signature arg names | `Result[void, string]` |
| `T.reprovideIt(ctx): body` / `T.reprovideIt: body` | RequestBroker | `replaceProvider` | declared signature arg names | `Result[void, string]` |

- Ctx form mirrors the two-overload convention of the underlying procs
  (no-ctx overload forwards `DefaultBrokerContext`).
- `provideIt` keeps `setProvider`'s "Provider already set" runtime guard;
  `reprovideIt` is replace-or-insert (mirrors `replaceProvider`).
- Body semantics: the body **is** the handler/provider proc body. `await` is
  legal in async lanes, `raises: []` is enforced exactly as for a hand-written
  handler; sync-mode `provideIt` bodies cannot `await` (compile error from
  chronos).

## Fool-proofing: the `providerBody` checker (RequestBroker only)

Listener/signal bodies are `Future[void]` — nothing to forget. Provider
bodies must produce `Result[T, string]`; a body that falls off the end would
silently return `default(Result)` == `err("")` (case object, zeroed
discriminator = error branch — results.nim:322-340). To close that hole,
`provideIt`/`reprovideIt` wrap the spliced body in a shared macro:

```
providerBody(sugarName: static string, body: untyped): untyped
```

Rule (on the untyped AST, before chronos' async transform):

1. If the body contains a **top-level terminal statement**, splice unchanged.
   Terminal = `return`, `raise`, `result = ...`, a `block` (without `break`)
   whose body is terminal, or a final `if`/`when`/`case`/`try` in which
   *every* branch is terminal (an `if` also needs an `else`).
   Soundness: top-level statements are straight-line — control always reaches
   the terminal statement or was already diverted by an earlier one. This
   keeps `result = ok(...)` followed by a mutation loop legal.
2. Else, if the last statement is **definitely void** (`for`, `while`,
   `discard`, `var`/`let`/`const` section, nested routine defs, `defer`, ...)
   → `error(...)` with a positioned, actionable message
   ("...otherwise the provider would silently answer err(\"\")").
   A final `if`/`when` without `else` gets a dedicated message (it can never
   be an expression).
3. Else the last statement is a **potential trailing expression** → rewrite
   it to `result = <expr>`, pinning it to the return type. `echo x` (a
   command AST, indistinguishable from `ok x`) then fails with a type error
   at the user's line instead of compiling.

Verified matrix (prototype `provide_proto3.nim`): 8 legit styles compile and
run (guard-returns, `result=`+loop, trailing expr, branch-returns, branch
expressions — each in sync and async where applicable); 6 misuse patterns are
compile errors with positions (discard-only, echo-end, loop-end, partial-if,
bare payload, async echo-end).

Accepted limits (documented, not worked around):
- a `block` containing `break` is conservatively non-terminal;
- noreturn calls (`quit()`, `raiseAssert`) are not recognized as terminal —
  the pin then yields a void-type mismatch; add an explicit `return` there.

## Implementation steps

### Step 1 — `providerBody` checker in `broker_utils.nim`

Add to `brokers/internal/helper/broker_utils.nim` (next to the bind-template
codegen, §"Shared codegen"):

- `proc containsBreak(n: NimNode): bool` (does not descend into nested
  `for`/`while`, whose breaks are local)
- `proc isTerminalProviderStmt*(n: NimNode): bool`
- `macro providerBody*(sugarName: static string, body: untyped): untyped`

Verify: unit-style checks in the new `test/test_broker_sugar.nim` —
positive via normal use, negative via
`static: doAssert not compiles(...)` (macro `error()` is caught by
`compiles`).

### Step 2 — generic `listenIt` / `onSignalIt`

New module `brokers/internal/helper/broker_it_sugar.nim`:

```nim
template listenIt*(T: typedesc, body: untyped): untyped =
  mixin listen
  T.listen(
    proc(brokerEvent: T): Future[void] {.async: (raises: []), gcsafe.} =
      template it(): T {.inject, used.} = brokerEvent
      body
  )

template listenIt*(T: typedesc, brokerCtx: untyped, body: untyped): untyped = ...
# onSignalIt*: same shape over `mixin onSignal`
```

- Re-export from `brokers/event_broker.nim` and `brokers/signal_broker.nim`
  (both ST and the `--threads:on` re-export path), so every lane gets it —
  the template just calls whatever `listen`/`onSignal` is in scope at the
  call site (ST, mt, API all share the signature shape).
- Void-payload brokers (`type Pulse = void`, SignalBroker; ST EventBroker
  also has a no-arg listener form): select the no-arg lambda via
  `when compiles(T.listen(proc(): Future[void] {...} = discard))`, injecting
  nothing. If that turns out brittle in practice, fall back to emitting
  per-type sugar from the macros (same emission sites as Step 3) — decide by
  test outcome, not by preference.

Verify: new cases in `test_event_broker.nim`, `test_signal_broker.nim`,
`test_multi_thread_event_broker.nim` (+ signal MT test file): value events,
inline-field emit interplay, ctx form, drop via returned handle, void pulse.

### Step 3 — per-type `provideIt` / `reprovideIt` codegen

`provideIt` **must** be per-type generated: the lambda needs the declared arg
names and the concrete `Result[Payload, string]` return type, neither of
which a generic template can derive from the broker tag.

Add a builder in `broker_utils.nim` (sibling of `buildBindTemplates`,
reusing `BindSlot`-style inputs):

```
buildProvideTemplates*(typeIdent, verbName, sugarName: string,
                       slot: BindSlot, argNames: seq[NimNode]): NimNode
```

emitting per slot the ctx-form + no-ctx-form templates whose lambda contains
the injected alias templates followed by `providerBody("<sugarName>", body)`.

Emission sites (both slots, guarded by `argSig`/`zeroArgSig` nil-ness, same
as the bind block):

- `brokers/request_broker.nim` — next to the `bindProvider` block
  (`request_broker.nim:1095-1120`); covers async, sync, and — via the mode
  enum — the API lane. Sync mode uses the sync proc shape
  (`Result[...] {.raises: [CatchableError], gcsafe.}`, no `await`).
- `brokers/internal/mt_request_broker.nim` — next to its bind block
  (`mt_request_broker.nim:1792-1797`). Registration inherits MT semantics:
  `provideIt` binds the bucket to the calling thread; `reprovideIt` is
  owning-thread-only (as `replaceProvider` is). Document in the template
  doc-comments.

**Dual-slot naming decision**: a broker declaring both a zero-arg and an
args signature gets `provideIt`/`reprovideIt` for the **args slot** and
`provideItNoArgs`/`reprovideItNoArgs` for the zero-arg slot. Deterministic —
no `when compiles` slot-guessing (an args-free body is valid for *both*
slots, so guessing would silently pick one). Single-slot brokers get plain
`provideIt` for whichever slot exists. (Mirrors the
`getCurrentProvider`/`getCurrentProviderNoArgs` split.)

Verify: new cases in `test_request_broker.nim` (async + sync + dual-slot +
POD proc-sugar broker + ctx form + already-set guard + reprovide swap) and
`test_multi_thread_request_broker.nim`; negative-compile asserts for the six
misuse patterns.

### Step 4 — tests wired into `nimble test`

`test/test_broker_sugar.nim` (checker unit tests + cross-broker cases that
don't fit the per-broker files) added to the test task list in
`brokers.nimble`, alongside the additions to the existing test files.

### Step 5 — docs + polish

- `AGENTS.md` / `README.md`: short section per broker with one example each;
  the RequestBroker section states the body rules (must produce a value on
  every path) and the two accepted limits.
- `Broker_FFI_API.md` untouched — no FFI/ABI surface change.
- `nimble nphall` formatting pass.
- Version: bump `brokers.nimble` 3.3.0 → 3.4.0 (additive surface) — confirm
  before committing the bump.

### Process requirements (per repo rules)

- Before editing: `gitnexus_impact` on `generateRequestBroker`,
  `buildBindTemplates`, and the EventBroker/SignalBroker generator procs;
  report blast radius.
- Before each commit: `gitnexus_detect_changes()`; keep the GitNexus
  symbol-count rewrites of `AGENTS.md`/`CLAUDE.md` out of commits.
- Gate: `nimble test` + `nimble testApi` green on ORC and refc (the tasks
  iterate both). No behavioral change is expected in any existing test —
  the sugar is purely additive codegen.

## MultiRequestBroker (added in the same PR)

`provideIt` was extended to MultiRequestBroker, reusing `buildProvideTemplates`
+ `providerBody` verbatim, emitted next to its existing `bindProvider` block.
Differences from RequestBroker, forced by the additive fan-out model:

- **No `reprovideIt`** — there is no `replaceProvider`; providers are additive
  and removed by handle (`removeProvider`). Mirrors the pre-existing
  `bindProvider`-without-`rebindProvider` decision.
- Returns `setProvider`'s `Result[<T>ProviderHandle, string]` (the handle), not
  `Result[void, string]`.
- Each `provideIt` **adds** a provider; the generated closure is a fresh
  reference, so the reference-dedup never collapses two blocks.
- Async-only (no sync-body branch). Dual-slot naming unchanged
  (`provideIt` / `provideItNoArgs`).

## Explicitly out of scope

- A `providerBody`-grade fall-through check for `listenIt`/`onSignalIt`
  bodies (they are `void`; nothing to forget).
- FFI wrapper generation — foreign-language surfaces are unaffected.

## Memory-model note

All sugar is template/macro expansion producing the *same* closure the user
would write by hand: no new allocation sites, no lifetime changes, identical
behavior under `--mm:refc` and `--mm:orc` on all platforms. The only codegen
delta versus a hand-written handler is the injected zero-arg alias templates
(compile-time only) and, for providers, the possible `result = <expr>` pin
(semantically identical to the implicit-result the expression already had).
