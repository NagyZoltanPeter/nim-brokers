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

# Global synchronization for cross-thread tests.
var gDone: Atomic[bool]

# Thread procs defined at module level to avoid closure captures.
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

suite "RequestBroker macro (multi-thread mode)":
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

    # Async wait — keeps event loop alive to process requests
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

  asyncTest "error when no provider set":
    let res = await MTReq.request("hello")
    check res.isErr()

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
