## benchlib — Phase 0 microbenchmark library for the CBOR refactoring.
## ====================================================================
## See doc/CBOR_Refactoring.md §7.3. This library exposes two request
## brokers used to measure the FFI `_call` path:
##
##   - AddRequest  — the simple all-scalar case  (add(a, b) -> sum)
##   - VecRequest  — a variable-size payload case (echo seq[int32])
##
## After the native FFI codegen retirement (Phase 2 of CBOR_Refactoring),
## only the `-d:BrokerFfiApi` build is reachable; the historical
## native baseline captured in doc/bench_baseline.md is the reference
## point for evaluating future optimizations against this same driver.

{.push raises: [].}

import std/[atomics, locks, os]
import
  brokers/[event_broker, request_broker, signal_broker, broker_context, api_library]
import brokers/internal/mt_broker_common

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
# Part D-4 — event broker + Nim-side listener setup
#
# benchlib gains a single event broker (`PingEvent`) plus a small set of
# control requests that let a foreign driver wire up Lane 1 (same-thread
# Nim listener) and Lane 2 (cross-thread Nim listener) audiences, alongside
# the foreign-callback Lane 3 they already drive via `_subscribe`. The
# control surface is:
#
#   `installSameThreadNimListenersRequest(count)`   — Lane 1 setup
#   `installCrossThreadNimListenerRequest()`        — Lane 2 setup
#   `triggerEmitRequest(count)`                     — emit N PingEvents
#   `getStatsRequest()`                             — read back the per-lane
#                                                     delivered counts
#
# All listener-side counters live in shared-heap atomics so the cross-thread
# Nim listener (spawned on its own non-broker thread) can update them
# without GC involvement.
# ---------------------------------------------------------------------------

EventBroker(API):
  type PingEvent = object
    seqNo*: int64

RequestBroker(API):
  type InstallSameThreadNimListenersRequest = object
    installed*: int32

  proc signature*(
    count: int32
  ): Future[Result[InstallSameThreadNimListenersRequest, string]] {.async.}

RequestBroker(API):
  type InstallCrossThreadNimListenerRequest = object
    installed*: int32

  proc signature*(): Future[Result[InstallCrossThreadNimListenerRequest, string]] {.
    async
  .}

RequestBroker(API):
  type TriggerEmitRequest = object
    emitted*: int32

  proc signature*(count: int32): Future[Result[TriggerEmitRequest, string]] {.async.}

RequestBroker(API):
  type GetStatsRequest = object
    sameThreadCount*: int64
    crossThreadCount*: int64

  proc signature*(): Future[Result[GetStatsRequest, string]] {.async.}

# ---------------------------------------------------------------------------
# FFI perftest — wider PingEvent variant + emit-now-with-payload trigger.
#
# Mirrors the Nim-side perf_test_multi_thread_event_broker.nim shape
# (5 emitters × 500 events × 512 B payload). Used by
# test/ffibench/perf_driver.cpp to measure end-to-end FFI overhead vs
# the Nim-direct numbers `nimble perftest` prints.
#
# The payload carries an emit-side timestamp (mono ns) so the C++
# subscriber can compute per-event delivery latency exactly the same
# way the Nim-side test does.
# ---------------------------------------------------------------------------

EventBroker(API):
  type PingPayloadEvent = object
    seqNo*: int64
    emitTimestampNs*: int64
    bytes*: seq[byte]

RequestBroker(API):
  type TriggerPingPayloadRequest = object
    emitted*: int32

  proc signature*(
    count: int32, payloadSize: int32, emitTimestampNs: int64
  ): Future[Result[TriggerPingPayloadRequest, string]] {.async.}

# ---------------------------------------------------------------------------
# E2E throughput bench surface (bench_e2e_driver.cpp).
#
# Three lanes x two payload families, all sharing ONE trivial O(1) parity
# predicate as the handler compute — so the families differ purely in
# TRANSPORT cost (encode/copy/decode of the payload), never in handler work:
#
#   PayloadSignal / PayloadCheckRequest — 500 B `seq[byte]` payload; the
#       predicate reads first byte, last byte, and length (O(1), payload
#       content is NOT walked).
#   ScalarSignal / ScalarCheckRequest   — 2 x int64 + 1 x float64 scalars;
#       the same predicate over (a, b, x).
#   E2eStatsRequest — reads the signal-lane counters (driver works with
#       deltas, so it is iteration-restart safe).
#
# Request lanes return the predicate bool; signal lanes count true results
# so the driver can verify the aggregate by delta.
# ---------------------------------------------------------------------------

