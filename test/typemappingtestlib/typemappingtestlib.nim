## typemappingtestlib — API test library for C/C++/Python binding validation
## =========================================================================
## Exercises every Nim→C→C++/Python type mapping through request params,
## request results, and event callback fields.
##
## Type coverage:
##   Scalars:        bool, int32, int64, float64, string
##   Enums:          Priority
##   Distinct:       JobId (distinct int32), Timestamp (distinct int64)
##   seq results:    seq[byte], seq[string], seq[int64], seq[Tag]
##   seq params:     seq[Tag] (seq[object]), seq[string], seq[int64]
##   array results:  array[4, int32], array[ConstArrayLen, int32] (const-defined size)
##   Event fields:   all of the above
##
## Build (from repo root):
##   nimble buildTypeMapTestLib

{.push raises: [].}

import brokers/[event_broker, request_broker, broker_context, api_library]

# ---------------------------------------------------------------------------
# Shared types — exercising enum, distinct, and seq[object]
# ---------------------------------------------------------------------------

## Priority — exercises enum type mapping (→ Python IntEnum).
type Priority* = enum
  pLow = 0
  pMedium = 1
  pHigh = 2
  pCritical = 3

## JobId — exercises distinct int32 mapping (→ Python int alias).
type JobId* = distinct int32

## Timestamp — exercises distinct int64 mapping (→ Python int alias).
type Timestamp* = distinct int64

## Tag — plain object used in seq[Tag] param and result tests.
type Tag* = object
  key*: string
  value*: string

## ConstArrayLen — exercises const-defined array size in FFI codegen.
const ConstArrayLen* = 6

# ---------------------------------------------------------------------------
# Request Brokers — original
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
# Request Brokers — extended scalar type coverage
# ---------------------------------------------------------------------------

## PrimScalarRequest: roundtrips bool + int32 + int64 + float64.
## Also emits a PrimScalarEvent with the same values.
RequestBroker(API):
  type PrimScalarRequest = object
    flag*: bool
    i32*: int32
    i64*: int64
    f64*: float64

  proc signature*(
    flag: bool, i32: int32, i64: int64, f64: float64
  ): Future[Result[PrimScalarRequest, string]] {.async.}

## TypedScalarRequest: roundtrips enum (Priority) and distinct (JobId).
## Returns nextId = jobId+1. Emits TypedScalarEvent.
RequestBroker(API):
  type TypedScalarRequest = object
    priority*: Priority
    jobId*: JobId
    nextId*: JobId

  proc signature*(
    priority: Priority, jobId: JobId
  ): Future[Result[TypedScalarRequest, string]] {.async.}

# ---------------------------------------------------------------------------
# Request Brokers — seq[T] result coverage
# ---------------------------------------------------------------------------

## ByteSeqRequest: returns seq[byte] with values [0, 1, …, size-1 mod 256].
RequestBroker(API):
  type ByteSeqRequest = object
    data*: seq[byte]

  proc signature*(size: int32): Future[Result[ByteSeqRequest, string]] {.async.}

## StringSeqRequest: returns seq[string] ["prefix-0", …, "prefix-(n-1)"].
## Also emits StringSeqEvent with the same items.
RequestBroker(API):
  type StringSeqRequest = object
    items*: seq[string]

  proc signature*(
    prefix: string, n: int32
  ): Future[Result[StringSeqRequest, string]] {.async.}

## PrimSeqRequest: returns seq[int64] [0, 10, 20, …, (n-1)*10].
## Also emits PrimSeqEvent with the same values.
RequestBroker(API):
  type PrimSeqRequest = object
    values*: seq[int64]

  proc signature*(n: int32): Future[Result[PrimSeqRequest, string]] {.async.}

## FixedArrayRequest: returns array[4, int32] = [seed, seed*2, seed*3, seed*4]
## and Timestamp = Timestamp(seed). Also emits FixedArrayEvent.
RequestBroker(API):
  type FixedArrayRequest = object
    values*: array[4, int32]
    ts*: Timestamp

  proc signature*(seed: int32): Future[Result[FixedArrayRequest, string]] {.async.}

## ConstArrayRequest: returns array[ConstArrayLen, int32] = [seed*1 .. seed*ConstArrayLen].
## Exercises const-defined array size in FFI codegen (nnkIdent path of arrayNodeSize).
RequestBroker(API):
  type ConstArrayRequest = object
    values*: array[ConstArrayLen, int32]

  proc signature*(seed: int32): Future[Result[ConstArrayRequest, string]] {.async.}

## ConstArrayEvent: array[ConstArrayLen, int32] in callback field (same const path).
EventBroker(API):
  type ConstArrayEvent = object
    values*: array[ConstArrayLen, int32]

## ObjSeqResultRequest: returns seq[Tag] with n entries (key-i / val-i).
RequestBroker(API):
  type ObjSeqResultRequest = object
    tags*: seq[Tag]

  proc signature*(n: int32): Future[Result[ObjSeqResultRequest, string]] {.async.}

