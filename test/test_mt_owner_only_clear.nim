{.used.}

## Owner-only clear / drop for RequestBroker(mt) and SignalBroker(mt)
## (doc/design/MT_OWNER_ONLY_CLEAR_PLAN.md).
##
## Only the thread that installed a provider / signal handler may clear, drop
## or replace it. A foreign `clearProvider` / `dropSignalHandler` is a logged
## no-op; a foreign `replaceProvider` / `replaceSignalHandler` returns `err`; a
## foreign `withMock*` trips a doAssert. A thread that exits without clearing
## has its providers / handlers cleared by `teardownBrokerThread`, so the ctx
## can be taken over and outstanding requests fail fast.

import std/[atomics, os, strutils]
import testutils/unittests
import chronos
import results

import brokers/[request_broker, signal_broker, broker_context]

RequestBroker(mt):
  proc ownedEcho(s: string): Future[Result[string, string]] {.async.}

SignalBroker(mt):
  type OwnedSig = object
    value*: int

var gCtx: BrokerContext
var gOwnerReady: Atomic[bool]
var gForeignDone: Atomic[bool]
var gStop: Atomic[bool]
var gOwnerSawProvider: Atomic[bool]
var gProviderCalls: Atomic[int]
var gSignalHits: Atomic[int]
var gSent: Atomic[bool]

proc resetFlags() =
  gOwnerReady.store(false)
  gForeignDone.store(false)
  gStop.store(false)
  gOwnerSawProvider.store(false)
  gProviderCalls.store(0)
  gSignalHits.store(0)
  gSent.store(false)

proc echoReal(s: string): Future[Result[string, string]] {.async.} =
  discard gProviderCalls.fetchAdd(1)
  ok("real:" & s)

proc echoMock(s: string): Future[Result[string, string]] {.async.} =
  ok("mock:" & s)

proc echoSlow(s: string): Future[Result[string, string]] {.async.} =
  discard gProviderCalls.fetchAdd(1)
  await sleepAsync(chronos.seconds(3))
  ok("slow:" & s)

proc sigReal(s: OwnedSig) {.async: (raises: []).} =
  discard gSignalHits.fetchAdd(s.value)

proc sigMock(s: OwnedSig) {.async: (raises: []).} =
  discard

proc spinUntil(flag: var Atomic[bool]) =
  while not flag.load():
    waitFor sleepAsync(chronos.milliseconds(2))

# ── owner threads ──────────────────────────────────────────────────────────

proc requestOwnerThread() {.thread.} =
  ## Owns the provider, serves until told to stop, checks its own view after
  ## the foreign clear attempt, then clears as the owner.
  doAssert OwnedEcho.setProvider(gCtx, echoReal).isOk()
  gOwnerReady.store(true)
  spinUntil(gForeignDone)
  gOwnerSawProvider.store(OwnedEcho.getCurrentProvider(gCtx).isSome)
  spinUntil(gStop)
  OwnedEcho.clearProvider(gCtx)
  waitFor sleepAsync(chronos.milliseconds(50))

proc signalOwnerThread() {.thread.} =
  doAssert OwnedSig.onSignal(gCtx, sigReal).isOk()
  gOwnerReady.store(true)
  spinUntil(gForeignDone)
  gOwnerSawProvider.store(OwnedSig.getCurrentSignalHandler(gCtx).isSome)
  spinUntil(gStop)
  waitFor OwnedSig.dropSignalHandler(gCtx)
  waitFor sleepAsync(chronos.milliseconds(50))

proc requestOwnerExitsThread() {.thread.} =
  ## Installs a slow provider and leaves without clearing it while a
  ## cross-thread request is still being served.
  doAssert OwnedEcho.setProvider(gCtx, echoSlow).isOk()
  gOwnerReady.store(true)
  spinUntil(gSent)
  waitFor sleepAsync(chronos.milliseconds(100))

proc signalOwnerExitsThread() {.thread.} =
  doAssert OwnedSig.onSignal(gCtx, sigReal).isOk()
  gOwnerReady.store(true)
  waitFor sleepAsync(chronos.milliseconds(20))

proc burstRequesterThread() {.thread.} =
  ## Enqueue four requests (the enqueue is the synchronous prologue of
  ## `request`), report it, then wait for all of them.
  var futs: seq[Future[Result[string, string]]]
  for i in 0 ..< 4:
    futs.add OwnedEcho.request(gCtx, $i)
  gSent.store(true)
  for f in futs:
    let r = waitFor f
    doAssert r.isErr(), "a request queued before the owner cleared must fail"

# ── tests ──────────────────────────────────────────────────────────────────