SignalBroker(API):
  type PayloadSignal = object
    payload*: seq[byte]

RequestBroker(API):
  type PayloadCheckRequest = object
    ok*: bool

  proc signature*(
    payload: seq[byte]
  ): Future[Result[PayloadCheckRequest, string]] {.async.}

SignalBroker(API):
  type ScalarSignal = object
    a*: int64
    b*: int64
    x*: float64

RequestBroker(API):
  type ScalarCheckRequest = object
    ok*: bool

  proc signature*(
    a: int64, b: int64, x: float64
  ): Future[Result[ScalarCheckRequest, string]] {.async.}

RequestBroker(API):
  type E2eStatsRequest = object
    payloadProcessed*: int64
    payloadTrue*: int64
    scalarProcessed*: int64
    scalarTrue*: int64

  proc signature*(): Future[Result[E2eStatsRequest, string]] {.async.}

var gE2ePayloadProcessed: Atomic[int64]
var gE2ePayloadTrue: Atomic[int64] ## count of true predicate results
var gE2eScalarProcessed: Atomic[int64]
var gE2eScalarTrue: Atomic[int64] ## count of true predicate results

proc scalarPred(a, b: int64, x: float64): bool =
  ## The shared trivial compute. `int64(x)` truncates toward zero on both
  ## sides of the boundary (IEEE double, values < 2^52 in the driver), so the
  ## C++ driver can predict the result exactly.
  ((a + b + int64(x)) and 1) == 0

proc payloadPred(payload: openArray[byte]): bool =
  ## Same predicate, inputs sourced from O(1) reads of the payload — the
  ## bytes are never walked, so handler cost is identical to the scalar lane.
  if payload.len == 0:
    return scalarPred(0, 0, 0.0)
  scalarPred(int64(payload[0]), int64(payload[^1]), float64(payload.len))

# Shared-heap counters for the Nim audiences. Updated under moRelaxed from
# whichever thread the listener fires on; read under moAcquire by the
# stats provider on the processing thread.
var gSameThreadCount: Atomic[int64]
var gCrossThreadCount: Atomic[int64]

# Cross-thread Nim listener support. Spawned on demand by the
# `installCrossThreadNimListener` provider. The thread sits in a chronos
# event loop on its own broker dispatch signal until the library shuts down.
var gCrossThreadStarted: Atomic[int]
var gCrossThreadShouldStop: Atomic[int]
var gCrossThreadCtx: BrokerContext
var gCrossThread: Thread[BrokerContext]
var gCrossThreadReady: Atomic[int]

proc crossThreadListenerProc(ctx: BrokerContext) {.thread.} =
  setThreadBrokerContext(ctx)
  discard getOrInitBrokerSignal()

  let listenRes = PingEvent.listen(
    ctx,
    proc(evt: PingEvent): Future[void] {.async: (raises: []), gcsafe.} =
      discard gCrossThreadCount.fetchAdd(1, moRelaxed),
  )
  if listenRes.isErr:
    gCrossThreadReady.store(-1, moRelease)
    return

  ensureBrokerDispatchStarted()
  gCrossThreadReady.store(1, moRelease)

  proc awaitStop(flag: ptr Atomic[int]) {.async: (raises: []).} =
    while flag[].load(moAcquire) != 1:
      let s = catch:
        await sleepAsync(milliseconds(5))
      if s.isErr():
        discard

  waitFor awaitStop(addr gCrossThreadShouldStop)
  stopBrokerDispatchHere()

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

  # Part D-4 — Lane 1 (same-thread Nim listener) installer. Registers
  # `count` listeners on THIS thread (the processing thread). Emit fires
  # on the same thread, so the MT EventBroker takes its same-thread
  # direct asyncSpawn fast path — Lane 1 is exercised end-to-end.
  let installSameRes = InstallSameThreadNimListenersRequest.setProvider(
    ctx,
    proc(
        count: int32
    ): Future[Result[InstallSameThreadNimListenersRequest, string]] {.closure, async.} =
      var installed: int32 = 0
      for _ in 0 ..< count:
        let r = PingEvent.listen(
          ctx,
          proc(evt: PingEvent): Future[void] {.async: (raises: []), gcsafe.} =
            discard gSameThreadCount.fetchAdd(1, moRelaxed),
        )
        if r.isOk:
          inc installed
      return ok(InstallSameThreadNimListenersRequest(installed: installed)),
  )
  if installSameRes.isErr():
    return
      err("InstallSameThreadNimListenersRequest provider: " & installSameRes.error())

  # Part D-4 — Lane 2 (cross-thread Nim listener) installer. Spawns a
  # dedicated Nim thread that listens on PingEvent. Emit on the
  # processing thread then takes the MT EventBroker typed-slab
  # cross-thread path — Lane 2 is exercised end-to-end.
  let installCrossRes = InstallCrossThreadNimListenerRequest.setProvider(
    ctx,
    proc(): Future[Result[InstallCrossThreadNimListenerRequest, string]] {.
        closure, async
    .} =
      var expected = 0
      if not gCrossThreadStarted.compareExchange(expected, 1, moAcquire, moRelaxed):
        return ok(InstallCrossThreadNimListenerRequest(installed: 1))
      gCrossThreadCtx = ctx
      gCrossThreadShouldStop.store(0, moRelaxed)
      gCrossThreadReady.store(0, moRelaxed)
      try:
        createThread(gCrossThread, crossThreadListenerProc, ctx)
      except Exception as exc:
        gCrossThreadStarted.store(0, moRelease)
        return err("crossThreadListener spawn failed: " & exc.msg)
      # Spin until the cross-thread listener has registered (otherwise the
      # next emit may race the .listen() call).
      var waited = 0
      while gCrossThreadReady.load(moAcquire) == 0 and waited < 5000:
        sleep(1)
        inc waited
      if gCrossThreadReady.load(moAcquire) != 1:
        return err("crossThreadListener failed to become ready")
      return ok(InstallCrossThreadNimListenerRequest(installed: 1)),
  )
  if installCrossRes.isErr():
    return
      err("InstallCrossThreadNimListenerRequest provider: " & installCrossRes.error())

  # Part D-4 — emit driver. Emits `count` PingEvents from the processing
  # thread. Each emit fans out across whatever audiences are wired up.
  let emitRes = TriggerEmitRequest.setProvider(
    ctx,
    proc(count: int32): Future[Result[TriggerEmitRequest, string]] {.closure, async.} =
      for i in 0 ..< count:
        PingEvent.emit(ctx, PingEvent(seqNo: int64(i)))
      return ok(TriggerEmitRequest(emitted: count)),
  )
  if emitRes.isErr():
    return err("TriggerEmitRequest provider: " & emitRes.error())

  # FFI perftest — emit `count` PingPayloadEvents from the processing
  # thread, each carrying `payloadSize` bytes + an emit-side mono-ns
  # timestamp. The C++ subscriber uses the timestamp to compute
  # per-event delivery latency.
  let pingPayloadRes = TriggerPingPayloadRequest.setProvider(
    ctx,
    proc(
        count: int32, payloadSize: int32, emitTimestampNs: int64
    ): Future[Result[TriggerPingPayloadRequest, string]] {.closure, async.} =
      # `emitTimestampNs` is supplied by the C++ caller in the C++
      # `std::chrono::steady_clock` domain. Nim just passes it through
      # so the foreign callback can compute delivery latency against
      # its own clock without a cross-language clock-domain mismatch.
      let n = max(payloadSize, 0)
      var payload = newSeq[byte](n)
      for i in 0 ..< n:
        payload[i] = byte(i and 0xFF)
      for i in 0 ..< count:
        PingPayloadEvent.emit(
          ctx,
          PingPayloadEvent(
            seqNo: int64(i), emitTimestampNs: emitTimestampNs, bytes: payload
          ),
        )
      return ok(TriggerPingPayloadRequest(emitted: count)),
  )
  if pingPayloadRes.isErr():
    return err("TriggerPingPayloadRequest provider: " & pingPayloadRes.error())

  # E2E bench — one-way payload signal handler: O(1) predicate, count trues.
  let payloadSigRes = PayloadSignal.onSignal(
    ctx,
    proc(s: PayloadSignal) {.async: (raises: []).} =
      if payloadPred(s.payload):
        discard gE2ePayloadTrue.fetchAdd(1, moRelaxed)
      discard gE2ePayloadProcessed.fetchAdd(1, moRelease),
  )
  if payloadSigRes.isErr():
    return err("PayloadSignal handler: " & payloadSigRes.error())

  # E2E bench — payload request turnaround: return the predicate result.
  let payloadReqRes = PayloadCheckRequest.setProvider(
    ctx,
    proc(
        payload: seq[byte]
    ): Future[Result[PayloadCheckRequest, string]] {.closure, async.} =
      return ok(PayloadCheckRequest(ok: payloadPred(payload))),
  )
  if payloadReqRes.isErr():
    return err("PayloadCheckRequest provider: " & payloadReqRes.error())

  # E2E bench — scalar signal handler: evaluate the predicate, count trues.
  let scalarSigRes = ScalarSignal.onSignal(
    ctx,
    proc(s: ScalarSignal) {.async: (raises: []).} =
      if scalarPred(s.a, s.b, s.x):
        discard gE2eScalarTrue.fetchAdd(1, moRelaxed)
      discard gE2eScalarProcessed.fetchAdd(1, moRelease),
  )
  if scalarSigRes.isErr():
    return err("ScalarSignal handler: " & scalarSigRes.error())

  # E2E bench — scalar request turnaround: return the predicate result.
  let scalarReqRes = ScalarCheckRequest.setProvider(
    ctx,
    proc(
        a: int64, b: int64, x: float64
    ): Future[Result[ScalarCheckRequest, string]] {.closure, async.} =
      return ok(ScalarCheckRequest(ok: scalarPred(a, b, x))),
  )
  if scalarReqRes.isErr():
    return err("ScalarCheckRequest provider: " & scalarReqRes.error())

  # E2E bench — counter accessor (driver reads deltas).
  let e2eStatsRes = E2eStatsRequest.setProvider(
    ctx,
    proc(): Future[Result[E2eStatsRequest, string]] {.closure, async.} =
      return ok(
        E2eStatsRequest(
          payloadProcessed: gE2ePayloadProcessed.load(moAcquire),
          payloadTrue: gE2ePayloadTrue.load(moAcquire),
          scalarProcessed: gE2eScalarProcessed.load(moAcquire),
          scalarTrue: gE2eScalarTrue.load(moAcquire),
        )
      ),
  )
  if e2eStatsRes.isErr():
    return err("E2eStatsRequest provider: " & e2eStatsRes.error())

  # Part D-4 — stats accessor. Reads the per-lane atomic counters.
  let statsRes = GetStatsRequest.setProvider(
    ctx,
    proc(): Future[Result[GetStatsRequest, string]] {.closure, async.} =
      return ok(
        GetStatsRequest(
          sameThreadCount: gSameThreadCount.load(moAcquire),
          crossThreadCount: gCrossThreadCount.load(moAcquire),
        )
      ),
  )
  if statsRes.isErr():
    return err("GetStatsRequest provider: " & statsRes.error())

  # Reset counters at provider-setup time so each `_createContext` starts
  # fresh (a single library process may go through multiple createContext /
  # shutdown cycles in the stress drivers).
  gSameThreadCount.store(0, moRelease)
  gCrossThreadCount.store(0, moRelease)
  gE2ePayloadProcessed.store(0, moRelease)
  gE2ePayloadTrue.store(0, moRelease)
  gE2eScalarProcessed.store(0, moRelease)
  gE2eScalarTrue.store(0, moRelease)

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
  # E2E bench: give the one-way signal lane burst headroom (64 -> 16384 spill
  # growth, ~4.6 MiB ring at full growth) while keeping the ceiling small
  # enough that sustained overproduction still exercises real -6 backpressure
  # (the driver retries and reports the retry count).
  callRingCeiling:
    16384

{.pop.}