## TagSeqRequest: triggers TagSeqEvent (seq[object] with string fields).
## Returns count of tags emitted.
RequestBroker(API):
  type TagSeqRequest = object
    count*: int32

  proc signature*(n: int32): Future[Result[TagSeqRequest, string]] {.async.}

# ---------------------------------------------------------------------------
# Request Brokers — seq[T] and seq[object] INPUT param coverage
# ---------------------------------------------------------------------------

## ObjSeqParamRequest: takes seq[Tag] as INPUT param.
## Returns count = len(tags) and first = tags[0].key (or "" if empty).
RequestBroker(API):
  type ObjSeqParamRequest = object
    count*: int32
    first*: string

  proc signature*(tags: seq[Tag]): Future[Result[ObjSeqParamRequest, string]] {.async.}

## SeqStringParamRequest: takes seq[string] as INPUT param.
## Returns count = len(items) and joined = items joined with ",".
RequestBroker(API):
  type SeqStringParamRequest = object
    count*: int32
    joined*: string

  proc signature*(
    items: seq[string]
  ): Future[Result[SeqStringParamRequest, string]] {.async.}

## PrimSeqParamRequest: takes seq[int64] as INPUT param.
## Returns count = len(values) and total = sum(values).
RequestBroker(API):
  type PrimSeqParamRequest = object
    count*: int32
    total*: int64

  proc signature*(
    values: seq[int64]
  ): Future[Result[PrimSeqParamRequest, string]] {.async.}

# ---------------------------------------------------------------------------
# Event Brokers — original
# ---------------------------------------------------------------------------

EventBroker(API):
  type CounterChanged = object
    value*: int32

# ---------------------------------------------------------------------------
# Event Brokers — extended type coverage
# ---------------------------------------------------------------------------

## PrimScalarEvent: bool + int32 + int64 + float64 in callback fields.
EventBroker(API):
  type PrimScalarEvent = object
    flag*: bool
    i32*: int32
    i64*: int64
    f64*: float64

## TypedScalarEvent: enum (Priority) + distinct (JobId, Timestamp) in callback.
EventBroker(API):
  type TypedScalarEvent = object
    priority*: Priority
    jobId*: JobId
    ts*: Timestamp

## StringSeqEvent: seq[string] in callback field.
EventBroker(API):
  type StringSeqEvent = object
    items*: seq[string]

## PrimSeqEvent: seq[int64] (seq[primitive]) in callback field.
EventBroker(API):
  type PrimSeqEvent = object
    values*: seq[int64]

## FixedArrayEvent: array[4, int32] in callback field.
EventBroker(API):
  type FixedArrayEvent = object
    values*: array[4, int32]

## TagSeqEvent: seq[Tag] (seq[object] with string fields) in callback field.
## Exercises the CItem string allocation/free path in event callbacks.
EventBroker(API):
  type TagSeqEvent = object
    tags*: seq[Tag]

# ---------------------------------------------------------------------------
# Provider state (per processing thread = per context)
# ---------------------------------------------------------------------------

var gLabel {.threadvar.}: string
var gCounter {.threadvar.}: int32
var gProviderCtx {.threadvar.}: BrokerContext

