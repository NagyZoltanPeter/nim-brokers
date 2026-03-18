{.used.}

import testutils/unittests
import chronos
import std/[strutils, atomics]

import request_broker

## ---------------------------------------------------------------------------
## Multi-thread Async-mode Requestbroker tests
## ---------------------------------------------------------------------------

RequestBroker(mt):
  type MTReq = object
    textValue*: string
    numValue*: int
    boolValue*: bool

  proc signature*(input: string): Future[Result[MTReq, string]] {.async.}

static:
  doAssert typeof(MTReq.request()) is Future[Result[MTReq, string]]

# ── Global synchronization ────────────────────────────────────────────────

var gDone: Atomic[bool]
var gThreadRes1: Atomic[bool]
var gThreadRes2: Atomic[bool]
var gThreadRes3: Atomic[bool]

# Shared result flag for setProvider-from-thread test.
var gSetProviderOk: Atomic[bool]

# Shared BrokerContext values for cross-thread BrokerContext tests.
# Written by main thread before spawning workers; read-only by workers.
var gCtxA: BrokerContext
var gCtxB: BrokerContext

# ── Thread procs at module level (no closures) ───────────────────────────

proc requester() {.thread.} =
  let res = waitFor MTReq.request("hi")
  doAssert res.isOk()
  doAssert res.value.textValue == "hi"
  doAssert res.value.numValue == 42
  doAssert res.value.boolValue == true
  gDone.store(true)

proc multiRequester() {.thread.} =
  for word in ["alpha", "beta", "gamma"]:
    let res = waitFor MTReq.request(word)
    doAssert res.isOk()
    doAssert res.value.textValue == word & "!"
    doAssert res.value.numValue == word.len
  gDone.store(true)

proc requesterNoProvider() {.thread.} =
  let res = waitFor MTReq.request("test")
  doAssert res.isErr()
  gDone.store(true)

proc requesterAfterClear() {.thread.} =
  let res = waitFor MTReq.request("test")
  doAssert res.isErr()
  gDone.store(true)

proc concurrentRequester1() {.thread.} =
  let res = waitFor MTReq.request("from-thread-1")
  doAssert res.isOk()
  doAssert res.value.textValue == "echo:from-thread-1"
  gThreadRes1.store(true)

proc concurrentRequester2() {.thread.} =
  let res = waitFor MTReq.request("from-thread-2")
  doAssert res.isOk()
  doAssert res.value.textValue == "echo:from-thread-2"
  gThreadRes2.store(true)

proc concurrentRequester3() {.thread.} =
  let res = waitFor MTReq.request("from-thread-3")
  doAssert res.isOk()
  doAssert res.value.textValue == "echo:from-thread-3"
  gThreadRes3.store(true)

# Thread that tries to setProvider for the default context (should fail
# when main thread already owns it).
proc setProviderFromThread() {.thread.} =
  let res = MTReq.setProvider(
    proc(input: string): Future[Result[MTReq, string]] {.async.} =
      ok(MTReq(textValue: "from-worker", numValue: 0, boolValue: false))
  )
  # Must fail — main thread already registered for this context.
  gSetProviderOk.store(res.isOk())
  gDone.store(true)

# Thread that tries to setProvider for gCtxA (should fail when main
# thread already owns gCtxA).
proc setProviderFromThreadKeyed() {.thread.} =
  let res = MTReq.setProvider(
    gCtxA,
    proc(input: string): Future[Result[MTReq, string]] {.async.} =
      ok(MTReq(textValue: "hijack", numValue: 0, boolValue: false))
  )
  gSetProviderOk.store(res.isOk())
  gDone.store(true)

# Thread that registers its OWN provider for gCtxB, serves requests,
# and signals done.  Runs its own chronos event loop.
proc providerThreadB() {.thread.} =
  proc inner() {.async.} =
    let res = MTReq.setProvider(
      gCtxB,
      proc(input: string): Future[Result[MTReq, string]] {.async.} =
        ok(MTReq(textValue: "ctxB:" & input, numValue: 200, boolValue: false))
    )
    doAssert res.isOk()
    gSetProviderOk.store(true)
    # Keep event loop alive until main thread signals we can stop.
    while not gDone.load():
      await sleepAsync(10.milliseconds)
    MTReq.clearProvider(gCtxB)
  waitFor inner()

