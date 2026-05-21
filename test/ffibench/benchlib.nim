## benchlib — Phase 0 microbenchmark library for the CBOR refactoring.
## ====================================================================
## See doc/CBOR_Refactoring.md §7.3. This library exposes two request
## brokers used to measure the FFI `_call` path:
##
##   - AddRequest  — the simple all-scalar case  (add(a, b) -> sum)
##   - VecRequest  — a variable-size payload case (echo seq[int32])
##
## After the native FFI codegen retirement (Phase 2 of CBOR_Refactoring),
## only the `-d:BrokerFfiApiCBOR` build is reachable; the historical
## native baseline captured in doc/bench_baseline.md is the reference
## point for evaluating future optimizations against this same driver.

{.push raises: [].}

import brokers/[request_broker, broker_context, api_library]

## InitializeRequest — required post-create configuration broker.
RequestBroker(API):
  type InitializeRequest = object
    ready*: bool

  proc signature*(): Future[Result[InitializeRequest, string]] {.async.}

## ShutdownRequest — required orderly teardown broker.
RequestBroker(API):
  type ShutdownRequest = object
    status*: int32

  proc signature*(): Future[Result[ShutdownRequest, string]] {.async.}

## AddRequest — the simple all-scalar request. Two int32 in, one int32 out.
RequestBroker(API):
  type AddRequest = object
    sum*: int32

  proc signature*(a: int32, b: int32): Future[Result[AddRequest, string]] {.async.}

## VecRequest — variable-size payload. Returns the element count and a
## trivial checksum so the driver can verify the round-trip is real.
##
## NOTE: a `seq[int32]` API-broker param auto-classifies to a 4 KiB MT
## cell (mt_config.nim: `seq[<other>]` -> StringBytes) and `RequestBroker
## (API)` does not accept a `maxPayloadBytes` override. Bench payloads are
## therefore capped under 4 KiB; the driver's isOk() guard fails the run
## if any call overflows the cell. Measuring >4 KiB payloads through an
## API broker would need either the `seq[byte]` 64 KiB classification
## (non-uniform native/CBOR C++ surface) or an API-broker tuning knob that
## does not currently exist — see doc/MT_vs_CBOR_Marshalling.md §3.
RequestBroker(API):
  type VecRequest = object
    length*: int32
    checksum*: int32

  proc signature*(payload: seq[int32]): Future[Result[VecRequest, string]] {.async.}

# ---------------------------------------------------------------------------
# Providers
# ---------------------------------------------------------------------------

proc setupProviders(ctx: BrokerContext): Result[void, string] =
  let initRes = InitializeRequest.setProvider(
    ctx,
    proc(): Future[Result[InitializeRequest, string]] {.closure, async.} =
      return ok(InitializeRequest(ready: true)),
  )
  if initRes.isErr():
    return err("InitializeRequest provider: " & initRes.error())

  let shutdownRes = ShutdownRequest.setProvider(
    ctx,
    proc(): Future[Result[ShutdownRequest, string]] {.closure, async.} =
      return ok(ShutdownRequest(status: 0)),
  )
  if shutdownRes.isErr():
    return err("ShutdownRequest provider: " & shutdownRes.error())

  let addRes = AddRequest.setProvider(
    ctx,
    proc(a: int32, b: int32): Future[Result[AddRequest, string]] {.closure, async.} =
      return ok(AddRequest(sum: a + b)),
  )
  if addRes.isErr():
    return err("AddRequest provider: " & addRes.error())

  let vecRes = VecRequest.setProvider(
    ctx,
    proc(payload: seq[int32]): Future[Result[VecRequest, string]] {.closure, async.} =
      var checksum: int32 = 0
      for v in payload:
        checksum = checksum + v
      return ok(VecRequest(length: int32(payload.len), checksum: checksum)),
  )
  if vecRes.isErr():
    return err("VecRequest provider: " & vecRes.error())

  ok()

# ---------------------------------------------------------------------------
# Library registration — MUST be last
# ---------------------------------------------------------------------------

registerBrokerLibrary:
  name:
    "benchlib"
  version:
    "0.1.0"
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest

{.pop.}