suite "RequestBroker(mt): owner-only clear / replace":
  setup:
    resetFlags()
    gCtx = NewBrokerContext()

  test "foreign clearProvider is a no-op":
    var th: Thread[void]
    createThread(th, requestOwnerThread)
    spinUntil(gOwnerReady)

    OwnedEcho.clearProvider(gCtx) # main is not the owner
    check OwnedEcho.isProvided(gCtx)
    let r = waitFor OwnedEcho.request(gCtx, "x")
    check r.isOk and r.value == "real:x"

    gForeignDone.store(true)
    gStop.store(true)
    joinThread(th)
    check gOwnerSawProvider.load()
    check not OwnedEcho.isProvided(gCtx)

  test "foreign replaceProvider returns err and changes nothing":
    var th: Thread[void]
    createThread(th, requestOwnerThread)
    spinUntil(gOwnerReady)

    check OwnedEcho.replaceProvider(gCtx, echoMock).isErr()
    check OwnedEcho.getCurrentProvider(gCtx).isNone # main holds no entry
    let r = waitFor OwnedEcho.request(gCtx, "x")
    check r.isOk and r.value == "real:x"

    gForeignDone.store(true)
    gStop.store(true)
    joinThread(th)

  test "foreign withMockProvider fails loudly and leaves the owner alone":
    var th: Thread[void]
    createThread(th, requestOwnerThread)
    spinUntil(gOwnerReady)

    var bodyRan = false
    expect AssertionDefect:
      OwnedEcho.withMockProvider(gCtx, echoMock):
        bodyRan = true
    check not bodyRan
    check OwnedEcho.isProvided(gCtx)
    check (waitFor OwnedEcho.request(gCtx, "x")).value == "real:x"

    gForeignDone.store(true)
    gStop.store(true)
    joinThread(th)

  test "owner clear: requests still queued are never executed":
    check OwnedEcho.setProvider(gCtx, echoReal).isOk()
    var th: Thread[void]
    createThread(th, burstRequesterThread)
    # Keep this (owner) thread's event loop idle so the requests stay queued.
    while not gSent.load():
      sleep(2)
    sleep(20)
    OwnedEcho.clearProvider(gCtx)
    waitFor sleepAsync(chronos.milliseconds(50)) # let the poll fn drain
    joinThread(th)
    check gProviderCalls.load() == 0

  test "owner thread exits without clearing: ctx is released, requests fail fast":
    OwnedEcho.setRequestTimeout(chronos.seconds(10))
    var th: Thread[void]
    createThread(th, requestOwnerExitsThread)
    spinUntil(gOwnerReady)

    let started = Moment.now()
    let fut = OwnedEcho.request(gCtx, "x")
    gSent.store(true)
    let r = waitFor fut
    let elapsed = Moment.now() - started
    joinThread(th)

    check r.isErr()
    check "cleared" in r.error
    check elapsed < chronos.seconds(2) # well before the 3 s provider / 10 s timeout
    check not OwnedEcho.isProvided(gCtx)
    # The ctx can be taken over by another thread now.
    check OwnedEcho.setProvider(gCtx, echoReal).isOk()
    check (waitFor OwnedEcho.request(gCtx, "y")).value == "real:y"
    OwnedEcho.clearProvider(gCtx)
    OwnedEcho.setRequestTimeout(chronos.seconds(20))

suite "SignalBroker(mt): owner-only drop / replace":
  setup:
    resetFlags()
    gCtx = NewBrokerContext()

  test "foreign dropSignalHandler is a no-op":
    var th: Thread[void]
    createThread(th, signalOwnerThread)
    spinUntil(gOwnerReady)

    waitFor OwnedSig.dropSignalHandler(gCtx) # main is not the owner
    check OwnedSig.signalHandlerPresent()
    check OwnedSig.signal(gCtx, OwnedSig(value: 7)).isOk()
    let deadline = Moment.now() + chronos.seconds(2)
    while gSignalHits.load() != 7 and Moment.now() < deadline:
      waitFor sleepAsync(chronos.milliseconds(2))
    check gSignalHits.load() == 7

    gForeignDone.store(true)
    gStop.store(true)
    joinThread(th)
    check gOwnerSawProvider.load()
    check OwnedSig.signal(gCtx, OwnedSig(value: 1)).isErr()

  test "foreign replaceSignalHandler returns err; withMockSignalHandler fails loudly":
    var th: Thread[void]
    createThread(th, signalOwnerThread)
    spinUntil(gOwnerReady)

    check OwnedSig.replaceSignalHandler(gCtx, sigMock).isErr()
    var bodyRan = false
    expect AssertionDefect:
      OwnedSig.withMockSignalHandler(gCtx, sigMock):
        bodyRan = true
    check not bodyRan
    check OwnedSig.signal(gCtx, OwnedSig(value: 3)).isOk()

    gForeignDone.store(true)
    gStop.store(true)
    joinThread(th)

  test "owner thread exits without dropping: ctx is released":
    var th: Thread[void]
    createThread(th, signalOwnerExitsThread)
    spinUntil(gOwnerReady)
    joinThread(th)

    check OwnedSig.signal(gCtx, OwnedSig(value: 1)).isErr()
    check OwnedSig.onSignal(gCtx, sigReal).isOk()
    waitFor OwnedSig.dropSignalHandler(gCtx)