# Requester that sends to gCtxA.
proc requesterCtxA() {.thread.} =
  let res = waitFor MTReq.request(gCtxA, "hello-A")
  doAssert res.isOk()
  doAssert res.value.textValue == "ctxA:hello-A"
  doAssert res.value.numValue == 100
  gThreadRes1.store(true)

# Requester that sends to gCtxB (owned by providerThreadB).
proc requesterCtxB() {.thread.} =
  let res = waitFor MTReq.request(gCtxB, "hello-B")
  doAssert res.isOk()
  doAssert res.value.textValue == "ctxB:hello-B"
  doAssert res.value.numValue == 200
  gThreadRes2.store(true)

# Requester that sends to default context (should fail when only keyed
# contexts are registered).
proc requesterDefaultCtxFail() {.thread.} =
  let res = waitFor MTReq.request("test")
  doAssert res.isErr()
  gThreadRes3.store(true)

# Thread proc for timeout test: requester expects timeout error.
proc requesterExpectTimeout() {.thread.} =
  let res = waitFor MTReq.request("will-timeout")
  doAssert res.isErr()
  doAssert "timed out" in res.error()
  gDone.store(true)

# Thread proc for timeout e2e test: measures that timeout actually unblocks.
proc requesterMeasureTimeout() {.thread.} =
  let start = Moment.now()
  let res = waitFor MTReq.request("will-timeout")
  let elapsed = Moment.now() - start
  doAssert res.isErr()
  doAssert "timed out" in res.error()
  # Should complete roughly within timeout + margin (not hang forever).
  # Timeout is 200ms, allow up to 2s margin for slow CI.
  doAssert elapsed < chronos.seconds(2),
    "request took too long: " & $elapsed & " (expected ~200ms timeout)"
  gDone.store(true)

# ── Test suite ────────────────────────────────────────────────────────────

suite "RequestBroker macro (multi-thread mode)":

  # ── Basic functionality ──

  asyncTest "issue request from another thread":
    check MTReq
    .setProvider(
      proc(input: string): Future[Result[MTReq, string]] {.async.} =
        ok(MTReq(textValue: input, numValue: 42, boolValue: true))
    )
    .isOk()

    gDone.store(false)
    var reqThread: Thread[void]
    reqThread.createThread(requester)

    while not gDone.load():
      await sleepAsync(10.milliseconds)

    reqThread.joinThread()
    MTReq.clearProvider()

  asyncTest "same-thread request bypasses channels":
    check MTReq
    .setProvider(
      proc(input: string): Future[Result[MTReq, string]] {.async.} =
        ok(MTReq(textValue: "same-" & input, numValue: 99, boolValue: false))
    )
    .isOk()

    let res = await MTReq.request("thread")
    check res.isOk()
    check res.value.textValue == "same-thread"
    check res.value.numValue == 99
    check res.value.boolValue == false

    MTReq.clearProvider()

  asyncTest "multiple sequential cross-thread requests":
    check MTReq
    .setProvider(
      proc(input: string): Future[Result[MTReq, string]] {.async.} =
        ok(MTReq(textValue: input & "!", numValue: input.len, boolValue: true))
    )
    .isOk()

    gDone.store(false)
    var reqThread: Thread[void]
    reqThread.createThread(multiRequester)

    while not gDone.load():
      await sleepAsync(10.milliseconds)

    reqThread.joinThread()
    MTReq.clearProvider()

  # ── Error / edge cases ──

  asyncTest "error when no provider set (same-thread)":
    let res = await MTReq.request("hello")
    check res.isErr()

  asyncTest "error when no provider set (cross-thread)":
    gDone.store(false)
    var reqThread: Thread[void]
    reqThread.createThread(requesterNoProvider)

    while not gDone.load():
      await sleepAsync(10.milliseconds)

    reqThread.joinThread()

  asyncTest "error after provider cleared (same-thread)":
    check MTReq
    .setProvider(
      proc(input: string): Future[Result[MTReq, string]] {.async.} =
        ok(MTReq(textValue: input, numValue: 1, boolValue: true))
    )
    .isOk()

    let res1 = await MTReq.request("before")
    check res1.isOk()
    check res1.value.textValue == "before"

    MTReq.clearProvider()

    let res2 = await MTReq.request("after")
    check res2.isErr()

  asyncTest "error after provider cleared (cross-thread)":
    check MTReq
    .setProvider(
      proc(input: string): Future[Result[MTReq, string]] {.async.} =
        ok(MTReq(textValue: input, numValue: 1, boolValue: true))
    )
    .isOk()

    let res = await MTReq.request("alive")
    check res.isOk()

    MTReq.clearProvider()
    await sleepAsync(50.milliseconds)

    gDone.store(false)
    var reqThread: Thread[void]
    reqThread.createThread(requesterAfterClear)

    while not gDone.load():
      await sleepAsync(10.milliseconds)

    reqThread.joinThread()

  asyncTest "duplicate setProvider returns error":
    check MTReq
    .setProvider(
      proc(input: string): Future[Result[MTReq, string]] {.async.} =
        ok(MTReq(textValue: input, numValue: 1, boolValue: true))
    )
    .isOk()

    let res = MTReq.setProvider(
      proc(input: string): Future[Result[MTReq, string]] {.async.} =
        ok(MTReq(textValue: "dup", numValue: 2, boolValue: false))
    )
    check res.isErr()

    MTReq.clearProvider()

  asyncTest "provider returning error propagates correctly":
    check MTReq
    .setProvider(
      proc(input: string): Future[Result[MTReq, string]] {.async.} =
        err("deliberate error: " & input)
    )
    .isOk()

    let res = await MTReq.request("boom")
    check res.isErr()
    check "deliberate error: boom" in res.error()

    MTReq.clearProvider()

  asyncTest "clearProvider is idempotent":
    check MTReq
    .setProvider(
      proc(input: string): Future[Result[MTReq, string]] {.async.} =
        ok(MTReq(textValue: input, numValue: 1, boolValue: true))
    )
    .isOk()

    MTReq.clearProvider()
    MTReq.clearProvider()

    let res = await MTReq.request("test")
    check res.isErr()

  asyncTest "set-clear-set cycle works":
    check MTReq
    .setProvider(
      proc(input: string): Future[Result[MTReq, string]] {.async.} =
        ok(MTReq(textValue: "first:" & input, numValue: 1, boolValue: true))
    )
    .isOk()

    let res1 = await MTReq.request("a")
    check res1.isOk()
    check res1.value.textValue == "first:a"

    MTReq.clearProvider()

    check MTReq
    .setProvider(
      proc(input: string): Future[Result[MTReq, string]] {.async.} =
        ok(MTReq(textValue: "second:" & input, numValue: 2, boolValue: false))
    )
    .isOk()

    let res2 = await MTReq.request("b")
    check res2.isOk()
    check res2.value.textValue == "second:b"
    check res2.value.numValue == 2

    MTReq.clearProvider()

  # ── Concurrency ──

  asyncTest "concurrent requests from multiple threads":
    check MTReq
    .setProvider(
      proc(input: string): Future[Result[MTReq, string]] {.async.} =
        ok(MTReq(textValue: "echo:" & input, numValue: input.len, boolValue: true))
    )
    .isOk()

    gThreadRes1.store(false)
    gThreadRes2.store(false)
    gThreadRes3.store(false)

    var t1, t2, t3: Thread[void]
    t1.createThread(concurrentRequester1)
    t2.createThread(concurrentRequester2)
    t3.createThread(concurrentRequester3)

    while not (gThreadRes1.load() and gThreadRes2.load() and gThreadRes3.load()):
      await sleepAsync(10.milliseconds)

    t1.joinThread()
    t2.joinThread()
    t3.joinThread()

    MTReq.clearProvider()

  asyncTest "zero-arg request returns error (no zero-arg signature)":
    check MTReq
    .setProvider(
      proc(input: string): Future[Result[MTReq, string]] {.async.} =
        ok(MTReq(textValue: input, numValue: 1, boolValue: true))
    )
    .isOk()

    let res = await MTReq.request()
    check res.isErr()

    MTReq.clearProvider()

  # ── setProvider from different thread ──

  asyncTest "setProvider from second thread (default ctx) must fail":
    check MTReq
    .setProvider(
      proc(input: string): Future[Result[MTReq, string]] {.async.} =
        ok(MTReq(textValue: input, numValue: 1, boolValue: true))
    )
    .isOk()

    gDone.store(false)
    gSetProviderOk.store(false)

    var workerThread: Thread[void]
    workerThread.createThread(setProviderFromThread)

    while not gDone.load():
      await sleepAsync(10.milliseconds)

    workerThread.joinThread()

    # Worker's setProvider must have failed.
    check not gSetProviderOk.load()

    # Original provider still works.
    let res = await MTReq.request("still-works")
    check res.isOk()
    check res.value.textValue == "still-works"

    MTReq.clearProvider()

  asyncTest "setProvider from second thread (keyed ctx) must fail":
    gCtxA = NewBrokerContext()

    check MTReq
    .setProvider(
      gCtxA,
      proc(input: string): Future[Result[MTReq, string]] {.async.} =
        ok(MTReq(textValue: "ctxA:" & input, numValue: 100, boolValue: true))
    )
    .isOk()

    gDone.store(false)
    gSetProviderOk.store(false)

    var workerThread: Thread[void]
    workerThread.createThread(setProviderFromThreadKeyed)

    while not gDone.load():
      await sleepAsync(10.milliseconds)

    workerThread.joinThread()

    # Worker's setProvider must have failed.
    check not gSetProviderOk.load()

    # Original provider still works.
    let res = await MTReq.request(gCtxA, "ok")
    check res.isOk()
    check res.value.textValue == "ctxA:ok"

    MTReq.clearProvider(gCtxA)

  # ── BrokerContext isolation ──

  asyncTest "two contexts on same thread are independent":
    let ctxX = NewBrokerContext()
    let ctxY = NewBrokerContext()

    check MTReq
    .setProvider(
      ctxX,
      proc(input: string): Future[Result[MTReq, string]] {.async.} =
        ok(MTReq(textValue: "X:" & input, numValue: 10, boolValue: true))
    )
    .isOk()

    check MTReq
    .setProvider(
      ctxY,
      proc(input: string): Future[Result[MTReq, string]] {.async.} =
        ok(MTReq(textValue: "Y:" & input, numValue: 20, boolValue: false))
    )
    .isOk()

    let resX = await MTReq.request(ctxX, "hello")
    check resX.isOk()
    check resX.value.textValue == "X:hello"
    check resX.value.numValue == 10

    let resY = await MTReq.request(ctxY, "world")
    check resY.isOk()
    check resY.value.textValue == "Y:world"
    check resY.value.numValue == 20

    # Clear one — the other must still work.
    MTReq.clearProvider(ctxX)

    let resX2 = await MTReq.request(ctxX, "gone")
    check resX2.isErr()

    let resY2 = await MTReq.request(ctxY, "still-here")
    check resY2.isOk()
    check resY2.value.textValue == "Y:still-here"

    MTReq.clearProvider(ctxY)

  asyncTest "two contexts on different threads with cross-thread requests":
    ## Main thread owns ctxA. A worker thread owns ctxB.
    ## Two requester threads send to ctxA and ctxB respectively.
    ## A third thread tries the default context and gets an error.
    gCtxA = NewBrokerContext()
    gCtxB = NewBrokerContext()

    # Main thread registers provider for ctxA.
    check MTReq
    .setProvider(
      gCtxA,
      proc(input: string): Future[Result[MTReq, string]] {.async.} =
        ok(MTReq(textValue: "ctxA:" & input, numValue: 100, boolValue: true))
    )
    .isOk()

    # Worker thread registers provider for ctxB.
    gDone.store(false)
    gSetProviderOk.store(false)
    var provThread: Thread[void]
    provThread.createThread(providerThreadB)

    # Wait for providerThreadB to finish registering.
    while not gSetProviderOk.load():
      await sleepAsync(10.milliseconds)

    # Launch three requester threads.
    gThreadRes1.store(false)
    gThreadRes2.store(false)
    gThreadRes3.store(false)
    var tA, tB, tDefault: Thread[void]
    tA.createThread(requesterCtxA)
    tB.createThread(requesterCtxB)
    tDefault.createThread(requesterDefaultCtxFail)

    # Keep event loop alive for ctxA requests (main thread is provider).
    while not (gThreadRes1.load() and gThreadRes2.load() and gThreadRes3.load()):
      await sleepAsync(10.milliseconds)

    tA.joinThread()
    tB.joinThread()
    tDefault.joinThread()

    # Signal providerThreadB to stop, then clean up.
    gDone.store(true)
    provThread.joinThread()

    MTReq.clearProvider(gCtxA)

  asyncTest "cross-thread request to keyed context":
    gCtxA = NewBrokerContext()

    check MTReq
    .setProvider(
      gCtxA,
      proc(input: string): Future[Result[MTReq, string]] {.async.} =
        ok(MTReq(textValue: "ctxA:" & input, numValue: 100, boolValue: true))
    )
    .isOk()

    gThreadRes1.store(false)
    var t: Thread[void]
    t.createThread(requesterCtxA)

    while not gThreadRes1.load():
      await sleepAsync(10.milliseconds)

    t.joinThread()
    MTReq.clearProvider(gCtxA)

  asyncTest "request to wrong context returns error":
    let ctxRegistered = NewBrokerContext()
    let ctxUnregistered = NewBrokerContext()

    check MTReq
    .setProvider(
      ctxRegistered,
      proc(input: string): Future[Result[MTReq, string]] {.async.} =
        ok(MTReq(textValue: input, numValue: 1, boolValue: true))
    )
    .isOk()

    let res = await MTReq.request(ctxUnregistered, "nope")
    check res.isErr()

    MTReq.clearProvider(ctxRegistered)

  # ── Timeout ──

  asyncTest "setRequestTimeout and requestTimeout getter/setter":
    let original = MTReq.requestTimeout()
    check original == chronos.seconds(5)

    MTReq.setRequestTimeout(chronos.milliseconds(500))
    check MTReq.requestTimeout() == chronos.milliseconds(500)

    # Restore default
    MTReq.setRequestTimeout(chronos.seconds(5))
    check MTReq.requestTimeout() == chronos.seconds(5)

  asyncTest "cross-thread request times out with slow provider":
    # Set a short timeout
    MTReq.setRequestTimeout(chronos.milliseconds(200))

    # Provider that sleeps longer than the timeout
    check MTReq
    .setProvider(
      proc(input: string): Future[Result[MTReq, string]] {.async.} =
        await sleepAsync(chronos.seconds(2))
        ok(MTReq(textValue: input, numValue: 1, boolValue: true))
    )
    .isOk()

    gDone.store(false)
    var reqThread: Thread[void]
    reqThread.createThread(requesterExpectTimeout)

    while not gDone.load():
      await sleepAsync(10.milliseconds)

    reqThread.joinThread()
    MTReq.clearProvider()
    # Restore default timeout
    MTReq.setRequestTimeout(chronos.seconds(5))

  asyncTest "same-thread request is NOT affected by short timeout":
    # Set a very short timeout (would fail cross-thread if provider is slow)
    MTReq.setRequestTimeout(chronos.milliseconds(1))

    check MTReq
    .setProvider(
      proc(input: string): Future[Result[MTReq, string]] {.async.} =
        # Same-thread calls provider directly — no timeout applies
        ok(MTReq(textValue: "fast:" & input, numValue: 77, boolValue: true))
    )
    .isOk()

    let res = await MTReq.request("hello")
    check res.isOk()
    check res.value.textValue == "fast:hello"
    check res.value.numValue == 77

    MTReq.clearProvider()
    # Restore default timeout
    MTReq.setRequestTimeout(chronos.seconds(5))

  asyncTest "cross-thread timeout actually unblocks (e2e timing)":
    # Set a 200ms timeout
    MTReq.setRequestTimeout(chronos.milliseconds(200))

    # Provider that blocks indefinitely (sleeps 60s)
    check MTReq
    .setProvider(
      proc(input: string): Future[Result[MTReq, string]] {.async.} =
        await sleepAsync(chronos.seconds(60))
        ok(MTReq(textValue: input, numValue: 1, boolValue: true))
    )
    .isOk()

    gDone.store(false)
    var reqThread: Thread[void]
    reqThread.createThread(requesterMeasureTimeout)

    while not gDone.load():
      await sleepAsync(10.milliseconds)

    reqThread.joinThread()
    MTReq.clearProvider()
    # Restore default timeout
    MTReq.setRequestTimeout(chronos.seconds(5))
