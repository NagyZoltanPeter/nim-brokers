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

import std/[options, tables, algorithm, strutils, hashes]
import
  brokers/[event_broker, request_broker, signal_broker, broker_context, api_library]

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

## Borrowed `==`/`hash` so JobId can be used as a Table key.
proc `==`*(a, b: JobId): bool {.borrow.}
proc hash*(a: JobId): Hash {.borrow.}

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

## Epoch — pure alias of int64 (NOT distinct), mirroring logos `Timestamp =
## int64`. Exercises `Option[Epoch]`: the field-capture fix must keep the
## written name (was leaking `Option[CompiledIntTypes]`).
type Epoch* = int64

## Hash32 / Key32 — two STRUCTURALLY IDENTICAL `array[32, byte]` aliases,
## mirroring logos `WakuMessageHash` / `Curve25519Key`. Used in `seq[Hash32]`
## and `Option[Key32]`: the field capture must keep each written name (was
## renaming `Option[WakuMessageHash]` -> `Option[Curve25519Key]`), and the
## resolver must register the array alias so it maps to bytes.
type Hash32* = array[32, byte]
type Key32* = array[32, byte]

## ContentTopic — a PURE primitive alias (`type X = string`, NOT distinct).
## This is the exact shape the type-resolver alias fix targets: the
## wrapper type discovery must follow the alias to `string` so a field /
## param / seq[alias] typed as ContentTopic maps to std::string /
## std::vector<std::string> (and the Python/Rust/Go equivalents) instead
## of emitting a "not yet mappable" TODO and dropping the whole method.
## Mirrors logos-delivery's `ContentTopic = string` / `PubsubTopic = string`.
type ContentTopic* = string

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
# Signal Brokers — one-way, slot-free `_call` coverage across all wrappers
# ---------------------------------------------------------------------------

## IngestSignal: composite object payload — exercises scalar + string + seq
## through the one-way signal path.
SignalBroker(API):
  type IngestSignal = object
    id*: int32
    label*: string
    values*: seq[int32]

## ScalarSignal: bare-scalar (distinct) payload — exercises the scalar signal
## wrapper method in every language.
SignalBroker(API):
  type ScalarSignal = int32

## LastSignalState: readback of the recorded signal state, so the one-way
## signals are observable through the request surface. The harnesses fire the
## signals then request this to assert delivery + wire fidelity.
RequestBroker(API):
  type LastSignalState = object
    id*: int32
    label*: string
    valueCount*: int32
    valueSum*: int32
    scalarVal*: int32
    objCount*: int32
    scalarCount*: int32

  proc signature*(): Future[Result[LastSignalState, string]] {.async.}

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

## Opt[T] parity probes (results' `Opt[T] = Result[T, void]`). These MUST map
## and ride the wire byte-for-byte identically to the `Option[T]` variants
## above — same CDDL (`T / null`), same std::optional / Optional / Option<T> /
## *T in every wrapper, same present/absent CBOR. Covers scalar, variable-shape
## (string) and registered-object inner types.
RequestBroker(API):
  type OptWrapScalarRequest* = object
    value*: Opt[int32]

  proc signature*(present: bool): Future[Result[OptWrapScalarRequest, string]] {.async.}

RequestBroker(API):
  type OptWrapStringRequest* = object
    value*: Opt[string]

  proc signature*(present: bool): Future[Result[OptWrapStringRequest, string]] {.async.}

RequestBroker(API):
  type OptWrapObjRequest* = object
    value*: Opt[Tag]

  proc signature*(present: bool): Future[Result[OptWrapObjRequest, string]] {.async.}

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
# Request Brokers — associative container (Table[K, V]) coverage
# ---------------------------------------------------------------------------

## MapResultRequest — returns Table[K, V] for every supported key flavor:
## string, int32, char, enum (Priority), and distinct-of-int32 (JobId).
## Each map has `n` entries. Also emits MapEvent.
RequestBroker(API):
  type MapResultRequest* = object
    strKeyed*: Table[string, int32]
    intKeyed*: Table[int32, string]
    charKeyed*: Table[char, int32]
    enumKeyed*: Table[Priority, int32]
    jobKeyed*: Table[JobId, int32]

  proc signature*(n: int32): Future[Result[MapResultRequest, string]] {.async.}

