## API CBOR Codec
## ---------------
## CBOR encode/decode primitives for the CBOR FFI strategy.
##
## This module owns the `BrokerCbor` flavor (configured with strict-but-
## forward-compat settings), the `CborResponseEnvelope[T]` wire type that
## represents `Result[T, string]` on the wire, and the encode/decode helpers
## that wrap `nim-cbor-serialization`'s exception-raising API as
## `Result`-returning procs suitable for `raises: []` call sites.
##
## Design choices (see plan §4):
## - Response envelope is a CBOR map with two optional fields:
##     `{ "ok": T }` for success, `{ "err": tstr }` for failure.
##   The map form lets us extend the schema without breaking older wrappers.
## - Void responses use the `CborUnit` zero-field marker so the generic
##   `CborResponseEnvelope[T]` type also covers `Result[void, string]`.
## - Encoding never raises — failures are surfaced as `Result.err`. Caller
##   threads (often foreign threads via the FFI gate) cannot meaningfully
##   handle a Nim `IOError` so all serialization exceptions are caught and
##   stringified at this layer.
##
## All buffers exchanged with the FFI boundary live elsewhere
## (`api_common`'s shared-heap helpers); this module deals only in
## `seq[byte]` / `openArray[byte]`.

{.push raises: [].}

import std/[options]
import results
import cbor_serialization
import cbor_serialization/std/options as cbor_options

export results, cbor_serialization, cbor_options

# ---------------------------------------------------------------------------
# Flavor
# ---------------------------------------------------------------------------

createCborFlavor(
  BrokerCbor,
  automaticObjectSerialization = true,
  automaticPrimitivesSerialization = true,
  requireAllFields = true,
    # Provider-side decode rejects malformed requests up front rather than
    # silently zero-initialising missing fields.
  omitOptionalFields = true, # Compactness: only populated Options hit the wire.
  allowUnknownFields = true,
    # Wrappers built against a newer schema can still talk to an older Nim
    # library — unknown fields are dropped on decode rather than failing.
  skipNullFields = false,
)

# ---------------------------------------------------------------------------
# Wire types
# ---------------------------------------------------------------------------

type CborUnit* = object
  ## Empty marker used as the payload of `Result[void, string]` envelopes.
  ## Encodes as a zero-field CBOR map (`{}`).

type CborResponseEnvelope*[T] = object
  ## Wire representation of `Result[T, string]`.
  ##
  ## With the BrokerCbor flavor (`omitOptionalFields = true`), exactly one
  ## of `ok` and `err` is populated on a well-formed envelope. Decode
  ## validates this in `fromEnvelope`.
  ok*: Option[T]
  err*: Option[string]

# ---------------------------------------------------------------------------
# Result <-> Envelope
# ---------------------------------------------------------------------------

proc toEnvelope*[T](r: Result[T, string]): CborResponseEnvelope[T] =
  if r.isOk():
    CborResponseEnvelope[T](ok: some(r.value), err: none(string))
  else:
    CborResponseEnvelope[T](ok: none(T), err: some(r.error))

proc fromEnvelope*[T](e: CborResponseEnvelope[T]): Result[T, string] {.raises: [].} =
  if e.ok.isSome() and e.err.isSome():
    return Result[T, string].err(
      "malformed CBOR response envelope: both 'ok' and 'err' present"
    )
  if e.ok.isSome():
    return Result[T, string].ok(e.ok.get())
  if e.err.isSome():
    return Result[T, string].err(e.err.get())
  Result[T, string].err(
    "malformed CBOR response envelope: neither 'ok' nor 'err' present"
  )

# ---------------------------------------------------------------------------
# Encode / Decode helpers
# ---------------------------------------------------------------------------

template cborEncode*[T](value: T): Result[seq[byte], string] =
  ## Encode `value` to CBOR using the BrokerCbor flavor. Wraps every encode
  ## failure as `Result.err`; never raises.
  ##
  ## Implemented as a template so that `BrokerCbor`'s flavor-bound templates
  ## (`init`, `writeValue`, `PreferredOutputType`) resolve at the user's
  ## call site rather than inside a generic proc — the latter loses access
  ## to the flavor's auto-generated object writers.
  block:
    var encRes: Result[seq[byte], string]
    try:
      let buf = BrokerCbor.encode(value)
      encRes = Result[seq[byte], string].ok(buf)
    except SerializationError as exc:
      encRes = Result[seq[byte], string].err("cbor encode failed: " & exc.msg)
    except IOError as exc:
      encRes = Result[seq[byte], string].err("cbor encode IO failure: " & exc.msg)
    except CatchableError as exc:
      encRes =
        Result[seq[byte], string].err("cbor encode unexpected failure: " & exc.msg)
    encRes

template cborDecode*[T](buf: openArray[byte], _: typedesc[T]): Result[T, string] =
  ## Decode a CBOR-encoded buffer into `T` using the BrokerCbor flavor.
  ## Wraps every decode failure as `Result.err`; never raises. Same
  ## template-vs-generic-proc rationale as `cborEncode`.
  block:
    var decRes: Result[T, string]
    try:
      let v = BrokerCbor.decode(buf, T)
      decRes = Result[T, string].ok(v)
    except SerializationError as exc:
      decRes = Result[T, string].err("cbor decode failed: " & exc.msg)
    except IOError as exc:
      decRes = Result[T, string].err("cbor decode IO failure: " & exc.msg)
    except CatchableError as exc:
      decRes = Result[T, string].err("cbor decode unexpected failure: " & exc.msg)
    decRes

# ---------------------------------------------------------------------------
# Result envelope shortcuts
# ---------------------------------------------------------------------------

template cborEncodeResultEnvelope*[T](r: Result[T, string]): Result[seq[byte], string] =
  ## Encode `Result[T, string]` as a CBOR response envelope.
  cborEncode(toEnvelope(r))

template cborDecodeResultEnvelope*[T](
    buf: openArray[byte], _: typedesc[T]
): Result[T, string] =
  ## Decode a CBOR response envelope into `Result[T, string]`.
  ##
  ## Returns the inner `Result` on success, or a framework error string
  ## (prefixed `cbor decode failed: ...`) on a CBOR-level failure.
  block:
    let envRes = cborDecode(buf, CborResponseEnvelope[T])
    var res: Result[T, string]
    if envRes.isErr():
      res = Result[T, string].err(envRes.error)
    else:
      res = fromEnvelope(envRes.value)
    res

{.pop.}
