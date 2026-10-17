## EXTAPI example — the API this Nim program *consumes*.
##
## `storage` is implemented by an external plugin (C++: examples/extapi/
## cpp_plugin, Rust: examples/extapi/rust_plugin). `codec` is a plain C-ABI
## library imported function by function (C++: cpp_cimport, Rust:
## rust_cimport). Nim code calls both with the ordinary broker verbs.

import brokers/[request_broker, event_broker, signal_broker, ext_plugin]

export request_broker, event_broker, signal_broker, ext_plugin

# --- storage: provided by an external plugin --------------------------------

RequestBroker(EXTAPI[storage], autoWire = false):
  ## Fetch a blob. Not auto-wired: the host owns the slot and switches between
  ## the plugin and its own Nim implementation at runtime.
  type FetchBlob = object
    data*: seq[byte]

  proc signature*(key: string): Future[Result[FetchBlob, string]] {.async.}

RequestBroker(EXTAPI[storage]):
  ## Store a blob; the plugin answers with an etag.
  type StoreBlob = object
    etag*: string

  proc signature*(
    key: string, data: seq[byte]
  ): Future[Result[StoreBlob, string]] {.async.}

RequestBroker(EXTAPI[storage]):
  ## Declared, but the example plugins do not provide it.
  type ListKeys = object
    keys*: seq[string]

  proc signature*(): Future[Result[ListKeys, string]] {.async.}

RequestBroker(EXTAPI[storage]):
  ## Slow on purpose (2 s unless cancelled): cancel and timeout demo.
  type Compact = object
    freed*: int64

  proc signature*(level: int32): Future[Result[Compact, string]] {.async.}

EventBroker(EXTAPI[storage]):
  ## Emitted by the plugin from its own threads.
  type BlobEvicted = object
    key*: string
    reason*: string

SignalBroker(EXTAPI[storage]):
  ## Fire-and-forget hint to the plugin.
  type CompactHint = object
    urgency*: int32

registerExtPlugin(storage, version = "1.0.0")

# --- codec: a plain C-ABI library, imported function by function ------------

const codecLib* {.strdefine.} = ""
  ## Path of the codec library, set at build time (-d:codecLib=...).

RequestBroker(
  EXTAPI[codec], importc = "codec_crc", dynlib = codecLib, dispatch = inplace
):
  ## Short form: a direct C call on the caller's thread.
  type Crc = object
    value*: uint32

  proc signature*(
    seed: uint32, buf: ptr uint8, len: uint32
  ): Future[Result[Crc, string]] {.async.}

RequestBroker(EXTAPI[codec], dynlib = codecLib, dispatch = workers(2)):
  ## Body form: a blocking C call on one of two import workers.
  type SlowSum = object
    total*: uint64

  proc codec_slow_sum(
    src: ptr uint8, len: uint32, ms: uint32, outp: ptr uint64
  ): int32 {.importc, cdecl.}

  proc signature*(
      data: seq[byte], ms: uint32
  ): Future[Result[SlowSum, string]] {.async.} =
    var total: uint64
    let p = (if data.len > 0: unsafeAddr data[0] else: nil)
    let rc = codec_slow_sum(p, uint32(data.len), ms, addr total)
    if rc != 0:
      return err("codec_slow_sum rc=" & $rc)
    return ok(SlowSum(total: total))

RequestBroker(
  EXTAPI[codec], importc = "codec_not_exported", dynlib = codecLib, dispatch = inplace
):
  ## The library does not export this symbol: it stays unprovided, and a Nim
  ## fallback serves it.
  type Mixed = object
    value*: uint32

  proc signature*(x: uint32): Future[Result[Mixed, string]] {.async.}

registerExtPlugin(codec, version = "1.0.0")

proc nimCrc*(seed: uint32, data: openArray[byte]): uint32 =
  ## Reference implementation of `codec_crc` (both cimport libraries).
  result = seed
  for b in data:
    result = result * 31'u32 + uint32(b)
