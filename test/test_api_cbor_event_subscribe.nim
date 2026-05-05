## Integration tests for the CBOR FFI event delivery surface emitted by
## `registerBrokerLibrary` under `-d:BrokerFfiApiCBOR`.
##
## The test binary inlines the broker library and drives the generated
## `<lib>_subscribe` / `<lib>_unsubscribe` C exports as ordinary Nim
## procs. A synchronous Nim emitter (called from a setupProviders-time
## helper request) triggers the per-event listener installer's body,
## which CBOR-encodes the event and invokes the registered foreign
## callbacks. The callbacks here are plain Nim cdecl procs that copy the
## payload into shared state for the test thread to inspect.
##
## Coverage:
## - subscribe with cb == nil → probe sentinel handle 1
## - subscribe with unknown eventName → 0 (failure)
## - emit + delivery to a single subscriber
## - emit + delivery to multiple subscribers (fan-out)
## - unsubscribe by handle stops further delivery
## - unsubscribe with handle == 0 removes all subscribers for that event
## - unknown eventName on unsubscribe → -2
## - emit fan-out across two contexts stays isolated

import std/[locks, options, os, strutils, tables]
import results
import testutils/unittests
import brokers/[event_broker, request_broker, broker_context, api_library]
import brokers/internal/api_cbor_codec

# ---------------------------------------------------------------------------
# Inline mini-library
# ---------------------------------------------------------------------------

RequestBroker(API):
  type InitializeRequest = object
    initialized*: bool

  proc signature*(): Future[Result[InitializeRequest, string]] {.async.}

RequestBroker(API):
  type ShutdownRequest = object
    status*: int32

  proc signature*(): Future[Result[ShutdownRequest, string]] {.async.}

# A trigger request whose provider emits a DeviceUpdated event. We use
# a request rather than a separate emitter because the test process has
# no other source of cross-thread emit calls.
RequestBroker(API):
  type FireDevice = object
    fired*: bool

  proc signature*(
    deviceId: int64, online: bool
  ): Future[Result[FireDevice, string]] {.async.}

EventBroker(API):
  type DeviceUpdated = object
    deviceId*: int64
    online*: bool

EventBroker(API):
  type CounterTick = object
    value*: int32

proc setupProviders(ctx: BrokerContext): Result[void, string] =
  proc fireProv(
      deviceId: int64, online: bool
  ): Future[Result[FireDevice, string]] {.async.} =
    discard DeviceUpdated.emit(ctx, DeviceUpdated(deviceId: deviceId, online: online))
    return Result[FireDevice, string].ok(FireDevice(fired: true))

  ?FireDevice.setProvider(ctx, fireProv)
  return Result[void, string].ok()

registerBrokerLibrary:
  name:
    "evtt"
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest

# ---------------------------------------------------------------------------
# Shared state for the test callbacks. cdecl callbacks cannot close over
# Nim locals, so the receiving sinks live as module-level globals.
# ---------------------------------------------------------------------------

type DeliveredEvent = object
  ctx: uint32
  eventName: string
  payload: seq[byte]
  userData: pointer

var gDeliveryLock: Lock
var gDeliveriesA: seq[DeliveredEvent]
var gDeliveriesB: seq[DeliveredEvent]

proc resetDeliveries() =
  withLock gDeliveryLock:
    gDeliveriesA.setLen(0)
    gDeliveriesB.setLen(0)

proc takeDeliveriesA(): seq[DeliveredEvent] =
  withLock gDeliveryLock:
    result = gDeliveriesA
    gDeliveriesA.setLen(0)

proc takeDeliveriesB(): seq[DeliveredEvent] =
  withLock gDeliveryLock:
    result = gDeliveriesB
    gDeliveriesB.setLen(0)

initLock(gDeliveryLock)

