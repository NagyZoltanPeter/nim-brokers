## perf_inproc.nim — in-process Nim request baselines for the FFI bench.
##
## Companion to perf_driver.cpp's Scenario A (FFI request path). Both echo a
## 512 B (128 × int32) payload through a RequestBroker using the same
## 5 × 500 = 2500-op shape, so the three layers stack directly:
##
##   ST  — single-thread `RequestBroker`: pure chronos dispatch. No threads,
##         no channel, no CBOR, no FFI. The async-dispatch floor (2500
##         sequential requests on one event loop).
##   MT  — `RequestBroker(mt)`: 5 worker threads × 500 cross-thread requests
##         (Channel[T] hop + provider on the main thread). Adds the
##         cross-thread cost the FFI `_call` path also pays — but still no
##         CBOR serialization and no FFI C-ABI marshalling.
##
##   FFI — perf_driver.cpp (not here): ST/MT cost + CBOR encode/decode +
##         FFI ABI. Run via `nimble perftestFfi`.
##
## Output mirrors perf_driver.cpp: a box per scenario plus a trailing
## `csv,perftest_inproc,...` line for diff-friendly capture.
##
## Both `RequestBroker:` and `RequestBroker(mt):` coexist in one --threads:on
## binary: plain `RequestBroker:` always generates the single-thread macro
## (request_broker.nim routes it to `generateRequestBroker(.., rbAsync)`
## regardless of --threads:on); only the `(mt)` modifier takes the MT lane.
##
## refc-safety: worker threads NEVER move a `seq` into a shared global (refc
## uses thread-local heaps). Latency samples are written into a fixed global
## value-array (disjoint per-thread slices), read by main only after join.

{.used.}

import std/[monotimes, times, strutils, algorithm, atomics]
from std/times import inNanoseconds

import chronos
import brokers/request_broker

const
  NumWorkerThreads = 5
  OpsPerThread = 500
  TotalOps = NumWorkerThreads * OpsPerThread
  PayloadBytes = 512
  VecElements = PayloadBytes div sizeof(int32) ## 128 × int32 = 512 B
  PipelineWindow = 64
    ## max in-flight requests per worker; × NumWorkerThreads (320) must stay ≤
    ## the broker's slab/queue/response-slot capacities (512 below)

# ---------------------------------------------------------------------------
# Broker definitions — identical VecRequest shape to benchlib (echo the
# element count + a checksum of the payload).
# ---------------------------------------------------------------------------

RequestBroker:
  type VecReqSt = object
    length*: int32
    checksum*: int64

  proc signature*(payload: seq[int32]): Future[Result[VecReqSt, string]] {.async.}

RequestBroker(mt, queueDepth = 512, slabCapacity = 512, responseSlots = 512):
  # Pools sized for pipelining: total in-flight (PipelineWindow ×
  # NumWorkerThreads) must fit, else fired requests hit back-pressure
  # (slab/queue/response-slot exhaustion). Defaults (64/256/256) are too
  # small for the windowed pipeline below.
  type VecReqMt = object
    length*: int32
    checksum*: int64

  proc signature*(payload: seq[int32]): Future[Result[VecReqMt, string]] {.async.}

# ---------------------------------------------------------------------------
# Helpers — fmt/stat formatting mirrors perf_driver.cpp so the boxes line up.
# ---------------------------------------------------------------------------

proc makePayload(): seq[int32] =
  result = newSeq[int32](VecElements)
  for i in 0 ..< VecElements:
    result[i] = int32(i)

proc fmtNs(ns: int64): string =
  if ns >= 1_000_000_000:
    formatFloat(ns.float / 1e9, ffDecimal, 3) & " s"
  elif ns >= 1_000_000:
    formatFloat(ns.float / 1e6, ffDecimal, 3) & " ms"
  elif ns >= 1_000:
    formatFloat(ns.float / 1e3, ffDecimal, 1) & " µs"
  else:
    $ns & " ns"

proc fmtRate(ops: int, ns: int64): string =
  if ns <= 0:
    return "n/a"
  let rate = ops.float * 1e9 / ns.float
  if rate >= 1e6:
    formatFloat(rate / 1e6, ffDecimal, 2) & " M req/s"
  elif rate >= 1e3:
    formatFloat(rate / 1e3, ffDecimal, 2) & " K req/s"
  else:
    formatFloat(rate, ffDecimal, 1) & " req/s"

type LatStats = object
  avgNs, minNs, maxNs, p50Ns, p99Ns: int64

