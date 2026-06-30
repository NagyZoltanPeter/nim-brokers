## perf_overhead.nim — exact overhead of same-thread RequestBrokers vs a
## direct proc call, plus per-call allocation churn and static footprint.
##
## Everything runs on ONE thread, ONE context, calling ONE shared
## implementation, so the only variable between rows is the dispatch path:
##
##   Direct sync call      — `impl(args)`                      (sync floor)
##   RequestBroker(sync)   — `T.request(args)`                 vs sync floor
##   Direct async await    — `await implAsync(args)`           (async floor)
##   RequestBroker (async) — `await T.request(args)`           vs async floor
##
## "Overhead" = row − its floor, in ns/call. The async rows subtract the
## async floor so chronos's own `await` cost is NOT counted as broker cost.
##
## Two payload sets: a scalar (a,b -> sum) that isolates pure dispatch, and
## a 512 B seq[int32] that shows whether a larger argument changes the cost
## (it shouldn't much — single-thread brokers call the provider directly, no
## channel copy).
##
## Memory:
##   churn     — getOccupiedMem() growth over N calls with the GC disabled,
##               ÷ N → bytes allocated per call. Under refc this is the
##               garbage produced per request; under ORC allocations are
##               freed at scope exit (GC_disable is a no-op) so churn ≈ 0 —
##               ORC's alloc/free *cost* shows up in ns/call instead.
##   footprint — getOccupiedMem() growth from registering the provider +
##               first request (Table + closure + context bucket).
##
## No --threads:on: plain `RequestBroker`/`RequestBroker(sync)` are the
## single-thread macros, which is exactly what we want to measure.

{.used.}

import std/[monotimes, times, strutils]
import chronos
import brokers/request_broker

const
  WarmN = 20_000
  LatN = 500_000 ## iterations timed for ns/call
  ChurnN = 100_000 ## iterations for allocation churn (GC disabled)
  VecElements = 128 ## 128 × int32 = 512 B

# Global sink — accumulating into it across the timed loops defeats
# dead-code elimination of the (otherwise pure) calls.
var gSink: int64 = 0

# ---------------------------------------------------------------------------
# Broker + baseline definitions. Each broker's value type doubles as its
# result type; the direct baselines reuse those same types so the compared
# rows return identical data.
# ---------------------------------------------------------------------------

RequestBroker(sync):
  type AddSync = object
    sum*: int64

  proc signature*(a: int32, b: int32): Result[AddSync, string]

RequestBroker:
  type AddAsync = object
    sum*: int64

  proc signature*(a: int32, b: int32): Future[Result[AddAsync, string]] {.async.}

RequestBroker(sync):
  type VecSync = object
    length*: int32
    checksum*: int64

  proc signature*(payload: seq[int32]): Result[VecSync, string]

RequestBroker:
  type VecAsync = object
    length*: int32
    checksum*: int64

  proc signature*(payload: seq[int32]): Future[Result[VecAsync, string]] {.async.}

proc addDirect(a, b: int32): Result[AddSync, string] {.gcsafe, raises: [].} =
  ok(AddSync(sum: a.int64 + b.int64))

proc addDirectAsync(
    a, b: int32
): Future[Result[AddAsync, string]] {.async: (raises: []).} =
  return ok(AddAsync(sum: a.int64 + b.int64))

proc vecDirect(payload: seq[int32]): Result[VecSync, string] {.gcsafe, raises: [].} =
  var c: int64 = 0
  for v in payload:
    c += v
  ok(VecSync(length: payload.len.int32, checksum: c))

proc vecDirectAsync(
    payload: seq[int32]
): Future[Result[VecAsync, string]] {.async: (raises: []).} =
  var c: int64 = 0
  for v in payload:
    c += v
  return ok(VecAsync(length: payload.len.int32, checksum: c))

