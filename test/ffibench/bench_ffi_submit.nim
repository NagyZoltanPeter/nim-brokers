## Concurrent-submit stress test + throughput bench for the one-way
## SignalBroker(API) `<lib>_call` path — the nim-brokers analog of nim-ffi's
## tests/bench/bench_ffi_submit.nim (logos-messaging/nim-ffi #97 / #101).
##
## K producer threads hammer one library context with `benchsubmit_call` on a
## signal apiName (slot-free enqueue onto the call-courier ring, returns on
## accept). Only the submit phase is timed — start gate until every producer
## returns from its last accepted submit; handler-side completion (single
## processing thread) is excluded, mirroring the nim-ffi methodology.
##
## The library is registered with `callRingDepth: 2_000_000` — ring capacity
## equal to the largest documented sweep — so ApiStatusAgain (-6) never fires
## and the timed phase measures PURE ENQUEUE cost, directly comparable to
## nim-ffi's unbounded ingress. The retry-on-Again loop is kept as a fallback
## for oversized custom sweeps; a non-zero retries column means the ring was
## outgrown and the row degraded to drain-bound acceptance. Ownership of the
## input buffer transfers into the library on EVERY attempt (it frees the
## buffer itself on -6/-10 as well), so each attempt allocs + copies — that
## cost is part of the honest submit path.
##
## Correctness stress: the handler-invocation count must match accepted
## submits exactly (no drops, no double-fires), with zero hard errors.
##
## Env knobs (nim-ffi parity): BROKER_SUBMIT_PER_THREAD (default 20000),
## BROKER_SUBMIT_ITERS (default 5, median reported), BROKER_SUBMIT_THREADS
## (default "1,2,4,8"; local high-contention: "1,8,16,32,64,100"),
## BROKER_SCALING_GATE (default 0 — baseline/report mode; 1 enforces 1.5x).

import std/[atomics, algorithm, monotimes, strutils, os]
# Only the Duration→ns reader: a wholesale std/times import would clash with
# chronos' Duration inside the broker macro expansions in this module.
from std/times import inNanoseconds
import results
import brokers/[signal_broker, request_broker, broker_context, api_library]
import brokers/internal/api_cbor_codec

# ---------------------------------------------------------------------------
# Inline mini-library
# ---------------------------------------------------------------------------

SignalBroker(API):
  type BenchSignal = object
    n*: int32

RequestBroker(API):
  type InitializeRequest = object
    ready*: bool

  proc signature*(): Future[Result[InitializeRequest, string]] {.async.}

RequestBroker(API):
  type ShutdownRequest = object
    status*: int32

  proc signature*(): Future[Result[ShutdownRequest, string]] {.async.}

var gHandled: Atomic[int] ## bumped once per handler invocation on the processing thread

proc setupProviders(ctx: BrokerContext): Result[void, string] =
  proc initProv(): Future[Result[InitializeRequest, string]] {.async.} =
    return ok(InitializeRequest(ready: true))

  ?InitializeRequest.setProvider(ctx, initProv)

  proc shutProv(): Future[Result[ShutdownRequest, string]] {.async.} =
    return ok(ShutdownRequest(status: 0))

  ?ShutdownRequest.setProvider(ctx, shutProv)

  ?BenchSignal.onSignal(
    ctx,
    proc(s: BenchSignal) {.async: (raises: []).} =
      discard gHandled.fetchAdd(1),
  )

  return Result[void, string].ok()

registerBrokerLibrary:
  name:
    "benchsubmit"
  version:
    "0.1.0"
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest
  # Pre-size the call-courier ring to the largest documented sweep
  # (100 threads x 20000 = 2M submits) so ApiStatusAgain never fires and the
  # timed phase measures pure enqueue, comparable to nim-ffi's unbounded
  # ingress. Cost: 2M x 280 B (sizeof CborCallMsg) = 534 MiB virtual per
  # context; the mod-cap cursor walks the whole buffer over a full iteration,
  # so resident peaks near that too (freed at each per-iteration destroy).
  # Sweeps beyond 2M total submits fall back to retry-on-Again (still
  # correct; the retries column exposes it).
  callRingDepth:
    2_000_000

# ---------------------------------------------------------------------------
# Producers
# ---------------------------------------------------------------------------

var gStart: Atomic[bool]
var gRetries: Atomic[int] ## ApiStatusAgain (-6) retries — backpressure evidence
var gHardErrors: Atomic[int] ## any status other than Ok / Again

let settleTimeout = 30_000 # ms; bound on the post-submit handler drain

## Forcing gate threshold (nim-ffi parity). Off by default here: this bench
## establishes the baseline for the bounded courier ingress first; flip
## BROKER_SCALING_GATE=1 once a target is agreed.
const RequiredScaling = 1.5

type ProducerArg = object
  ctx: uint32
  count: int
  payload: pointer ## shared-mem copy of the pre-encoded CBOR payload
  payloadLen: int32

proc producerBody(arg: ptr ProducerArg) {.thread, gcsafe.} =
  while not gStart.load():
    cpuRelax()
  for _ in 0 ..< arg[].count:
    while true:
      # Fresh buffer per attempt: `_call` consumes it on every return path.
      let buf = benchsubmit_allocBuffer(arg[].payloadLen)
      copyMem(buf, arg[].payload, arg[].payloadLen)
      var respBuf: pointer = nil
      var respLen: int32 = 0
      var rc: int32
      # The exported C ABI entry is called from foreign (non-Nim-checked)
      # threads in production; in this in-process harness Nim's gcsafe
      # checker sees its registry global and objects. Runtime-safe: the
      # entry guards all shared state itself (ensureForeignThreadGc + lock).
      {.cast(gcsafe).}:
        rc = benchsubmit_call(
          arg[].ctx,
          "bench_signal".cstring,
          buf,
          arg[].payloadLen,
          addr respBuf,
          addr respLen,
        )
      if rc == ApiStatusOk:
        break
      if rc == ApiStatusAgain:
        discard gRetries.fetchAdd(1)
        cpuRelax()
        continue
      discard gHardErrors.fetchAdd(1)
      break

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

proc waitForHandled(target: int): bool =
  ## Spins until `gHandled` reaches `target`, bounded by `settleTimeout`.
  let deadline = getMonoTime().ticks + settleTimeout.int64 * 1_000_000
  while gHandled.load() < target:
    if getMonoTime().ticks > deadline:
      return false
    os.sleep(1)
  true

proc median(xs: seq[float]): float =
  if xs.len == 0:
    return 0.0
  let s = xs.sorted()
  if s.len mod 2 == 1:
    return s[s.len div 2]
  (s[s.len div 2 - 1] + s[s.len div 2]) / 2.0

type IterResult = object
  submitRate: float ## accepted submits/sec over the submit phase only
  retries: int
  hardErrors: int
  overruns: int ## handler invocations beyond accepted — must be 0

proc runOnce(numThreads, perThread: int, payload: seq[byte]): IterResult =
  var err: cstring = nil
  let ctx = benchsubmit_createContext(addr err)
  if ctx == 0'u32:
    quit("createContext failed: " & (if err.isNil: "<nil>" else: $err))

  let total = numThreads * perThread
  gStart.store(false)
  gHandled.store(0)
  gRetries.store(0)
  gHardErrors.store(0)

  # Payload lives in shared memory so `{.thread.}` producers touch no GC heap.
  let shared = cast[ptr UncheckedArray[byte]](allocShared0(payload.len))
  copyMem(shared, unsafeAddr payload[0], payload.len)

  var threads = newSeq[Thread[ptr ProducerArg]](numThreads)
  var args = newSeq[ProducerArg](numThreads)
  for i in 0 ..< numThreads:
    args[i] = ProducerArg(
      ctx: ctx, count: perThread, payload: shared, payloadLen: int32(payload.len)
    )
    createThread(threads[i], producerBody, addr args[i])

  # Times the submit phase only; handler drain (single processing thread)
  # is excluded, as in the nim-ffi bench.
  let start = getMonoTime()
  gStart.store(true)
  joinThreads(threads)
  let submitSec = (getMonoTime() - start).inNanoseconds.float / 1_000_000_000.0

  let accepted = total - gHardErrors.load()
  if not waitForHandled(accepted):
    quit(
      "timed out waiting for handler invocations: got " & $gHandled.load() & " of " &
        $accepted
    )
  os.sleep(50) # let any erroneous extra invocations land before reading overruns

  result = IterResult(
    submitRate: accepted.float / submitSec,
    retries: gRetries.load(),
    hardErrors: gHardErrors.load(),
    overruns: max(0, gHandled.load() - accepted),
  )
  discard benchsubmit_shutdown(ctx)
  deallocShared(shared)

proc enforceScalingGate(medianRate: seq[float]) =
  ## Fails the process when submit throughput doesn't scale past RequiredScaling.
  let scalingMax = medianRate[^1] / medianRate[0]
  echo ""
  if scalingMax < RequiredScaling:
    quit(
      "SCALING GATE: submit scaling " & formatFloat(scalingMax, ffDecimal, 2) &
        "x < required " & formatFloat(RequiredScaling, ffDecimal, 2) & "x."
    )
  echo "  scaling gate: ",
    formatFloat(scalingMax, ffDecimal, 2),
    "x >= ",
    formatFloat(RequiredScaling, ffDecimal, 2),
    "x — submit path scales."

proc main() =
  let perThread = parseInt(getEnv("BROKER_SUBMIT_PER_THREAD", "20000"))
  let iters = parseInt(getEnv("BROKER_SUBMIT_ITERS", "5"))
  let gateOn = getEnv("BROKER_SCALING_GATE", "0") != "0"
  if perThread < 1 or iters < 1:
    quit("BROKER_SUBMIT_PER_THREAD and BROKER_SUBMIT_ITERS must be >= 1")
  let threadCounts = block:
    var cs: seq[int]
    for part in getEnv("BROKER_SUBMIT_THREADS", "1,2,4,8").split(','):
      let p = part.strip()
      if p.len > 0:
        cs.add(parseInt(p))
    if cs.len < 2:
      quit("BROKER_SUBMIT_THREADS needs >= 2 counts (first = baseline, last = peak)")
    cs

  let payload = cborEncode(BenchSignal(n: 7'i32)).valueOr:
    quit("cborEncode failed: " & error)

  echo "── one-way signal _call submit throughput (median of ",
    iters, ") ──────"
  echo "  ",
    perThread, " submits per producer thread; ", payload.len,
    " B CBOR payload; noop handler"
  echo ""
  echo "  ",
    alignLeft("threads", 9),
    alignLeft("submits", 10),
    alignLeft("submit/sec", 16),
    alignLeft("vs 1-thread", 13),
    alignLeft("again-retries", 14)

  var medianRate: seq[float]
  var allPassed = true
  for n in threadCounts:
    var rates: seq[float]
    var retries = 0
    var hardErrors = 0
    var overruns = 0
    for _ in 0 ..< iters:
      let r = runOnce(n, perThread, payload)
      rates.add(r.submitRate)
      retries += r.retries
      hardErrors += r.hardErrors
      overruns += r.overruns
    let med = median(rates)
    medianRate.add(med)
    echo "  ",
      alignLeft($n, 9),
      alignLeft($(n * perThread), 10),
      alignLeft(formatFloat(med, ffDecimal, 0), 16),
      alignLeft(formatFloat(med / medianRate[0], ffDecimal, 2) & "x", 13),
      alignLeft($retries, 14)

    if hardErrors != 0:
      echo "  !! ", hardErrors, " hard submit errors at ", n, " threads"
      allPassed = false
    if overruns != 0:
      echo "  !! ", overruns, " handler invocations beyond expected at ", n, " threads"
      allPassed = false

  if not allPassed:
    quit("stress test FAILED: see !! lines above")
  echo ""
  echo "  correctness: handler count matched accepted submits exactly (no drops/dupes)."

  if gateOn:
    enforceScalingGate(medianRate)

when isMainModule:
  main()