proc summarize(samples: var seq[int64]): LatStats =
  if samples.len == 0:
    return
  sort(samples)
  result.minNs = samples[0]
  result.maxNs = samples[^1]
  var s: int64 = 0
  for v in samples:
    s += v
  result.avgNs = s div samples.len.int64
  result.p50Ns = samples[samples.len div 2]
  let p99i = (samples.len * 99) div 100
  result.p99Ns = samples[min(p99i, samples.len - 1)]

proc report(title, csvTag, shape: string, ok, fail: int, wallNs: int64, s: LatStats) =
  echo ""
  echo "  ┌─── ", title, " ──────────"
  echo "  │ Workload       : ",
    NumWorkerThreads, " × ", OpsPerThread, " = ", TotalOps, " (", shape, ")"
  echo "  │ Payload        : ", PayloadBytes, " bytes (", VecElements, " × int32)"
  echo "  │ Successful     : ", ok, " / ", TotalOps, " (", fail, " failed)"
  echo "  │ Wall-clock     : ", fmtNs(wallNs)
  echo "  │ Throughput     : ", fmtRate(ok, wallNs)
  echo "  │ Avg latency    : ", fmtNs(s.avgNs)
  echo "  │ Min latency    : ", fmtNs(s.minNs)
  echo "  │ p50 latency    : ", fmtNs(s.p50Ns)
  echo "  │ p99 latency    : ", fmtNs(s.p99Ns)
  echo "  │ Max latency    : ", fmtNs(s.maxNs)
  echo "  └──────────────────────────────────────────────────────"
  # CSV: scenario,ok,fail,wall_ns,avg_ns,min_ns,p50_ns,p99_ns,max_ns
  echo "csv,perftest_inproc,",
    csvTag, ",", ok, ",", fail, ",", wallNs, ",", s.avgNs, ",", s.minNs, ",", s.p50Ns,
    ",", s.p99Ns, ",", s.maxNs

# ---------------------------------------------------------------------------
# Scenario ST — single-thread, sequential, dispatch-only floor.
# ---------------------------------------------------------------------------

proc runStScenario() {.async.} =
  let ctx = NewBrokerContext()
  let payload = makePayload()
  let provRes = VecReqSt.setProvider(
    ctx,
    proc(payload: seq[int32]): Future[Result[VecReqSt, string]] {.closure, async.} =
      var checksum: int64 = 0
      for v in payload:
        checksum += v
      return ok(VecReqSt(length: int32(payload.len), checksum: checksum)),
  )
  doAssert provRes.isOk(), "ST setProvider failed"

  var samples = newSeqOfCap[int64](TotalOps)
  var fail = 0
  let t0 = getMonoTime()
  for i in 0 ..< TotalOps:
    let c0 = getMonoTime()
    let r = await VecReqSt.request(ctx, payload)
    let dt = (getMonoTime() - c0).inNanoseconds
    if r.isErr() or r.get().length != VecElements.int32:
      inc fail
    else:
      samples.add(dt)
  let wall = (getMonoTime() - t0).inNanoseconds

  var s = summarize(samples)
  report(
    "In-proc Request — single-thread Nim",
    "st_request",
    "sequential, 1 thread",
    TotalOps - fail,
    fail,
    wall,
    s,
  )

# ---------------------------------------------------------------------------
# Scenario MT — 5 worker threads, cross-thread channel hop.
# ---------------------------------------------------------------------------

# refc-safe sample storage: fixed value-array, disjoint per-thread slices.
var gMtLat: array[NumWorkerThreads, array[OpsPerThread, int64]]
var gMtCount: array[NumWorkerThreads, int]
var gMtFail: array[NumWorkerThreads, int]
var gWorkersFinished: Atomic[int]
var gThreadOrdinal: Atomic[int]

proc mtWorker() {.thread.} =
  let ordinal = gThreadOrdinal.fetchAdd(1)
  let payload = makePayload() # thread-local; copied into the channel per request
  var k = 0
  var fail = 0
  for i in 0 ..< OpsPerThread:
    let c0 = getMonoTime()
    let r = waitFor VecReqMt.request(payload)
    let dt = (getMonoTime() - c0).inNanoseconds
    if r.isErr() or r.get().length != VecElements.int32:
      inc fail
    else:
      gMtLat[ordinal][k] = dt
      inc k
  gMtCount[ordinal] = k
  gMtFail[ordinal] = fail
  discard gWorkersFinished.fetchAdd(1)

