## typemappingtestlib_cbor — CBOR FFI mirror of typemappingtestlib
## ===============================================================
## Same Nim type matrix as the native counterpart, exercised through
## the CBOR FFI strategy (-d:BrokerFfiApi -d:BrokerFfiApiCBOR). The
## tests in test_typemappingtestlib_cbor*.{nim,py,cpp} drive this
## library via `<lib>_call` / `<lib>_subscribe` and assert the round
## trips match the native lib's behaviour byte-for-byte at the
## semantic level.
##
## Type coverage:
##   Scalars:        bool, int32, int64, float64, string
##   Enums:          Priority
##   Distinct:       JobId (distinct int32), Timestamp (distinct int64)
##   seq results:    seq[byte], seq[string], seq[int64], seq[Tag]
##   seq params:     seq[Tag], seq[string], seq[int64]
##   array results:  array[4, int32], array[ConstArrayLen, int32]
##   Event fields:   all of the above
##
## Build (from repo root):
##   nimble buildTypeMapTestLibCbor

{.push raises: [].}

import results
import brokers/[event_broker, request_broker, broker_context, api_library]

# ---------------------------------------------------------------------------
# Shared types
# ---------------------------------------------------------------------------

type Priority* = enum
  pLow = 0
  pMedium = 1
  pHigh = 2
  pCritical = 3

type JobId* = distinct int32
type Timestamp* = distinct int64

type Tag* = object
  key*: string
  value*: string

const ConstArrayLen* = 6

# ---------------------------------------------------------------------------
# Request brokers — original
# ---------------------------------------------------------------------------

RequestBroker(API):
  type InitializeRequest = object
    label*: string

  proc signature*(label: string): Future[Result[InitializeRequest, string]] {.async.}

RequestBroker(API):
  type ShutdownRequest = object
    status*: int32

  proc signature*(): Future[Result[ShutdownRequest, string]] {.async.}

RequestBroker(API):
  type EchoRequest = object
    reply*: string

  proc signature*(message: string): Future[Result[EchoRequest, string]] {.async.}

RequestBroker(API):
  type CounterRequest = object
    value*: int32

  proc signature*(): Future[Result[CounterRequest, string]] {.async.}

# ---------------------------------------------------------------------------
# Request brokers — extended scalar coverage
# ---------------------------------------------------------------------------

RequestBroker(API):
  type PrimScalarRequest = object
    flag*: bool
    i32*: int32
    i64*: int64
    f64*: float64

  proc signature*(
    flag: bool, i32: int32, i64: int64, f64: float64
  ): Future[Result[PrimScalarRequest, string]] {.async.}

RequestBroker(API):
  type TypedScalarRequest = object
    priority*: Priority
    jobId*: JobId
    nextId*: JobId

  proc signature*(
    priority: Priority, jobId: JobId
  ): Future[Result[TypedScalarRequest, string]] {.async.}

# ---------------------------------------------------------------------------
# Request brokers — seq[T] result coverage
# ---------------------------------------------------------------------------

RequestBroker(API):
  type ByteSeqRequest = object
    data*: seq[byte]

  proc signature*(size: int32): Future[Result[ByteSeqRequest, string]] {.async.}

RequestBroker(API):
  type StringSeqRequest = object
    items*: seq[string]

  proc signature*(
    prefix: string, n: int32
  ): Future[Result[StringSeqRequest, string]] {.async.}

RequestBroker(API):
  type PrimSeqRequest = object
    values*: seq[int64]

  proc signature*(n: int32): Future[Result[PrimSeqRequest, string]] {.async.}

RequestBroker(API):
  type FixedArrayRequest = object
    values*: array[4, int32]
    ts*: Timestamp

  proc signature*(seed: int32): Future[Result[FixedArrayRequest, string]] {.async.}

RequestBroker(API):
  type ConstArrayRequest = object
    values*: array[ConstArrayLen, int32]

  proc signature*(seed: int32): Future[Result[ConstArrayRequest, string]] {.async.}

EventBroker(API):
  type ConstArrayEvent = object
    values*: array[ConstArrayLen, int32]

RequestBroker(API):
  type ObjSeqResultRequest = object
    tags*: seq[Tag]

  proc signature*(n: int32): Future[Result[ObjSeqResultRequest, string]] {.async.}

RequestBroker(API):
  type TagSeqRequest = object
    count*: int32

  proc signature*(n: int32): Future[Result[TagSeqRequest, string]] {.async.}