# ---------------------------------------------------------------------------
# Measurement templates — inlined into the async run procs, so `body` may
# contain `await`. `i` is the loop index, usable inside `body`.
# ---------------------------------------------------------------------------

template latency(body: untyped): int64 =
  block:
    for i {.inject.} in 0 ..< WarmN:
      body
    let t0 = getMonoTime()
    for i {.inject.} in 0 ..< LatN:
      body
    (getMonoTime() - t0).inNanoseconds div LatN.int64

template churn(body: untyped): float =
  block:
    # GC_fullCollect is declared as possibly-raising; the async run procs are
    # raises:[]. The raise is spurious, so swallow it to satisfy the effect
    # system.
    try:
      GC_fullCollect()
    except Exception:
      discard
    # refc: freeze collection so occupied-mem growth = total bytes allocated.
    # ORC: GC_disable/GC_enable don't exist; allocations are freed at scope
    # exit anyway, so churn naturally measures ≈ 0 (alloc/free cost is in ns).
    when declared(GC_disable):
      GC_disable()
    let m0 = getOccupiedMem()
    for i {.inject.} in 0 ..< ChurnN:
      body
    let m1 = getOccupiedMem()
    when declared(GC_enable):
      GC_enable()
    try:
      GC_fullCollect()
    except Exception:
      discard
let delta = max(m1 - m0, 0)
float(delta) / float(ChurnN)

proc footprintOf(register: proc() {.gcsafe, raises: [].}): int {.raises: [].} =
  ## getOccupiedMem growth across provider registration + lazy init.
  try:
    GC_fullCollect()
  except Exception:
    discard
  let m0 = getOccupiedMem()
  register()
  try:
    GC_fullCollect()
  except Exception:
    discard
  getOccupiedMem() - m0

# ---------------------------------------------------------------------------
# Reporting — one row per scenario + a trailing CSV line.
# ---------------------------------------------------------------------------