## MapParamRequest — Table[string, int32] as an INPUT param. Returns the
## sum of the values and the keys joined (sorted) with "|".
RequestBroker(API):
  type MapParamRequest* = object
    total*: int64
    joined*: string

  proc signature*(
    scores: Table[string, int32]
  ): Future[Result[MapParamRequest, string]] {.async.}

## MapEvent — Table[string, int32] in an event payload.
EventBroker(API):
  type MapEvent* = object
    counts*: Table[string, int32]

# ---------------------------------------------------------------------------
# Pure-alias coverage (type-resolver alias fix). ContentTopic = string is
# exercised in EVERY direction: request param (in), result field (out),
# seq[alias] result field (out), and event payload field (out). Without the
# alias fix each of these emits a "not yet mappable" TODO and the owning
# method/event is dropped from all four wrappers — so reverting the fix
# breaks these round-trips in C++/Python/Rust/Go.
# ---------------------------------------------------------------------------

## AliasFieldRequest — pure alias as INPUT param + as result field + as
## seq[alias] result field. Echoes the topic and fabricates n derived topics.
RequestBroker(API):
  type AliasFieldRequest* = object
    topic*: ContentTopic
    topics*: seq[ContentTopic]

  proc signature*(
    topic: ContentTopic, n: int32
  ): Future[Result[AliasFieldRequest, string]] {.async.}

## AliasEvent — pure alias (+ seq[alias]) in an event payload.
EventBroker(API):
  type AliasEvent* = object
    topic*: ContentTopic
    topics*: seq[ContentTopic]

## TriggerAliasEventRequest — fires AliasEvent with a fabricated payload.
RequestBroker(API):
  type TriggerAliasEventRequest* = object
    fired*: int32

  proc signature*(
    topic: ContentTopic, n: int32
  ): Future[Result[TriggerAliasEventRequest, string]] {.async.}

# ---------------------------------------------------------------------------
# seq[byte] / Option[seq[byte]] coverage gaps: a TOP-LEVEL seq[byte] event
# field, an Option[seq[byte]] event field, and an Option[seq[byte]] INPUT
# param (the result-field direction is already covered by OptSeqRequest).
# ---------------------------------------------------------------------------

## ByteSeqEvent — a direct (top-level) seq[byte] event payload field.
EventBroker(API):
  type ByteSeqEvent* = object
    data*: seq[byte]

## OptByteSeqEvent — Option[seq[byte]] in an event payload.
EventBroker(API):
  type OptByteSeqEvent* = object
    value*: Option[seq[byte]]

## OptWrapByteSeqEvent — Opt[seq[byte]] (results) in an event payload. Must ride
## the wire byte-for-byte identically to OptByteSeqEvent and deliver the same
## optional shape (std::optional / Optional / Option / *T) in every wrapper.
EventBroker(API):
  type OptWrapByteSeqEvent* = object
    value*: Opt[seq[byte]]

## TriggerByteEventsRequest — fires ByteSeqEvent([0..size-1]),
## OptByteSeqEvent(some([1,2,3,4]) when present else none), and the
## Opt[seq[byte]] parity twin OptWrapByteSeqEvent with the same payload.
RequestBroker(API):
  type TriggerByteEventsRequest* = object
    fired*: int32

  proc signature*(
    size: int32, present: bool
  ): Future[Result[TriggerByteEventsRequest, string]] {.async.}

## OptByteParamRequest — Option[seq[byte]] as an INPUT param. Returns
## length = -1 when absent, else the byte count.
RequestBroker(API):
  type OptByteParamRequest* = object
    length*: int32

  proc signature*(
    value: Option[seq[byte]]
  ): Future[Result[OptByteParamRequest, string]] {.async.}

