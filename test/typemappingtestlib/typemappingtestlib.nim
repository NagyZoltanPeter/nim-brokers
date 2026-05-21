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

import std/options
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

## Inner — composite object used by the seq[Object<seq>] probes. The
## key trait is that it carries its OWN `seq[byte]` field, so a
## containing `seq[Inner]` exercises an inner object with a composite
## field — the shape TYPESUPPORT.md historically marked ❌ before the
## native ABI was retired.
type Inner* = object
  id*: int32
  tag*: string
  bytes*: seq[byte]

## Slot — used by the array[N, Object] event probe. Plain primitive +
## string fields; the point is putting it inside a fixed-size array
## payload (`array[4, Slot]`), not the field shape itself.
type Slot* = object
  idx*: int32
  name*: string

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

## DualSigRequest: same broker exposes BOTH a zero-arg and an N-arg
## signature. Each one becomes a separate C export plus a separate
## method on every language wrapper, with a suffix derived from the
## proc name (after the literal "signature" prefix). This covers the
## documented "two signatures in one broker" feature for every wrapper.
RequestBroker(API):
  type DualSigRequest = object
    label*: string
    counter*: int32

  proc signatureZero*(): Future[Result[DualSigRequest, string]] {.async.}
  proc signatureWithLabel*(
    label: string, bump: int32
  ): Future[Result[DualSigRequest, string]] {.async.}

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
# Request Brokers — primitive (non-object) result type coverage
# ---------------------------------------------------------------------------

## VoidActionRequest: the broker type IS `void` — a payload-less request.
## Exercises the `isVoid` codegen path: the response carries only a
## success/error signal, no value. The provider also emits a VoidPing event.
RequestBroker(API):
  type VoidActionRequest = void

  proc signature*(label: string): Future[Result[VoidActionRequest, string]] {.async.}

## VoidPing: a payload-less (`void`) API event — a pure notification.
EventBroker(API):
  type VoidPing = void

## IntResultRequest: the broker type IS a primitive (int32), not an object.
## Exercises the `hasInlineFields == false` request codegen path — the C
## result struct must carry the scalar value alongside `error_message`,
## and every wrapper must unwrap it as a bare `int32` rather than a struct.
## Provider returns value*2 and emits SimpleIntEvent(value*10).
RequestBroker(API):
  type IntResultRequest = int32

  proc signature*(value: int32): Future[Result[IntResultRequest, string]] {.async.}

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

## OptSeqRequest — Phase E2b, `Option[seq[byte]]` as a result field.
## At the C ABI this expands to THREE fields under Layout X:
##   `value: uint8_t*`, `value_count: int32_t`, `value_has_value: bool`.
## The bool is the source of truth for present/absent — not the
## (nullptr, 0) pattern. A present-but-empty seq is therefore
## distinguishable from an absent seq.
RequestBroker(API):
  type OptSeqRequest* = object
    value*: Option[seq[byte]]

  proc signature*(present: bool): Future[Result[OptSeqRequest, string]] {.async.}

## OptScalarRequest — exercises `Option[int32]` as a result field. Phase
## E1 of native Option support: every Option field expands at the C ABI
## to `<name>: T` + `<name>_has_value: bool` (uniform shape; documented
## in the codegen modules).
RequestBroker(API):
  type OptScalarRequest* = object
    value*: Option[int32]

  proc signature*(present: bool): Future[Result[OptScalarRequest, string]] {.async.}

## OptStringRequest — Phase E2a, variable-shape Option (string). At the C
## ABI the field expands to `value: char*` + `value_has_value: bool`.
## Layout X is uniform: the bool is always emitted even though `nullptr`
## could encode absent for pointer-shaped inner types — readers MUST
## consult `value_has_value` first; `value` is undefined when absent.
RequestBroker(API):
  type OptStringRequest* = object
    value*: Option[string]

  proc signature*(present: bool): Future[Result[OptStringRequest, string]] {.async.}

## OptObjRequest — Phase E3, Option of a registered object (`Option[Tag]`).
## Shape (iii): the inner object is embedded by value at the C ABI —
## `value: TagCItem` + `value_has_value: bool`. When absent the embedded
## CItem is zero-initialised (nil cstring fields); readers MUST consult
## `value_has_value` first.
RequestBroker(API):
  type OptObjRequest* = object
    value*: Option[Tag]

  proc signature*(present: bool): Future[Result[OptObjRequest, string]] {.async.}

