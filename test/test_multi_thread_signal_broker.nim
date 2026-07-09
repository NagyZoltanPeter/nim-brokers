{.used.}

import testutils/unittests
import chronos
import std/[atomics, os]

import brokers/signal_broker

## ---------------------------------------------------------------------------
## Multi-thread SignalBroker tests
## ---------------------------------------------------------------------------

SignalBroker(mt):
  type MtSignal = object
    value*: int
    label*: string

SignalBroker(mt):
  type MtPulse = void

# Tiny capacity so a cross-thread burst deterministically overflows while the
# handler thread is blocked (its dispatcher can't drain).
SignalBroker(mt, queueDepth = 2, slabCapacity = 2):
  type MtTiny = object
    n*: int

# ── Cross-thread synchronization ──────────────────────────────────────────

var gDone: Atomic[bool]
var gReceivedCount: Atomic[int]
var gReceivedSum: Atomic[int]
var gHandlerReady: Atomic[bool]
var gCtx: BrokerContext

var gTinyReceived: Atomic[int]
var gTinyReady: Atomic[bool]
var gTinyCtx: BrokerContext

# Installs a handler then BLOCKS in os.sleep so its chronos dispatcher never
# runs — cells enqueued by other threads accumulate until the slab overflows.
proc tinyBlockedThread() {.thread.} =
  discard MtTiny.onSignal(
    gTinyCtx,
    proc(s: MtTiny): Future[void] {.async: (raises: []).} =
      discard gTinyReceived.fetchAdd(1),
  )
  gTinyReady.store(true)
  os.sleep(250) # block: dispatcher parked, no draining
  proc inner() {.async.} =
    while not gDone.load():
      await sleepAsync(chronos.milliseconds(1))
    await MtTiny.dropSignalHandler(gTinyCtx)

  waitFor inner()

# A thread that installs the handler, signals ready, keeps its loop alive,
# then drops the handler on shutdown.
proc handlerThread() {.thread.} =
  proc inner() {.async.} =
    let r = MtSignal.onSignal(
      gCtx,
      proc(s: MtSignal): Future[void] {.async: (raises: []).} =
        discard gReceivedCount.fetchAdd(1)
        discard gReceivedSum.fetchAdd(s.value),
    )
    doAssert r.isOk()
    gHandlerReady.store(true)
    while not gDone.load():
      await sleepAsync(chronos.milliseconds(1))
    await MtSignal.dropSignalHandler(gCtx)

  waitFor inner()

proc drain() =
  waitFor sleepAsync(chronos.milliseconds(30))

suite "SignalBroker(mt) — same thread":
  teardown:
    waitFor MtSignal.dropSignalHandler()
    waitFor MtPulse.dropSignalHandler()

  test "same-thread onSignal + signal dispatches directly":
    var seen = 0
    var sum = 0
    check MtSignal
      .onSignal(
        proc(s: MtSignal): Future[void] {.async: (raises: []).} =
          inc seen
          sum += s.value
      )
      .isOk()
    check MtSignal.hasSignalHandler()
    check MtSignal.signal(MtSignal(value: 7, label: "a")).isOk()
    check MtSignal.signal(value = 5, label = "b").isOk()
    drain()
    check seen == 2
    check sum == 12

  test "duplicate onSignal errors":
    check MtSignal
      .onSignal(
        proc(s: MtSignal): Future[void] {.async: (raises: []).} =
          discard
      )
      .isOk()
    let dup = MtSignal.onSignal(
      proc(s: MtSignal): Future[void] {.async: (raises: []).} =
        discard
    )
    check dup.isErr()

  test "signal with no handler errors":
    let r = MtSignal.signal(MtSignal(value: 1, label: "x"))
    check r.isErr()
    check r.error == "no signal handler installed"

  test "drop then signal errors":
    discard MtSignal.onSignal(
      proc(s: MtSignal): Future[void] {.async: (raises: []).} =
        discard
    )
    waitFor MtSignal.dropSignalHandler()
    check not MtSignal.hasSignalHandler()
    check MtSignal.signal(MtSignal(value: 1, label: "x")).isErr()

  test "void pulse (same thread)":
    var pulses = 0
    check MtPulse
      .onSignal(
        proc(): Future[void] {.async: (raises: []).} =
          inc pulses
      )
      .isOk()
    check MtPulse.signal().isOk()
    drain()
    check pulses == 1

suite "SignalBroker(mt) — cross thread":
  test "cross-thread signal delivered to handler thread":
    gDone.store(false)
    gReceivedCount.store(0)
    gReceivedSum.store(0)
    gHandlerReady.store(false)
    gCtx = NewBrokerContext()

    var th: Thread[void]
    createThread(th, handlerThread)
    while not gHandlerReady.load():
      waitFor sleepAsync(chronos.milliseconds(1))

    # Signal cross-thread from the main thread.
    for i in 1 .. 3:
      check MtSignal.signal(gCtx, MtSignal(value: i, label: "x")).isOk()

    # Give the handler thread time to drain its ring.
    waitFor sleepAsync(chronos.milliseconds(100))
    gDone.store(true)
    joinThread(th)

    check gReceivedCount.load() == 3
    check gReceivedSum.load() == 6

  test "cross-thread burst past capacity returns queue full, not a silent drop":
    gDone.store(false)
    gTinyReceived.store(0)
    gTinyReady.store(false)
    gTinyCtx = NewBrokerContext()

    var th: Thread[void]
    createThread(th, tinyBlockedThread)
    while not gTinyReady.load():
      os.sleep(1)

    # Handler thread is blocked in os.sleep → nothing drains. slabCapacity=2,
    # so the first couple are accepted and the rest report backpressure.
    var oks = 0
    var fulls = 0
    for i in 1 .. 12:
      let r = MtTiny.signal(gTinyCtx, MtTiny(n: i))
      if r.isOk():
        inc oks
      elif r.error == "queue full":
        inc fulls
    check oks >= 1
    check fulls >= 1 # overflow surfaced, not silently dropped

    # Let the handler thread wake, drain, and drop.
    waitFor sleepAsync(chronos.milliseconds(300))
    gDone.store(true)
    joinThread(th)

## ---------------------------------------------------------------------------
## bind / rebind signal-handler sugar (issue #42) — same-thread (owning)
## ---------------------------------------------------------------------------

SignalBroker(mt):
  type MtBindSig = object
    v*: int

type MtSigBindService = ref object
  seen: int

proc onMtBindSig(self: MtSigBindService, s: MtBindSig) {.async: (raises: []).} =
  self.seen = s.v

proc onMtBindSigMock(self: MtSigBindService, s: MtBindSig) {.async: (raises: []).} =
  self.seen = -s.v

suite "SignalBroker(mt) bind/rebind sugar (issue #42)":
  teardown:
    waitFor MtBindSig.dropSignalHandler()

  test "bindSignalHandler + rebindSignalHandler on the owning thread":
    let self = MtSigBindService()
    check MtBindSig.bindSignalHandler(self.onMtBindSig).isOk()
    check MtBindSig.signal(MtBindSig(v: 8)).isOk()
    drain()
    check self.seen == 8

    check MtBindSig.rebindSignalHandler(DefaultBrokerContext, self.onMtBindSigMock).isOk()
    check MtBindSig.signal(MtBindSig(v: 3)).isOk()
    drain()
    check self.seen == -3