## OptWrapByteParamRequest — Opt[seq[byte]] as an INPUT param, the parity twin
## of OptByteParamRequest. Guards the wrapper-side ENCODE path specifically: the
## Rust `__Args` struct must canonicalize `Opt[seq[byte]]` -> `option[seq[byte]]`
## to attach `#[serde(with = "::serde_bytes")]`, else Rust emits a CBOR array of
## ints (major type 4) instead of a byte string (major type 2) and the Nim
## decoder rejects it. Same contract as OptByteParamRequest: -1 when absent.
RequestBroker(API):
  type OptWrapByteParamRequest* = object
    length*: int32

  proc signature*(
    value: Opt[seq[byte]]
  ): Future[Result[OptWrapByteParamRequest, string]] {.async.}

# ---------------------------------------------------------------------------
# Proc-sugar scalar payloads: a verb-named RequestBroker (no `type` decl)
# whose response payload is a registered alias / distinct that resolves to a
# primitive. Mirrors logos-delivery's `proc send(): Result[RequestId]` /
# `proc defaultPubsubTopic(): Result[PubsubTopic]`. Without the registration
# relaxation these drop as "return type ... not emittable".
# ---------------------------------------------------------------------------

## EchoTopic — proc-sugar, payload is a pure ALIAS (ContentTopic = string).
RequestBroker(API):
  proc echoTopic(topic: ContentTopic): Future[Result[ContentTopic, string]] {.async.}

## NextJob — proc-sugar, payload is a DISTINCT (JobId = distinct int32).
RequestBroker(API):
  proc nextJob(jobId: JobId): Future[Result[JobId, string]] {.async.}

## ListTopics — proc-sugar, payload is a CONTAINER (seq[ContentTopic], i.e.
## seq of a registered alias). Mirrors logos-delivery's
## `proc connectedPeers(): Result[seq[string]]` / `listenAddresses`. Case (b).
RequestBroker(API):
  proc listTopics(
    prefix: ContentTopic, n: int32
  ): Future[Result[seq[ContentTopic], string]] {.async.}

## RowData — a standalone object returned ONLY via a proc-sugar broker (like
## logos StoreQueryResponse behind `proc storeQuery(): Result[StoreQueryResponse]`).
## Exercises return-type scanning (register the response object) + aliasing the
## verb-named broker to it.
type RowData* = object
  id*: int32
  label*: string

RequestBroker(API):
  proc getRow(key: string): Future[Result[RowData, string]] {.async.}

## Bare-primitive proc-sugar payloads (like logos `proc startDiscv5():
## Result[bool]` / `proc peerExchangeRequest(): Result[int]`). The verb-named
## broker must NOT wrap the primitive in a synthetic alias — the method is
## `Result<bool>` / `Result<int32_t>`, not `Result<IsReady>` / `Result<DoubleIt>`.
RequestBroker(API):
  proc isReady(): Future[Result[bool, string]] {.async.}

RequestBroker(API):
  proc doubleIt(n: int32): Future[Result[int32, string]] {.async.}

## StoreLike — mirrors logos StoreQueryRequest's previously-unmapped fields:
## Option[alias-of-int64], seq[array[N,byte] alias], Option[array[N,byte] alias].
RequestBroker(API):
  type StoreLikeRequest* = object
    startTime*: Option[Epoch]
    hashes*: seq[Hash32]
    cursor*: Option[Key32]

  proc signature*(present: bool): Future[Result[StoreLikeRequest, string]] {.async.}

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

# Signal recording state — written by the signal handlers, read back via the
# LastSignalState request so the harnesses can verify one-way delivery.
var gSigId {.threadvar.}: int32
var gSigLabel {.threadvar.}: string
var gSigValueCount {.threadvar.}: int32
var gSigValueSum {.threadvar.}: int32
var gSigScalarVal {.threadvar.}: int32
var gSigObjCount {.threadvar.}: int32
var gSigScalarCount {.threadvar.}: int32

