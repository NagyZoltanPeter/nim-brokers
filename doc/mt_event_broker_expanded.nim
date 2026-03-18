## Generated code for `EventBroker(mt):` — cleaned up for readability.
##
## This is what the macro produces for:
##
##   EventBroker(mt):
##     type Alert = object
##       level*: int
##       message*: string
##
## The code below is *not* compiled — it exists only for documentation.
## Names have been humanised (the macro uses gensym'd identifiers).

{.push raises: [].}

import std/[locks, tables, atomics]
import chronos, chronicles
import results
import asyncchannels
import broker_context
import mt_broker_common  # currentMtThreadId(), atomics re-exported

export results, chronos, broker_context, asyncchannels, chronicles, mt_broker_common

# ═══════════════════════════════════════════════════════════════════════════
#  Types
# ═══════════════════════════════════════════════════════════════════════════

type
  Alert* = object
    level*: int
    message*: string

  ## Handle returned by `listen`, used for `dropListener`.
  AlertListener* = object
    id*: uint64
    threadId*: pointer
      ## Thread that registered this listener (for validation on drop).

  ## Callback type for listener handlers.
  AlertListenerProc* =
    proc(event: Alert): Future[void] {.async: (raises: []), gcsafe.}

  ## Internal message sent over the event channel.
  AlertEventMsg = object
    isShutdown: bool
    event: Alert

  ## One entry in the global shared bucket array.
  ## Multiple buckets can share the same BrokerContext — one per listener thread.
  AlertBucket = object
    brokerCtx: BrokerContext
    eventChan: ptr AsyncChannel[AlertEventMsg]
    threadId: pointer   # address of threadvar marker — unique per thread
    active: bool

# ═══════════════════════════════════════════════════════════════════════════
#  Global shared state (Lock-protected, createShared for refc safety)
# ═══════════════════════════════════════════════════════════════════════════

var gBuckets: ptr UncheckedArray[AlertBucket]
var gBucketCount: int
var gBucketCap: int
var gLock: Lock
var gInitDone: Atomic[int]
  ## 0 = uninitialised, 1 = initialising, 2 = ready.
  ## CAS(0→1) wins the race; losers spin until 2.

proc ensureInit() =
  if gInitDone.load(moRelaxed) == 2:
    return # fast path — already initialised
  var expected = 0
  if gInitDone.compareExchange(expected, 1, moAcquire, moRelaxed):
    # We won the init race.
    initLock(gLock)
    gBucketCap = 4
    gBuckets = cast[ptr UncheckedArray[AlertBucket]](
      createShared(AlertBucket, gBucketCap))
    gBucketCount = 0
    gInitDone.store(2, moRelease)
  else:
    # Another thread is initialising — spin until ready.
    while gInitDone.load(moAcquire) != 2:
      discard

proc growBuckets() =
  ## Must be called under lock.
  let newCap = gBucketCap * 2
  let newBuf = cast[ptr UncheckedArray[AlertBucket]](
    createShared(AlertBucket, newCap))
  for i in 0 ..< gBucketCount:
    newBuf[i] = gBuckets[i]
  deallocShared(gBuckets)
  gBuckets = newBuf
  gBucketCap = newCap

# ═══════════════════════════════════════════════════════════════════════════
#  Threadvar listener storage (GC-managed, per-thread)
#
#  Parallel seqs — index `i` maps a BrokerContext to its handler table
#  and next-ID counter for this thread.
#
#  Closures cannot live in shared memory — they reference GC-managed
#  environments. Instead we store them in threadvars and look them up
#  at dispatch time. The shared bucket only holds metadata + channel.
# ═══════════════════════════════════════════════════════════════════════════

var tvListenerCtxs     {.threadvar.}: seq[BrokerContext]
var tvListenerHandlers {.threadvar.}: seq[Table[uint64, AlertListenerProc]]
var tvNextIds          {.threadvar.}: seq[uint64]

# ═══════════════════════════════════════════════════════════════════════════
#  Listener notify wrapper — try/catch per listener callback.
# ═══════════════════════════════════════════════════════════════════════════