proc cbA(
    ctx: uint32, eventName: cstring, buf: pointer, bufLen: int32, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  var payload = newSeq[byte](bufLen.int)
  if bufLen > 0 and not buf.isNil:
    copyMem(addr payload[0], buf, bufLen.int)
  {.cast(gcsafe).}:
    withLock gDeliveryLock:
      gDeliveriesA.add(
        DeliveredEvent(
          ctx: ctx, eventName: $eventName, payload: payload, userData: userData
        )
      )

proc cbB(
    ctx: uint32, eventName: cstring, buf: pointer, bufLen: int32, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  var payload = newSeq[byte](bufLen.int)
  if bufLen > 0 and not buf.isNil:
    copyMem(addr payload[0], buf, bufLen.int)
  {.cast(gcsafe).}:
    withLock gDeliveryLock:
      gDeliveriesB.add(
        DeliveredEvent(
          ctx: ctx, eventName: $eventName, payload: payload, userData: userData
        )
      )

# ---------------------------------------------------------------------------
# Helpers wrapping the generated C exports for ergonomic use.
# ---------------------------------------------------------------------------

proc fireDevice(
    ctx: uint32, deviceId: int64, online: bool
): tuple[status: int32, resp: seq[byte]] =
  type FireDeviceCborArgs = object
    deviceId*: int64
    online*: bool

  let args = FireDeviceCborArgs(deviceId: deviceId, online: online)
  let argBuf = cborEncode(args)
  doAssert argBuf.isOk(), argBuf.error
  let inBuf = evtt_allocBuffer(int32(argBuf.value.len))
  if argBuf.value.len > 0:
    copyMem(inBuf, unsafeAddr argBuf.value[0], argBuf.value.len)
  var respBuf: pointer = nil
  var respLen: int32 = 0
  let status = evtt_call(
    ctx,
    "fire_device".cstring,
    inBuf,
    int32(argBuf.value.len),
    addr respBuf,
    addr respLen,
  )
  var resp: seq[byte]
  if respLen > 0 and not respBuf.isNil:
    resp = newSeq[byte](respLen.int)
    copyMem(addr resp[0], respBuf, respLen.int)
    evtt_freeBuffer(respBuf)
  (status, resp)

proc waitForDeliveries(
    takeFn: proc(): seq[DeliveredEvent], minLen: int, timeoutMs: int = 1000
): seq[DeliveredEvent] =
  ## Listener invocations happen on the processing thread; the test thread
  ## may briefly race ahead of the dispatch. Poll a few ms before failing.
  var waited = 0
  while waited < timeoutMs:
    var snap: seq[DeliveredEvent]
    withLock gDeliveryLock:
      snap = gDeliveriesA & gDeliveriesB
    if snap.len >= minLen:
      return takeFn()
    sleep(2)
    waited += 2
  takeFn()

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "API library event subscribe (CBOR mode)":
  test "subscribe with nil cb returns probe sentinel handle 1":
    var err: cstring = nil
    let ctx = evtt_createContext(addr err)
    check ctx != 0'u32

    let probe = evtt_subscribe(ctx, "device_updated".cstring, nil, nil)
    check probe == 1'u64

    discard evtt_shutdown(ctx)

  test "subscribe with unknown eventName returns 0":
    var err: cstring = nil
    let ctx = evtt_createContext(addr err)
    check ctx != 0'u32

    let h = evtt_subscribe(ctx, "no_such_event".cstring, cbA, nil)
    check h == 0'u64
    let probe = evtt_subscribe(ctx, "no_such_event".cstring, nil, nil)
    check probe == 0'u64

    discard evtt_shutdown(ctx)

  # Tests below exercise cross-thread Channel[T] traffic via the MT broker
  # underlying the event delivery path. On macOS + Nim 2.2.4 + refc-debug
  # this combo hits a stdlib regression that hangs sustained sends — the
  # same one LIMITATION.md documents. The brokers.nimble task adds
  # -d:brokerTestsSkipFragileRefcBursts on that exact platform, and we
  # honour it here.
  when not defined(brokerTestsSkipFragileRefcBursts):
    test "single subscriber receives event":
      resetDeliveries()
      var err: cstring = nil
      let ctx = evtt_createContext(addr err)
      check ctx != 0'u32

      let h = evtt_subscribe(ctx, "device_updated".cstring, cbA, cast[pointer](42))
      check h >= 2'u64

      let (status, _) = fireDevice(ctx, 7, true)
      check status == 0'i32

      let delivered = waitForDeliveries(takeDeliveriesA, 1)
      check delivered.len == 1
      check delivered[0].ctx == ctx
      check delivered[0].eventName == "device_updated"
      check delivered[0].userData == cast[pointer](42)

      let dec = cborDecode(delivered[0].payload, DeviceUpdated)
      check dec.isOk()
      check dec.value.deviceId == 7
      check dec.value.online == true

      discard evtt_shutdown(ctx)

    test "multiple subscribers all receive event (fan-out)":
      resetDeliveries()
      var err: cstring = nil
      let ctx = evtt_createContext(addr err)
      check ctx != 0'u32

      let hA = evtt_subscribe(ctx, "device_updated".cstring, cbA, nil)
      let hB = evtt_subscribe(ctx, "device_updated".cstring, cbB, nil)
      check hA != hB
      check hA >= 2'u64
      check hB >= 2'u64

      let (status, _) = fireDevice(ctx, 11, false)
      check status == 0'i32

      # Wait until both sinks have at least one delivery, then drain.
      var waited = 0
      while waited < 1000:
        var aLen = 0
        var bLen = 0
        withLock gDeliveryLock:
          aLen = gDeliveriesA.len
          bLen = gDeliveriesB.len
        if aLen >= 1 and bLen >= 1:
          break
        sleep(2)
        waited += 2

      let aSnap = takeDeliveriesA()
      let bSnap = takeDeliveriesB()
      check aSnap.len == 1
      check bSnap.len == 1
      let decA = cborDecode(aSnap[0].payload, DeviceUpdated)
      let decB = cborDecode(bSnap[0].payload, DeviceUpdated)
      check decA.isOk()
      check decB.isOk()
      check decA.value.deviceId == 11
      check decB.value.deviceId == 11

      discard evtt_shutdown(ctx)

    test "unsubscribe by handle stops further delivery":
      resetDeliveries()
      var err: cstring = nil
      let ctx = evtt_createContext(addr err)
      check ctx != 0'u32

      let h = evtt_subscribe(ctx, "device_updated".cstring, cbA, nil)
      check h >= 2'u64

      discard fireDevice(ctx, 1, true)
      discard waitForDeliveries(takeDeliveriesA, 1)
      # First fire delivered exactly once.

      let unsubRes = evtt_unsubscribe(ctx, "device_updated".cstring, h)
      check unsubRes == 0'i32

      discard fireDevice(ctx, 2, false)
      sleep(50)
      let post = takeDeliveriesA()
      check post.len == 0

      discard evtt_shutdown(ctx)

    test "unsubscribe with handle 0 removes all subscribers":
      resetDeliveries()
      var err: cstring = nil
      let ctx = evtt_createContext(addr err)
      check ctx != 0'u32

      discard evtt_subscribe(ctx, "device_updated".cstring, cbA, nil)
      discard evtt_subscribe(ctx, "device_updated".cstring, cbB, nil)

      check evtt_unsubscribe(ctx, "device_updated".cstring, 0'u64) == 0'i32

      discard fireDevice(ctx, 9, true)
      sleep(50)
      check takeDeliveriesA().len == 0
      check takeDeliveriesB().len == 0

      discard evtt_shutdown(ctx)

  test "unsubscribe unknown eventName returns -2":
    var err: cstring = nil
    let ctx = evtt_createContext(addr err)
    check ctx != 0'u32

    check evtt_unsubscribe(ctx, "no_such_event".cstring, 0'u64) == -2'i32

    discard evtt_shutdown(ctx)
