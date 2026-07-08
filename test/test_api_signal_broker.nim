{.used.}

## SignalBroker(API) — FFI `_call` slot-free one-way path.
##
## Compiled in-process with `--nimMainPrefix:sigtest` so the generated C ABI
## exports (`sigtest_call`, `sigtest_createContext`, …) are callable directly.

import std/[atomics, os, json, strutils]
import results
import testutils/unittests
import brokers/[signal_broker, request_broker, broker_context, api_library]
import brokers/internal/api_cbor_codec

# ---------------------------------------------------------------------------
# Inline mini-library
# ---------------------------------------------------------------------------

SignalBroker(API):
  type IngestSample = object
    deviceId*: string
    value*: int64

SignalBroker(API):
  type PulseSig = void

# Declared but deliberately NOT installed in setupProviders — `_call` must
# fast-fail with ProviderErr.
SignalBroker(API):
  type Unhandled = object
    n*: int32

RequestBroker(API):
  type InitializeRequest = object
    initialized*: bool

  proc signature*(): Future[Result[InitializeRequest, string]] {.async.}

RequestBroker(API):
  type ShutdownRequest = object
    status*: int32

  proc signature*(): Future[Result[ShutdownRequest, string]] {.async.}

var gLastValue: Atomic[int]
var gSigCount: Atomic[int]
var gPulseCount: Atomic[int]

proc setupProviders(ctx: BrokerContext): Result[void, string] =
  proc initProv(): Future[Result[InitializeRequest, string]] {.async.} =
    return ok(InitializeRequest(initialized: true))

  ?InitializeRequest.setProvider(ctx, initProv)

  proc shutProv(): Future[Result[ShutdownRequest, string]] {.async.} =
    return ok(ShutdownRequest(status: 0))

  ?ShutdownRequest.setProvider(ctx, shutProv)

  ?IngestSample.onSignal(
    ctx,
    proc(s: IngestSample) {.async: (raises: []).} =
      gLastValue.store(int(s.value))
      discard gSigCount.fetchAdd(1),
  )

  ?PulseSig.onSignal(
    ctx,
    proc() {.async: (raises: []).} =
      discard gPulseCount.fetchAdd(1),
  )

  return Result[void, string].ok()

registerBrokerLibrary:
  name:
    "sigtest"
  version:
    "0.1.0"
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc copyToCBuffer(bytes: openArray[byte]): pointer =
  result = sigtest_allocBuffer(int32(bytes.len))
  if bytes.len > 0:
    copyMem(result, unsafeAddr bytes[0], bytes.len)

proc callSignal(ctx: uint32, apiName: string, payload: openArray[byte]): int32 =
  let inBuf =
    if payload.len > 0:
      copyToCBuffer(payload)
    else:
      nil
  var respBuf: pointer = nil
  var respLen: int32 = 0
  result = sigtest_call(
    ctx, apiName.cstring, inBuf, int32(payload.len), addr respBuf, addr respLen
  )
  if not respBuf.isNil:
    sigtest_freeBuffer(respBuf)

proc waitFor(counter: var Atomic[int], target: int, maxMs = 500): bool =
  var tries = 0
  while counter.load() < target and tries < maxMs:
    sleep(1)
    inc tries
  counter.load() >= target

proc noopRespCb(
    userData: pointer, reqId: uint64, status: int32, respBuf: pointer, respLen: int32
) {.cdecl, gcsafe, raises: [].} =
  discard

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "SignalBroker(API) — FFI _call (slot-free, one-way)":
  test "signal _call is accepted and the handler runs on the processing thread":
    var err: cstring = nil
    let ctx = sigtest_createContext(addr err)
    check ctx != 0'u32
    gLastValue.store(0)
    gSigCount.store(0)

    let payload = cborEncode(IngestSample(deviceId: "d1", value: 42'i64))
    check payload.isOk
    check callSignal(ctx, "ingest_sample", payload.value) == ApiStatusOk

    check waitFor(gSigCount, 1)
    check gLastValue.load() == 42
    check sigtest_shutdown(ctx) == 0'i32

  test "void pulse signal _call runs the no-arg handler":
    var err: cstring = nil
    let ctx = sigtest_createContext(addr err)
    check ctx != 0'u32
    gPulseCount.store(0)

    check callSignal(ctx, "pulse_sig", @[]) == ApiStatusOk
    check waitFor(gPulseCount, 1)
    check sigtest_shutdown(ctx) == 0'i32

  test "signal _call with no installed handler returns ProviderErr":
    var err: cstring = nil
    let ctx = sigtest_createContext(addr err)
    check ctx != 0'u32

    let payload = cborEncode(Unhandled(n: 1'i32))
    check payload.isOk
    check callSignal(ctx, "unhandled", payload.value) == ApiStatusProviderErr
    check sigtest_shutdown(ctx) == 0'i32

  test "callAsync on a signal name is rejected as one-way":
    var err: cstring = nil
    let ctx = sigtest_createContext(addr err)
    check ctx != 0'u32

    let payload = cborEncode(IngestSample(deviceId: "d", value: 1'i64))
    check payload.isOk
    let buf = copyToCBuffer(payload.value)
    let st = sigtest_callAsync(
      ctx,
      "ingest_sample".cstring,
      buf,
      int32(payload.value.len),
      1'u64,
      0'u32,
      noopRespCb,
      nil,
    )
    check st == ApiStatusOneWay
    check sigtest_shutdown(ctx) == 0'i32

  test "discovery: signals appear in _listApis and _getSchema":
    var buf: pointer = nil
    var len: int32 = 0
    check sigtest_listApis(addr buf, addr len) == 0'i32
    var jsonStr = newString(len.int)
    if len > 0:
      copyMem(addr jsonStr[0], buf, len.int)
    sigtest_freeBuffer(buf)
    let list = parseJson(jsonStr)
    var sigNames: seq[string]
    for s in list["signals"]:
      sigNames.add(s.getStr())
    check "ingest_sample" in sigNames
    check "pulse_sig" in sigNames
    check "unhandled" in sigNames

    buf = nil
    len = 0
    check sigtest_getSchema(addr buf, addr len) == 0'i32
    var schemaStr = newString(len.int)
    if len > 0:
      copyMem(addr schemaStr[0], buf, len.int)
    sigtest_freeBuffer(buf)
    let schema = parseJson(schemaStr)
    var found = false
    for s in schema["signals"]:
      if s["apiName"].getStr() == "ingest_sample":
        check s["payloadType"].getStr() == "IngestSample"
        found = true
    check found
    check "IngestSampleSignal" in schema["cddl"].getStr()
