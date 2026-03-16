{.used.}

import testutils/unittests
import chronos
import std/[strutils, atomics, monotimes]
from std/times import inNanoseconds

import event_broker

## ---------------------------------------------------------------------------
## Performance / stress tests for multi-thread EventBroker
## ---------------------------------------------------------------------------
##
## Two scenarios:
##  1. Cross-thread stress: 5 emitter threads each fire N events to a single
##     listener on the main thread. Measures per-event delivery latency and
##     aggregate throughput.
##  2. Same-thread baseline: emitter and listener on the same thread.
##     Measures the fast-path cost for comparison.
##
## Both use a realistic payload (seq[byte] data in events) to account for
## cross-thread copy overhead.
## ---------------------------------------------------------------------------

const
  EventsPerThread = 500
  NumEmitterThreads = 5
  TotalCrossThreadEvents = EventsPerThread * NumEmitterThreads
  PayloadSize = 512 ## bytes in the event payload

# ---------------------------------------------------------------------------
# Broker definition — realistic payload with seq data
# ---------------------------------------------------------------------------

EventBroker(mt):
  type PerfEvt = object
    tag*: string
    payload*: seq[byte]
    seqNum*: int
    timestampNs*: int64 ## mono time at emit (for latency measurement)

# ---------------------------------------------------------------------------
# Global synchronization
# ---------------------------------------------------------------------------

var gEventsReceived: Atomic[int]
var gLatencySumNs: Atomic[int64]
var gLatencyMinNs: Atomic[int64]
var gLatencyMaxNs: Atomic[int64]

# ---------------------------------------------------------------------------
# Helper: build payload of PayloadSize bytes
# ---------------------------------------------------------------------------

proc makePayload(): seq[byte] =
  result = newSeq[byte](PayloadSize)
  for i in 0 ..< PayloadSize:
    result[i] = byte(i mod 256)

# ---------------------------------------------------------------------------
# Helper: atomic min/max update (CAS loop)
# ---------------------------------------------------------------------------

proc atomicMin(a: var Atomic[int64], val: int64) =
  var cur = a.load()
  while val < cur:
    if a.compareExchange(cur, val):
      return

proc atomicMax(a: var Atomic[int64], val: int64) =
  var cur = a.load()
  while val > cur:
    if a.compareExchange(cur, val):
      return

# ---------------------------------------------------------------------------
# Emitter thread proc — fires EventsPerThread events
# ---------------------------------------------------------------------------

proc stressEmitter() {.thread.} =
  let payload = makePayload()
  for i in 0 ..< EventsPerThread:
    PerfEvt.emit(PerfEvt(
      tag: "stress",
      payload: payload,
      seqNum: i,
      timestampNs: getMonoTime().ticks,
    ))

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
  if elapsedNs == 0: return "∞"
  let rps = float64(count) * 1e9 / float64(elapsedNs)
  if rps >= 1_000_000:
    formatFloat(rps / 1_000_000, ffDecimal, 2) & " M evt/s"
  elif rps >= 1_000:
    formatFloat(rps / 1_000, ffDecimal, 2) & " K evt/s"
  else:
    formatFloat(rps, ffDecimal, 1) & " evt/s"

# ---------------------------------------------------------------------------
# Test suite
# ---------------------------------------------------------------------------

suite "Multi-thread EventBroker — performance":

  asyncTest "Cross-thread stress: " & $NumEmitterThreads & " emitters × " &
            $EventsPerThread & " events (payload " & $PayloadSize & "B)":
    gEventsReceived.store(0)
    gLatencySumNs.store(0)
    gLatencyMinNs.store(int64.high)
    gLatencyMaxNs.store(0)

    # Register listener on main thread — measures delivery latency.
    let handle = PerfEvt.listen(
      proc(evt: PerfEvt): Future[void] {.async: (raises: []).} =
        let now = getMonoTime().ticks
        let latency = now - evt.timestampNs
        discard gLatencySumNs.fetchAdd(latency)
        atomicMin(gLatencyMinNs, latency)
        atomicMax(gLatencyMaxNs, latency)
        discard gEventsReceived.fetchAdd(1)
    )
    check handle.isOk()

    # Spawn emitter threads.
    var threads: array[NumEmitterThreads, Thread[void]]
    let wallStart = getMonoTime()

    for i in 0 ..< NumEmitterThreads:
      threads[i].createThread(stressEmitter)

    # Keep event loop alive so processLoop can dispatch events.
    while gEventsReceived.load() < TotalCrossThreadEvents:
      await sleepAsync(chronos.milliseconds(1))

    let wallElapsed = (getMonoTime() - wallStart).inNanoseconds

    for i in 0 ..< NumEmitterThreads:
      threads[i].joinThread()

    PerfEvt.dropAllListeners()
    await sleepAsync(chronos.milliseconds(50))

    # -- Statistics --
    let avgNs = gLatencySumNs.load() div int64(TotalCrossThreadEvents)
    let minNs = gLatencyMinNs.load()
    let maxNs = gLatencyMaxNs.load()

    echo ""
    echo "  ┌─── Cross-Thread Results ─────────────────────────────"
    echo "  │ Total events   : ", TotalCrossThreadEvents
    echo "  │ Wall-clock time: ", fmtNs(wallElapsed)
    echo "  │ Throughput     : ", fmtRate(TotalCrossThreadEvents, wallElapsed)
    echo "  │ Avg latency    : ", fmtNs(avgNs)
    echo "  │ Min latency    : ", fmtNs(minNs)
    echo "  │ Max latency    : ", fmtNs(maxNs)
    echo "  │ Payload size   : ", PayloadSize, " bytes"
    echo "  └──────────────────────────────────────────────────────"
    echo ""

  asyncTest "Same-thread baseline: " & $TotalCrossThreadEvents &
            " events (payload " & $PayloadSize & "B)":
    let payload = makePayload()
    var receivedCount = 0
    var sumNs: int64 = 0
    var minNs: int64 = int64.high
    var maxNs: int64 = 0

    # Listener on same thread — uses the fast path (asyncSpawn, no channel).
    let handle = PerfEvt.listen(
      proc(evt: PerfEvt): Future[void] {.async: (raises: []).} =
        discard  # callback runs synchronously in same-thread mode
    )
    check handle.isOk()

    let wallStart = getMonoTime()

    for i in 0 ..< TotalCrossThreadEvents:
      let t0 = getMonoTime()
      PerfEvt.emit(PerfEvt(
        tag: "local",
        payload: payload,
        seqNum: i,
        timestampNs: 0,
      ))
      # Yield to let asyncSpawn'd listeners run.
      await sleepAsync(chronos.milliseconds(0))
      let elapsed = (getMonoTime() - t0).inNanoseconds

      sumNs += elapsed
      if elapsed < minNs: minNs = elapsed
      if elapsed > maxNs: maxNs = elapsed
      receivedCount += 1

    let wallElapsed = (getMonoTime() - wallStart).inNanoseconds

    PerfEvt.dropAllListeners()
    await sleepAsync(chronos.milliseconds(50))

    let avgNs = sumNs div int64(TotalCrossThreadEvents)

    echo ""
    echo "  ┌─── Same-Thread Results (baseline) ───────────────────"
    echo "  │ Total events   : ", TotalCrossThreadEvents
    echo "  │ Wall-clock time: ", fmtNs(wallElapsed)
    echo "  │ Throughput     : ", fmtRate(TotalCrossThreadEvents, wallElapsed)
    echo "  │ Avg latency    : ", fmtNs(avgNs)
    echo "  │ Min latency    : ", fmtNs(minNs)
    echo "  │ Max latency    : ", fmtNs(maxNs)
    echo "  │ Payload size   : ", PayloadSize, " bytes"
    echo "  └──────────────────────────────────────────────────────"
    echo ""

    echo "  Note: Compare 'Avg latency' between cross-thread and same-thread"
    echo "        to see the per-event cost of channel I/O + thread sync."
    echo ""