proc setupProviders(ctx: BrokerContext) =
  gProviderCtx = ctx
  gCounter = 0
  gLabel = ""

  # --- Signal handlers + readback provider (one-way signal coverage) ---
  discard IngestSignal.onSignal(
    ctx,
    proc(s: IngestSignal) {.async: (raises: []).} =
      gSigId = s.id
      gSigLabel = s.label
      gSigValueCount = int32(s.values.len)
      var sum: int32 = 0
      for v in s.values:
        sum += v
      gSigValueSum = sum
      gSigObjCount += 1,
  )

  discard ScalarSignal.onSignal(
    ctx,
    proc(s: ScalarSignal) {.async: (raises: []).} =
      gSigScalarVal = int32(s)
      gSigScalarCount += 1,
  )

  discard LastSignalState.setProvider(
    ctx,
    proc(): Future[Result[LastSignalState, string]] {.closure, async.} =
      ok(
        LastSignalState(
          id: gSigId,
          label: gSigLabel,
          valueCount: gSigValueCount,
          valueSum: gSigValueSum,
          scalarVal: gSigScalarVal,
          objCount: gSigObjCount,
          scalarCount: gSigScalarCount,
        )
      ),
  )

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
      CounterChanged.emit(gProviderCtx, CounterChanged(value: gCounter))
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
      PrimScalarEvent.emit(
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
      TypedScalarEvent.emit(
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
      VoidPing.emit(gProviderCtx, VoidPing())
      return ok(VoidActionRequest()),
  )

  # --- primitive (non-object) result provider ---

  discard IntResultRequest.setProvider(
    ctx,
    proc(value: int32): Future[Result[IntResultRequest, string]] {.closure, async.} =
      SimpleIntEvent.emit(gProviderCtx, SimpleIntEvent(int64(value) * 10'i64))
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
      StringSeqEvent.emit(gProviderCtx, StringSeqEvent(items: items))
      return ok(StringSeqRequest(items: items)),
  )

  discard PrimSeqRequest.setProvider(
    ctx,
    proc(n: int32): Future[Result[PrimSeqRequest, string]] {.closure, async.} =
      var values: seq[int64] = @[]
      for i in 0 ..< int(n):
        values.add(int64(i) * 10'i64)
      PrimSeqEvent.emit(gProviderCtx, PrimSeqEvent(values: values))
      return ok(PrimSeqRequest(values: values)),
  )

  discard FixedArrayRequest.setProvider(
    ctx,
    proc(seed: int32): Future[Result[FixedArrayRequest, string]] {.closure, async.} =
      let vals: array[4, int32] = [seed, seed * 2'i32, seed * 3'i32, seed * 4'i32]
      FixedArrayEvent.emit(gProviderCtx, FixedArrayEvent(values: vals))
      return ok(FixedArrayRequest(values: vals, ts: Timestamp(int64(seed)))),
  )

  discard ConstArrayRequest.setProvider(
    ctx,
    proc(seed: int32): Future[Result[ConstArrayRequest, string]] {.closure, async.} =
      var vals: array[ConstArrayLen, int32]
      for i in 0 ..< ConstArrayLen:
        vals[i] = seed * int32(i + 1)
      ConstArrayEvent.emit(gProviderCtx, ConstArrayEvent(values: vals))
      return ok(ConstArrayRequest(values: vals)),
  )

  discard ObjSeqResultRequest.setProvider(
    ctx,
    proc(n: int32): Future[Result[ObjSeqResultRequest, string]] {.closure, async.} =
      var tags: seq[Tag] = @[]
      for i in 0 ..< int(n):
        tags.add(Tag(key: "key-" & $i, value: "val-" & $i))
      TagSeqEvent.emit(gProviderCtx, TagSeqEvent(tags: tags))
      return ok(ObjSeqResultRequest(tags: tags)),
  )

  # --- TagSeqRequest: triggers TagSeqEvent (seq[object] with strings) ---
  discard TagSeqRequest.setProvider(
    ctx,
    proc(n: int32): Future[Result[TagSeqRequest, string]] {.closure, async.} =
      var tags: seq[Tag] = @[]
      for i in 0 ..< int(n):
        tags.add(Tag(key: "tag-key-" & $i, value: "tag-val-" & $i))
      TagSeqEvent.emit(gProviderCtx, TagSeqEvent(tags: tags))
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

  discard OptWrapScalarRequest.setProvider(
    ctx,
    proc(
        present: bool
    ): Future[Result[OptWrapScalarRequest, string]] {.closure, async.} =
      if present:
        return ok(OptWrapScalarRequest(value: Opt.some(42'i32)))
      else:
        return ok(OptWrapScalarRequest(value: Opt.none(int32))),
  )

  discard OptWrapStringRequest.setProvider(
    ctx,
    proc(
        present: bool
    ): Future[Result[OptWrapStringRequest, string]] {.closure, async.} =
      if present:
        return ok(OptWrapStringRequest(value: Opt.some("hello")))
      else:
        return ok(OptWrapStringRequest(value: Opt.none(string))),
  )

  discard OptWrapObjRequest.setProvider(
    ctx,
    proc(present: bool): Future[Result[OptWrapObjRequest, string]] {.closure, async.} =
      if present:
        return ok(OptWrapObjRequest(value: Opt.some(Tag(key: "ok", value: "yes"))))
      else:
        return ok(OptWrapObjRequest(value: Opt.none(Tag))),
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
      InnersUpdatedEvent.emit(gProviderCtx, InnersUpdatedEvent(items: items))
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
      return ok(
        SetTagsRequest(joined: tags[0] & "|" & tags[1] & "|" & tags[2] & "|" & tags[3])
      ),
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
      FixedObjArrayEvent.emit(gProviderCtx, FixedObjArrayEvent(slots: slots))
      return ok(TriggerFixedObjArrayRequest(fired: 4)),
  )

  # ----- Closing the last ❓ cells -----

  discard NestedObjRequest.setProvider(
    ctx,
    proc(
        key: string, value: string
    ): Future[Result[NestedObjRequest, string]] {.closure, async.} =
      return ok(
        NestedObjRequest(label: key & "=" & value, nested: Tag(key: key, value: value))
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
      StrArrayEvent.emit(gProviderCtx, StrArrayEvent(words: words))
      return ok(TriggerStrArrayRequest(fired: 4)),
  )

  # ----- Table[K, V] providers -----

  discard MapResultRequest.setProvider(
    ctx,
    proc(n: int32): Future[Result[MapResultRequest, string]] {.closure, async.} =
      var
        s: Table[string, int32]
        i: Table[int32, string]
        c: Table[char, int32]
        e: Table[Priority, int32]
        j: Table[JobId, int32]
      for k in 0 ..< int(n):
        s["key-" & $k] = int32(k)
        i[int32(k)] = "val-" & $k
        c[char(ord('a') + k)] = int32(k * 2)
        e[Priority(k mod 4)] = int32(k)
        j[JobId(int32(k))] = int32(k * 3)
      return ok(
        MapResultRequest(
          strKeyed: s, intKeyed: i, charKeyed: c, enumKeyed: e, jobKeyed: j
        )
      ),
  )

  discard MapParamRequest.setProvider(
    ctx,
    proc(
        scores: Table[string, int32]
    ): Future[Result[MapParamRequest, string]] {.closure, async.} =
      var total: int64 = 0
      var keys: seq[string] = @[]
      for k, v in scores:
        total += int64(v)
        keys.add(k)
      keys.sort()
      # Echo the received map back through a (string-keyed) event so every
      # wrapper — including the string-key-only ones — can verify MapEvent.
      MapEvent.emit(gProviderCtx, MapEvent(counts: scores))
      return ok(MapParamRequest(total: total, joined: keys.join("|"))),
  )

  # ----- Pure-alias (ContentTopic = string) providers -----

  discard AliasFieldRequest.setProvider(
    ctx,
    proc(
        topic: ContentTopic, n: int32
    ): Future[Result[AliasFieldRequest, string]] {.closure, async.} =
      var topics: seq[ContentTopic] = @[]
      for i in 0 ..< int(n):
        topics.add(topic & "/" & $i)
      return ok(AliasFieldRequest(topic: topic, topics: topics)),
  )

  discard TriggerAliasEventRequest.setProvider(
    ctx,
    proc(
        topic: ContentTopic, n: int32
    ): Future[Result[TriggerAliasEventRequest, string]] {.closure, async.} =
      var topics: seq[ContentTopic] = @[]
      for i in 0 ..< int(n):
        topics.add(topic & "/" & $i)
      AliasEvent.emit(gProviderCtx, AliasEvent(topic: topic, topics: topics))
      return ok(TriggerAliasEventRequest(fired: n)),
  )

  # ----- seq[byte] / Option[seq[byte]] event + param providers -----

  discard TriggerByteEventsRequest.setProvider(
    ctx,
    proc(
        size: int32, present: bool
    ): Future[Result[TriggerByteEventsRequest, string]] {.closure, async.} =
      var data = newSeq[byte](int(size))
      for i in 0 ..< int(size):
        data[i] = byte(i mod 256)
      ByteSeqEvent.emit(gProviderCtx, ByteSeqEvent(data: data))
      let optVal =
        if present:
          some(@[byte 1, 2, 3, 4])
        else:
          none(seq[byte])
      OptByteSeqEvent.emit(gProviderCtx, OptByteSeqEvent(value: optVal))
      let optWrapVal =
        if present:
          Opt.some(@[byte 1, 2, 3, 4])
        else:
          Opt.none(seq[byte])
      OptWrapByteSeqEvent.emit(gProviderCtx, OptWrapByteSeqEvent(value: optWrapVal))
      return ok(TriggerByteEventsRequest(fired: 3)),
  )

  discard OptByteParamRequest.setProvider(
    ctx,
    proc(
        value: Option[seq[byte]]
    ): Future[Result[OptByteParamRequest, string]] {.closure, async.} =
      let length =
        if value.isSome():
          int32(value.get().len)
        else:
          -1'i32
      return ok(OptByteParamRequest(length: length)),
  )

  discard OptWrapByteParamRequest.setProvider(
    ctx,
    proc(
        value: Opt[seq[byte]]
    ): Future[Result[OptWrapByteParamRequest, string]] {.closure, async.} =
      let length =
        if value.isSome():
          int32(value.get().len)
        else:
          -1'i32
      return ok(OptWrapByteParamRequest(length: length)),
  )

  # ----- proc-sugar scalar payload providers (alias / distinct) -----

  discard EchoTopic.setProvider(
    ctx,
    proc(topic: ContentTopic): Future[Result[ContentTopic, string]] {.closure, async.} =
      return ok(ContentTopic(topic & "/echo")),
  )

  discard NextJob.setProvider(
    ctx,
    proc(jobId: JobId): Future[Result[JobId, string]] {.closure, async.} =
      return ok(JobId(int32(jobId) + 1'i32)),
  )

  discard ListTopics.setProvider(
    ctx,
    proc(
        prefix: ContentTopic, n: int32
    ): Future[Result[seq[ContentTopic], string]] {.closure, async.} =
      var topics: seq[ContentTopic] = @[]
      for i in 0 ..< int(n):
        topics.add(prefix & "/" & $i)
      return ok(topics),
  )

  discard GetRow.setProvider(
    ctx,
    proc(key: string): Future[Result[RowData, string]] {.closure, async.} =
      return ok(RowData(id: int32(key.len), label: "row:" & key)),
  )

  discard IsReady.setProvider(
    ctx,
    proc(): Future[Result[bool, string]] {.closure, async.} =
      return ok(true),
  )

  discard DoubleIt.setProvider(
    ctx,
    proc(n: int32): Future[Result[int32, string]] {.closure, async.} =
      return ok(n * 2'i32),
  )

  discard StoreLikeRequest.setProvider(
    ctx,
    proc(present: bool): Future[Result[StoreLikeRequest, string]] {.closure, async.} =
      var h: Hash32
      for i in 0 .. 31:
        h[i] = byte(i)
      var k: Key32
      for i in 0 .. 31:
        k[i] = byte(255 - i)
      if present:
        return ok(
          StoreLikeRequest(startTime: some(Epoch(1700)), hashes: @[h], cursor: some(k))
        )
      else:
        return
          ok(StoreLikeRequest(startTime: none(Epoch), hashes: @[], cursor: none(Key32))),
  )

# ---------------------------------------------------------------------------
# Library registration
# ---------------------------------------------------------------------------

# Exercises the const-identifier form of `version:` (a `{.strdefine.}` so the
# value can also be injected at build time, e.g. `-d:typemapLibVersion=...`).
# The generated `<lib>_version()` resolves it at compile time of THIS module;
# the cross-language `version()` tests assert it round-trips as "0.1.0".
const typemapLibVersion* {.strdefine.} = "0.1.0"

registerBrokerLibrary:
  name:
    "typemappingtestlib"
  version:
    typemapLibVersion
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest
