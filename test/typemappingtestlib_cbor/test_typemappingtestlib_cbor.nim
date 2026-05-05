## Nim-side parity test for typemappingtestlib_cbor.
##
## Drives every request through `<lib>_call` and every event through
## `<lib>_subscribe`, asserting that the wire (CBOR) round-trip matches
## the providers' computed values. The library is inlined (not loaded
## as a shared object) so we exercise the same generated runtime that
## a foreign caller would, but with full Nim-level visibility of the
## synthesised args / response types.

import std/[atomics, monotimes, options, os, strutils, times]
import results
import testutils/unittests
import brokers/internal/api_cbor_codec
import ./typemappingtestlib_cbor

# ---------------------------------------------------------------------------
# C-export wrappers (FFI gate)
# ---------------------------------------------------------------------------

proc copyToCBuffer(bytes: openArray[byte]): pointer =
  result = typemappingtestlib_cbor_allocBuffer(int32(bytes.len))
  if bytes.len > 0:
    copyMem(result, unsafeAddr bytes[0], bytes.len)

proc takeBuf(buf: pointer, len: int32): seq[byte] =
  if buf.isNil or len <= 0:
    return @[]
  result = newSeq[byte](len.int)
  copyMem(addr result[0], buf, len.int)
  typemappingtestlib_cbor_freeBuffer(buf)

proc callApi(
    ctx: uint32, apiName: string, payload: openArray[byte] = []
): tuple[status: int32, resp: seq[byte]] =
  let inBuf =
    if payload.len > 0:
      copyToCBuffer(payload)
    else:
      nil
  var respBuf: pointer = nil
  var respLen: int32 = 0
  let status = typemappingtestlib_cbor_call(
    ctx, apiName.cstring, inBuf, int32(payload.len), addr respBuf, addr respLen
  )
  (status, takeBuf(respBuf, respLen))

# ---------------------------------------------------------------------------
# Decoded-event buffer shared with subscription callbacks
# ---------------------------------------------------------------------------
#
# The CBOR FFI runtime invokes the subscription callback on its
# delivery thread. We park the raw CBOR payload bytes in a tiny
# atomically-protected slot keyed by event name and let the test body
# spin-wait on a flag. This avoids pulling in chronos here.

type DeliveredEvent = object
  name: string
  bytes: seq[byte]

var gDeliveredCount: Atomic[int]
var gDelivered {.threadvar.}: seq[DeliveredEvent]
  ## thread-local; only the callback writes to it
var gDeliveredMain: seq[DeliveredEvent]
  ## the main test thread reads/writes this; callback hands off via the
  ## intermediate copy below

# Because the callback runs on a foreign delivery thread we must hand
# the bytes off via shared memory. Simplest: heap-allocate a copy keyed
# by event name and stash it in a global protected by the atomic
# counter above. Tests pop entries by indexing.
type RawSlot = object
  name: cstring
  data: pointer
  len: int32

var gSlots: array[256, RawSlot]
var gSlotIdx: Atomic[int]

proc resetSlots() =
  for i in 0 ..< gSlots.len:
    if gSlots[i].data != nil:
      deallocShared(gSlots[i].data)
      gSlots[i].data = nil
      gSlots[i].len = 0
    gSlots[i].name = nil
  gSlotIdx.store(0)
  gDeliveredCount.store(0)

proc captureCb(
    ctx: uint32, eventName: cstring, payloadBuf: pointer, payloadLen: int32, _: pointer
) {.cdecl.} =
  let idx = gSlotIdx.fetchAdd(1)
  if idx >= gSlots.len:
    return
  if payloadLen > 0 and not payloadBuf.isNil:
    let buf = allocShared0(payloadLen.int)
    copyMem(buf, payloadBuf, payloadLen.int)
    gSlots[idx].data = buf
    gSlots[idx].len = payloadLen
  gSlots[idx].name = eventName
  discard gDeliveredCount.fetchAdd(1)

proc nowMs(): int64 =
  cast[int64](getMonoTime().ticks div 1_000_000)

proc waitForEvent(name: string, timeoutMs: int = 500): seq[byte] =
  let deadline = nowMs() + timeoutMs
  while nowMs() < deadline:
    let count = gSlotIdx.load()
    for i in 0 ..< count:
      if gSlots[i].name != nil and $gSlots[i].name == name and gSlots[i].len > 0:
        var outBytes = newSeq[byte](gSlots[i].len.int)
        copyMem(addr outBytes[0], gSlots[i].data, gSlots[i].len.int)
        return outBytes
    sleep(5)
  return @[]

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

template setupCtx(): uint32 =
  var err: cstring = nil
  let c = typemappingtestlib_cbor_createContext(addr err)
  check c != 0'u32
  c