proc row(
    payloadTag, name: string,
    nsPerCall, floorNs: int64,
    churnBpc: float,
    footprintB: int,
    isFloor: bool,
) =
  var line = "  " & alignLeft(name, 22) & ": " & align($nsPerCall, 5) & " ns/call"
  let overheadNs = nsPerCall - floorNs
  if isFloor:
    line &= "   (floor)        "
  else:
    line &=
      "   overhead " & (if overheadNs >= 0: "+" else: "") & align($overheadNs, 4) & " ns"
  line &= "   churn " & align(formatFloat(churnBpc, ffDecimal, 1), 6) & " B/call"
  if not isFloor:
    line &= "   footprint " & $footprintB & " B"
  echo line
  # CSV: payload,scenario,ns_per_call,overhead_ns,churn_bpc,footprint_b
  echo "csv,perfoverhead,",
    payloadTag,
    ",",
    name.replace(" ", "_").replace("(", "").replace(")", ""),
    ",",
    nsPerCall,
    ",",
    (if isFloor: 0'i64 else: overheadNs),
    ",",
    formatFloat(churnBpc, ffDecimal, 1),
    ",",
    (if isFloor: -1 else: footprintB)

# ---------------------------------------------------------------------------
# Scenario sets
# ---------------------------------------------------------------------------

proc runScalar() {.async.} =
  echo "\n── Scalar (a,b -> sum) — ",
    LatN, " timed iters, churn over ", ChurnN, " ──"

  let dNs = latency(gSink += addDirect(int32(i), int32(i)).get().sum)
  let dCh = churn(gSink += addDirect(int32(i), int32(i)).get().sum)
  row("scalar", "Direct sync call", dNs, dNs, dCh, 0, true)

  let sFoot = footprintOf(
    proc() {.gcsafe, raises: [].} =
      doAssert AddSync
        .setProvider(
          proc(a: int32, b: int32): Result[AddSync, string] {.gcsafe, raises: [].} =
            ok(AddSync(sum: a.int64 + b.int64))
        )
        .isOk()
      discard AddSync.request(int32(0), int32(0))
  )
  let sNs = latency(gSink += AddSync.request(int32(i), int32(i)).get().sum)
  let sCh = churn(gSink += AddSync.request(int32(i), int32(i)).get().sum)
  row("scalar", "RequestBroker(sync)", sNs, dNs, sCh, sFoot, false)

  let daNs = latency(gSink += (await addDirectAsync(int32(i), int32(i))).get().sum)
  let daCh = churn(gSink += (await addDirectAsync(int32(i), int32(i))).get().sum)
  row("scalar", "Direct async await", daNs, daNs, daCh, 0, true)

  let aFoot = footprintOf(
    proc() {.gcsafe, raises: [].} =
      doAssert AddAsync
        .setProvider(
          proc(
              a: int32, b: int32
          ): Future[Result[AddAsync, string]] {.closure, async.} =
            return ok(AddAsync(sum: a.int64 + b.int64))
        )
        .isOk()
      discard waitFor AddAsync.request(int32(0), int32(0))
  )
  let aNs = latency(gSink += (await AddAsync.request(int32(i), int32(i))).get().sum)
  let aCh = churn(gSink += (await AddAsync.request(int32(i), int32(i))).get().sum)
  row("scalar", "RequestBroker(async)", aNs, daNs, aCh, aFoot, false)

proc runVec() {.async.} =
  echo "\n── Vec (512 B / 128×int32 echo) — ",
    LatN, " timed iters, churn over ", ChurnN, " ──"
  var payload = newSeq[int32](VecElements)
  for i in 0 ..< VecElements:
    payload[i] = int32(i)

  let dNs = latency(gSink += vecDirect(payload).get().checksum)
  let dCh = churn(gSink += vecDirect(payload).get().checksum)
  row("vec", "Direct sync call", dNs, dNs, dCh, 0, true)

  let sFoot = footprintOf(
    proc() {.gcsafe, raises: [].} =
      var p = newSeq[int32](VecElements)
      doAssert VecSync
        .setProvider(
          proc(payload: seq[int32]): Result[VecSync, string] {.gcsafe, raises: [].} =
            var c: int64 = 0
            for v in payload:
              c += v
            ok(VecSync(length: payload.len.int32, checksum: c))
        )
        .isOk()
      discard VecSync.request(p)
  )
  let sNs = latency(gSink += VecSync.request(payload).get().checksum)
  let sCh = churn(gSink += VecSync.request(payload).get().checksum)
  row("vec", "RequestBroker(sync)", sNs, dNs, sCh, sFoot, false)

  let daNs = latency(gSink += (await vecDirectAsync(payload)).get().checksum)
  let daCh = churn(gSink += (await vecDirectAsync(payload)).get().checksum)
  row("vec", "Direct async await", daNs, daNs, daCh, 0, true)

  let aFoot = footprintOf(
    proc() {.gcsafe, raises: [].} =
      var p = newSeq[int32](VecElements)
      doAssert VecAsync
        .setProvider(
          proc(
              payload: seq[int32]
          ): Future[Result[VecAsync, string]] {.closure, async.} =
            var c: int64 = 0
            for v in payload:
              c += v
            return ok(VecAsync(length: payload.len.int32, checksum: c))
        )
        .isOk()
      discard waitFor VecAsync.request(p)
  )
  let aNs = latency(gSink += (await VecAsync.request(payload)).get().checksum)
  let aCh = churn(gSink += (await VecAsync.request(payload)).get().checksum)
  row("vec", "RequestBroker(async)", aNs, daNs, aCh, aFoot, false)

proc main() {.async.} =
  echo "RequestBroker same-thread dispatch overhead vs direct proc call"
  await runScalar()
  await runVec()
  if gSink == 0x7FFF_FFFF_FFFF_FFFF'i64:
    echo "sink ", gSink # keep gSink observable; effectively never prints

waitFor main()
