{.used.}

import testutils/unittests
import chronos
import std/[strutils, atomics, monotimes]
from std/times import inNanoseconds

import brokers/event_broker

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

# Tuned for burst: defaults (queueDepth=256, slabCapacity=1024) overflow
# under 5×500 emitter bursts. The `fastBurst` preset bumps both with a
# small per-cell payload size. Memory cost (PayloadSize = 512 B fits in
# fastBurst's 256 B cap? — no; bump maxPayloadBytes to 1024 for our test).
#   ring  =  4096 slots × ~24 B   ≈   96 KB
#   slab  =  8192 cells × ~1056 B ≈  8.4 MB
#   total ≈ ~8.5 MB (vs ~1.1 MB at defaults).
EventBroker(mt, preset = fastBurst, maxPayloadBytes = 1024):
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
    PerfEvt.emit(
      PerfEvt(
        tag: "stress", payload: payload, seqNum: i, timestampNs: getMonoTime().ticks
      )
    )

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

    # Phase 1: wait for emitter threads to finish issuing events.
    # We poll thread state while keeping the event loop alive so the
    # listener can drain events into gEventsReceived.
    # NOTE: the new ring-based MT EventBroker drops events when the listener
    # ring is full (lossy, non-blocking emit); we cap the post-emit wait and
    # report delivered/emitted instead of assuming losslessness.
    const PostEmitWaitMs = 2_000
    const EmitJoinTimeoutMs = 30_000

    let emitJoinDeadlineNs = wallStart.ticks + EmitJoinTimeoutMs.int64 * 1_000_000
    while true:
      var allDone = true
      for i in 0 ..< NumEmitterThreads:
        if threads[i].running:
          allDone = false
          break
      if allDone or getMonoTime().ticks >= emitJoinDeadlineNs:
        break
      await sleepAsync(chronos.milliseconds(1))

    for i in 0 ..< NumEmitterThreads:
      threads[i].joinThread()

    let emitElapsed = (getMonoTime() - wallStart).inNanoseconds

    # Phase 2: short drain window for in-flight events to be delivered.
    let drainStart = getMonoTime()
    while gEventsReceived.load() < TotalCrossThreadEvents:
      if (getMonoTime() - drainStart).inNanoseconds >= PostEmitWaitMs.int64 * 1_000_000:
        break
      await sleepAsync(chronos.milliseconds(1))

    let wallElapsed = (getMonoTime() - wallStart).inNanoseconds
    let delivered = gEventsReceived.load().int

    await PerfEvt.dropAllListeners()
    await sleepAsync(chronos.milliseconds(50))

    # -- Statistics --
    let denom = max(delivered, 1)
    let avgNs = gLatencySumNs.load() div int64(denom)
    let minNs = gLatencyMinNs.load()
    let maxNs = gLatencyMaxNs.load()

    echo ""
    echo "  ┌─── Cross-Thread Results ─────────────────────────────"
    echo "  │ Emitted        : ", TotalCrossThreadEvents
    echo "  │ Delivered      : ",
      delivered,
      " (",
      formatFloat(
        float64(delivered) * 100.0 / float64(TotalCrossThreadEvents), ffDecimal, 2
      ),
      "%)"
    echo "  │ Dropped        : ", TotalCrossThreadEvents - delivered
    echo "  │ Emit window    : ", fmtNs(emitElapsed)
    echo "  │ Total wall     : ", fmtNs(wallElapsed)
    echo "  │ Emit rate      : ",
      fmtRate(TotalCrossThreadEvents, emitElapsed), " (offered)"
    echo "  │ Delivery rate  : ", fmtRate(delivered, wallElapsed), " (received)"
    echo "  │ Avg latency    : ", fmtNs(avgNs)
    echo "  │ Min latency    : ", fmtNs(minNs)
    echo "  │ Max latency    : ", fmtNs(maxNs)
    echo "  │ Payload size   : ", PayloadSize, " bytes"
    echo "  └──────────────────────────────────────────────────────"
    echo ""

  asyncTest "Same-thread baseline: " & $TotalCrossThreadEvents & " events (payload " &
    $PayloadSize & "B)":
    let payload = makePayload()
    var receivedCount = 0
    var sumNs: int64 = 0
    var minNs: int64 = int64.high
    var maxNs: int64 = 0

    # Listener on same thread — uses the fast path (asyncSpawn, no channel).
    let handle = PerfEvt.listen(
      proc(evt: PerfEvt): Future[void] {.async: (raises: []).} =
        discard # callback runs synchronously in same-thread mode
    )
    check handle.isOk()

    let wallStart = getMonoTime()

    for i in 0 ..< TotalCrossThreadEvents:
      let t0 = getMonoTime()
      PerfEvt.emit(PerfEvt(tag: "local", payload: payload, seqNum: i, timestampNs: 0))
      # Yield to let asyncSpawn'd listeners run.
      await sleepAsync(chronos.milliseconds(0))
      let elapsed = (getMonoTime() - t0).inNanoseconds

      sumNs += elapsed
      if elapsed < minNs:
        minNs = elapsed
      if elapsed > maxNs:
        maxNs = elapsed
      receivedCount += 1

    let wallElapsed = (getMonoTime() - wallStart).inNanoseconds

    await PerfEvt.dropAllListeners()
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
