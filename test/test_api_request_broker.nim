{.used.}

import testutils/unittests
import chronos
import std/[atomics, os]

import request_broker

## ---------------------------------------------------------------------------
## API-mode RequestBroker tests
## ---------------------------------------------------------------------------
## These tests compile with -d:BrokerFfiApi --threads:on.
## NOTE: We use `suite` / `test` (not `asyncTest`) because the API test's main
## thread must NOT have a chronos event loop — the exported C functions create
## their own transient event loop via `waitFor`, and having a pre-existing
## chronos dispatcher on the main thread can cause sentinel callback conflicts.

RequestBroker(API):
  type ApiTestReq = object
    name*: string
    value*: int32
    active*: bool

  proc signature*(): Future[Result[ApiTestReq, string]] {.async.}

RequestBroker(API):
  type ApiTestReqArgs = object
    result_text*: string
    result_num*: int64

  proc signature*(
    input: string, count: int64
  ): Future[Result[ApiTestReqArgs, string]] {.async.}

type ApiTestBatchItem* = object
  name*: string
  deviceType*: string
  address*: string

RequestBroker(API):
  type ApiTestBatchReq = object
    items*: seq[ApiTestBatchItem]

  proc signature*(
    items: seq[ApiTestBatchItem]
  ): Future[Result[ApiTestBatchReq, string]] {.async.}

# ── Global synchronization ──────────────────────────────────────────────
var gProviderReady: Atomic[bool]
var gStopProvider: Atomic[bool]

# ── Provider thread ─────────────────────────────────────────────────────
proc providerThread(ctx: BrokerContext) {.thread.} =
  setThreadBrokerContext(ctx)

  discard ApiTestReq.setProvider(
    ctx,
    proc(): Future[Result[ApiTestReq, string]] {.async.} =
      return ok(ApiTestReq(name: "test-item", value: 42, active: true)),
  )

  discard ApiTestReqArgs.setProvider(
    ctx,
    proc(
        input: string, count: int64
    ): Future[Result[ApiTestReqArgs, string]] {.async.} =
      return ok(ApiTestReqArgs(result_text: "echo:" & input, result_num: count * 2)),
  )

  discard ApiTestBatchReq.setProvider(
    ctx,
    proc(
        items: seq[ApiTestBatchItem]
    ): Future[Result[ApiTestBatchReq, string]] {.async.} =
      return ok(ApiTestBatchReq(items: items)),
  )

  gProviderReady.store(true)

  proc awaitUntilStopped() {.async: (raises: []).} =
    while not gStopProvider.load():
      let catchRes = catch:
        await sleepAsync(chronos.milliseconds(1))
      if catchRes.isErr():
        break

    ApiTestReq.clearProvider(ctx)
    ApiTestReqArgs.clearProvider(ctx)
    ApiTestBatchReq.clearProvider(ctx)

  waitFor awaitUntilStopped()

# ── Requester threads that call exported C functions ────────────────────
var gZeroArgResult: Atomic[bool]
var gZeroArgCtx: BrokerContext

proc requesterZeroArg() {.thread.} =
  ## Calls the exported C function from a separate thread (no event loop).
  let result = api_test_req(uint32(gZeroArgCtx))
  if result.error_message.isNil() and $result.name == "test-item" and result.value == 42 and
      result.active:
    gZeroArgResult.store(true)
  if not result.name.isNil():
    freeCString(result.name)

var gArgResult: Atomic[bool]
var gArgCtx: BrokerContext

proc requesterWithArgs() {.thread.} =
  ## Calls the arg-based exported C function from a separate thread.
  let result = api_test_req_args(uint32(gArgCtx), cstring("hello"), 5)
  if result.error_message.isNil() and $result.result_text == "echo:hello" and
      result.result_num == 10:
    gArgResult.store(true)
  if not result.result_text.isNil():
    freeCString(result.result_text)

var gNoProviderResult: Atomic[bool]

var gBatchArgResult: Atomic[bool]
var gBatchArgCtx: BrokerContext

proc requesterBatchArgs() {.thread.} =
  var batch = [
    ApiTestBatchItemCItem(
      name: cstring("alpha"),
      deviceType: cstring("sensor"),
      address: cstring("10.0.0.1"),
    ),
    ApiTestBatchItemCItem(
      name: cstring("beta"), deviceType: cstring("camera"), address: cstring("10.0.0.2")
    ),
  ]
  let result = api_test_batch_req(
    uint32(gBatchArgCtx), cast[pointer](addr batch[0]), cint(batch.len)
  )
  if result.error_message.isNil() and result.items_count == 2 and
      not result.items.isNil():
    let items = cast[ptr UncheckedArray[ApiTestBatchItemCItem]](result.items)
    if $items[0].name == "alpha" and $items[0].deviceType == "sensor" and
        $items[0].address == "10.0.0.1" and $items[1].name == "beta" and
        $items[1].deviceType == "camera" and $items[1].address == "10.0.0.2":
      gBatchArgResult.store(true)
  free_api_test_batch_req_result(addr result)

proc requesterNoProvider() {.thread.} =
  ## Calls exported C function when no provider is set — should return error.
  let ctx = NewBrokerContext()
  let result = api_test_req(uint32(ctx))
  if not result.error_message.isNil() and ($result.error_message).len > 0:
    gNoProviderResult.store(true)
    freeCString(result.error_message)

suite "API RequestBroker":
  test "zero-arg request via exported C function":
    let ctx = NewBrokerContext()
    gProviderReady.store(false)
    gStopProvider.store(false)
    gZeroArgResult.store(false)
    gZeroArgCtx = ctx

    var provThread: Thread[BrokerContext]
    createThread(provThread, providerThread, ctx)
    defer:
      gStopProvider.store(true)
      provThread.joinThread()

    # Wait for provider to be ready (busy-wait, no chronos on main thread)
    while not gProviderReady.load():
      sleep(10)

    # Call from a separate thread (no event loop)
    var reqThread: Thread[void]
    createThread(reqThread, requesterZeroArg)
    joinThread(reqThread)

    check gZeroArgResult.load() == true

  test "arg-based request via exported C function":
    let ctx = NewBrokerContext()
    gProviderReady.store(false)
    gStopProvider.store(false)
    gArgResult.store(false)
    gArgCtx = ctx

    var provThread: Thread[BrokerContext]
    createThread(provThread, providerThread, ctx)
    defer:
      gStopProvider.store(true)
      provThread.joinThread()

    while not gProviderReady.load():
      sleep(10)

    var reqThread: Thread[void]
    createThread(reqThread, requesterWithArgs)
    joinThread(reqThread)

    check gArgResult.load() == true

  test "seq input request via exported C function":
    let ctx = NewBrokerContext()
    gProviderReady.store(false)
    gStopProvider.store(false)
    gBatchArgResult.store(false)
    gBatchArgCtx = ctx

    var provThread: Thread[BrokerContext]
    createThread(provThread, providerThread, ctx)
    defer:
      gStopProvider.store(true)
      provThread.joinThread()

    while not gProviderReady.load():
      sleep(10)

    var reqThread: Thread[void]
    createThread(reqThread, requesterBatchArgs)
    joinThread(reqThread)

    check gBatchArgResult.load() == true

  test "request with no provider returns error":
    gNoProviderResult.store(false)

    var reqThread: Thread[void]
    createThread(reqThread, requesterNoProvider)
    joinThread(reqThread)

    check gNoProviderResult.load() == true