# ---------------------------------------------------------------------------
# Request brokers — seq[T] / seq[object] INPUT param coverage
# ---------------------------------------------------------------------------

RequestBroker(API):
  type ObjSeqParamRequest = object
    count*: int32
    first*: string

  proc signature*(tags: seq[Tag]): Future[Result[ObjSeqParamRequest, string]] {.async.}

RequestBroker(API):
  type SeqStringParamRequest = object
    count*: int32
    joined*: string

  proc signature*(
    items: seq[string]
  ): Future[Result[SeqStringParamRequest, string]] {.async.}

RequestBroker(API):
  type PrimSeqParamRequest = object
    count*: int32
    total*: int64

  proc signature*(
    values: seq[int64]
  ): Future[Result[PrimSeqParamRequest, string]] {.async.}

# ---------------------------------------------------------------------------
# Event brokers
# ---------------------------------------------------------------------------

EventBroker(API):
  type CounterChanged = object
    value*: int32

EventBroker(API):
  type PrimScalarEvent = object
    flag*: bool
    i32*: int32
    i64*: int64
    f64*: float64

EventBroker(API):
  type TypedScalarEvent = object
    priority*: Priority
    jobId*: JobId
    ts*: Timestamp

EventBroker(API):
  type StringSeqEvent = object
    items*: seq[string]

EventBroker(API):
  type PrimSeqEvent = object
    values*: seq[int64]

EventBroker(API):
  type FixedArrayEvent = object
    values*: array[4, int32]

EventBroker(API):
  type TagSeqEvent = object
    tags*: seq[Tag]

# ---------------------------------------------------------------------------
# Provider state (per processing thread = per context)
# ---------------------------------------------------------------------------

var gLabel {.threadvar.}: string
var gCounter {.threadvar.}: int32
var gProviderCtx {.threadvar.}: BrokerContext

