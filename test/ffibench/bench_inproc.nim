## bench_inproc — in-process async-dispatch floor for the Phase 0 bench.
## See doc/CBOR_Refactoring.md §7.3.
##
## Measures a single-thread `RequestBroker` request round-trip — chronos
## Future + provider call + Result unwrap — with NO FFI and NO
## serialization. This is the lower bound the FFI numbers ride on top of.
##
## NOTE on scope: this is the *single-thread* async-dispatch floor. It
## deliberately omits the MT cross-thread channel hop that the FFI `_call`
## path additionally pays. Treat it as the dispatch-only floor; the
## cross-thread MT floor is a known follow-up refinement.

import std/[monotimes, times, strutils]
import chronos
import brokers/[request_broker, broker_context]

RequestBroker:
  type AddReq = object
    sum: int32

  proc signature(a: int32, b: int32): Future[Result[AddReq, string]] {.async.}

proc run() {.async.} =
  let ctx = NewBrokerContext()
  let provRes = AddReq.setProvider(
    ctx,
    proc(a: int32, b: int32): Future[Result[AddReq, string]] {.closure, async.} =
      return ok(AddReq(sum: a + b)),
  )
  doAssert provRes.isOk(), "setProvider failed"

  # warmup
  for i in 0 ..< 50000:
    discard await AddReq.request(ctx, int32(i), int32(i))

  const iterations = 1_000_000
  var acc: int64 = 0
  let t0 = getMonoTime()
  for i in 0 ..< iterations:
    let r = await AddReq.request(ctx, int32(i), int32(i))
    if r.isOk():
      acc += r.get().sum
  let t1 = getMonoTime()

  let nsPerCall = float(inNanoseconds(t1 - t0)) / float(iterations)
  doAssert acc != 0
  echo "# benchlib in-process floor (single-thread async RequestBroker)"
  echo "# mode,scenario,payload_bytes,ns_per_call"
  echo "inproc,add_scalar,8,", nsPerCall.formatFloat(ffDecimal, 1)

waitFor run()
