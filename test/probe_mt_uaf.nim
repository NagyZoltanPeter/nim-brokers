## Minimal probe for the macOS arm64 ORC + ASAN UAF.
##
## Build (from repo root):
##   nim c -r --cc:clang --debugger:native --threads:on --mm:orc \
##       --passC:"-fsanitize=address -fno-omit-frame-pointer -O1 -g -fno-optimize-sibling-calls" \
##       --passL:"-fsanitize=address" --path:. \
##       --outdir:build -d:probeMode=<mode> test/probe_mt_uaf.nim
##
## Modes (compile-time -d:probeMode=<...>):
##   baseline       — many emitters in/out, no drop/relisten cycle
##   relisten       — emitters in/out + drop/relisten cycle each round (suspect trigger)
##   relistenKeepAlive — same drop/relisten cycle, but emitters never exit early
##   gcCollect      — relisten + GC_fullCollect() before emitter exit
##   gcCollectAll   — same as relisten, plus extra GC + dropAll between phases
##   keepAlive      — never let emitter threads exit until end (best case)
##   freshCtx       — relisten cycle, but each round uses a NEW BrokerContext
##                    (forces a fresh bucket+channel — proxy for proposed fix)
##   shutdownEach   — relisten cycle, but use new `Evt.shutdown()` instead of
##                    dropAllListeners between rounds (validates proposed fix).

import std/[atomics, os]
import chronos
import brokers/[event_broker, broker_context]

const probeMode {.strdefine.} = "baseline"

EventBroker(mt):
  type Evt = object
    value: int

var gReceived: Atomic[int]
gReceived.store(0)

proc emitter() {.thread.} =
  Evt.emit(Evt(value: 1))
  when probeMode == "gcCollect" or probeMode == "gcCollectAll":
    GC_fullCollect()

proc emitterCtx(ctx: BrokerContext) {.thread.} =
  setThreadBrokerContext(ctx)
  Evt.emit(Evt(value: 1))

proc emitterKeepAlive(stopFlag: ptr Atomic[bool]) {.thread.} =
  Evt.emit(Evt(value: 1))
  while not stopFlag[].load():
    sleep(5)

proc registerListener(ctx = DefaultBrokerContext) =
  let h = Evt.listen(
    ctx,
    proc(e: Evt): Future[void] {.async: (raises: []).} =
      discard gReceived.fetchAdd(1),
  )
  doAssert h.isOk

proc run() {.async.} =
  registerListener()

  when probeMode == "keepAlive":
    var stop: Atomic[bool]
    stop.store(false)
    var threads: array[10, Thread[ptr Atomic[bool]]]
    for i in 0 ..< threads.len:
      threads[i].createThread(emitterKeepAlive, addr stop)
    while gReceived.load() < threads.len:
      await sleepAsync(milliseconds(1))
    # Then a "phase 2" — three more concurrent emitters, also kept alive.
    var ph2: array[3, Thread[ptr Atomic[bool]]]
    for i in 0 ..< ph2.len:
      ph2[i].createThread(emitterKeepAlive, addr stop)
    while gReceived.load() < threads.len + ph2.len:
      await sleepAsync(milliseconds(1))
    await Evt.dropAllListeners()
    await sleepAsync(milliseconds(50))
    stop.store(true)
    for i in 0 ..< threads.len:
      threads[i].joinThread()
    for i in 0 ..< ph2.len:
      ph2[i].joinThread()
  elif probeMode == "relistenKeepAlive":
    # Drop/relisten cycle, but emitters never exit until final.
    var stop: Atomic[bool]
    stop.store(false)
    var t1: Thread[ptr Atomic[bool]]
    t1.createThread(emitterKeepAlive, addr stop)
    while gReceived.load() < 1:
      await sleepAsync(milliseconds(1))
    for round in 0 ..< 8:
      await Evt.dropAllListeners()
      await sleepAsync(milliseconds(20))
      registerListener()
    let baseline = gReceived.load()
    var t2, t3, t4: Thread[ptr Atomic[bool]]
    t2.createThread(emitterKeepAlive, addr stop)
    t3.createThread(emitterKeepAlive, addr stop)
    t4.createThread(emitterKeepAlive, addr stop)
    while gReceived.load() < baseline + 3:
      await sleepAsync(milliseconds(1))
    await Evt.dropAllListeners()
    await sleepAsync(milliseconds(50))
    stop.store(true)
    t1.joinThread()
    t2.joinThread()
    t3.joinThread()
    t4.joinThread()
  elif probeMode == "freshCtx":
    await Evt.dropAllListeners() # drop the default-ctx listener; we'll use fresh ctxs.
    for round in 0 ..< 8:
      let ctx = NewBrokerContext()
      registerListener(ctx)
      var t1: Thread[BrokerContext]
      t1.createThread(emitterCtx, ctx)
      let target = gReceived.load() + 1
      while gReceived.load() < target:
        await sleepAsync(milliseconds(1))
      t1.joinThread()
      await Evt.dropAllListeners(ctx)
      await sleepAsync(milliseconds(20))
    # Phase 2 — fresh ctx + three concurrent emitters.
    let ctx2 = NewBrokerContext()
    registerListener(ctx2)
    let baseline = gReceived.load()
    var t2, t3, t4: Thread[BrokerContext]
    t2.createThread(emitterCtx, ctx2)
    t3.createThread(emitterCtx, ctx2)
    t4.createThread(emitterCtx, ctx2)
    while gReceived.load() < baseline + 3:
      await sleepAsync(milliseconds(1))
    t2.joinThread()
    t3.joinThread()
    t4.joinThread()
    await Evt.dropAllListeners(ctx2)
    await sleepAsync(milliseconds(50))
  else:
    # Phase 1 — emitters in/out, optionally drop+relisten between rounds.
    for round in 0 ..< 8:
      var t1: Thread[void]
      t1.createThread(emitter)
      let target = gReceived.load() + 1
      while gReceived.load() < target:
        await sleepAsync(milliseconds(1))
      t1.joinThread()
      when probeMode == "shutdownEach":
        await Evt.shutdown()
        await sleepAsync(milliseconds(20))
        registerListener()
      elif probeMode == "relisten" or probeMode == "gcCollect" or
          probeMode == "gcCollectAll":
        await Evt.dropAllListeners()
        await sleepAsync(milliseconds(20))
        when probeMode == "gcCollectAll":
          GC_fullCollect()
        registerListener()
    # Phase 2 — three concurrent emitters (the original failing config).
    let baseline = gReceived.load()
    var t2, t3, t4: Thread[void]
    t2.createThread(emitter)
    t3.createThread(emitter)
    t4.createThread(emitter)
    while gReceived.load() < baseline + 3:
      await sleepAsync(milliseconds(1))
    t2.joinThread()
    t3.joinThread()
    t4.joinThread()
    await Evt.dropAllListeners()
    await sleepAsync(milliseconds(50))

  echo "PROBE OK mode=", probeMode, " received=", gReceived.load()

waitFor run()
