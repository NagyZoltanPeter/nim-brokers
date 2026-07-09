{.used.}

import testutils/unittests
import chronos
import std/[atomics]

import brokers/event_broker

## ---------------------------------------------------------------------------
## Multi-thread EventBroker tests
## ---------------------------------------------------------------------------

EventBroker(mt):
  type MtEvt = object
    value*: int
    label*: string

# ── Global synchronization ────────────────────────────────────────────────

var gDone: Atomic[bool]
var gReceivedCount: Atomic[int]
var gReceivedSum: Atomic[int]

# Shared BrokerContext values for cross-thread context tests.
var gCtxA: BrokerContext
var gCtxB: BrokerContext

# Listener handle stored by listener thread, read by main after join.
# Using a simple int64 since Atomic doesn't support objects.
var gListenerHandleId: Atomic[uint64]
var gListenerReady: Atomic[bool]

# ── Thread procs (module-level, no closures) ─────────────────────────────

proc emitterThread() {.thread.} =
  MtEvt.emit(MtEvt(value: 42, label: "cross"))

proc emitterThreadMulti() {.thread.} =
  for i in 1 .. 3:
    MtEvt.emit(MtEvt(value: i, label: "multi"))

proc emitterThreadCtxA() {.thread.} =
  MtEvt.emit(gCtxA, MtEvt(value: 100, label: "ctxA"))

proc emitterThreadCtxB() {.thread.} =
  MtEvt.emit(gCtxB, MtEvt(value: 200, label: "ctxB"))

# A thread that listens, signals ready, then keeps event loop alive.
proc listenerThread() {.thread.} =
  proc inner() {.async.} =
    let handle = MtEvt.listen(
      proc(evt: MtEvt): Future[void] {.async: (raises: []).} =
        discard gReceivedCount.fetchAdd(1)
        discard gReceivedSum.fetchAdd(evt.value)
    )
    doAssert handle.isOk()
    gListenerHandleId.store(handle.get().id)
    gListenerReady.store(true)
    # Keep event loop alive until signalled to stop
    while not gDone.load():
      await sleepAsync(chronos.milliseconds(1))
    await MtEvt.dropAllListeners()

  waitFor inner()

# A thread that listens but does NOT call dropAllListeners — caller does.
proc listenerThreadNoDrop() {.thread.} =
  proc inner() {.async.} =
    let handle = MtEvt.listen(
      proc(evt: MtEvt): Future[void] {.async: (raises: []).} =
        discard gReceivedCount.fetchAdd(1)
        discard gReceivedSum.fetchAdd(evt.value)
    )
    doAssert handle.isOk()
    gListenerHandleId.store(handle.get().id)
    gListenerReady.store(true)
    # Keep event loop alive until signalled to stop
    while not gDone.load():
      await sleepAsync(chronos.milliseconds(1))

  waitFor inner()

# Multiple concurrent emitters
proc concurrentEmitter1() {.thread.} =
  MtEvt.emit(MtEvt(value: 10, label: "c1"))

proc concurrentEmitter2() {.thread.} =
  MtEvt.emit(MtEvt(value: 20, label: "c2"))

proc concurrentEmitter3() {.thread.} =
  MtEvt.emit(MtEvt(value: 30, label: "c3"))

# ── Test suite ────────────────────────────────────────────────────────────