proc notifyAlertListener(
    callback: AlertListenerProc, event: Alert
): Future[void] {.async: (raises: []).} =
  if callback.isNil():
    return
  try:
    await callback(event)
  except CatchableError:
    error "Failed to execute event listener",
      eventType = "Alert",
      error = getCurrentExceptionMsg()

# ═══════════════════════════════════════════════════════════════════════════
#  Process loop — runs on the listener thread's chronos event loop.
#  Receives events from cross-thread emitters and dispatches to local
#  listeners. Tracks in-flight futures for clean shutdown.
# ═══════════════════════════════════════════════════════════════════════════

proc processLoop(
    eventChan: ptr AsyncChannel[AlertEventMsg],
    loopCtx: BrokerContext,
) {.async: (raises: []).} =
  var inFlight: seq[Future[void]] = @[]
  while true:
    let recvRes = catch:
      await eventChan.recv()
    if recvRes.isErr():
      break                           # channel closed or cancelled
    let msg = recvRes.get()
    if msg.isShutdown:
      # Drain in-flight listeners before exiting
      for fut in inFlight:
        if not fut.finished():
          try:
            discard await withTimeout(fut, chronos.seconds(5))
          except CatchableError:
            discard
      # Clean up threadvar entries for this context
      # (safe: processLoop runs on the owning thread)
      for i in 0 ..< tvListenerCtxs.len:
        if tvListenerCtxs[i] == loopCtx:
          tvListenerHandlers[i].clear()
          tvListenerCtxs.del(i)
          tvListenerHandlers.del(i)
          tvNextIds.del(i)
          break
      break                           # exit loop

    # Prune completed futures — await marks them as consumed so Chronos
    # does not warn about unresolved futures.  The await is instant
    # because the future has already finished.
    var j = 0
    while j < inFlight.len:
      if inFlight[j].finished():
        try:
          await inFlight[j]      # instant — consumes the future
        except CatchableError:
          discard                # notifyAlertListener is raises:[], but Chronos needs the guard
        inFlight.del(j)
      else:
        inc j

    # Dispatch to all local listeners for this context.
    # Calling the async proc schedules it on the event loop and returns
    # a Future immediately — no asyncSpawn needed.  We track the future
    # in inFlight so we can (a) consume it on prune and (b) drain it
    # on shutdown.
    var idx = -1
    for i in 0 ..< tvListenerCtxs.len:
      if tvListenerCtxs[i] == loopCtx:
        idx = i
        break
    if idx >= 0:
      var callbacks: seq[AlertListenerProc] = @[]
      for cb in tvListenerHandlers[idx].values:
        callbacks.add(cb)
      for cb in callbacks:
        # Schedule listener — returns Future, already on the event loop.
        let fut = notifyAlertListener(cb, msg.event)
        inFlight.add(fut)
  # NOTE: We do NOT close the channel here. A concurrent emitter may still
  # hold a pointer captured before the bucket was removed from the registry.
  # sendSync on a closed channel is undefined behavior; sendSync on an
  # open-but-drained channel is safe (brief block, then return).
  # The channel memory is intentionally leaked (no deallocShared) to prevent
  # use-after-free.

# ═══════════════════════════════════════════════════════════════════════════
#  listen — register a listener on the current thread.
#  Stores the closure in threadvar; creates shared bucket + channel
#  if this is the first listener for (context, thread) pair.
# ═══════════════════════════════════════════════════════════════════════════

proc listen*(
    _: typedesc[Alert],
    handler: AlertListenerProc,
): Result[AlertListener, string] =
  return listen(Alert, DefaultBrokerContext, handler)

