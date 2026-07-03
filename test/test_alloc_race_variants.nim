{.used.}

## EXPERIMENT (round 4, throwaway): single-ingredient variants of the
## crashing test "two contexts on different threads with cross-thread
## requests" from test_multi_thread_request_broker.nim. Each variant is
## run SOLO (own process, unittest2 positional glob) by the testAllocRace
## nimble task to localize which ingredient arms the win+refc UAF:
##
##   V1  worker-hosted provider + one requester thread (worker -> worker)
##   V2  main-hosted provider + three concurrent requester threads
##   V3  worker-hosted provider + main-thread requester (no requester threads)
##   V4  no provider + one error-path requester thread
##   V5  worker-hosted provider + worker requester + default-fail requester
##   V6  full original shape (baseline)

import testutils/unittests
import chronos
import std/atomics

import brokers/request_broker

RequestBroker(mt):
  type ARReq = object
    textValue*: string
    numValue*: int
    boolValue*: bool

  proc signature*(input: string): Future[Result[ARReq, string]] {.async.}

# ── Global synchronization ────────────────────────────────────────────────

var gDone: Atomic[bool]
var gProvReady: Atomic[bool]
var gThreadRes1: Atomic[bool]
var gThreadRes2: Atomic[bool]
var gThreadRes3: Atomic[bool]

var gCtxA: BrokerContext
var gCtxB: BrokerContext

# ── Thread procs at module level (no closures) ───────────────────────────

# Worker thread that OWNS a provider for gCtxB, serves requests until the
# main thread signals gDone, then clears the provider and exits (refc heap
# teardown happens here).
proc providerThreadB() {.thread.} =
  proc inner() {.async.} =
    let res = ARReq.setProvider(
      gCtxB,
      proc(input: string): Future[Result[ARReq, string]] {.async.} =
        ok(ARReq(textValue: "ctxB:" & input, numValue: 200, boolValue: false)),
    )
    doAssert res.isOk()
    gProvReady.store(true)
    while not gDone.load():
      await sleepAsync(10.milliseconds)
    ARReq.clearProvider(gCtxB)

  waitFor inner()

proc requesterCtxA1() {.thread.} =
  let res = waitFor ARReq.request(gCtxA, "hello-A1")
  doAssert res.isOk()
  doAssert res.value.textValue == "ctxA:hello-A1"
  gThreadRes1.store(true)

proc requesterCtxA2() {.thread.} =
  let res = waitFor ARReq.request(gCtxA, "hello-A2")
  doAssert res.isOk()
  doAssert res.value.textValue == "ctxA:hello-A2"
  gThreadRes2.store(true)

proc requesterCtxA3() {.thread.} =
  let res = waitFor ARReq.request(gCtxA, "hello-A3")
  doAssert res.isOk()
  doAssert res.value.textValue == "ctxA:hello-A3"
  gThreadRes3.store(true)

proc requesterCtxB() {.thread.} =
  let res = waitFor ARReq.request(gCtxB, "hello-B")
  doAssert res.isOk()
  doAssert res.value.textValue == "ctxB:hello-B"
  doAssert res.value.numValue == 200
  gThreadRes2.store(true)

proc requesterDefaultCtxFail() {.thread.} =
  let res = waitFor ARReq.request("test")
  doAssert res.isErr()
  gThreadRes3.store(true)

# ── Variants ──────────────────────────────────────────────────────────────

suite "alloc-race variants":
  asyncTest "V1 worker provider, one worker requester":
    gCtxB = NewBrokerContext()
    gDone.store(false)
    gProvReady.store(false)
    gThreadRes2.store(false)

    var provThread: Thread[void]
    provThread.createThread(providerThreadB)
    while not gProvReady.load():
      await sleepAsync(10.milliseconds)

    var tB: Thread[void]
    tB.createThread(requesterCtxB)
    while not gThreadRes2.load():
      await sleepAsync(10.milliseconds)

    tB.joinThread()
    gDone.store(true)
    provThread.joinThread()

  asyncTest "V2 main provider, three concurrent requesters":
    gCtxA = NewBrokerContext()
    check ARReq
      .setProvider(
        gCtxA,
        proc(input: string): Future[Result[ARReq, string]] {.async.} =
          ok(ARReq(textValue: "ctxA:" & input, numValue: 100, boolValue: true)),
      )
      .isOk()

    gThreadRes1.store(false)
    gThreadRes2.store(false)
    gThreadRes3.store(false)
    var t1, t2, t3: Thread[void]
    t1.createThread(requesterCtxA1)
    t2.createThread(requesterCtxA2)
    t3.createThread(requesterCtxA3)

    while not (gThreadRes1.load() and gThreadRes2.load() and gThreadRes3.load()):
      await sleepAsync(10.milliseconds)

    t1.joinThread()
    t2.joinThread()
    t3.joinThread()
    ARReq.clearProvider(gCtxA)

  asyncTest "V3 worker provider, main-thread requester":
    gCtxB = NewBrokerContext()
    gDone.store(false)
    gProvReady.store(false)

    var provThread: Thread[void]
    provThread.createThread(providerThreadB)
    while not gProvReady.load():
      await sleepAsync(10.milliseconds)

    let res = await ARReq.request(gCtxB, "hello-B")
    check res.isOk()
    check res.value.textValue == "ctxB:hello-B"

    gDone.store(true)
    provThread.joinThread()

  asyncTest "V4 no provider, one error-path requester":
    gThreadRes3.store(false)
    var tD: Thread[void]
    tD.createThread(requesterDefaultCtxFail)
    while not gThreadRes3.load():
      await sleepAsync(10.milliseconds)
    tD.joinThread()

  asyncTest "V5 worker provider, worker requester + default-fail requester":
    gCtxB = NewBrokerContext()
    gDone.store(false)
    gProvReady.store(false)
    gThreadRes2.store(false)
    gThreadRes3.store(false)

    var provThread: Thread[void]
    provThread.createThread(providerThreadB)
    while not gProvReady.load():
      await sleepAsync(10.milliseconds)

    var tB, tD: Thread[void]
    tB.createThread(requesterCtxB)
    tD.createThread(requesterDefaultCtxFail)

    while not (gThreadRes2.load() and gThreadRes3.load()):
      await sleepAsync(10.milliseconds)

    tB.joinThread()
    tD.joinThread()
    gDone.store(true)
    provThread.joinThread()

  asyncTest "V6 full original shape":
    gCtxA = NewBrokerContext()
    gCtxB = NewBrokerContext()

    check ARReq
      .setProvider(
        gCtxA,
        proc(input: string): Future[Result[ARReq, string]] {.async.} =
          ok(ARReq(textValue: "ctxA:" & input, numValue: 100, boolValue: true)),
      )
      .isOk()

    gDone.store(false)
    gProvReady.store(false)
    var provThread: Thread[void]
    provThread.createThread(providerThreadB)
    while not gProvReady.load():
      await sleepAsync(10.milliseconds)

    gThreadRes1.store(false)
    gThreadRes2.store(false)
    gThreadRes3.store(false)
    var tA, tB, tDefault: Thread[void]
    tA.createThread(requesterCtxA1)
    tB.createThread(requesterCtxB)
    tDefault.createThread(requesterDefaultCtxFail)

    while not (gThreadRes1.load() and gThreadRes2.load() and gThreadRes3.load()):
      await sleepAsync(10.milliseconds)

    tA.joinThread()
    tB.joinThread()
    tDefault.joinThread()

    gDone.store(true)
    provThread.joinThread()

    ARReq.clearProvider(gCtxA)