suite "EventBroker macro (multi-thread mode)":
  asyncTest "cross-thread emit to single listener":
    gReceivedCount.store(0)
    gReceivedSum.store(0)

    let handle = MtEvt.listen(
      proc(evt: MtEvt): Future[void] {.async: (raises: []).} =
        discard gReceivedCount.fetchAdd(1)
        discard gReceivedSum.fetchAdd(evt.value)
    )
    check handle.isOk()

    var t: Thread[void]
    t.createThread(emitterThread)
    while gReceivedCount.load() < 1:
      await sleepAsync(chronos.milliseconds(1))
    t.joinThread()

    check gReceivedCount.load() == 1
    check gReceivedSum.load() == 42
    await MtEvt.dropAllListeners()
    await sleepAsync(chronos.milliseconds(50))

  asyncTest "cross-thread emit to multiple listeners on same thread":
    gReceivedCount.store(0)
    gReceivedSum.store(0)

    let h1 = MtEvt.listen(
      proc(evt: MtEvt): Future[void] {.async: (raises: []).} =
        discard gReceivedCount.fetchAdd(1)
        discard gReceivedSum.fetchAdd(evt.value)
    )
    let h2 = MtEvt.listen(
      proc(evt: MtEvt): Future[void] {.async: (raises: []).} =
        discard gReceivedCount.fetchAdd(1)
        discard gReceivedSum.fetchAdd(evt.value)
    )
    check h1.isOk()
    check h2.isOk()

    var t: Thread[void]
    t.createThread(emitterThread)
    while gReceivedCount.load() < 2:
      await sleepAsync(chronos.milliseconds(1))
    t.joinThread()

    check gReceivedCount.load() == 2
    check gReceivedSum.load() == 84 # 42 * 2
    await MtEvt.dropAllListeners()
    await sleepAsync(chronos.milliseconds(50))

  asyncTest "multiple listener threads, single emitter":
    gReceivedCount.store(0)
    gReceivedSum.store(0)
    gDone.store(false)
    gListenerReady.store(false)

    # Also register on main thread
    let mainHandle = MtEvt.listen(
      proc(evt: MtEvt): Future[void] {.async: (raises: []).} =
        discard gReceivedCount.fetchAdd(1)
        discard gReceivedSum.fetchAdd(evt.value)
    )
    check mainHandle.isOk()

    # Spawn a listener on another thread
    var lt: Thread[void]
    lt.createThread(listenerThread)
    while not gListenerReady.load():
      await sleepAsync(chronos.milliseconds(1))

    # Now emit from main thread (tests both same-thread and cross-thread delivery)
    MtEvt.emit(MtEvt(value: 7, label: "fanout"))

    # Wait for both listeners (main + worker) to receive
    while gReceivedCount.load() < 2:
      await sleepAsync(chronos.milliseconds(1))

    check gReceivedCount.load() == 2
    check gReceivedSum.load() == 14 # 7 * 2

    gDone.store(true)
    lt.joinThread()
    await MtEvt.dropAllListeners()
    await sleepAsync(chronos.milliseconds(50))

  asyncTest "same-thread emit (fast path)":
    gReceivedCount.store(0)
    gReceivedSum.store(0)

    let handle = MtEvt.listen(
      proc(evt: MtEvt): Future[void] {.async: (raises: []).} =
        discard gReceivedCount.fetchAdd(1)
        discard gReceivedSum.fetchAdd(evt.value)
    )
    check handle.isOk()

    MtEvt.emit(MtEvt(value: 99, label: "local"))

    # Same-thread: after a brief yield, the listener should have run
    await sleepAsync(chronos.milliseconds(10))
    check gReceivedCount.load() == 1
    check gReceivedSum.load() == 99
    await MtEvt.dropAllListeners()
    await sleepAsync(chronos.milliseconds(50))

  asyncTest "emit with no listeners (no crash)":
    # No listeners registered — emit should be a no-op
    MtEvt.emit(MtEvt(value: 999, label: "nobody"))
    await sleepAsync(chronos.milliseconds(10))
    # Just verifying no crash / no assertion

  asyncTest "dropListener removes one, keeps others":
    gReceivedCount.store(0)
    gReceivedSum.store(0)

    let h1 = MtEvt.listen(
      proc(evt: MtEvt): Future[void] {.async: (raises: []).} =
        discard gReceivedCount.fetchAdd(1)
        discard gReceivedSum.fetchAdd(10)
    )
    let h2 = MtEvt.listen(
      proc(evt: MtEvt): Future[void] {.async: (raises: []).} =
        discard gReceivedCount.fetchAdd(1)
        discard gReceivedSum.fetchAdd(20)
    )
    check h1.isOk()
    check h2.isOk()

    # Drop first listener
    await MtEvt.dropListener(h1.get())

    MtEvt.emit(MtEvt(value: 1, label: "partial"))
    await sleepAsync(chronos.milliseconds(10))

    check gReceivedCount.load() == 1
    check gReceivedSum.load() == 20 # only h2 fired
    await MtEvt.dropAllListeners()
    await sleepAsync(chronos.milliseconds(50))

  asyncTest "dropAllListeners from own thread":
    gReceivedCount.store(0)

    discard MtEvt.listen(
      proc(evt: MtEvt): Future[void] {.async: (raises: []).} =
        discard gReceivedCount.fetchAdd(1)
    )
    discard MtEvt.listen(
      proc(evt: MtEvt): Future[void] {.async: (raises: []).} =
        discard gReceivedCount.fetchAdd(1)
    )

    await MtEvt.dropAllListeners()
    await sleepAsync(chronos.milliseconds(50))

    MtEvt.emit(MtEvt(value: 1, label: "gone"))
    await sleepAsync(chronos.milliseconds(10))
    check gReceivedCount.load() == 0

  asyncTest "dropAllListeners from different thread shuts down remote listeners":
    gReceivedCount.store(0)
    gReceivedSum.store(0)
    gDone.store(false)
    gListenerReady.store(false)

    # Spawn a listener on another thread (this one does NOT call dropAllListeners)
    var lt: Thread[void]
    lt.createThread(listenerThreadNoDrop)
    while not gListenerReady.load():
      await sleepAsync(chronos.milliseconds(1))

    # Emit to confirm listener works
    MtEvt.emit(MtEvt(value: 5, label: "before"))
    await sleepAsync(chronos.milliseconds(50))
    check gReceivedCount.load() >= 1

    # dropAllListeners from MAIN thread — this is the cross-thread shutdown
    await MtEvt.dropAllListeners()
    # Give the listener thread's processLoop time to receive shutdown and drain
    await sleepAsync(chronos.milliseconds(100))

    # Verify no more delivery
    gReceivedCount.store(0)
    MtEvt.emit(MtEvt(value: 999, label: "after"))
    await sleepAsync(chronos.milliseconds(10))
    check gReceivedCount.load() == 0

    # Now signal listener thread to exit its event loop and join
    gDone.store(true)
    lt.joinThread()

  asyncTest "BrokerContext isolation":
    gReceivedCount.store(0)
    gReceivedSum.store(0)
    gCtxA = NewBrokerContext()
    gCtxB = NewBrokerContext()

    discard MtEvt.listen(
      gCtxA,
      proc(evt: MtEvt): Future[void] {.async: (raises: []).} =
        discard gReceivedCount.fetchAdd(1)
        discard gReceivedSum.fetchAdd(evt.value),
    )
    discard MtEvt.listen(
      gCtxB,
      proc(evt: MtEvt): Future[void] {.async: (raises: []).} =
        discard gReceivedCount.fetchAdd(1)
        discard gReceivedSum.fetchAdd(evt.value),
    )

    # Emit only to ctxA
    MtEvt.emit(gCtxA, MtEvt(value: 10, label: "onlyA"))
    await sleepAsync(chronos.milliseconds(10))

    check gReceivedCount.load() == 1
    check gReceivedSum.load() == 10

    # Emit only to ctxB
    MtEvt.emit(gCtxB, MtEvt(value: 20, label: "onlyB"))
    await sleepAsync(chronos.milliseconds(10))

    check gReceivedCount.load() == 2
    check gReceivedSum.load() == 30

    await MtEvt.dropAllListeners(gCtxA)
    await MtEvt.dropAllListeners(gCtxB)
    await sleepAsync(chronos.milliseconds(50))

  asyncTest "BrokerContext isolation cross-thread":
    gReceivedCount.store(0)
    gReceivedSum.store(0)
    gCtxA = NewBrokerContext()
    gCtxB = NewBrokerContext()

    discard MtEvt.listen(
      gCtxA,
      proc(evt: MtEvt): Future[void] {.async: (raises: []).} =
        discard gReceivedCount.fetchAdd(1)
        discard gReceivedSum.fetchAdd(evt.value),
    )
    discard MtEvt.listen(
      gCtxB,
      proc(evt: MtEvt): Future[void] {.async: (raises: []).} =
        discard gReceivedCount.fetchAdd(1)
        discard gReceivedSum.fetchAdd(evt.value),
    )

    # Emit to ctxA from another thread
    var ta: Thread[void]
    ta.createThread(emitterThreadCtxA)
    while gReceivedCount.load() < 1:
      await sleepAsync(chronos.milliseconds(1))
    ta.joinThread()

    check gReceivedCount.load() == 1
    check gReceivedSum.load() == 100

    await MtEvt.dropAllListeners(gCtxA)
    await MtEvt.dropAllListeners(gCtxB)
    await sleepAsync(chronos.milliseconds(50))

  asyncTest "concurrent emitters from multiple threads":
    # Historically this scenario tripped two distinct hazards depending on
    # the build mode: §2.2 (Nim 2.2.4 macOS refc-debug `Channel[T].send`
    # race) and §2.6 (macOS+ORC channel slot-payload UAF after sender
    # exit). Both are closed by the channel-dispatch refactor since broker
    # transport no longer uses `Channel[T]`. See doc/LIMITATION.md.
    gReceivedCount.store(0)
    gReceivedSum.store(0)

    let handle = MtEvt.listen(
      proc(evt: MtEvt): Future[void] {.async: (raises: []).} =
        discard gReceivedCount.fetchAdd(1)
        discard gReceivedSum.fetchAdd(evt.value)
    )
    check handle.isOk()

    var t1, t2, t3: Thread[void]
    t1.createThread(concurrentEmitter1)
    t2.createThread(concurrentEmitter2)
    t3.createThread(concurrentEmitter3)

    while gReceivedCount.load() < 3:
      await sleepAsync(chronos.milliseconds(1))

    t1.joinThread()
    t2.joinThread()
    t3.joinThread()

    check gReceivedCount.load() == 3
    check gReceivedSum.load() == 60 # 10 + 20 + 30
    await MtEvt.dropAllListeners()
    await sleepAsync(chronos.milliseconds(50))

  asyncTest "field-constructor emit syntax":
    gReceivedCount.store(0)
    gReceivedSum.store(0)

    let handle = MtEvt.listen(
      proc(evt: MtEvt): Future[void] {.async: (raises: []).} =
        discard gReceivedCount.fetchAdd(1)
        discard gReceivedSum.fetchAdd(evt.value)
    )
    check handle.isOk()

    MtEvt.emit(value = 77, label = "ctor")
    await sleepAsync(chronos.milliseconds(10))

    check gReceivedCount.load() == 1
    check gReceivedSum.load() == 77
    await MtEvt.dropAllListeners()
    await sleepAsync(chronos.milliseconds(50))

  asyncTest "multiple sequential emissions":
    gReceivedCount.store(0)
    gReceivedSum.store(0)

    let handle = MtEvt.listen(
      proc(evt: MtEvt): Future[void] {.async: (raises: []).} =
        discard gReceivedCount.fetchAdd(1)
        discard gReceivedSum.fetchAdd(evt.value)
    )
    check handle.isOk()

    var t: Thread[void]
    t.createThread(emitterThreadMulti)
    while gReceivedCount.load() < 3:
      await sleepAsync(chronos.milliseconds(1))
    t.joinThread()

    check gReceivedCount.load() == 3
    check gReceivedSum.load() == 6 # 1 + 2 + 3
    await MtEvt.dropAllListeners()
    await sleepAsync(chronos.milliseconds(50))