## Distinct-over-seq probe. Registered by the type resolver to keep the
## `resolveAliasBase`-over-`nnkBracketExpr` path exercised at compile
## time, but NOT used in any active broker signature: per-wrapper
## byte-string tagging on the wire side (Rust `#[serde(with =
## "serde_bytes")]`, jsoncons byte-string trait, cbor2 bytes coercion)
## must propagate through distinct/alias before a round-trip with
## `Key`-typed fields can succeed. See the inbound-bytes probe
## (`BytesEchoRequest`) below for the byte-string round-trip support
## that exists today.
type Key* {.used.} = distinct seq[byte]

## KeyRange — plain object input param. Object-as-input-param is
## CBOR-only (see ObjParamRequest gating note above). Uses `string`
## rather than `seq[byte]` to keep the wire format uniformly text-string
## across every wrapper (per-wrapper byte-string handling for inbound
## binary fields is a follow-up task).
type KeyRange* = object
  startKey*: string ## inclusive lower bound
  stopKey*: string ## exclusive upper bound; empty = unbounded

## TupleRow — named tuple alias. Per agreed Option (B) the codegen
## emits this as a struct with the same field names in every wrapper.
type TupleRow* = tuple[key: string, payload: string]

RequestBroker(API):
  type ScanRequest* = object
    rows*: seq[TupleRow]

  proc signature*(
    category: string, range: KeyRange, reverse: bool
  ): Future[Result[ScanRequest, string]] {.async.}

## BytesEchoRequest — exercises `seq[byte]` as an INPUT param. The CBOR
## encoder uses major type 2 (byte string) so the Nim cbor_serialization
## decoder accepts it; per-wrapper byte-string handling has its own
## coverage downstream of the codegen.
RequestBroker(API):
  type BytesEchoRequest* = object
    length*: int32 ## number of bytes received
    first*: int32 ## payload[0] cast to int (-1 if empty)
    last*: int32 ## payload[^1] cast to int (-1 if empty)

  proc signature*(
    payload: seq[byte]
  ): Future[Result[BytesEchoRequest, string]] {.async.}

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

## ObjParamRequest: takes a single Tag (Object) as INPUT param — exercises
## whole-struct pass-by-value across the FFI surface. Returns "key=value".
RequestBroker(API):
  type ObjParamRequest = object
    summary*: string

  proc signature*(tag: Tag): Future[Result[ObjParamRequest, string]] {.async.}

# ---------------------------------------------------------------------------
# Previously-restricted shapes — now active CBOR brokers.
#
# These shapes were marked ❌ in TYPESUPPORT.md while the native ABI
# was in play (CItem layout couldn't express them, the C header
# emitted bare struct refs, etc.). Post Round-2 CBOR-only retirement
# the wrappers handle every one of these correctly — wire format is
# pure CBOR map/array nesting and each wrapper codegen recurses
# through seq[T] / array[N, T] / inline Object the same way. They
# now ride the parity matrix so any future regression is caught.
#
#   ListInnersRequest         seq[Object<seq>] as result          §1
#   BulkInnersRequest         seq[Object<seq>] as param           §2
#   InnersUpdatedEvent        seq[Object<seq>] as event payload   §3
#   FixedStrArrayRequest      array[N, string] as result          §1
#   SetTagsRequest            array[N, string] as param           §2
#   SumPrimArrayRequest       array[N, primitive] as param        §2
#   FixedObjArrayEvent        array[N, Object] as event payload   §3
# ---------------------------------------------------------------------------

## ListInnersRequest — returns seq[Inner], where each Inner carries
## its own seq[byte] (composite-field-in-element-of-seq). Producer
## echoes the requested count, fabricating bytes [i, i+1, …].
RequestBroker(API):
  type ListInnersRequest = object
    items*: seq[Inner]

  proc signature*(count: int32): Future[Result[ListInnersRequest, string]] {.async.}

## BulkInnersRequest — accepts seq[Inner] as input param, returns the
## sum of `id`s and total bytes-count for round-trip verification.
RequestBroker(API):
  type BulkInnersRequest = object
    idSum*: int64
    byteCount*: int64

  proc signature*(
    items: seq[Inner]
  ): Future[Result[BulkInnersRequest, string]] {.async.}

## InnersUpdatedEvent — event payload is seq[Inner]. Fired by
## TriggerInnersUpdatedRequest below.
EventBroker(API):
  type InnersUpdatedEvent = object
    items*: seq[Inner]

## TriggerInnersUpdatedRequest — invokes InnersUpdatedEvent.emit with
## a fabricated payload of N Inner records.
RequestBroker(API):
  type TriggerInnersUpdatedRequest = object
    fired*: int32

  proc signature*(
    count: int32
  ): Future[Result[TriggerInnersUpdatedRequest, string]] {.async.}

## FixedStrArrayRequest — returns array[4, string]. Element i is
## "<prefix>-<i>".
RequestBroker(API):
  type FixedStrArrayRequest = object
    tags*: array[4, string]

  proc signature*(
    prefix: string
  ): Future[Result[FixedStrArrayRequest, string]] {.async.}

## SetTagsRequest — accepts array[4, string] as input param, returns
## the concatenated joined-by-"|" form for round-trip verification.
RequestBroker(API):
  type SetTagsRequest = object
    joined*: string

  proc signature*(
    tags: array[4, string]
  ): Future[Result[SetTagsRequest, string]] {.async.}

## SumPrimArrayRequest — accepts array[4, int32] as input param,
## returns the sum.
RequestBroker(API):
  type SumPrimArrayRequest = object
    total*: int64

  proc signature*(
    nums: array[4, int32]
  ): Future[Result[SumPrimArrayRequest, string]] {.async.}

## FixedObjArrayEvent — event payload is array[4, Slot]. Fired by
## TriggerFixedObjArrayRequest below.
EventBroker(API):
  type FixedObjArrayEvent = object
    slots*: array[4, Slot]

## TriggerFixedObjArrayRequest — invokes FixedObjArrayEvent.emit with
## a fabricated 4-element payload.
RequestBroker(API):
  type TriggerFixedObjArrayRequest = object
    fired*: int32

  proc signature*(
    base: int32
  ): Future[Result[TriggerFixedObjArrayRequest, string]] {.async.}

# ---------------------------------------------------------------------------
# Closing the last ❓ cells in TYPESUPPORT.md (§1 row 8, §2 array-Object
# param, §3 array[N, string] event).
# ---------------------------------------------------------------------------

## NestedObjRequest — Object with a directly-inlined Object field
## (not via seq / array / Option). Closes §1 footnote 1: the bare
## inline-nested-Object shape. Holds a `Tag` directly + a label.
RequestBroker(API):
  type NestedObjRequest = object
    label*: string
    nested*: Tag

  proc signature*(
    key: string, value: string
  ): Future[Result[NestedObjRequest, string]] {.async.}

## SetSlotsRequest — accepts array[4, Slot] as input param. Closes §2
## footnote 5: array[N, Object] in the parameter direction (result +
## event already covered). Returns joined slot names for verification.
RequestBroker(API):
  type SetSlotsRequest = object
    summary*: string

  proc signature*(
    slots: array[4, Slot]
  ): Future[Result[SetSlotsRequest, string]] {.async.}

## StrArrayEvent — event payload is array[4, string]. Closes §3
## footnote 6: array[N, string] in the event direction. Fired by
## TriggerStrArrayRequest below.
EventBroker(API):
  type StrArrayEvent = object
    words*: array[4, string]

## TriggerStrArrayRequest — invokes StrArrayEvent.emit with a
## fabricated 4-string payload built from a caller-supplied prefix.
RequestBroker(API):
  type TriggerStrArrayRequest = object
    fired*: int32

  proc signature*(
    prefix: string
  ): Future[Result[TriggerStrArrayRequest, string]] {.async.}

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

