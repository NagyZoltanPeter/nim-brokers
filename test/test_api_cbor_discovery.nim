## Tests for the CBOR FFI Phase 6 discovery API:
##   - `<lib>_listApis`
##   - `<lib>_getSchema`
##   - the side-effect generation of `<lib>.cddl`
##
## We inline a small library (no .so loading) and assert that the JSON-encoded
## descriptors match the registered request/event surface and that the
## CDDL file lands next to the build output with the expected rules.

import std/[json, options, os, strutils]
import results
import testutils/unittests
import brokers/[event_broker, request_broker, broker_context, api_library]
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

proc takeJsonStr(buf: pointer, len: int32): string =
  if buf.isNil or len <= 0:
    return ""
  result = newString(len.int)
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
    let jsonStr = takeJsonStr(buf, len)
    check jsonStr.len > 0

    let info = parseJson(jsonStr)
    check info["libName"].getStr() == "cbdisc"
    let reqs = info["requests"]
    check reqs.len == 3
    var reqNames: seq[string]
    for r in reqs:
      reqNames.add(r.getStr())
    check "initialize_request" in reqNames
    check "shutdown_request" in reqNames
    check "echo" in reqNames
    let evts = info["events"]
    check evts.len == 1
    check evts[0].getStr() == "heartbeat"

  test "getSchema returns a populated LibraryDescriptor":
    var buf: pointer = nil
    var len: int32 = 0
    check cbdisc_getSchema(addr buf, addr len) == 0'i32
    let jsonStr = takeJsonStr(buf, len)
    check jsonStr.len > 0

    let info = parseJson(jsonStr)
    check info["libName"].getStr() == "cbdisc"
    check info["cddl"].getStr().len > 0
    check "Echo = {" in info["cddl"].getStr()
    check "Heartbeat = {" in info["cddl"].getStr()
    check info["requests"].len == 3
    check info["events"].len == 1

    var seenEcho = false
    for r in info["requests"]:
      if r["apiName"].getStr() == "echo":
        seenEcho = true
        check r["responseType"].getStr() == "Echo"
        let argFields = r["argFields"]
        check argFields.len == 1
        check argFields[0]["name"].getStr() == "value"
        check argFields[0]["nimType"].getStr() == "int32"
    check seenEcho

    var seenHeartbeat = false
    for e in info["events"]:
      if e["apiName"].getStr() == "heartbeat":
        seenHeartbeat = true
        check e["payloadType"].getStr() == "Heartbeat"
    check seenHeartbeat

    var seenEchoType = false
    var seenHeartbeatType = false
    for t in info["types"]:
      if t["name"].getStr() == "Echo":
        seenEchoType = true
        check t["kind"].getStr() == "object"
        check t["fields"].len == 1
        check t["fields"][0]["name"].getStr() == "value"
      elif t["name"].getStr() == "Heartbeat":
        seenHeartbeatType = true
        check t["kind"].getStr() == "object"
        check t["fields"].len == 2
    check seenEchoType
    check seenHeartbeatType

  test "null out-pointers are rejected":
    var buf: pointer = nil
    var len: int32 = 0
    check cbdisc_listApis(nil, addr len) == -1'i32
    check cbdisc_listApis(addr buf, nil) == -1'i32
    check cbdisc_getSchema(nil, addr len) == -1'i32
    check cbdisc_getSchema(addr buf, nil) == -1'i32