proc subscribe(ctx: uint32, eventName: string): uint64 =
  typemappingtestlib_cbor_subscribe(ctx, eventName.cstring, captureCb, nil)

suite "typemappingtestlib_cbor parity":
  test "lifecycle + initialize round-trip (string param)":
    resetSlots()
    let ctx = setupCtx()

    type InitArgs = object
      label*: string

    let args = InitArgs(label: "mylabel")
    let argBuf = cborEncode(args)
    check argBuf.isOk()

    let (st, resp) = callApi(ctx, "initialize_request", argBuf.value)
    check st == 0'i32
    let dec = cborDecodeResultEnvelope(resp, InitializeRequest)
    check dec.isOk()
    check dec.value.label == "mylabel"

    discard typemappingtestlib_cbor_shutdown(ctx)

  test "echo round-trip (provider concatenates with stored label)":
    resetSlots()
    let ctx = setupCtx()

    type InitArgs = object
      label*: string

    discard
      callApi(ctx, "initialize_request", cborEncode(InitArgs(label: "init")).value)

    type EchoArgs = object
      message*: string

    let (st, resp) =
      callApi(ctx, "echo_request", cborEncode(EchoArgs(message: "ping")).value)
    check st == 0'i32
    let dec = cborDecodeResultEnvelope(resp, EchoRequest)
    check dec.isOk()
    check dec.value.reply == "init:ping"

    discard typemappingtestlib_cbor_shutdown(ctx)

  test "primitive-scalar request + matching event":
    resetSlots()
    let ctx = setupCtx()
    discard subscribe(ctx, "prim_scalar_event")

    type Args = object
      flag*: bool
      i32*: int32
      i64*: int64
      f64*: float64

    let args = Args(flag: true, i32: 7, i64: 1234567890123'i64, f64: 3.5)
    let (st, resp) = callApi(ctx, "prim_scalar_request", cborEncode(args).value)
    check st == 0'i32
    let dec = cborDecodeResultEnvelope(resp, PrimScalarRequest)
    check dec.isOk()
    check dec.value.flag == true
    check dec.value.i32 == 7'i32
    check dec.value.i64 == 1234567890123'i64
    check dec.value.f64 == 3.5

    let evt = waitForEvent("prim_scalar_event")
    check evt.len > 0
    let evtDec = cborDecode(evt, PrimScalarEvent)
    check evtDec.isOk()
    check evtDec.value.i64 == args.i64

    discard typemappingtestlib_cbor_shutdown(ctx)

  test "enum + distinct round-trip":
    resetSlots()
    let ctx = setupCtx()
    discard subscribe(ctx, "typed_scalar_event")

    type Args = object
      priority*: Priority
      jobId*: JobId

    let args = Args(priority: pHigh, jobId: JobId(41))
    let (st, resp) = callApi(ctx, "typed_scalar_request", cborEncode(args).value)
    check st == 0'i32
    let dec = cborDecodeResultEnvelope(resp, TypedScalarRequest)
    check dec.isOk()
    check dec.value.priority == pHigh
    check int32(dec.value.jobId) == 41'i32
    check int32(dec.value.nextId) == 42'i32

    let evt = waitForEvent("typed_scalar_event")
    check evt.len > 0
    let evtDec = cborDecode(evt, TypedScalarEvent)
    check evtDec.isOk()
    check int64(evtDec.value.ts) == 410'i64

    discard typemappingtestlib_cbor_shutdown(ctx)

  test "seq[byte] result":
    resetSlots()
    let ctx = setupCtx()
    type Args = object
      size*: int32

    let (st, resp) = callApi(ctx, "byte_seq_request", cborEncode(Args(size: 5)).value)
    check st == 0'i32
    let dec = cborDecodeResultEnvelope(resp, ByteSeqRequest)
    check dec.isOk()
    check dec.value.data == @[0'u8, 1, 2, 3, 4]
    discard typemappingtestlib_cbor_shutdown(ctx)

  test "seq[string] result + matching event":
    resetSlots()
    let ctx = setupCtx()
    discard subscribe(ctx, "string_seq_event")
    type Args = object
      prefix*: string
      n*: int32

    let (st, resp) =
      callApi(ctx, "string_seq_request", cborEncode(Args(prefix: "x", n: 3)).value)
    check st == 0'i32
    let dec = cborDecodeResultEnvelope(resp, StringSeqRequest)
    check dec.isOk()
    check dec.value.items == @["x-0", "x-1", "x-2"]

    let evt = waitForEvent("string_seq_event")
    check evt.len > 0
    let evtDec = cborDecode(evt, StringSeqEvent)
    check evtDec.isOk()
    check evtDec.value.items.len == 3

    discard typemappingtestlib_cbor_shutdown(ctx)

  test "seq[int64] result + matching event":
    resetSlots()
    let ctx = setupCtx()
    discard subscribe(ctx, "prim_seq_event")
    type Args = object
      n*: int32

    let (st, resp) = callApi(ctx, "prim_seq_request", cborEncode(Args(n: 4)).value)
    check st == 0'i32
    let dec = cborDecodeResultEnvelope(resp, PrimSeqRequest)
    check dec.isOk()
    check dec.value.values == @[0'i64, 10, 20, 30]

    let evt = waitForEvent("prim_seq_event")
    check evt.len > 0

    discard typemappingtestlib_cbor_shutdown(ctx)

  test "array[4, int32] result + matching event":
    resetSlots()
    let ctx = setupCtx()
    discard subscribe(ctx, "fixed_array_event")
    type Args = object
      seed*: int32

    let (st, resp) =
      callApi(ctx, "fixed_array_request", cborEncode(Args(seed: 5)).value)
    check st == 0'i32
    let dec = cborDecodeResultEnvelope(resp, FixedArrayRequest)
    check dec.isOk()
    check dec.value.values == [5'i32, 10, 15, 20]
    check int64(dec.value.ts) == 5'i64

    let evt = waitForEvent("fixed_array_event")
    check evt.len > 0

    discard typemappingtestlib_cbor_shutdown(ctx)

  test "array[ConstArrayLen, int32] result":
    resetSlots()
    let ctx = setupCtx()
    type Args = object
      seed*: int32

    let (st, resp) =
      callApi(ctx, "const_array_request", cborEncode(Args(seed: 3)).value)
    check st == 0'i32
    let dec = cborDecodeResultEnvelope(resp, ConstArrayRequest)
    check dec.isOk()
    check dec.value.values == [3'i32, 6, 9, 12, 15, 18]
    discard typemappingtestlib_cbor_shutdown(ctx)

  test "seq[Tag] result + tag_seq event":
    resetSlots()
    let ctx = setupCtx()
    discard subscribe(ctx, "tag_seq_event")
    type Args = object
      n*: int32

    let (st, resp) =
      callApi(ctx, "obj_seq_result_request", cborEncode(Args(n: 2)).value)
    check st == 0'i32
    let dec = cborDecodeResultEnvelope(resp, ObjSeqResultRequest)
    check dec.isOk()
    check dec.value.tags.len == 2
    check dec.value.tags[0] == Tag(key: "key-0", value: "val-0")

    let evt = waitForEvent("tag_seq_event")
    check evt.len > 0

    discard typemappingtestlib_cbor_shutdown(ctx)

  test "seq[Tag] INPUT param":
    resetSlots()
    let ctx = setupCtx()
    type Args = object
      tags*: seq[Tag]

    let args =
      Args(tags: @[Tag(key: "alpha", value: "1"), Tag(key: "beta", value: "2")])
    let (st, resp) = callApi(ctx, "obj_seq_param_request", cborEncode(args).value)
    check st == 0'i32
    let dec = cborDecodeResultEnvelope(resp, ObjSeqParamRequest)
    check dec.isOk()
    check dec.value.count == 2
    check dec.value.first == "alpha"
    discard typemappingtestlib_cbor_shutdown(ctx)

  test "seq[string] INPUT param":
    resetSlots()
    let ctx = setupCtx()
    type Args = object
      items*: seq[string]

    let (st, resp) = callApi(
      ctx, "seq_string_param_request", cborEncode(Args(items: @["a", "b", "c"])).value
    )
    check st == 0'i32
    let dec = cborDecodeResultEnvelope(resp, SeqStringParamRequest)
    check dec.isOk()
    check dec.value.count == 3
    check dec.value.joined == "a,b,c"
    discard typemappingtestlib_cbor_shutdown(ctx)

  test "seq[int64] INPUT param":
    resetSlots()
    let ctx = setupCtx()
    type Args = object
      values*: seq[int64]

    let (st, resp) = callApi(
      ctx, "prim_seq_param_request", cborEncode(Args(values: @[1'i64, 2, 3, 4])).value
    )
    check st == 0'i32
    let dec = cborDecodeResultEnvelope(resp, PrimSeqParamRequest)
    check dec.isOk()
    check dec.value.count == 4
    check dec.value.total == 10
    discard typemappingtestlib_cbor_shutdown(ctx)

  test "counter request emits counter_changed":
    resetSlots()
    let ctx = setupCtx()
    discard subscribe(ctx, "counter_changed")
    let (st, _) = callApi(ctx, "counter_request", @[])
    check st == 0'i32
    let evt = waitForEvent("counter_changed")
    check evt.len > 0
    let dec = cborDecode(evt, CounterChanged)
    check dec.isOk()
    check dec.value.value == 1'i32
    discard typemappingtestlib_cbor_shutdown(ctx)