proc setupProviders(ctx: BrokerContext): Result[void, string] =
  gProviderCtx = ctx
  gCounter = 0
  gLabel = ""

  proc initProv(label: string): Future[Result[InitializeRequest, string]] {.async.} =
    gLabel = label
    return ok(InitializeRequest(label: label))

  ?InitializeRequest.setProvider(ctx, initProv)

  proc shutProv(): Future[Result[ShutdownRequest, string]] {.async.} =
    return ok(ShutdownRequest(status: 0))

  ?ShutdownRequest.setProvider(ctx, shutProv)

  proc echoProv(message: string): Future[Result[EchoRequest, string]] {.async.} =
    return ok(EchoRequest(reply: gLabel & ":" & message))

  ?EchoRequest.setProvider(ctx, echoProv)

  proc counterProv(): Future[Result[CounterRequest, string]] {.async.} =
    inc gCounter
    await CounterChanged.emit(gProviderCtx, CounterChanged(value: gCounter))
    return ok(CounterRequest(value: gCounter))

  ?CounterRequest.setProvider(ctx, counterProv)

  proc primScalarProv(
      flag: bool, i32: int32, i64: int64, f64: float64
  ): Future[Result[PrimScalarRequest, string]] {.async.} =
    await PrimScalarEvent.emit(
      gProviderCtx, PrimScalarEvent(flag: flag, i32: i32, i64: i64, f64: f64)
    )
    return ok(PrimScalarRequest(flag: flag, i32: i32, i64: i64, f64: f64))

  ?PrimScalarRequest.setProvider(ctx, primScalarProv)

  proc typedScalarProv(
      priority: Priority, jobId: JobId
  ): Future[Result[TypedScalarRequest, string]] {.async.} =
    let nextId = JobId(int32(jobId) + 1'i32)
    await TypedScalarEvent.emit(
      gProviderCtx,
      TypedScalarEvent(
        priority: priority, jobId: jobId, ts: Timestamp(int64(int32(jobId)) * 10'i64)
      ),
    )
    return ok(TypedScalarRequest(priority: priority, jobId: jobId, nextId: nextId))

  ?TypedScalarRequest.setProvider(ctx, typedScalarProv)

  proc byteSeqProv(size: int32): Future[Result[ByteSeqRequest, string]] {.async.} =
    var data = newSeq[byte](int(size))
    for i in 0 ..< int(size):
      data[i] = byte(i mod 256)
    return ok(ByteSeqRequest(data: data))

  ?ByteSeqRequest.setProvider(ctx, byteSeqProv)

  proc stringSeqProv(
      prefix: string, n: int32
  ): Future[Result[StringSeqRequest, string]] {.async.} =
    var items: seq[string] = @[]
    for i in 0 ..< int(n):
      items.add(prefix & "-" & $i)
    await StringSeqEvent.emit(gProviderCtx, StringSeqEvent(items: items))
    return ok(StringSeqRequest(items: items))

  ?StringSeqRequest.setProvider(ctx, stringSeqProv)

  proc primSeqProv(n: int32): Future[Result[PrimSeqRequest, string]] {.async.} =
    var values: seq[int64] = @[]
    for i in 0 ..< int(n):
      values.add(int64(i) * 10'i64)
    await PrimSeqEvent.emit(gProviderCtx, PrimSeqEvent(values: values))
    return ok(PrimSeqRequest(values: values))

  ?PrimSeqRequest.setProvider(ctx, primSeqProv)

  proc fixedArrayProv(
      seed: int32
  ): Future[Result[FixedArrayRequest, string]] {.async.} =
    let vals: array[4, int32] = [seed, seed * 2'i32, seed * 3'i32, seed * 4'i32]
    await FixedArrayEvent.emit(gProviderCtx, FixedArrayEvent(values: vals))
    return ok(FixedArrayRequest(values: vals, ts: Timestamp(int64(seed))))

  ?FixedArrayRequest.setProvider(ctx, fixedArrayProv)

  proc constArrayProv(
      seed: int32
  ): Future[Result[ConstArrayRequest, string]] {.async.} =
    var vals: array[ConstArrayLen, int32]
    for i in 0 ..< ConstArrayLen:
      vals[i] = seed * int32(i + 1)
    await ConstArrayEvent.emit(gProviderCtx, ConstArrayEvent(values: vals))
    return ok(ConstArrayRequest(values: vals))

  ?ConstArrayRequest.setProvider(ctx, constArrayProv)

  proc objSeqResultProv(
      n: int32
  ): Future[Result[ObjSeqResultRequest, string]] {.async.} =
    var tags: seq[Tag] = @[]
    for i in 0 ..< int(n):
      tags.add(Tag(key: "key-" & $i, value: "val-" & $i))
    await TagSeqEvent.emit(gProviderCtx, TagSeqEvent(tags: tags))
    return ok(ObjSeqResultRequest(tags: tags))

  ?ObjSeqResultRequest.setProvider(ctx, objSeqResultProv)

  proc tagSeqProv(n: int32): Future[Result[TagSeqRequest, string]] {.async.} =
    var tags: seq[Tag] = @[]
    for i in 0 ..< int(n):
      tags.add(Tag(key: "tag-key-" & $i, value: "tag-val-" & $i))
    await TagSeqEvent.emit(gProviderCtx, TagSeqEvent(tags: tags))
    return ok(TagSeqRequest(count: int32(tags.len)))

  ?TagSeqRequest.setProvider(ctx, tagSeqProv)

  proc objSeqParamProv(
      tags: seq[Tag]
  ): Future[Result[ObjSeqParamRequest, string]] {.async.} =
    let first =
      if tags.len > 0:
        tags[0].key
      else:
        ""
    return ok(ObjSeqParamRequest(count: int32(tags.len), first: first))

  ?ObjSeqParamRequest.setProvider(ctx, objSeqParamProv)

  proc seqStringParamProv(
      items: seq[string]
  ): Future[Result[SeqStringParamRequest, string]] {.async.} =
    var joined = ""
    for i, s in items:
      if i > 0:
        joined.add(",")
      joined.add(s)
    return ok(SeqStringParamRequest(count: int32(items.len), joined: joined))

  ?SeqStringParamRequest.setProvider(ctx, seqStringParamProv)

  proc primSeqParamProv(
      values: seq[int64]
  ): Future[Result[PrimSeqParamRequest, string]] {.async.} =
    var total: int64 = 0
    for v in values:
      total += v
    return ok(PrimSeqParamRequest(count: int32(values.len), total: total))

  ?PrimSeqParamRequest.setProvider(ctx, primSeqParamProv)

  return ok()

# ---------------------------------------------------------------------------
# Library registration
# ---------------------------------------------------------------------------

registerBrokerLibrary:
  name:
    "typemappingtestlib_cbor"
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest

{.pop.}