proc listen*(
    _: typedesc[Alert],
    brokerCtx: BrokerContext,
    handler: AlertListenerProc,
): Result[AlertListener, string] =
  if handler.isNil():
    return err("Must provide a non-nil event handler")
  ensureInit()

  # Find or create threadvar entry for this context
  var tvIdx = -1
  for i in 0 ..< tvListenerCtxs.len:
    if tvListenerCtxs[i] == brokerCtx:
      tvIdx = i
      break
  if tvIdx < 0:
    tvListenerCtxs.add(brokerCtx)
    tvListenerHandlers.add(initTable[uint64, AlertListenerProc]())
    tvNextIds.add(1'u64)
    tvIdx = tvListenerCtxs.len - 1

  # Allocate listener ID
  if tvNextIds[tvIdx] == high(uint64):
    return err("Cannot add more listeners: ID space exhausted")
  let newId = tvNextIds[tvIdx]
  tvNextIds[tvIdx] += 1
  tvListenerHandlers[tvIdx][newId] = handler

  # Ensure a bucket + channel exists for (brokerCtx, this thread)
  let myThreadId = currentMtThreadId()
  var bucketExists = false
  var spawnChan: ptr AsyncChannel[AlertEventMsg]
  withLock(gLock):
    for i in 0 ..< gBucketCount:
      if gBuckets[i].brokerCtx == brokerCtx and
         gBuckets[i].threadId == myThreadId and
         gBuckets[i].active:
        bucketExists = true
        break
    if not bucketExists:
      if gBucketCount >= gBucketCap:
        growBuckets()
      spawnChan = cast[ptr AsyncChannel[AlertEventMsg]](
        createShared(AsyncChannel[AlertEventMsg], 1))
      discard spawnChan[].open()
      let idx = gBucketCount
      gBuckets[idx] = AlertBucket(
        brokerCtx: brokerCtx,
        eventChan: spawnChan,
        threadId: myThreadId,
        active: true)
      gBucketCount += 1

  # asyncSpawn outside lock to prevent potential deadlock.
  # If Chronos eagerly steps the coroutine and the listener calls emit
  # (which acquires the same lock), we'd deadlock.
  if not bucketExists:
    asyncSpawn processLoop(spawnChan, brokerCtx)

  return ok(AlertListener(id: newId, threadId: myThreadId))

# ═══════════════════════════════════════════════════════════════════════════
#  emit — broadcast an event to all listeners (async).
#  Same-thread listeners: dispatched directly via asyncSpawn (no channel).
#  Cross-thread listeners: sendSync to each listener thread's channel.
#
#  Use `await` in async contexts; `waitFor` from {.thread.} procs.
# ═══════════════════════════════════════════════════════════════════════════

proc emitImpl(
    brokerCtx: BrokerContext, event: Alert
) {.async: (raises: []).} =
  ensureInit()

  # Collect targets under lock
  type EvTarget = object
    eventChan: ptr AsyncChannel[AlertEventMsg]
    isSameThread: bool

  var targets: seq[EvTarget] = @[]
  let myThreadId = currentMtThreadId()

  withLock(gLock):
    for i in 0 ..< gBucketCount:
      if gBuckets[i].brokerCtx == brokerCtx and
         gBuckets[i].active:
        targets.add(EvTarget(
          eventChan: gBuckets[i].eventChan,
          isSameThread: gBuckets[i].threadId == myThreadId))

  if targets.len == 0:
    return

  for target in targets:
    if target.isSameThread:
      # ── Same-thread path: dispatch directly to local listeners ──
      var idx = -1
      for i in 0 ..< tvListenerCtxs.len:
        if tvListenerCtxs[i] == brokerCtx:
          idx = i
          break
      if idx >= 0:
        var callbacks: seq[AlertListenerProc] = @[]
        for cb in tvListenerHandlers[idx].values:
          callbacks.add(cb)
        for cb in callbacks:
          asyncSpawn notifyAlertListener(cb, event)
    else:
      # ── Cross-thread path: send via channel ──
      # sendSync is brief — buffer + signal
      let msg = AlertEventMsg(isShutdown: false, event: event)
      target.eventChan[].sendSync(msg)

# Public emit overloads

proc emit*(event: Alert) {.async: (raises: []).} =
  await emitImpl(DefaultBrokerContext, event)

proc emit*(_: typedesc[Alert], event: Alert) {.async: (raises: []).} =
  await emitImpl(DefaultBrokerContext, event)

proc emit*(
    _: typedesc[Alert], brokerCtx: BrokerContext, event: Alert
) {.async: (raises: []).} =
  await emitImpl(brokerCtx, event)

# Field-constructor emit overloads (for inline object types)

proc emit*(_: typedesc[Alert], level: int, message: string) {.async: (raises: []).} =
  await emitImpl(DefaultBrokerContext, Alert(level: level, message: message))

proc emit*(
    _: typedesc[Alert], brokerCtx: BrokerContext, level: int, message: string
) {.async: (raises: []).} =
  await emitImpl(brokerCtx, Alert(level: level, message: message))

# ═══════════════════════════════════════════════════════════════════════════
#  dropListener — remove a single listener.
#  Must be called from the same thread that registered it.
# ═══════════════════════════════════════════════════════════════════════════

proc dropListener*(_: typedesc[Alert], handle: AlertListener) =
  dropListener(Alert, DefaultBrokerContext, handle)

proc dropListener*(
    _: typedesc[Alert],
    brokerCtx: BrokerContext,
    handle: AlertListener,
) =
  if handle.id == 0'u64:
    return
  # Enforce: must be called from the thread that registered the listener
  if handle.threadId != currentMtThreadId():
    error "dropListener called from wrong thread",
      eventType = "Alert",
      handleThread = repr(handle.threadId),
      currentThread = repr(currentMtThreadId())
    return

  var tvIdx = -1
  for i in 0 ..< tvListenerCtxs.len:
    if tvListenerCtxs[i] == brokerCtx:
      tvIdx = i
      break
  if tvIdx < 0:
    return

  tvListenerHandlers[tvIdx].del(handle.id)

  # If no more listeners for this context on this thread, shut down channel
  if tvListenerHandlers[tvIdx].len == 0:
    tvListenerCtxs.del(tvIdx)
    tvListenerHandlers.del(tvIdx)
    tvNextIds.del(tvIdx)

    var chanToShutdown: ptr AsyncChannel[AlertEventMsg]
    let myThreadId = currentMtThreadId()
    withLock(gLock):
      for i in 0 ..< gBucketCount:
        if gBuckets[i].brokerCtx == brokerCtx and
           gBuckets[i].threadId == myThreadId:
          chanToShutdown = gBuckets[i].eventChan
          gBuckets[i].active = false
          # Shift remaining buckets
          for j in i ..< gBucketCount - 1:
            gBuckets[j] = gBuckets[j + 1]
          gBucketCount -= 1
          break
    if not chanToShutdown.isNil():
      chanToShutdown[].sendSync(AlertEventMsg(isShutdown: true))

# ═══════════════════════════════════════════════════════════════════════════
#  dropAllListeners — remove all listeners for a context.
#  Callable from any thread. Sends shutdown to all listener threads.
#  Each processLoop drains in-flight tasks and cleans its own threadvars.
# ═══════════════════════════════════════════════════════════════════════════

proc dropAllListeners*(_: typedesc[Alert]) =
  dropAllListeners(Alert, DefaultBrokerContext)

proc dropAllListeners*(_: typedesc[Alert], brokerCtx: BrokerContext) =
  ensureInit()

  # Phase 1: Under lock, collect all channels for this context and remove buckets
  var chansToShutdown: seq[ptr AsyncChannel[AlertEventMsg]] = @[]

  withLock(gLock):
    var i = 0
    while i < gBucketCount:
      if gBuckets[i].brokerCtx == brokerCtx:
        chansToShutdown.add(gBuckets[i].eventChan)
        gBuckets[i].active = false
        # Shift remaining
        for j in i ..< gBucketCount - 1:
          gBuckets[j] = gBuckets[j + 1]
        gBucketCount -= 1
        # Don't increment i — next element shifted into this position
      else:
        inc i

  # Phase 2: Clean up local threadvar entries if current thread has listeners
  var tvIdx = -1
  for i in 0 ..< tvListenerCtxs.len:
    if tvListenerCtxs[i] == brokerCtx:
      tvIdx = i
      break
  if tvIdx >= 0:
    tvListenerHandlers[tvIdx].clear()
    tvListenerCtxs.del(tvIdx)
    tvListenerHandlers.del(tvIdx)
    tvNextIds.del(tvIdx)

  # Phase 3: Send shutdown to all collected channels
  # Each processLoop will drain in-flight tasks and clean its own threadvars
  for chan in chansToShutdown:
    chan[].sendSync(AlertEventMsg(isShutdown: true))

{.pop.}