## SimpleIntEvent: the event payload type IS a primitive (int64), not an
## object. Exercises the `hasInlineFields == false` event codegen path —
## the C callback typedef must carry a single scalar value parameter
## instead of a struct, and every wrapper must deliver a bare int64.
EventBroker(API):
  type SimpleIntEvent = int64

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

  # DualSigRequest — a broker with both a zero-arg and an N-arg signature.
  # Each provider serves its respective signature; both coexist on the same
  # broker type. The zero-arg variant returns the sentinel ("zero", 0); the
  # N-arg variant echoes the supplied label and bump.
  discard DualSigRequest.setProvider(
    ctx,
    proc(): Future[Result[DualSigRequest, string]] {.closure, async.} =
      return ok(DualSigRequest(label: "zero", counter: 0)),
  )
  discard DualSigRequest.setProvider(
    ctx,
    proc(
        label: string, bump: int32
    ): Future[Result[DualSigRequest, string]] {.closure, async.} =
      return ok(DualSigRequest(label: label, counter: bump)),
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

  # --- void (payload-less) request provider ---

  discard VoidActionRequest.setProvider(
    ctx,
    proc(label: string): Future[Result[VoidActionRequest, string]] {.closure, async.} =
      if label.len == 0:
        return err("empty label")
      await VoidPing.emit(gProviderCtx, VoidPing())
      return ok(VoidActionRequest()),
  )

  # --- primitive (non-object) result provider ---

  discard IntResultRequest.setProvider(
    ctx,
    proc(value: int32): Future[Result[IntResultRequest, string]] {.closure, async.} =
      await SimpleIntEvent.emit(gProviderCtx, SimpleIntEvent(int64(value) * 10'i64))
      return ok(IntResultRequest(value * 2'i32)),
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

  discard OptScalarRequest.setProvider(
    ctx,
    proc(present: bool): Future[Result[OptScalarRequest, string]] {.closure, async.} =
      if present:
        return ok(OptScalarRequest(value: some(42'i32)))
      else:
        return ok(OptScalarRequest(value: none(int32))),
  )

  discard OptStringRequest.setProvider(
    ctx,
    proc(present: bool): Future[Result[OptStringRequest, string]] {.closure, async.} =
      if present:
        return ok(OptStringRequest(value: some("hello")))
      else:
        return ok(OptStringRequest(value: none(string))),
  )

  discard OptObjRequest.setProvider(
    ctx,
    proc(present: bool): Future[Result[OptObjRequest, string]] {.closure, async.} =
      if present:
        return ok(OptObjRequest(value: some(Tag(key: "ok", value: "yes"))))
      else:
        return ok(OptObjRequest(value: none(Tag))),
  )

  discard ObjParamRequest.setProvider(
    ctx,
    proc(tag: Tag): Future[Result[ObjParamRequest, string]] {.closure, async.} =
      return ok(ObjParamRequest(summary: tag.key & "=" & tag.value)),
  )

  # --- New probe providers: Option[seq], tuple, KeyRange ---

  discard OptSeqRequest.setProvider(
    ctx,
    proc(present: bool): Future[Result[OptSeqRequest, string]] {.closure, async.} =
      if present:
        return ok(OptSeqRequest(value: some(@[byte 1, 2, 3, 4])))
      else:
        return ok(OptSeqRequest(value: none(seq[byte]))),
  )

  # BytesEchoRequest + ScanRequest providers — exercise seq[byte] as
  # input, distinct-over-seq (Key), tuple (TupleRow → struct), seq[Tuple]
  # (rows), and object-as-param (KeyRange) in one round-trip.
  discard BytesEchoRequest.setProvider(
    ctx,
    proc(
        payload: seq[byte]
    ): Future[Result[BytesEchoRequest, string]] {.closure, async.} =
      let first =
        if payload.len > 0:
          int32(payload[0])
        else:
          -1'i32
      let last =
        if payload.len > 0:
          int32(payload[^1])
        else:
          -1'i32
      return ok(BytesEchoRequest(length: int32(payload.len), first: first, last: last)),
  )

  discard ScanRequest.setProvider(
    ctx,
    proc(
        category: string, range: KeyRange, reverse: bool
    ): Future[Result[ScanRequest, string]] {.closure, async.} =
      var rows: seq[TupleRow] = @[]
      for i in 0 ..< 3:
        let k = $i & ":" & range.startKey
        let p = category & "-row-" & $i & ":" & range.stopKey
        rows.add((key: k, payload: p))
      if reverse:
        var rev: seq[TupleRow] = @[]
        for i in countdown(rows.len - 1, 0):
          rev.add(rows[i])
        rows = rev
      return ok(ScanRequest(rows: rows)),
  )

  # ----- Previously-restricted-shape providers (see broker decls above) -----

  discard ListInnersRequest.setProvider(
    ctx,
    proc(count: int32): Future[Result[ListInnersRequest, string]] {.closure, async.} =
      var items: seq[Inner] = @[]
      for i in 0 ..< count:
        var bs: seq[byte] = @[]
        # i + 1 bytes, starting at byte(i). Empty seq for i == 0 keeps
        # zero-length-byte-string round-trip in scope.
        for j in 0 .. i:
          bs.add(byte((i + j) and 0xFF))
        items.add(Inner(id: i, tag: "inner-" & $i, bytes: bs))
      return ok(ListInnersRequest(items: items)),
  )

  discard BulkInnersRequest.setProvider(
    ctx,
    proc(
        items: seq[Inner]
    ): Future[Result[BulkInnersRequest, string]] {.closure, async.} =
      var idSum: int64 = 0
      var byteCount: int64 = 0
      for it in items:
        idSum += int64(it.id)
        byteCount += int64(it.bytes.len)
      return ok(BulkInnersRequest(idSum: idSum, byteCount: byteCount)),
  )

  discard TriggerInnersUpdatedRequest.setProvider(
    ctx,
    proc(
        count: int32
    ): Future[Result[TriggerInnersUpdatedRequest, string]] {.closure, async.} =
      var items: seq[Inner] = @[]
      for i in 0 ..< count:
        var bs: seq[byte] = @[]
        for j in 0 .. i:
          bs.add(byte((i + j) and 0xFF))
        items.add(Inner(id: i, tag: "evt-" & $i, bytes: bs))
      await InnersUpdatedEvent.emit(gProviderCtx, InnersUpdatedEvent(items: items))
      return ok(TriggerInnersUpdatedRequest(fired: count)),
  )

  discard FixedStrArrayRequest.setProvider(
    ctx,
    proc(
        prefix: string
    ): Future[Result[FixedStrArrayRequest, string]] {.closure, async.} =
      var tags: array[4, string]
      for i in 0 .. 3:
        tags[i] = prefix & "-" & $i
      return ok(FixedStrArrayRequest(tags: tags)),
  )

  discard SetTagsRequest.setProvider(
    ctx,
    proc(
        tags: array[4, string]
    ): Future[Result[SetTagsRequest, string]] {.closure, async.} =
      return ok(SetTagsRequest(joined: tags[0] & "|" & tags[1] & "|" & tags[2] & "|" & tags[3])),
  )

  discard SumPrimArrayRequest.setProvider(
    ctx,
    proc(
        nums: array[4, int32]
    ): Future[Result[SumPrimArrayRequest, string]] {.closure, async.} =
      return ok(
        SumPrimArrayRequest(
          total: int64(nums[0]) + int64(nums[1]) + int64(nums[2]) + int64(nums[3])
        )
      ),
  )

  discard TriggerFixedObjArrayRequest.setProvider(
    ctx,
    proc(
        base: int32
    ): Future[Result[TriggerFixedObjArrayRequest, string]] {.closure, async.} =
      let slots: array[4, Slot] = [
        Slot(idx: base, name: "alpha"),
        Slot(idx: base + 1, name: "beta"),
        Slot(idx: base + 2, name: ""),
        Slot(idx: base + 3, name: "delta with spaces"),
      ]
      await FixedObjArrayEvent.emit(gProviderCtx, FixedObjArrayEvent(slots: slots))
      return ok(TriggerFixedObjArrayRequest(fired: 4)),
  )

  # ----- Closing the last ❓ cells -----

  discard NestedObjRequest.setProvider(
    ctx,
    proc(
        key: string, value: string
    ): Future[Result[NestedObjRequest, string]] {.closure, async.} =
      return ok(
        NestedObjRequest(
          label: key & "=" & value, nested: Tag(key: key, value: value)
        )
      ),
  )

  discard SetSlotsRequest.setProvider(
    ctx,
    proc(
        slots: array[4, Slot]
    ): Future[Result[SetSlotsRequest, string]] {.closure, async.} =
      return ok(
        SetSlotsRequest(
          summary:
            slots[0].name & "|" & slots[1].name & "|" & slots[2].name & "|" &
            slots[3].name
        )
      ),
  )

  discard TriggerStrArrayRequest.setProvider(
    ctx,
    proc(
        prefix: string
    ): Future[Result[TriggerStrArrayRequest, string]] {.closure, async.} =
      var words: array[4, string]
      for i in 0 .. 3:
        words[i] = prefix & "-" & $i
      await StrArrayEvent.emit(gProviderCtx, StrArrayEvent(words: words))
      return ok(TriggerStrArrayRequest(fired: 4)),
  )

# ---------------------------------------------------------------------------
# Library registration
# ---------------------------------------------------------------------------

registerBrokerLibrary:
  name:
    "typemappingtestlib"
  version:
    "0.1.0"
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest
