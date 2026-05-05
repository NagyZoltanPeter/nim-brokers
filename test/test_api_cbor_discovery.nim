## Tests for the CBOR FFI Phase 6 discovery API:
##   - `<lib>_listApis`
##   - `<lib>_getSchema`
##   - the side-effect generation of `<lib>.cddl`
##
## We inline a small library (no .so loading) and assert that the encoded
## descriptors match the registered request/event surface and that the
## CDDL file lands next to the build output with the expected rules.

import std/[options, os, strutils]
import results
import testutils/unittests
import brokers/[event_broker, request_broker, broker_context, api_library]
import brokers/internal/api_cbor_codec
import brokers/internal/api_cbor_descriptor

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

RequestBroker(API):
  type Echo = object
    value*: int32

  proc signature*(value: int32): Future[Result[Echo, string]] {.async.}

EventBroker(API):
  type Heartbeat = object
    seqNo*: int64
    label*: string

proc setupProviders(ctx: BrokerContext): Result[void, string] =
  proc initProv(): Future[Result[InitializeRequest, string]] {.async.} =
    return Result[InitializeRequest, string].ok(InitializeRequest(initialized: true))

  ?InitializeRequest.setProvider(ctx, initProv)

  proc shutProv(): Future[Result[ShutdownRequest, string]] {.async.} =
    return Result[ShutdownRequest, string].ok(ShutdownRequest(status: 0))

  ?ShutdownRequest.setProvider(ctx, shutProv)

  proc echoProv(value: int32): Future[Result[Echo, string]] {.async.} =
    return Result[Echo, string].ok(Echo(value: value))

  ?Echo.setProvider(ctx, echoProv)

  return Result[void, string].ok()

registerBrokerLibrary:
  name:
    "cbdisc"
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc takeBuf(buf: pointer, len: int32): seq[byte] =
  if buf.isNil or len <= 0:
    return @[]
  result = newSeq[byte](len.int)
  copyMem(addr result[0], buf, len.int)
  cbdisc_freeBuffer(buf)

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "CBOR FFI discovery API":
  test "listApis returns the registered request and event names":
    var buf: pointer = nil
    var len: int32 = 0
    check cbdisc_listApis(addr buf, addr len) == 0'i32
    let bytes = takeBuf(buf, len)
    check bytes.len > 0

    let dec = cborDecode(bytes, ApiList)
    check dec.isOk()
    let info = dec.value
    check info.libName == "cbdisc"
    check info.requests.len == 3
    check "initialize_request" in info.requests
    check "shutdown_request" in info.requests
    check "echo" in info.requests
    check info.events == @["heartbeat"]

  test "getSchema returns a populated LibraryDescriptor":
    var buf: pointer = nil
    var len: int32 = 0
    check cbdisc_getSchema(addr buf, addr len) == 0'i32
    let bytes = takeBuf(buf, len)
    check bytes.len > 0

    let dec = cborDecode(bytes, LibraryDescriptor)
    check dec.isOk()
    let info = dec.value
    check info.libName == "cbdisc"
    check info.cddl.len > 0
    check "Echo = {" in info.cddl
    check "Heartbeat = {" in info.cddl
    check info.requests.len == 3
    check info.events.len == 1

    var seenEcho = false
    for r in info.requests:
      if r.apiName == "echo":
        seenEcho = true
        check r.responseType == "Echo"
        check r.argFields.len == 1
        check r.argFields[0].name == "value"
        check r.argFields[0].nimType == "int32"
    check seenEcho

    var seenHeartbeat = false
    for e in info.events:
      if e.apiName == "heartbeat":
        seenHeartbeat = true
        check e.payloadType == "Heartbeat"
    check seenHeartbeat

    var seenEchoType = false
    var seenHeartbeatType = false
    for t in info.types:
      if t.name == "Echo":
        seenEchoType = true
        check t.kind == "object"
        check t.fields.len == 1
        check t.fields[0].name == "value"
      elif t.name == "Heartbeat":
        seenHeartbeatType = true
        check t.kind == "object"
        check t.fields.len == 2
    check seenEchoType
    check seenHeartbeatType

  test "null out-pointers are rejected":
    var buf: pointer = nil
    var len: int32 = 0
    check cbdisc_listApis(nil, addr len) == -1'i32
    check cbdisc_listApis(addr buf, nil) == -1'i32
    check cbdisc_getSchema(nil, addr len) == -1'i32
    check cbdisc_getSchema(addr buf, nil) == -1'i32