proc runMtScenario() {.async.} =
  gWorkersFinished.store(0)
  gThreadOrdinal.store(0)

  let provRes = VecReqMt.setProvider(
    proc(payload: seq[int32]): Future[Result[VecReqMt, string]] {.async.} =
      var checksum: int64 = 0
      for v in payload:
        checksum += v
      ok(VecReqMt(length: int32(payload.len), checksum: checksum))
  )
  doAssert provRes.isOk(), "MT setProvider failed"

  var threads: array[NumWorkerThreads, Thread[void]]
  let t0 = getMonoTime()
  for i in 0 ..< NumWorkerThreads:
    threads[i].createThread(mtWorker)

  # Keep the provider's event loop alive so cross-thread requests get served.
  while gWorkersFinished.load() < NumWorkerThreads:
    await sleepAsync(chronos.milliseconds(1))
  let wall = (getMonoTime() - t0).inNanoseconds

  for i in 0 ..< NumWorkerThreads:
    threads[i].joinThread()
  VecReqMt.clearProvider()

  var all = newSeqOfCap[int64](TotalOps)
  var fail = 0
  for t in 0 ..< NumWorkerThreads:
    for k in 0 ..< gMtCount[t]:
      all.add(gMtLat[t][k])
    fail += gMtFail[t]

  var s = summarize(all)
  report(
    "In-proc Request — multi-thread Nim (cross-thread)",
    "mt_request",
    "5 threads",
    TotalOps - fail,
    fail,
    wall,
    s,
  )

# ---------------------------------------------------------------------------
# Scenario MT pipelined — each worker keeps a window of in-flight requests
# (fire without awaiting → collect futures → await allFinished), so the
# requester loop stays hot and amortizes the per-request wakeup.
# ---------------------------------------------------------------------------

proc mtPipelineBody(ordinal: int) {.async.} =
  let payload = makePayload()
  var done = 0
  var i = 0
  while i < OpsPerThread:
    let batch = min(PipelineWindow, OpsPerThread - i)
    var futs = newSeqOfCap[Future[Result[VecReqMt, string]]](batch)
    for b in 0 ..< batch:
      futs.add(VecReqMt.request(payload)) # fire — do NOT await yet
    discard await allFinished(futs) # async-wait for the whole window
    for f in futs:
      let r = f.read()
      if r.isOk() and r.get().length == VecElements.int32:
        inc done
    i += batch
  gMtCount[ordinal] = done

proc mtPipelineWorker() {.thread.} =
  let ordinal = gThreadOrdinal.fetchAdd(1)
  waitFor mtPipelineBody(ordinal)
  discard gWorkersFinished.fetchAdd(1)

proc runMtPipelinedScenario() {.async.} =
  gWorkersFinished.store(0)
  gThreadOrdinal.store(0)
  for t in 0 ..< NumWorkerThreads:
    gMtCount[t] = 0

  let provRes = VecReqMt.setProvider(
    proc(payload: seq[int32]): Future[Result[VecReqMt, string]] {.async.} =
      var checksum: int64 = 0
      for v in payload:
        checksum += v
      ok(VecReqMt(length: int32(payload.len), checksum: checksum))
  )
  doAssert provRes.isOk(), "MT pipelined setProvider failed"

  var threads: array[NumWorkerThreads, Thread[void]]
  let t0 = getMonoTime()
  for i in 0 ..< NumWorkerThreads:
    threads[i].createThread(mtPipelineWorker)
  while gWorkersFinished.load() < NumWorkerThreads:
    await sleepAsync(chronos.milliseconds(1))
  let wall = (getMonoTime() - t0).inNanoseconds
  for i in 0 ..< NumWorkerThreads:
    threads[i].joinThread()
  VecReqMt.clearProvider()

  var done = 0
  for t in 0 ..< NumWorkerThreads:
    done += gMtCount[t]

  echo ""
  echo "  ┌─── In-proc Request — multi-thread Nim PIPELINED (",
    NumWorkerThreads, " threads × window ", PipelineWindow,
    ") ──────────"
  echo "  │ Completed      : ", done, " / ", TotalOps
  echo "  │ Wall-clock     : ", fmtNs(wall)
  echo "  │ Throughput     : ", fmtRate(done, wall)
  echo "  └──────────────────────────────────────────────────────"
  echo "csv,perftest_inproc,mt_request_pipelined,",
    done, ",", TotalOps - done, ",", wall

proc main() {.async.} =
  echo "in-proc Nim request baselines — 5 × 500 × 512 B (vecRequest echo)"
  await runStScenario()
  await runMtScenario()
  await runMtPipelinedScenario()

waitFor main()
