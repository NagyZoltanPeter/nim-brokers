{.push raises: [].}

## Issue #51: `listenIt` / `onSignalIt` used inside an *implicitly generic*
## proc — any `proc f(T: typedesc[X], …)`, which is exactly what
## `BrokerImplement` emits for `new` / `create` / `createUnderContext`.
##
## A generic body is sem-checked at the caller's instantiation site, so the old
## module-global sugar (which reached its `listen` / `onSignal` through
## `mixin`) resolved the verb in the CALLER's scope. A caller that does not
## import `sugar_scope_events` has no matching overload there, and the sugar
## failed with a type mismatch raised inside `brokers/event_broker.nim`.
##
## Everything that touches the event/signal types stays in this module; the
## test module only calls the generic entry points below.

import chronos, results
import brokers/broker_interface, brokers/broker_implement, brokers/broker_context
import ./sugar_scope_events

type Counter* = ref object
  seen*: int

proc wire*(T: typedesc[Counter]): Counter =
  ## Implicitly generic through the `typedesc` parameter — the minimal shape of
  ## the bug, without any broker OOP machinery.
  let c = Counter()
  discard ScopedEvent.listenIt:
    c.seen += it.n
  discard ScopedSignal.onSignalIt:
    c.seen += it.n * 10
  c

proc fireEvent*(n: int) =
  ScopedEvent.emit(n = n)

proc fireSignal*(n: int) =
  discard ScopedSignal.signal(n = n)

proc unwire*() {.async: (raises: []).} =
  await ScopedEvent.dropAllListeners()
  await ScopedSignal.dropSignalHandler()

# ── the reported shape: sugar inside a `BrokerImplement` constructor ────────

BrokerInterface(IScoped):
  RequestBroker:
    proc total(): Future[Result[int, string]] {.async.}

type ScopedImpl* = ref object of IScoped
  counter*: Counter
  nodeCtx*: BrokerContext
    ## A context of its own, captured in `new` — mirrors the reported code,
    ## which listened on the node context rather than the instance one.

BrokerImplement ScopedImpl of IScoped:
  proc new(T: typedesc[ScopedImpl]): ScopedImpl =
    let self = ScopedImpl(counter: Counter(), nodeCtx: NewBrokerContext())

    discard ScopedEvent.listenIt(self.nodeCtx):
      self.counter.seen += it.n

    discard ScopedSignal.onSignalIt(self.nodeCtx):
      self.counter.seen += it.n * 10

    self

  method total(self: ScopedImpl): Future[Result[int, string]] {.async.} =
    ok(self.counter.seen)

proc fireEventIn*(ctx: BrokerContext, n: int) =
  ScopedEvent.emit(ctx, ScopedEvent(n: n))

proc fireSignalIn*(ctx: BrokerContext, n: int) =
  discard ScopedSignal.signal(ctx, ScopedSignal(n: n))

when compileOption("threads"):
  proc wireMt*(T: typedesc[Counter]): Counter =
    ## Same generic shape, multi-thread lane.
    let c = Counter()
    discard ScopedMtEvent.listenIt:
      c.seen += it.n
    discard ScopedMtSignal.onSignalIt:
      c.seen += it.n * 10
    c

  proc fireMtEvent*(n: int) =
    ScopedMtEvent.emit(ScopedMtEvent(n: n))

  proc fireMtSignal*(n: int) =
    discard ScopedMtSignal.signal(ScopedMtSignal(n: n))

  proc unwireMt*() {.async: (raises: []).} =
    await ScopedMtEvent.dropAllListeners()
    await ScopedMtSignal.dropSignalHandler()