## ---------------------------------------------------------------------------
## Multi-thread EventBroker — void (payload-less) event
##
## `type X = void` is lowered to a unique empty object, which travels through
## the MT slab/channel path as a zero-byte payload. The listener still takes
## the (empty) event value — argless-listener parity with single-thread mode
## is a deliberate non-goal for the internal MT layer.
## ---------------------------------------------------------------------------

EventBroker(mt):
  type MtVoidSignal = void

var gVoidHits: Atomic[int]

suite "EventBroker macro (multi-thread mode, void / payload-less)":
  asyncTest "same-thread payload-less emit reaches listeners":
    gVoidHits.store(0)

    let handle = MtVoidSignal.listen(
      proc(evt: MtVoidSignal): Future[void] {.async: (raises: []).} =
        discard gVoidHits.fetchAdd(1)
    )
    check handle.isOk()

    MtVoidSignal.emit(MtVoidSignal())
    MtVoidSignal.emit(MtVoidSignal())
    await sleepAsync(chronos.milliseconds(20))

    check gVoidHits.load() == 2

    await MtVoidSignal.dropAllListeners()
    await sleepAsync(chronos.milliseconds(50))

  asyncTest "dropAllListeners stops payload-less delivery":
    gVoidHits.store(0)

    let handle = MtVoidSignal.listen(
      proc(evt: MtVoidSignal): Future[void] {.async: (raises: []).} =
        discard gVoidHits.fetchAdd(1)
    )
    check handle.isOk()

    MtVoidSignal.emit(MtVoidSignal())
    await sleepAsync(chronos.milliseconds(20))
    check gVoidHits.load() == 1

    await MtVoidSignal.dropAllListeners()
    await sleepAsync(chronos.milliseconds(20))
    MtVoidSignal.emit(MtVoidSignal())
    await sleepAsync(chronos.milliseconds(20))
    check gVoidHits.load() == 1

## ---------------------------------------------------------------------------
## bind listener sugar (issue #42) — same-thread (owning) exercise
## ---------------------------------------------------------------------------

EventBroker(mt):
  type MtBindEvent = object
    n*: int

type MtEvtBindService = ref object
  seen: int

proc onMtBindEvent(self: MtEvtBindService, e: MtBindEvent) {.async: (raises: []).} =
  self.seen = e.n

suite "EventBroker(mt) bindListener sugar (issue #42)":
  asyncTest "bindListener installs a class-method listener (same thread)":
    let self = MtEvtBindService()
    let h = MtBindEvent.bindListener(self.onMtBindEvent)
    check h.isOk()

    MtBindEvent.emit(MtBindEvent(n: 21))
    await sleepAsync(chronos.milliseconds(20))
    check self.seen == 21

    await MtBindEvent.dropAllListeners()
