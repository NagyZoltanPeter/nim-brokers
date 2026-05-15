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
import ./typemappingtestlib

# ---------------------------------------------------------------------------
# C-export wrappers (FFI gate)
# ---------------------------------------------------------------------------

proc copyToCBuffer(bytes: openArray[byte]): pointer =
  result = typemappingtestlib_allocBuffer(int32(bytes.len))
  if bytes.len > 0:
    copyMem(result, unsafeAddr bytes[0], bytes.len)

proc takeBuf(buf: pointer, len: int32): seq[byte] =
  if buf.isNil or len <= 0:
    return @[]
  result = newSeq[byte](len.int)
  copyMem(addr result[0], buf, len.int)
  typemappingtestlib_freeBuffer(buf)

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
  let status = typemappingtestlib_call(
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
  let c = typemappingtestlib_createContext(addr err)
  check c != 0'u32
  c

proc subscribe(ctx: uint32, eventName: string): uint64 =
  typemappingtestlib_subscribe(ctx, eventName.cstring, captureCb, nil)

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

    discard typemappingtestlib_shutdown(ctx)

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

    discard typemappingtestlib_shutdown(ctx)

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

    discard typemappingtestlib_shutdown(ctx)

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

    discard typemappingtestlib_shutdown(ctx)

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
    discard typemappingtestlib_shutdown(ctx)

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

    discard typemappingtestlib_shutdown(ctx)

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

    discard typemappingtestlib_shutdown(ctx)

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

    discard typemappingtestlib_shutdown(ctx)

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
    discard typemappingtestlib_shutdown(ctx)

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

    discard typemappingtestlib_shutdown(ctx)

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
    discard typemappingtestlib_shutdown(ctx)

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
    discard typemappingtestlib_shutdown(ctx)

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
    discard typemappingtestlib_shutdown(ctx)

  test "Option[string] result — present + absent (OptStringRequest)":
    # Phase E2a — variable-shape Option (string).
    resetSlots()
    let ctx = setupCtx()
    type Args = object
      present*: bool

    let (st, resp) =
      callApi(ctx, "opt_string_request", cborEncode(Args(present: true)).value)
    check st == 0'i32
    let dec = cborDecodeResultEnvelope(resp, OptStringRequest)
    check dec.isOk()
    check dec.value.value.isSome()
    check dec.value.value.get() == "hello"

    let (st2, resp2) =
      callApi(ctx, "opt_string_request", cborEncode(Args(present: false)).value)
    check st2 == 0'i32
    let dec2 = cborDecodeResultEnvelope(resp2, OptStringRequest)
    check dec2.isOk()
    check dec2.value.value.isNone()
    discard typemappingtestlib_shutdown(ctx)

  test "Option[seq[byte]] result — present":
    # Probe for Option[T] over the FFI surface. Native codegen rejects
    # Option[T] outright; the broker is gated to CBOR mode.
    resetSlots()
    let ctx = setupCtx()
    type Args = object
      present*: bool

    let (st, resp) =
      callApi(ctx, "opt_seq_request", cborEncode(Args(present: true)).value)
    check st == 0'i32
    let dec = cborDecodeResultEnvelope(resp, OptSeqRequest)
    check dec.isOk()
    check dec.value.value.isSome()
    check dec.value.value.get() == @[byte 1, 2, 3, 4]
    discard typemappingtestlib_shutdown(ctx)

  test "Option[seq[byte]] result — absent":
    resetSlots()
    let ctx = setupCtx()
    type Args = object
      present*: bool

    let (st, resp) =
      callApi(ctx, "opt_seq_request", cborEncode(Args(present: false)).value)
    check st == 0'i32
    let dec = cborDecodeResultEnvelope(resp, OptSeqRequest)
    check dec.isOk()
    check dec.value.value.isNone()
    discard typemappingtestlib_shutdown(ctx)

  test "inbound seq[byte] byte-string round-trip (BytesEchoRequest)":
    # Wrappers must encode `seq[byte]` field VALUES as CBOR byte string;
    # this Nim-side test pins the provider's behaviour.
    resetSlots()
    let ctx = setupCtx()
    type Args = object
      payload*: seq[byte]

    let args = Args(payload: @[byte 10, 20, 30, 40, 50])
    let (st, resp) = callApi(ctx, "bytes_echo_request", cborEncode(args).value)
    check st == 0'i32
    let dec = cborDecodeResultEnvelope(resp, BytesEchoRequest)
    check dec.isOk()
    check dec.value.length == 5'i32
    check dec.value.first == 10'i32
    check dec.value.last == 50'i32

    let emptyArgs = Args(payload: @[])
    let (st2, resp2) = callApi(ctx, "bytes_echo_request", cborEncode(emptyArgs).value)
    check st2 == 0'i32
    let dec2 = cborDecodeResultEnvelope(resp2, BytesEchoRequest)
    check dec2.isOk()
    check dec2.value.length == 0'i32
    check dec2.value.first == -1'i32
    check dec2.value.last == -1'i32
    discard typemappingtestlib_shutdown(ctx)

  test "tuple-as-struct + distinct-over-seq + object-as-param round-trip (ScanRequest)":
    # Probes the tuple support pass: KeyRange (object input param),
    # Key (distinct seq[byte]), TupleRow (named tuple alias rendered
    # as struct), and ScanRequest.rows (seq[Tuple]).
    resetSlots()
    let ctx = setupCtx()
    type Args = object
      category*: string
      range*: KeyRange
      reverse*: bool

    let args = Args(
      category: "scan", range: KeyRange(startKey: "lo", stopKey: "hi"), reverse: false
    )
    let (st, resp) = callApi(ctx, "scan_request", cborEncode(args).value)
    check st == 0'i32
    let dec = cborDecodeResultEnvelope(resp, ScanRequest)
    check dec.isOk()
    check dec.value.rows.len == 3
    # Forward order: row[0].key starts with "0:", row[2].key starts with "2:".
    check dec.value.rows[0].key == "0:lo"
    check dec.value.rows[2].key == "2:lo"
    check dec.value.rows[0].payload == "scan-row-0:hi"

    # Reverse run — same rows, opposite order.
    let revArgs = Args(
      category: "scan", range: KeyRange(startKey: "lo", stopKey: "hi"), reverse: true
    )
    let (st2, resp2) = callApi(ctx, "scan_request", cborEncode(revArgs).value)
    check st2 == 0'i32
    let dec2 = cborDecodeResultEnvelope(resp2, ScanRequest)
    check dec2.isOk()
    check dec2.value.rows.len == 3
    check dec2.value.rows[0].key == "2:lo"
    check dec2.value.rows[2].key == "0:lo"
    discard typemappingtestlib_shutdown(ctx)

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
    discard typemappingtestlib_shutdown(ctx)

  # ===========================================================================
  # Round-trip matrix expansion (Phase 9A) — boundary / edge values
  # ===========================================================================

  test "rt.bool_false + int32/int64 boundaries":
    resetSlots()
    let ctx = setupCtx()
    type Args = object
      flag*: bool
      i32*: int32
      i64*: int64
      f64*: float64

    template roundtrip(args: Args, label: string): PrimScalarRequest =
      let (st, resp) = callApi(ctx, "prim_scalar_request", cborEncode(args).value)
      check st == 0'i32
      let dec = cborDecodeResultEnvelope(resp, PrimScalarRequest)
      check dec.isOk()
      dec.value

    let rFalse = roundtrip(Args(flag: false, i32: 0, i64: 0, f64: 0.0), "bool_false")
    check rFalse.flag == false
    let rI32Min =
      roundtrip(Args(flag: false, i32: int32.low, i64: 0, f64: 0.0), "int32_min")
    check rI32Min.i32 == int32.low
    let rI32Max =
      roundtrip(Args(flag: false, i32: int32.high, i64: 0, f64: 0.0), "int32_max")
    check rI32Max.i32 == int32.high
    let rI64Min =
      roundtrip(Args(flag: false, i32: 0, i64: int64.low, f64: 0.0), "int64_min")
    check rI64Min.i64 == int64.low
    let rI64Max =
      roundtrip(Args(flag: false, i32: 0, i64: int64.high, f64: 0.0), "int64_max")
    check rI64Max.i64 == int64.high
    let rPi = roundtrip(Args(flag: false, i32: 0, i64: 0, f64: 3.141592653589793), "pi")
    check rPi.f64 == 3.141592653589793

    discard typemappingtestlib_shutdown(ctx)

  test "rt.priority all values + jobId boundaries":
    resetSlots()
    let ctx = setupCtx()
    type Args = object
      priority*: Priority
      jobId*: JobId

    for p in [pLow, pMedium, pHigh, pCritical]:
      let (st, resp) = callApi(
        ctx,
        "typed_scalar_request",
        cborEncode(Args(priority: p, jobId: JobId(1))).value,
      )
      check st == 0'i32
      let dec = cborDecodeResultEnvelope(resp, TypedScalarRequest)
      check dec.isOk()
      check dec.value.priority == p

    let (st0, resp0) = callApi(
      ctx,
      "typed_scalar_request",
      cborEncode(Args(priority: pLow, jobId: JobId(0))).value,
    )
    check st0 == 0'i32
    let dec0 = cborDecodeResultEnvelope(resp0, TypedScalarRequest)
    check dec0.isOk()
    check int32(dec0.value.jobId) == 0'i32
    check int32(dec0.value.nextId) == 1'i32

    let (stB, respB) = callApi(
      ctx,
      "typed_scalar_request",
      cborEncode(Args(priority: pLow, jobId: JobId(int32.high - 1'i32))).value,
    )
    check stB == 0'i32
    let decB = cborDecodeResultEnvelope(respB, TypedScalarRequest)
    check decB.isOk()
    check int32(decB.value.nextId) == int32.high

    discard typemappingtestlib_shutdown(ctx)

  test "rt.byte_seq empty / single / wrap-around":
    resetSlots()
    let ctx = setupCtx()
    type Args = object
      size*: int32

    let (s0, r0) = callApi(ctx, "byte_seq_request", cborEncode(Args(size: 0)).value)
    check s0 == 0'i32
    let d0 = cborDecodeResultEnvelope(r0, ByteSeqRequest)
    check d0.isOk()
    check d0.value.data.len == 0

    let (s1, r1) = callApi(ctx, "byte_seq_request", cborEncode(Args(size: 1)).value)
    check s1 == 0'i32
    let d1 = cborDecodeResultEnvelope(r1, ByteSeqRequest)
    check d1.isOk()
    check d1.value.data == @[0'u8]

    let (sW, rW) = callApi(ctx, "byte_seq_request", cborEncode(Args(size: 260)).value)
    check sW == 0'i32
    let dW = cborDecodeResultEnvelope(rW, ByteSeqRequest)
    check dW.isOk()
    check dW.value.data.len == 260
    check dW.value.data[0] == 0'u8
    check dW.value.data[255] == 255'u8
    check dW.value.data[256] == 0'u8

    discard typemappingtestlib_shutdown(ctx)

  test "rt.string/seq result empty + special chars":
    resetSlots()
    let ctx = setupCtx()
    type Args = object
      prefix*: string
      n*: int32

    let (s0, r0) =
      callApi(ctx, "string_seq_request", cborEncode(Args(prefix: "x", n: 0)).value)
    check s0 == 0'i32
    let d0 = cborDecodeResultEnvelope(r0, StringSeqRequest)
    check d0.isOk()
    check d0.value.items.len == 0

    let (sS, rS) =
      callApi(ctx, "string_seq_request", cborEncode(Args(prefix: "a/b:c", n: 2)).value)
    check sS == 0'i32
    let dS = cborDecodeResultEnvelope(rS, StringSeqRequest)
    check dS.isOk()
    check dS.value.items == @["a/b:c-0", "a/b:c-1"]

    discard typemappingtestlib_shutdown(ctx)

  test "rt.fixed/const array seed=0/negative":
    resetSlots()
    let ctx = setupCtx()
    type FAArgs = object
      seed*: int32

    let (s0, r0) =
      callApi(ctx, "fixed_array_request", cborEncode(FAArgs(seed: 0)).value)
    check s0 == 0'i32
    let d0 = cborDecodeResultEnvelope(r0, FixedArrayRequest)
    check d0.isOk()
    check d0.value.values == [0'i32, 0, 0, 0]
    check int64(d0.value.ts) == 0'i64

    let (sN, rN) =
      callApi(ctx, "fixed_array_request", cborEncode(FAArgs(seed: -3)).value)
    check sN == 0'i32
    let dN = cborDecodeResultEnvelope(rN, FixedArrayRequest)
    check dN.isOk()
    check dN.value.values == [-3'i32, -6, -9, -12]

    let (sC, rC) =
      callApi(ctx, "const_array_request", cborEncode(FAArgs(seed: 0)).value)
    check sC == 0'i32
    let dC = cborDecodeResultEnvelope(rC, ConstArrayRequest)
    check dC.isOk()
    check dC.value.values == [0'i32, 0, 0, 0, 0, 0]

    discard typemappingtestlib_shutdown(ctx)

  test "rt.empty seq[] params and results":
    resetSlots()
    let ctx = setupCtx()
    # obj seq result empty
    type ObjArgs = object
      n*: int32

    let (sR, rR) =
      callApi(ctx, "obj_seq_result_request", cborEncode(ObjArgs(n: 0)).value)
    check sR == 0'i32
    let dR = cborDecodeResultEnvelope(rR, ObjSeqResultRequest)
    check dR.isOk()
    check dR.value.tags.len == 0

    # obj seq param empty
    type TagArgs = object
      tags*: seq[Tag]

    let (sT, rT) =
      callApi(ctx, "obj_seq_param_request", cborEncode(TagArgs(tags: @[])).value)
    check sT == 0'i32
    let dT = cborDecodeResultEnvelope(rT, ObjSeqParamRequest)
    check dT.isOk()
    check dT.value.count == 0
    check dT.value.first == ""

    # string seq param empty
    type StrArgs = object
      items*: seq[string]

    let (sS, rS) =
      callApi(ctx, "seq_string_param_request", cborEncode(StrArgs(items: @[])).value)
    check sS == 0'i32
    let dS = cborDecodeResultEnvelope(rS, SeqStringParamRequest)
    check dS.isOk()
    check dS.value.count == 0

    # prim seq param empty + single + large
    type PrmArgs = object
      values*: seq[int64]

    let (sE, rE) =
      callApi(ctx, "prim_seq_param_request", cborEncode(PrmArgs(values: @[])).value)
    check sE == 0'i32
    let dE = cborDecodeResultEnvelope(rE, PrimSeqParamRequest)
    check dE.isOk()
    check dE.value.count == 0
    check dE.value.total == 0'i64

    let (sP, rP) = callApi(
      ctx, "prim_seq_param_request", cborEncode(PrmArgs(values: @[42'i64])).value
    )
    check sP == 0'i32
    let dP = cborDecodeResultEnvelope(rP, PrimSeqParamRequest)
    check dP.isOk()
    check dP.value.total == 42'i64

    var big = newSeq[int64](100)
    var expected: int64 = 0
    for i in 0 ..< 100:
      big[i] = int64(i)
      expected += int64(i)
    let (sB, rB) =
      callApi(ctx, "prim_seq_param_request", cborEncode(PrmArgs(values: big)).value)
    check sB == 0'i32
    let dB = cborDecodeResultEnvelope(rB, PrimSeqParamRequest)
    check dB.isOk()
    check dB.value.count == 100'i32
    check dB.value.total == expected

    # string seq param unicode
    let (sU, rU) = callApi(
      ctx,
      "seq_string_param_request",
      cborEncode(StrArgs(items: @["héllo", "wörld"])).value,
    )
    check sU == 0'i32
    let dU = cborDecodeResultEnvelope(rU, SeqStringParamRequest)
    check dU.isOk()
    check dU.value.count == 2'i32
    check dU.value.joined == "héllo,wörld"

    discard typemappingtestlib_shutdown(ctx)
