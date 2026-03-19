{.used.}

import testutils/unittests
import chronos
import std/[strutils, atomics, monotimes]
from std/times import inNanoseconds

import request_broker

## ---------------------------------------------------------------------------
## Performance / stress tests for multi-thread RequestBroker
## ---------------------------------------------------------------------------
##
## Two scenarios:
##  1. Cross-thread stress: main thread provides, 5 worker threads each
##     fire N requests concurrently. Measures per-request latency and
##     aggregate throughput.
##  2. Same-thread baseline: provider and requester on the same thread.
##     Measures the fast-path cost for comparison.
##
## Both use a realistic payload (seq[byte] data in request and response)
## to account for cross-thread copy overhead.
## ---------------------------------------------------------------------------

const
  RequestsPerThread = 500
  NumWorkerThreads = 5
  TotalCrossThreadRequests = RequestsPerThread * NumWorkerThreads
  PayloadSize = 512 ## bytes in the request/response payload

# ---------------------------------------------------------------------------
# Broker definition — realistic payload with seq data
# ---------------------------------------------------------------------------

RequestBroker(mt):
  type PerfData = object
    tag*: string
    payload*: seq[byte]
    seqNum*: int

  proc signature*(
    tag: string, data: seq[byte]
  ): Future[Result[PerfData, string]] {.async.}

# ---------------------------------------------------------------------------
# Global synchronization
# ---------------------------------------------------------------------------

var gWorkersFinished: Atomic[int]

# Per-thread latency accumulators (indexed by thread ordinal 0..4).
# Each slot is written by exactly one worker thread, read by main after join.
var gLatencySumsNs: array[NumWorkerThreads, int64] ## sum of latencies (ns)
var gLatencyMins: array[NumWorkerThreads, int64] ## min latency (ns)
var gLatencyMaxs: array[NumWorkerThreads, int64] ## max latency (ns)
var gThreadOrdinal: Atomic[int] ## ordinal dispenser

# ---------------------------------------------------------------------------
# Helper: build payload of PayloadSize bytes
# ---------------------------------------------------------------------------

proc makePayload(): seq[byte] =
  result = newSeq[byte](PayloadSize)
  for i in 0 ..< PayloadSize:
    result[i] = byte(i mod 256)

# ---------------------------------------------------------------------------
# Worker thread proc — issues RequestsPerThread requests, records latency
# ---------------------------------------------------------------------------

proc stressWorker() {.thread.} =
  let ordinal = gThreadOrdinal.fetchAdd(1)
  # Each thread builds its own payload (GC-safe — no shared seq access).
  let payload = makePayload()
  var sumNs: int64 = 0
  var minNs: int64 = int64.high
  var maxNs: int64 = 0

  for i in 0 ..< RequestsPerThread:
    let t0 = getMonoTime()
    let res = waitFor PerfData.request("w" & $ordinal, payload)
    let elapsed = (getMonoTime() - t0).inNanoseconds

    doAssert res.isOk(), "request failed: " & res.error
    doAssert res.value.payload.len == PayloadSize
    doAssert res.value.tag == "w" & $ordinal

    sumNs += elapsed
    if elapsed < minNs:
      minNs = elapsed
    if elapsed > maxNs:
      maxNs = elapsed

  gLatencySumsNs[ordinal] = sumNs
  gLatencyMins[ordinal] = minNs
  gLatencyMaxs[ordinal] = maxNs
  discard gWorkersFinished.fetchAdd(1)

# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------

proc fmtNs(ns: int64): string =
  if ns >= 1_000_000:
    $(ns div 1_000_000) & "." & align($(ns mod 1_000_000 div 1_000), 3, '0') & " ms"
  elif ns >= 1_000:
    $(ns div 1_000) & "." & align($(ns mod 1_000 div 100), 1, '0') & " µs"
  else:
    $ns & " ns"

proc fmtRate(count: int, elapsedNs: int64): string =
  if elapsedNs == 0:
    return "∞"
  let rps = float64(count) * 1e9 / float64(elapsedNs)
  if rps >= 1_000_000:
    formatFloat(rps / 1_000_000, ffDecimal, 2) & " M req/s"
  elif rps >= 1_000:
    formatFloat(rps / 1_000, ffDecimal, 2) & " K req/s"
  else:
    formatFloat(rps, ffDecimal, 1) & " req/s"

# ---------------------------------------------------------------------------
# Test suite
# ---------------------------------------------------------------------------

suite "Multi-thread RequestBroker — performance":
  asyncTest "Cross-thread stress: " & $NumWorkerThreads & " threads × " &
    $RequestsPerThread & " requests (payload " & $PayloadSize & "B)":
    gWorkersFinished.store(0)
    gThreadOrdinal.store(0)

    # Zero out accumulators.
    for i in 0 ..< NumWorkerThreads:
      gLatencySumsNs[i] = 0
      gLatencyMins[i] = int64.high
      gLatencyMaxs[i] = 0

    # Register provider on main thread.
    check PerfData
      .setProvider(
        proc(tag: string, data: seq[byte]): Future[Result[PerfData, string]] {.async.} =
          ok(PerfData(tag: tag, payload: data, seqNum: data.len))
      )
      .isOk()

    # Spawn worker threads.
    var threads: array[NumWorkerThreads, Thread[void]]
    let wallStart = getMonoTime()

    for i in 0 ..< NumWorkerThreads:
      threads[i].createThread(stressWorker)

    # Keep event loop alive so processLoop can serve requests.
    while gWorkersFinished.load() < NumWorkerThreads:
      await sleepAsync(chronos.milliseconds(1))

    let wallElapsed = (getMonoTime() - wallStart).inNanoseconds

    for i in 0 ..< NumWorkerThreads:
      threads[i].joinThread()

    PerfData.clearProvider()

    # -- Aggregate statistics --
    var allSumNs: int64 = 0
    var globalMin: int64 = int64.high
    var globalMax: int64 = 0

    for i in 0 ..< NumWorkerThreads:
      allSumNs += gLatencySumsNs[i]
      if gLatencyMins[i] < globalMin:
        globalMin = gLatencyMins[i]
      if gLatencyMaxs[i] > globalMax:
        globalMax = gLatencyMaxs[i]

    let avgNs = allSumNs div int64(TotalCrossThreadRequests)

    echo ""
    echo "  ┌─── Cross-Thread Results ─────────────────────────────"
    echo "  │ Total requests : ", TotalCrossThreadRequests
    echo "  │ Wall-clock time: ", fmtNs(wallElapsed)
    echo "  │ Throughput     : ", fmtRate(TotalCrossThreadRequests, wallElapsed)
    echo "  │ Avg latency    : ", fmtNs(avgNs)
    echo "  │ Min latency    : ", fmtNs(globalMin)
    echo "  │ Max latency    : ", fmtNs(globalMax)
    echo "  │ Payload size   : ", PayloadSize, " bytes (request + response)"
    echo "  └──────────────────────────────────────────────────────"

    # Per-thread breakdown.
    for i in 0 ..< NumWorkerThreads:
      let tAvg = gLatencySumsNs[i] div int64(RequestsPerThread)
      echo "    Thread ",
        i,
        ": avg=",
        fmtNs(tAvg),
        "  min=",
        fmtNs(gLatencyMins[i]),
        "  max=",
        fmtNs(gLatencyMaxs[i])

    echo ""

  asyncTest "Same-thread baseline: " & $TotalCrossThreadRequests & " requests (payload " &
    $PayloadSize & "B)":
    let payload = makePayload()

    # Provider on this thread — requests will use the fast path.
    check PerfData
      .setProvider(
        proc(tag: string, data: seq[byte]): Future[Result[PerfData, string]] {.async.} =
          ok(PerfData(tag: tag, payload: data, seqNum: data.len))
      )
      .isOk()

    var sumNs: int64 = 0
    var minNs: int64 = int64.high
    var maxNs: int64 = 0

    let wallStart = getMonoTime()

    for i in 0 ..< TotalCrossThreadRequests:
      let t0 = getMonoTime()
      let res = await PerfData.request("local", payload)
      let elapsed = (getMonoTime() - t0).inNanoseconds

      check res.isOk()
      check res.value.payload.len == PayloadSize

      sumNs += elapsed
      if elapsed < minNs:
        minNs = elapsed
      if elapsed > maxNs:
        maxNs = elapsed

    let wallElapsed = (getMonoTime() - wallStart).inNanoseconds

    PerfData.clearProvider()

    let avgNs = sumNs div int64(TotalCrossThreadRequests)

    echo ""
    echo "  ┌─── Same-Thread Results (baseline) ───────────────────"
    echo "  │ Total requests : ", TotalCrossThreadRequests
    echo "  │ Wall-clock time: ", fmtNs(wallElapsed)
    echo "  │ Throughput     : ", fmtRate(TotalCrossThreadRequests, wallElapsed)
    echo "  │ Avg latency    : ", fmtNs(avgNs)
    echo "  │ Min latency    : ", fmtNs(minNs)
    echo "  │ Max latency    : ", fmtNs(maxNs)
    echo "  │ Payload size   : ", PayloadSize, " bytes (request + response)"
    echo "  └──────────────────────────────────────────────────────"
    echo ""

    # Compute overhead ratio.
    echo "  Note: Compare 'Avg latency' between cross-thread and same-thread"
    echo "        to see the per-request cost of channel I/O + thread sync."
    echo ""
