## perf_phases.nim — phase-timed breakdown of an MT RequestBroker round-trip.
##
## Splits one cross-thread request into three legs by stamping a shared
## monotonic clock (one `gEpoch`, so timestamps taken on different threads are
## directly comparable) at four points:
##
##   reqStart  (requester, before `waitFor request`)
##   provEnter (provider body entry — carried back in the response)
##   provExit  (provider body exit  — carried back in the response)
##   reqEnd    (requester, after `waitFor request` returns)
##
##   inbound  = provEnter − reqStart   enqueue + signal + provider wake + dequeue + dispatch
##   handler  = provExit  − provEnter  the provider body itself (trivial echo)
##   outbound = reqEnd    − provExit   reply marshal + signal + requester wake + future complete
##
## Three configs:
##   same-thread  — requester == provider thread → MT same-thread fast path
##                  (no ring, no signals). The dispatch floor.
##   cross ×1     — 1 worker thread, provider on main. Clean per-request wake cost.
##   cross ×5     — 5 worker threads. Adds lock + scheduler contention (the
##                  perf_inproc MT shape).
##
## refc-safe: workers write only int64 phase samples into fixed global
## value-arrays (disjoint per-thread slices); no seq crosses a thread.

{.used.}

import std/[monotimes, times, strutils, algorithm, atomics]

import chronos
import brokers/request_broker

const
  NumWorkerThreads = 5
  OpsPerThread = 500
  PayloadBytes = 512
  VecElements = PayloadBytes div sizeof(int32)

var gEpoch: MonoTime

proc nowNs(): int64 {.inline, gcsafe.} =
  (getMonoTime() - gEpoch).inNanoseconds

# ---------------------------------------------------------------------------
# Broker — response carries the provider-side timestamps back to the caller.
# ---------------------------------------------------------------------------

RequestBroker(mt):
  type PhaseReq = object
    length*: int32
    checksum*: int64
    provEnterNs*: int64
    provExitNs*: int64

  proc signature*(payload: seq[int32]): Future[Result[PhaseReq, string]] {.async.}

proc makePayload(): seq[int32] =
  result = newSeq[int32](VecElements)
  for i in 0 ..< VecElements:
    result[i] = int32(i)

# ---------------------------------------------------------------------------
# Stats
# ---------------------------------------------------------------------------

type LatStats = object
  avgNs, minNs, p50Ns, p99Ns, maxNs: int64

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
  result.p99Ns = samples[min((samples.len * 99) div 100, samples.len - 1)]

proc fmtNs(ns: int64): string =
  if ns >= 1_000_000:
    formatFloat(ns.float / 1e6, ffDecimal, 3) & " ms"
  elif ns >= 1_000:
    formatFloat(ns.float / 1e3, ffDecimal, 2) & " µs"
  else:
    $ns & " ns"

proc line(name: string, s: LatStats) =
  echo "  │ ",
    alignLeft(name, 10),
    " avg ",
    align(fmtNs(s.avgNs), 9),
    "   p50 ",
    align(fmtNs(s.p50Ns), 9),
    "   p99 ",
    align(fmtNs(s.p99Ns), 9),
    "   max ",
    align(fmtNs(s.maxNs), 9)

# ---------------------------------------------------------------------------
# Cross-thread storage — fixed value-arrays, disjoint per-thread slices.
# ---------------------------------------------------------------------------

var gInbound: array[NumWorkerThreads, array[OpsPerThread, int64]]
var gHandler: array[NumWorkerThreads, array[OpsPerThread, int64]]
var gOutbound: array[NumWorkerThreads, array[OpsPerThread, int64]]
var gTotal: array[NumWorkerThreads, array[OpsPerThread, int64]]
var gCount: array[NumWorkerThreads, int]
var gWorkersFinished: Atomic[int]
var gThreadOrdinal: Atomic[int]

proc phaseWorker() {.thread.} =
  let ordinal = gThreadOrdinal.fetchAdd(1)
  let payload = makePayload()
  var k = 0
  for i in 0 ..< OpsPerThread:
    let reqStart = nowNs()
    let r = waitFor PhaseReq.request(payload)
    let reqEnd = nowNs()
    if r.isOk() and r.get().length == VecElements.int32:
      let v = r.get()
      gInbound[ordinal][k] = v.provEnterNs - reqStart
      gHandler[ordinal][k] = v.provExitNs - v.provEnterNs
      gOutbound[ordinal][k] = reqEnd - v.provExitNs
      gTotal[ordinal][k] = reqEnd - reqStart
      inc k
  gCount[ordinal] = k
  discard gWorkersFinished.fetchAdd(1)

proc collect(nWorkers: int): tuple[inb, hnd, outb, tot: seq[int64]] =
  for t in 0 ..< nWorkers:
    for k in 0 ..< gCount[t]:
      result.inb.add(gInbound[t][k])
      result.hnd.add(gHandler[t][k])
      result.outb.add(gOutbound[t][k])
      result.tot.add(gTotal[t][k])

proc reportCross(
    title: string, nWorkers: int, c: tuple[inb, hnd, outb, tot: seq[int64]]
) =
  echo ""
  echo "  ┌─── ",
    title, " (", nWorkers, " worker × ", OpsPerThread,
    ") ──────────"
  var inb = c.inb
  var hnd = c.hnd
  var outb = c.outb
  var tot = c.tot
  line("inbound", summarize(inb))
  line("handler", summarize(hnd))
  line("outbound", summarize(outb))
  line("TOTAL", summarize(tot))
  echo "  └──────────────────────────────────────────────────────"

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

proc runSameThread() {.async.} =
  ## Requester and provider on the SAME (main) thread → fast path.
  let payload = makePayload()
  var tot = newSeqOfCap[int64](OpsPerThread)
  for i in 0 ..< OpsPerThread:
    let t0 = nowNs()
    let r = await PhaseReq.request(payload)
    let t1 = nowNs()
    if r.isOk():
      tot.add(t1 - t0)
  echo ""
  echo "  ┌─── same-thread (fast path, no cross-thread) ──────────"
  line("TOTAL", summarize(tot))
  echo "  └──────────────────────────────────────────────────────"

proc runCross(nWorkers: int, title: string) {.async.} =
  gWorkersFinished.store(0)
  gThreadOrdinal.store(0)
  for t in 0 ..< NumWorkerThreads:
    gCount[t] = 0
  var threads: array[NumWorkerThreads, Thread[void]]
  for i in 0 ..< nWorkers:
    threads[i].createThread(phaseWorker)
  while gWorkersFinished.load() < nWorkers:
    await sleepAsync(chronos.milliseconds(1))
  for i in 0 ..< nWorkers:
    threads[i].joinThread()
  reportCross(title, nWorkers, collect(nWorkers))

proc main() {.async.} =
  gEpoch = getMonoTime()
  let provRes = PhaseReq.setProvider(
    proc(payload: seq[int32]): Future[Result[PhaseReq, string]] {.async.} =
      let enter = nowNs()
      var c: int64 = 0
      for v in payload:
        c += v
      let exit = nowNs()
      return ok(
        PhaseReq(
          length: payload.len.int32, checksum: c, provEnterNs: enter, provExitNs: exit
        )
      )
  )
  doAssert provRes.isOk(), "setProvider failed"

  echo "MT RequestBroker round-trip — phase breakdown (", PayloadBytes, " B payload)"
  await runSameThread()
  await runCross(1, "cross-thread")
  await runCross(NumWorkerThreads, "cross-thread")

waitFor main()
