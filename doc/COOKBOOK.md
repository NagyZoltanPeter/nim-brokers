# nim-brokers Cookbook

A collection of small, copy-pasteable snippets — one idea each, most under 20
lines. For the narrative reference see the [Usage Guide](../USAGEGUIDE.md); for
the elevator pitch see the [README](../README.md).

> All handlers are exception-free (`{.async: (raises: []).}` / `raises: []`);
> errors ride `Result[T, string]`. `emit` and `signal` are sync; `request` and
> the `drop*` procs are async. Add `import chronos` where futures appear.

## Table of Contents

- [EventBroker](#eventbroker)
  - [Declare and listen](#declare-and-listen)
  - [listenIt — listener body sugar](#listenit--listener-body-sugar)
  - [Emit — by value and by fields](#emit--by-value-and-by-fields)
  - [Drop listeners](#drop-listeners)
- [RequestBroker](#requestbroker)
  - [Declare and provide](#declare-and-provide)
  - [provideIt / reprovideIt — provider body sugar](#provideit--reprovideit--provider-body-sugar)
  - [Proc-sugar declaration](#proc-sugar-declaration)
  - [Sync mode (no event loop)](#sync-mode-no-event-loop)
  - [Bind a class method as provider](#bind-a-class-method-as-provider)
- [SignalBroker](#signalbroker)
  - [One-way notification](#one-way-notification)
  - [onSignalIt — handler body sugar](#onsignalit--handler-body-sugar)
  - [Payload-less pulse](#payload-less-pulse)
- [MultiRequestBroker](#multirequestbroker)
  - [Fan-out to many providers](#fan-out-to-many-providers)
- [BrokerContext](#brokercontext)
  - [What a context is](#what-a-context-is)
  - [Isolated instances with contexts](#isolated-instances-with-contexts)
- [BrokerInterface / BrokerImplement](#brokerinterface--brokerimplement)
  - [Declare an interface](#declare-an-interface)
  - [Implement the interface](#implement-the-interface)
  - [Use it, and mock it in a test](#use-it-and-mock-it-in-a-test)
- [Threaded brokers `(mt)`](#threaded-brokers-mt)
  - [Cross-thread request](#cross-thread-request)
  - [Cross-thread event](#cross-thread-event)

---

## EventBroker

Pub/sub: many emitters → many listeners, fire-and-forget.

### Declare and listen

```nim
import chronos, brokers/event_broker

EventBroker:
  type UserLoggedIn = object
    userId*: int
    name*: string

# listen returns Result[ListenerHandle, string]; keep the handle to drop later.
let h = UserLoggedIn.listen(
  proc(evt: UserLoggedIn): Future[void] {.async: (raises: []).} =
    echo "login: ", evt.name)
```

### listenIt — listener body sugar

```nim
# Same registration without the lambda boilerplate: the block IS the listener
# body, the event value is injected as `it`. Returns listen's Result.
let h2 = UserLoggedIn.listenIt:
  echo "login: ", it.name, " (#", it.userId, ")"

# Scoped to a context; the body may await (raises: [] applies as usual).
let h3 = UserLoggedIn.listenIt(myCtx):
  await sleepAsync(chronos.milliseconds(1))   # wrap cancellable awaits in try
  echo "scoped: ", it.name

# void event types inject nothing — the block is just the body.
# Works in every lane: single-thread, (mt), (API).
```

### Emit — by value and by fields

```nim
# By value — works for any payload type.
UserLoggedIn.emit(UserLoggedIn(userId: 7, name: "zoli"))

# By fields — shortcut for inline object types only.
UserLoggedIn.emit(userId = 7, name = "zoli")

# emit is sync `void`: it snapshots listeners and asyncSpawns each.
# Never await it. In tests, yield once to let handlers run:
await sleepAsync(0)
```

### Drop listeners

```nim
# drop* is async in every lane (single-thread / (mt) / (API)) — await it.
await UserLoggedIn.dropListener(h.get())   # drop one; cancels its in-flight work
await UserLoggedIn.dropAllListeners()       # drop all for this context
```

---

## RequestBroker

Request/response with a **single** provider per signature.

### Declare and provide

```nim
import chronos, brokers/request_broker

RequestBroker:
  type FetchUser = object
    name*: string
  proc signature*(id: int): Future[Result[FetchUser, string]] {.async.}

# One provider per signature; a second setProvider returns err — clear first.
discard FetchUser.setProvider(
  proc(id: int): Future[Result[FetchUser, string]] {.async.} =
    ok(FetchUser(name: "u" & $id)))

let r = await FetchUser.request(42)   # Result[FetchUser, string]
echo r.get().name                     # "u42"
FetchUser.clearProvider()
```

### provideIt / reprovideIt — provider body sugar

```nim
# The block is the provider's REAL proc body — the declared signature arg
# names (`id` here) are injected; return / result= / trailing expression all
# work, and async-mode bodies may await.
discard FetchUser.provideIt:          # -> setProvider (keeps "already set" guard)
  if id < 0:
    return err("bad id: " & $id)
  return ok(FetchUser(name: "u" & $id))

discard FetchUser.reprovideIt:        # -> replaceProvider (swap, no guard)
  ok(FetchUser(name: "v2-u" & $id))   # trailing expression works too

# Fool-proof: a body that could fall through without producing a value is a
# COMPILE error (it would silently answer err("")). These do not compile:
#   FetchUser.provideIt: echo "side effect only"     # void trailing call
#   FetchUser.provideIt:
#     if id > 0: return ok(...)                      # if without else
#
# Dual-slot brokers (zero-arg + args signatures) name the slots explicitly:
#   provideIt / reprovideIt           -> args slot
#   provideItNoArgs / reprovideItNoArgs -> zero-arg slot
# Sync mode: same sugar, body cannot await. Works in every lane.
```

### Proc-sugar declaration

```nim
# No named type: the broker is the Capitalized verb, and request() returns
# the RAW payload (here: a plain string, no wrapper object to unwrap).
RequestBroker:
  proc getVersion(): Future[Result[string, string]] {.async.}   # broker: GetVersion

discard GetVersion.setProvider(
  proc(): Future[Result[string, string]] {.async.} = ok("1.2.3"))

echo (await GetVersion.request()).get()   # "1.2.3"
```

### Sync mode (no event loop)

```nim
import brokers/request_broker

# No Future, no {.async.} — request() blocks and returns the Result directly.
RequestBroker(sync):
  proc plusOne(x: int): Result[int, string]

discard PlusOne.setProvider(proc(x: int): Result[int, string] = ok(x + 1))
echo PlusOne.request(41).get()   # 42
```

### Bind a class method as provider

```nim
# `self.handle` is not a closure in Nim. bindProvider synthesises the
# forwarding trampoline you'd otherwise hand-write — identical codegen.
type Service = ref object
  brokerCtx: BrokerContext

proc handle(self: Service, id: int): Future[Result[FetchUser, string]] {.async.} =
  ok(FetchUser(name: "svc" & $id))

let svc = Service(brokerCtx: NewBrokerContext())
FetchUser.bindProvider(svc.brokerCtx, svc.handle)   # vs. setProvider(ctx, proc ...)
# rebindProvider swaps an installed one; a plain closure also works.
```

---

## SignalBroker

One-way notification into a module: a **single** handler, **no reply path**.

### One-way notification

```nim
import chronos, brokers/signal_broker

SignalBroker:
  type IngestSample = object
    deviceId*: string
    value*: float64

# One handler (a second onSignal returns err). Exceptions are swallowed.
discard IngestSample.onSignal(
  proc(s: IngestSample) {.async: (raises: []).} =
    echo s.deviceId, " = ", s.value)

# signal() is a plain (non-async) proc — never await it.
let r = IngestSample.signal(deviceId = "d1", value = 0.5)
#   ok()  = ACCEPTED (handler present + queue had room) — NOT "handled"
#   err() = "no signal handler installed" | "queue full"
if r.isErr: echo "not delivered: ", r.error

await IngestSample.dropSignalHandler()   # async — await it
```

### onSignalIt — handler body sugar

```nim
# Same as listenIt, for the single signal handler: the block is the handler
# body, the signal value is injected as `it`. onSignal's duplicate guard and
# Result[void, string] return are unchanged.
discard IngestSample.onSignalIt:
  echo it.deviceId, " = ", it.value
```

### Payload-less pulse

```nim
SignalBroker:
  type Wakeup = void          # no payload

discard Wakeup.onSignal(proc() {.async: (raises: []).} = echo "tick")
discard Wakeup.onSignalIt: echo "tick (sugar)"   # void payload: nothing injected
discard Wakeup.signal()       # fire the pulse
```

---

## MultiRequestBroker

Request/response fanned out to **many** providers; results aggregated.

### Fan-out to many providers

```nim
import chronos, brokers/multi_request_broker

MultiRequestBroker:
  type Quote = object
    price*: int
  proc signature*(sym: string): Future[Result[Quote, string]] {.async.}

# setProvider returns Result[ProviderHandle, string]; register several.
discard Quote.setProvider(proc(s: string): Future[Result[Quote, string]] {.async.} =
  ok(Quote(price: 100)))
discard Quote.setProvider(proc(s: string): Future[Result[Quote, string]] {.async.} =
  ok(Quote(price: 101)))

let all = await Quote.request("BTC")   # Result[seq[Quote], string]; len == 2
echo all.get().len                     # any provider failing fails the whole request
```

---

## BrokerContext

### What a context is

```nim
# A BrokerContext is a `distinct uint32` tag that multiplexes independent
# broker instances. Every broker API takes an OPTIONAL first BrokerContext arg;
# omit it and the thread-global DefaultBrokerContext is used.
import brokers/broker_context

let ctx = NewBrokerContext()   # globally-unique id (atomic counter, thread-safe)
```

### Isolated instances with contexts

```nim
# Same broker type, two contexts → fully isolated. Emitting to one context
# does NOT reach listeners registered under another. Great for per-tenant,
# per-component, or per-test isolation without declaring new broker types.
discard MyEvent.listen(ctxA, handlerA)
discard MyEvent.listen(ctxB, handlerB)

MyEvent.emit(ctxA, payload)    # only ctxA's listener fires
MyEvent.emit(ctxB, payload)    # only ctxB's listener fires

await MyEvent.dropAllListeners(ctxA)
await MyEvent.dropAllListeners(ctxB)
```

---

## BrokerInterface / BrokerImplement

An OOP facade: group brokers behind an interface type, implement per instance.
Each instance gets its own `BrokerContext`, so instances are isolated, and
`instance.method()` calls **tunnel through the broker** (so mocks are honored).

### Declare an interface

```nim
import chronos, brokers/broker_interface, brokers/broker_implement

BrokerInterface(IGreeter):
  RequestBroker:                                   # request verbs...
    proc greet(name: string): Future[Result[string, string]] {.async.}
  EventBroker:                                     # ...and events, grouped
    type Greeted = object
      who*: string
```

### Implement the interface

```nim
type GreeterImpl = ref object of IGreeter   # MUST be `ref object of <Interface>`
  prefix: string

BrokerImplement GreeterImpl of IGreeter:
  proc new(T: typedesc[GreeterImpl], prefix: string): GreeterImpl =
    GreeterImpl(prefix: prefix)             # bare ctor; create() wires providers
  method greet(self: GreeterImpl, name: string): Future[Result[string, string]] {.async.} =
    ok(self.prefix & name)
```

### Use it, and mock it in a test

```nim
let g = GreeterImpl.create(prefix = "hello ")     # fresh context + provider wiring
echo (waitFor g.greet("alice")).value             # "hello alice" (tunnels through Greet)

# Because calls route through the broker, a scoped mock is honored:
Greet.withMockProvider(g.brokerCtx,
  proc(name: string): Future[Result[string, string]] {.async.} = ok("MOCK<" & name & ">")):
  echo (waitFor g.greet("alice")).value           # "MOCK<alice>"

g.close()   # deterministic cleanup of this instance's providers + listeners
```

---

## Threaded brokers `(mt)`

Add `(mt)` for cross-thread dispatch — **the call surface is identical**. Build
with `--threads:on` (and `--mm:orc` or `--mm:refc`). A listening thread must keep
its event loop alive.

### Cross-thread request

```nim
import std/atomics, chronos, brokers/request_broker

RequestBroker(mt):
  type Weather = object
    tempC*: float
  proc signature*(city: string): Future[Result[Weather, string]] {.async.}

var done: Atomic[bool]

proc worker() {.thread.} =                       # requests from another thread
  discard (waitFor Weather.request("Berlin")).isOk()
  done.store(true)

proc main() {.async.} =
  discard Weather.setProvider(                   # provider runs on THIS thread
    proc(city: string): Future[Result[Weather, string]] {.async.} =
      ok(Weather(tempC: 21.5)))
  var t: Thread[void]
  t.createThread(worker)
  while not done.load(): await sleepAsync(1.milliseconds)
  t.joinThread()

waitFor main()
```

### Cross-thread event

```nim
import std/atomics, chronos, brokers/event_broker

EventBroker(mt):
  type Alert = object
    message*: string

proc worker() {.thread.} =
  Alert.emit(Alert(message: "from worker"))      # emit is sync void — same as ST

proc main() {.async.} =
  discard Alert.listen(                           # listener on the main thread
    proc(e: Alert): Future[void] {.async: (raises: []).} =
      echo "alert: ", e.message)
  var t: Thread[void]
  t.createThread(worker)
  await sleepAsync(50.milliseconds)               # let the cross-thread event arrive
  t.joinThread()
  await Alert.dropAllListeners()

waitFor main()
```
