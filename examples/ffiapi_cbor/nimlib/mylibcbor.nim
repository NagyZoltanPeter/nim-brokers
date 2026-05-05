## mylibcbor — minimal CBOR-mode FFI example library.
##
## Demonstrates the typed C++ wrapper generated under
## `-d:BrokerFfiApiCBOR`: lifecycle, a zero-arg request, an arg-based
## request, and an event subscription that's triggered by a request
## provider on the processing thread.
##
## Build (from repo root):
##   nimble buildFfiCborExample
##
## Produces examples/ffiapi_cbor/nimlib/build/libmylibcbor.{so,dylib,dll}
## plus mylibcbor.h and mylibcbor.hpp next to it.

{.push raises: [].}

import results
import brokers/[event_broker, request_broker, broker_context, api_library]

# ---------------------------------------------------------------------------
# Request types
# ---------------------------------------------------------------------------

RequestBroker(API):
  type InitializeRequest = object
    initialized*: bool

  proc signature*(): Future[Result[InitializeRequest, string]] {.async.}

RequestBroker(API):
  type ShutdownRequest = object
    status*: int32

  proc signature*(): Future[Result[ShutdownRequest, string]] {.async.}

RequestBroker(API):
  type GetStatus = object
    online*: bool
    counter*: int32
    label*: string

  proc signature*(): Future[Result[GetStatus, string]] {.async.}

RequestBroker(API):
  type AddNumbers = object
    sum*: int64

  proc signature*(a: int32, b: int32): Future[Result[AddNumbers, string]] {.async.}

# Trigger request that emits an event on the processing thread, so the
# example can show the C++ subscribe handler firing.
RequestBroker(API):
  type FireDevice = object
    fired*: bool

  proc signature*(
    deviceId: int64, online: bool
  ): Future[Result[FireDevice, string]] {.async.}

# ---------------------------------------------------------------------------
# Event types
# ---------------------------------------------------------------------------

EventBroker(API):
  type DeviceUpdated = object
    deviceId*: int64
    online*: bool

# ---------------------------------------------------------------------------
# Provider wiring
# ---------------------------------------------------------------------------

proc setupProviders(ctx: BrokerContext): Result[void, string] =
  proc statusProv(): Future[Result[GetStatus, string]] {.async.} =
    return Result[GetStatus, string].ok(
      GetStatus(online: true, counter: 42, label: "mylibcbor up")
    )

  ?GetStatus.setProvider(ctx, statusProv)

  proc addProv(a: int32, b: int32): Future[Result[AddNumbers, string]] {.async.} =
    return Result[AddNumbers, string].ok(AddNumbers(sum: int64(a) + int64(b)))

  ?AddNumbers.setProvider(ctx, addProv)

  proc fireProv(
      deviceId: int64, online: bool
  ): Future[Result[FireDevice, string]] {.async.} =
    discard DeviceUpdated.emit(ctx, DeviceUpdated(deviceId: deviceId, online: online))
    return Result[FireDevice, string].ok(FireDevice(fired: true))

  ?FireDevice.setProvider(ctx, fireProv)

  return Result[void, string].ok()

registerBrokerLibrary:
  name:
    "mylibcbor"
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest
