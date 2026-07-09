{.used.}

import testutils/unittests
import chronos
import std/options

import brokers/signal_broker

## ---------------------------------------------------------------------------
## Single-thread SignalBroker tests
## ---------------------------------------------------------------------------

SignalBroker:
  type IngestSample = object
    deviceId*: string
    value*: float64

SignalBroker:
  type Pulse = void

proc drain() =
  ## Signals are fire-and-forget (sync call site + asyncSpawn); drain the event
  ## loop so spawned handler tasks run to completion before asserting.
  waitFor sleepAsync(chronos.milliseconds(20))

static:
  doAssert typeof(IngestSample.signal(IngestSample())) is Result[void, string]
  doAssert typeof(IngestSample.dropSignalHandler()) is Future[void]

suite "SignalBroker (single-thread)":
  teardown:
    waitFor IngestSample.dropSignalHandler()
    waitFor Pulse.dropSignalHandler()

  test "onSignal installs a handler, signal accepts and dispatches":
    var lastDeviceId = ""
    var lastValue = 0.0
    var ingestCount = 0
    check IngestSample
      .onSignal(
        proc(s: IngestSample) {.async: (raises: []).} =
          lastDeviceId = s.deviceId
          lastValue = s.value
          inc ingestCount
      )
      .isOk()

    check IngestSample.hasSignalHandler()
    let r = IngestSample.signal(IngestSample(deviceId: "d1", value: 0.5))
    check r.isOk()
    drain()
    check lastDeviceId == "d1"
    check lastValue == 0.5
    check ingestCount == 1

  test "inline-field signal overload builds the payload":
    var lastDeviceId = ""
    var lastValue = 0.0
    discard IngestSample.onSignal(
      proc(s: IngestSample) {.async: (raises: []).} =
        lastDeviceId = s.deviceId
        lastValue = s.value
    )
    let r = IngestSample.signal(deviceId = "d2", value = 1.25)
    check r.isOk()
    drain()
    check lastDeviceId == "d2"
    check lastValue == 1.25

  test "onSignal errors when a handler is already installed":
    check IngestSample
      .onSignal(
        proc(s: IngestSample) {.async: (raises: []).} =
          discard
      )
      .isOk()
    let dup = IngestSample.onSignal(
      proc(s: IngestSample) {.async: (raises: []).} =
        discard
    )
    check dup.isErr()

  test "signal errors when no handler is installed":
    let r = IngestSample.signal(IngestSample(deviceId: "x", value: 0.0))
    check r.isErr()
    check r.error == "no signal handler installed"

  test "dropSignalHandler removes the handler; subsequent signal errs":
    var ingestCount = 0
    discard IngestSample.onSignal(
      proc(s: IngestSample) {.async: (raises: []).} =
        inc ingestCount
    )
    check IngestSample.hasSignalHandler()
    waitFor IngestSample.dropSignalHandler()
    check not IngestSample.hasSignalHandler()
    check IngestSample.signal(IngestSample(deviceId: "d", value: 1.0)).isErr()

  test "context scoping keeps handlers independent":
    let ctxA = NewBrokerContext()
    let ctxB = NewBrokerContext()
    var seenA = 0
    var seenB = 0
    let handlerA = proc(s: IngestSample) {.async: (raises: []).} =
      inc seenA
    let handlerB = proc(s: IngestSample) {.async: (raises: []).} =
      inc seenB
    check IngestSample.onSignal(ctxA, handlerA).isOk()
    check IngestSample.onSignal(ctxB, handlerB).isOk()

    # default context has no handler
    check IngestSample.signal(IngestSample(deviceId: "d", value: 0.0)).isErr()

    check IngestSample.signal(ctxA, IngestSample(deviceId: "a", value: 0.0)).isOk()
    drain()
    check seenA == 1
    check seenB == 0

    waitFor IngestSample.dropSignalHandler(ctxA)
    waitFor IngestSample.dropSignalHandler(ctxB)

  test "zero-arg (void) pulse signal":
    var pulseCount = 0
    check Pulse
      .onSignal(
        proc() {.async: (raises: []).} =
          inc pulseCount
      )
      .isOk()
    check Pulse.signal().isOk()
    drain()
    check pulseCount == 1
    check Pulse.signal(DefaultBrokerContext).isOk()
    drain()
    check pulseCount == 2

  test "replaceSignalHandler replaces without the already-set guard":
    var lastDeviceId = ""
    discard IngestSample.onSignal(
      proc(s: IngestSample) {.async: (raises: []).} =
        lastDeviceId = "first"
    )
    check IngestSample
      .replaceSignalHandler(
        DefaultBrokerContext,
        proc(s: IngestSample) {.async: (raises: []).} =
          lastDeviceId = "second",
      )
      .isOk()
    discard IngestSample.signal(IngestSample(deviceId: "d", value: 0.0))
    drain()
    check lastDeviceId == "second"

  test "replaceSignalHandler with default(...) clears the slot":
    discard IngestSample.onSignal(
      proc(s: IngestSample) {.async: (raises: []).} =
        discard
    )
    check IngestSample
      .replaceSignalHandler(DefaultBrokerContext, default(IngestSampleSignalHandler))
      .isOk()
    check not IngestSample.hasSignalHandler()

  test "withMockSignalHandler restores the prior handler even on exception":
    var lastDeviceId = ""
    let realHandler = proc(s: IngestSample) {.async: (raises: []).} =
      lastDeviceId = "real"
    discard IngestSample.onSignal(realHandler)
    let saved = IngestSample.getCurrentSignalHandler(DefaultBrokerContext)
    check saved.isSome()

    expect ValueError:
      IngestSample.withMockSignalHandler(
        DefaultBrokerContext,
        proc(s: IngestSample) {.async: (raises: []).} =
          lastDeviceId = "mock",
      ):
        raise newException(ValueError, "scope error")

    # prior handler restored after the scope unwound
    check IngestSample.hasSignalHandler()
    discard IngestSample.signal(IngestSample(deviceId: "d", value: 0.0))
    drain()
    check lastDeviceId == "real"

  test "withMockSignalHandler drops when no prior handler existed":
    check not IngestSample.hasSignalHandler()
    IngestSample.withMockSignalHandler(
      DefaultBrokerContext,
      proc(s: IngestSample) {.async: (raises: []).} =
        discard,
    ):
      check IngestSample.hasSignalHandler()
    check not IngestSample.hasSignalHandler()

## ---------------------------------------------------------------------------
## bind / rebind signal-handler sugar (issue #42)
## ---------------------------------------------------------------------------

SignalBroker:
  type BindSig = object
    v*: int

type SigBindService = ref object
  seen: int

proc onBindSig(self: SigBindService, s: BindSig) {.async: (raises: []).} =
  self.seen = s.v

proc onBindSigMock(self: SigBindService, s: BindSig) {.async: (raises: []).} =
  self.seen = -s.v

suite "SignalBroker bind/rebind sugar (issue #42)":
  teardown:
    waitFor BindSig.dropSignalHandler()

  test "bindSignalHandler installs a class-method handler":
    let self = SigBindService()
    check BindSig.bindSignalHandler(self.onBindSig).isOk()
    check BindSig.signal(BindSig(v: 5)).isOk()
    drain()
    check self.seen == 5

  test "rebindSignalHandler swaps to a mock":
    let self = SigBindService()
    check BindSig.bindSignalHandler(self.onBindSig).isOk()
    check BindSig.rebindSignalHandler(DefaultBrokerContext, self.onBindSigMock).isOk()
    check BindSig.signal(BindSig(v: 7)).isOk()
    drain()
    check self.seen == -7