proc setupProviders(ctx: BrokerContext) =
  gProviderCtx = ctx
  gCounter = 0
  gLabel = ""

  # --- Original providers ---

  discard InitializeRequest.setProvider(
    ctx,
    proc(label: string): Future[Result[InitializeRequest, string]] {.closure, async.} =
      gLabel = label
      return ok(InitializeRequest(label: label)),
  )

  discard ShutdownRequest.setProvider(
    ctx,
    proc(): Future[Result[ShutdownRequest, string]] {.closure, async.} =
      return ok(ShutdownRequest(status: 0)),
  )

  discard EchoRequest.setProvider(
    ctx,
    proc(message: string): Future[Result[EchoRequest, string]] {.closure, async.} =
      return ok(EchoRequest(reply: gLabel & ":" & message)),
  )

  discard CounterRequest.setProvider(
    ctx,
    proc(): Future[Result[CounterRequest, string]] {.closure, async.} =
      inc gCounter
      await CounterChanged.emit(gProviderCtx, CounterChanged(value: gCounter))
      return ok(CounterRequest(value: gCounter)),
  )

  # --- Scalar type providers ---

  discard PrimScalarRequest.setProvider(
    ctx,
    proc(
        flag: bool, i32: int32, i64: int64, f64: float64
    ): Future[Result[PrimScalarRequest, string]] {.closure, async.} =
      await PrimScalarEvent.emit(
        gProviderCtx, PrimScalarEvent(flag: flag, i32: i32, i64: i64, f64: f64)
      )
      return ok(PrimScalarRequest(flag: flag, i32: i32, i64: i64, f64: f64)),
  )

  discard TypedScalarRequest.setProvider(
    ctx,
    proc(
        priority: Priority, jobId: JobId
    ): Future[Result[TypedScalarRequest, string]] {.closure, async.} =
      let nextId = JobId(int32(jobId) + 1'i32)
      await TypedScalarEvent.emit(
        gProviderCtx,
        TypedScalarEvent(
          priority: priority, jobId: jobId, ts: Timestamp(int64(int32(jobId)) * 10'i64)
        ),
      )
      return ok(TypedScalarRequest(priority: priority, jobId: jobId, nextId: nextId)),
  )

  # --- seq[T] result providers ---

  discard ByteSeqRequest.setProvider(
    ctx,
    proc(size: int32): Future[Result[ByteSeqRequest, string]] {.closure, async.} =
      var data = newSeq[byte](int(size))
      for i in 0 ..< int(size):
        data[i] = byte(i mod 256)
      return ok(ByteSeqRequest(data: data)),
  )

  discard StringSeqRequest.setProvider(
    ctx,
    proc(
        prefix: string, n: int32
    ): Future[Result[StringSeqRequest, string]] {.closure, async.} =
      var items: seq[string] = @[]
      for i in 0 ..< int(n):
        items.add(prefix & "-" & $i)
      await StringSeqEvent.emit(gProviderCtx, StringSeqEvent(items: items))
      return ok(StringSeqRequest(items: items)),
  )

  discard PrimSeqRequest.setProvider(
    ctx,
    proc(n: int32): Future[Result[PrimSeqRequest, string]] {.closure, async.} =
      var values: seq[int64] = @[]
      for i in 0 ..< int(n):
        values.add(int64(i) * 10'i64)
      await PrimSeqEvent.emit(gProviderCtx, PrimSeqEvent(values: values))
      return ok(PrimSeqRequest(values: values)),
  )

  discard FixedArrayRequest.setProvider(
    ctx,
    proc(seed: int32): Future[Result[FixedArrayRequest, string]] {.closure, async.} =
      let vals: array[4, int32] = [seed, seed * 2'i32, seed * 3'i32, seed * 4'i32]
      await FixedArrayEvent.emit(gProviderCtx, FixedArrayEvent(values: vals))
      return ok(FixedArrayRequest(values: vals, ts: Timestamp(int64(seed)))),
  )

  discard ConstArrayRequest.setProvider(
    ctx,
    proc(seed: int32): Future[Result[ConstArrayRequest, string]] {.closure, async.} =
      var vals: array[ConstArrayLen, int32]
      for i in 0 ..< ConstArrayLen:
        vals[i] = seed * int32(i + 1)
      await ConstArrayEvent.emit(gProviderCtx, ConstArrayEvent(values: vals))
      return ok(ConstArrayRequest(values: vals)),
  )

  discard ObjSeqResultRequest.setProvider(
    ctx,
    proc(n: int32): Future[Result[ObjSeqResultRequest, string]] {.closure, async.} =
      var tags: seq[Tag] = @[]
      for i in 0 ..< int(n):
        tags.add(Tag(key: "key-" & $i, value: "val-" & $i))
      await TagSeqEvent.emit(gProviderCtx, TagSeqEvent(tags: tags))
      return ok(ObjSeqResultRequest(tags: tags)),
  )

  # --- TagSeqRequest: triggers TagSeqEvent (seq[object] with strings) ---
  discard TagSeqRequest.setProvider(
    ctx,
    proc(n: int32): Future[Result[TagSeqRequest, string]] {.closure, async.} =
      var tags: seq[Tag] = @[]
      for i in 0 ..< int(n):
        tags.add(Tag(key: "tag-key-" & $i, value: "tag-val-" & $i))
      await TagSeqEvent.emit(gProviderCtx, TagSeqEvent(tags: tags))
      return ok(TagSeqRequest(count: int32(tags.len))),
  )

  # --- seq[T] input param providers ---

  discard ObjSeqParamRequest.setProvider(
    ctx,
    proc(
        tags: seq[Tag]
    ): Future[Result[ObjSeqParamRequest, string]] {.closure, async.} =
      let first =
        if tags.len > 0:
          tags[0].key
        else:
          ""
      return ok(ObjSeqParamRequest(count: int32(tags.len), first: first)),
  )

  discard SeqStringParamRequest.setProvider(
    ctx,
    proc(
        items: seq[string]
    ): Future[Result[SeqStringParamRequest, string]] {.closure, async.} =
      var joined = ""
      for i, s in items:
        if i > 0:
          joined.add(",")
        joined.add(s)
      return ok(SeqStringParamRequest(count: int32(items.len), joined: joined)),
  )

  discard PrimSeqParamRequest.setProvider(
    ctx,
    proc(
        values: seq[int64]
    ): Future[Result[PrimSeqParamRequest, string]] {.closure, async.} =
      var total: int64 = 0
      for v in values:
        total += v
      return ok(PrimSeqParamRequest(count: int32(values.len), total: total)),
  )

# ---------------------------------------------------------------------------
# Library registration
# ---------------------------------------------------------------------------

registerBrokerLibrary:
  name:
    "typemappingtestlib"
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest
