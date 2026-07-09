{.used.}

import testutils/unittests
import chronos
import std/[strutils, atomics, monotimes]
from std/times import inNanoseconds

import brokers/signal_broker

## ---------------------------------------------------------------------------
## Performance / stress tests for multi-thread SignalBroker
## ---------------------------------------------------------------------------
##
##  1. Cross-thread stress: N emitter threads each fire M signals to a single
##     handler on the main thread. Measures per-signal delivery latency,
##     aggregate throughput, AND backpressure visibility — unlike EventBroker's
##     lossy `emit`, `signal` returns `err("queue full")` on ring overflow, so
##     the offered/accepted/delivered split is observable.
##  2. Same-thread baseline: handler and producer on the same thread (direct
##     asyncSpawn fast path, no ring).
## ---------------------------------------------------------------------------

const
  SignalsPerThread = 500
  NumEmitterThreads = 5
  TotalCrossThreadSignals = SignalsPerThread * NumEmitterThreads
  PayloadSize = 512

SignalBroker(mt, preset = fastBurst, maxPayloadBytes = 1024):
  type PerfSig = object
    tag*: string
    payload*: seq[byte]
    seqNum*: int
    timestampNs*: int64

var gDelivered: Atomic[int]
var gAccepted: Atomic[int]
var gRejected: Atomic[int]
var gLatencySumNs: Atomic[int64]
var gLatencyMinNs: Atomic[int64]
var gLatencyMaxNs: Atomic[int64]

proc makePayload(): seq[byte] =
  result = newSeq[byte](PayloadSize)
  for i in 0 ..< PayloadSize:
    result[i] = byte(i mod 256)

proc atomicMin(a: var Atomic[int64], val: int64) =
  while true:
    let cur = a.load()
    if val >= cur:
      return
    var expected = cur
    if a.compareExchange(expected, val):
      return

proc atomicMax(a: var Atomic[int64], val: int64) =
  while true:
    let cur = a.load()
    if val <= cur:
      return
    var expected = cur
    if a.compareExchange(expected, val):
      return

proc stressEmitter() {.thread.} =
  let payload = makePayload()
  for i in 0 ..< SignalsPerThread:
    let r = PerfSig.signal(
      PerfSig(
        tag: "stress", payload: payload, seqNum: i, timestampNs: getMonoTime().ticks
      )
    )
    if r.isOk():
      discard gAccepted.fetchAdd(1)
    else:
      discard gRejected.fetchAdd(1)

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
    formatFloat(rps / 1_000_000, ffDecimal, 2) & " M sig/s"
  elif rps >= 1_000:
    formatFloat(rps / 1_000, ffDecimal, 2) & " K sig/s"
  else:
    formatFloat(rps, ffDecimal, 1) & " sig/s"

suite "Multi-thread SignalBroker — performance":
  asyncTest "Cross-thread stress: " & $NumEmitterThreads & " emitters × " &
    $SignalsPerThread & " signals (payload " & $PayloadSize & "B)":
    gDelivered.store(0)
    gAccepted.store(0)
    gRejected.store(0)
    gLatencySumNs.store(0)
    gLatencyMinNs.store(int64.high)
    gLatencyMaxNs.store(0)

    let installed = PerfSig.onSignal(
      proc(s: PerfSig) {.async: (raises: []).} =
        let now = getMonoTime().ticks
        let latency = now - s.timestampNs
        discard gLatencySumNs.fetchAdd(latency)
        atomicMin(gLatencyMinNs, latency)
        atomicMax(gLatencyMaxNs, latency)
        discard gDelivered.fetchAdd(1)
    )
    check installed.isOk()

    var threads: array[NumEmitterThreads, Thread[void]]
    let wallStart = getMonoTime()
    for i in 0 ..< NumEmitterThreads:
      threads[i].createThread(stressEmitter)

    const EmitJoinTimeoutMs = 30_000
    const PostEmitWaitMs = 2_000
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
    let accepted = gAccepted.load().int

    # Drain window: deliver everything that was ACCEPTED (rejects never arrive).
    let drainStart = getMonoTime()
    while gDelivered.load() < accepted:
      if (getMonoTime() - drainStart).inNanoseconds >= PostEmitWaitMs.int64 * 1_000_000:
        break
      await sleepAsync(chronos.milliseconds(1))

    let wallElapsed = (getMonoTime() - wallStart).inNanoseconds
    let delivered = gDelivered.load().int
    let rejected = gRejected.load().int

    await PerfSig.dropSignalHandler()
    await sleepAsync(chronos.milliseconds(50))

    let denom = max(delivered, 1)
    let avgNs = gLatencySumNs.load() div int64(denom)

    echo ""
    echo "  ┌─── Cross-Thread Signal Results ──────────────────────"
    echo "  │ Offered        : ", TotalCrossThreadSignals
    echo "  │ Accepted (ok)  : ",
      accepted,
      " (",
      formatFloat(
        float64(accepted) * 100.0 / float64(TotalCrossThreadSignals), ffDecimal, 2
      ),
      "%)"
    echo "  │ Rejected (full): ", rejected, " (backpressure, not silent drop)"
    echo "  │ Delivered      : ", delivered
    echo "  │ Emit window    : ", fmtNs(emitElapsed)
    echo "  │ Total wall     : ", fmtNs(wallElapsed)
    echo "  │ Offer rate     : ", fmtRate(TotalCrossThreadSignals, emitElapsed)
    echo "  │ Delivery rate  : ", fmtRate(delivered, wallElapsed)
    echo "  │ Avg latency    : ", fmtNs(avgNs)
    echo "  │ Min latency    : ", fmtNs(gLatencyMinNs.load())
    echo "  │ Max latency    : ", fmtNs(gLatencyMaxNs.load())
    echo "  │ Payload size   : ", PayloadSize, " bytes"
    echo "  └──────────────────────────────────────────────────────"
    echo ""

    # Every offered signal is accounted for — accepted + rejected == offered
    # (nothing is silently dropped at the accept boundary), and every accepted
    # signal is delivered within the drain window.
    check accepted + rejected == TotalCrossThreadSignals
    check delivered == accepted

  asyncTest "Same-thread baseline: " & $TotalCrossThreadSignals & " signals":
    gDelivered.store(0)
    let payload = makePayload()
    let installed = PerfSig.onSignal(
      proc(s: PerfSig) {.async: (raises: []).} =
        discard gDelivered.fetchAdd(1)
    )
    check installed.isOk()

    let wallStart = getMonoTime()
    for i in 0 ..< TotalCrossThreadSignals:
      discard PerfSig.signal(
        PerfSig(tag: "base", payload: payload, seqNum: i, timestampNs: 0)
      )
    let offerElapsed = (getMonoTime() - wallStart).inNanoseconds

    let drainStart = getMonoTime()
    while gDelivered.load() < TotalCrossThreadSignals:
      if (getMonoTime() - drainStart).inNanoseconds >= 2_000 * 1_000_000:
        break
      await sleepAsync(chronos.milliseconds(1))
    let wallElapsed = (getMonoTime() - wallStart).inNanoseconds

    await PerfSig.dropSignalHandler()
    await sleepAsync(chronos.milliseconds(50))

    echo ""
    echo "  ┌─── Same-Thread Signal Baseline ──────────────────────"
    echo "  │ Signals        : ", TotalCrossThreadSignals
    echo "  │ Delivered      : ", gDelivered.load()
    echo "  │ Offer window   : ", fmtNs(offerElapsed)
    echo "  │ Total wall     : ", fmtNs(wallElapsed)
    echo "  │ Offer rate     : ", fmtRate(TotalCrossThreadSignals, offerElapsed)
    echo "  └──────────────────────────────────────────────────────"
    echo ""
    check gDelivered.load() == TotalCrossThreadSignals
