## Generated code for `RequestBroker(mt):` — cleaned up for readability.
##
## This is what the macro produces for:
##
##   RequestBroker(mt):
##     type Weather = object
##       city*: string
##       tempC*: float
##
##     proc signature*(city: string): Future[Result[Weather, string]] {.async.}
##
## The code below is *not* compiled — it exists only for documentation.
## Names have been humanised (the macro uses gensym'd identifiers).

{.push raises: [].}

import std/[locks, atomics]
import chronos, chronicles
import results
import asyncchannels
import broker_context
import mt_broker_common  # currentMtThreadId(), atomics re-exported

export results, chronos, chronicles, broker_context, asyncchannels, mt_broker_common

# ═══════════════════════════════════════════════════════════════════════════
#  Types
# ═══════════════════════════════════════════════════════════════════════════

type
  Weather* = object
    city*: string
    tempC*: float

  ## Callback type for the provider handler.
  WeatherProvider =
    proc(city: string): Future[Result[Weather, string]] {.async.}

  ## Internal message sent over the request channel.
  WeatherRequestMsg = object
    isShutdown: bool
    requestKind: int  # 0 = zero-arg (unused here), 1 = with-args
    city: string      # flattened from signature params
    responseChan: ptr AsyncChannel[Result[Weather, string]]

  ## One entry in the global shared bucket array.
  WeatherBucket = object
    brokerCtx: BrokerContext
    requestChan: ptr AsyncChannel[WeatherRequestMsg]
    threadId: pointer   # address of threadvar marker — unique per thread
    active: bool

# ═══════════════════════════════════════════════════════════════════════════
#  Global shared state (Lock-protected, createShared for refc safety)
# ═══════════════════════════════════════════════════════════════════════════

var gBuckets: ptr UncheckedArray[WeatherBucket]
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
    gBuckets = cast[ptr UncheckedArray[WeatherBucket]](
      createShared(WeatherBucket, gBucketCap))
    gBucketCount = 0
    gInitDone.store(2, moRelease)
  else:
    # Another thread is initialising — spin until ready.
    while gInitDone.load(moAcquire) != 2:
      discard

proc growBuckets() =
  ## Must be called under lock.
  let newCap = gBucketCap * 2
  let newBuf = cast[ptr UncheckedArray[WeatherBucket]](
    createShared(WeatherBucket, newCap))
  for i in 0 ..< gBucketCount:
    newBuf[i] = gBuckets[i]
  deallocShared(gBuckets)
  gBuckets = newBuf
  gBucketCap = newCap

# ═══════════════════════════════════════════════════════════════════════════
#  Cross-thread request timeout
# ═══════════════════════════════════════════════════════════════════════════

var gWeatherMtRequestTimeout*: Duration = chronos.seconds(5)
  ## Cross-thread request timeout. Set during initialization before
  ## spawning worker threads. Reading from multiple threads is safe
  ## on x86-64 (aligned int64), but concurrent writes are not guaranteed.

proc setRequestTimeout*(_: typedesc[Weather], timeout: Duration) =
  ## Set the cross-thread request timeout for this broker type.
  gWeatherMtRequestTimeout = timeout

proc requestTimeout*(_: typedesc[Weather]): Duration =
  ## Get the current cross-thread request timeout for this broker type.
  gWeatherMtRequestTimeout

# ═══════════════════════════════════════════════════════════════════════════
#  Threadvar provider storage (GC-managed, per-thread)
#
#  Closures cannot live in shared memory — they reference GC-managed
#  environments. Instead we store them in threadvars and look them up
#  at dispatch time. The shared bucket only holds metadata + channel.
# ═══════════════════════════════════════════════════════════════════════════

var tvProviderCtxs    {.threadvar.}: seq[BrokerContext]
var tvProviderHandlers {.threadvar.}: seq[WeatherProvider]

# ═══════════════════════════════════════════════════════════════════════════
#  Process loop — runs on the provider thread's chronos event loop.
#  Receives requests from cross-thread callers and dispatches to the
#  local provider handler. Reads handlers from threadvar each time.
# ═══════════════════════════════════════════════════════════════════════════

proc processLoop(
    requestChan: ptr AsyncChannel[WeatherRequestMsg],
    loopCtx: BrokerContext,
) {.async: (raises: []).} =
  while true:
    let recvRes = catch:
      await requestChan.recv()
    if recvRes.isErr():
      break                       # channel closed or cancelled
    let msg = recvRes.get()
    # NOTE: processLoop does NOT clean threadvars on shutdown.  Threadvar
    # cleanup is done by clearProvider (which validates thread ownership).
    # Having processLoop also clean threadvars would race with new
    # setProvider registrations on the same thread.
    if msg.isShutdown:
      break                       # clearProvider sent shutdown

    if msg.requestKind == 1:
      # Look up provider from threadvar
      var handler: WeatherProvider
      for i in 0 ..< tvProviderCtxs.len:
        if tvProviderCtxs[i] == loopCtx:
          handler = tvProviderHandlers[i]
          break

      if handler.isNil():
        msg.responseChan[].sendSync(
          err(Result[Weather, string],
              "RequestBroker(Weather): no provider registered"))
      else:
        let catchedRes = catch:
          await handler(msg.city)
        if catchedRes.isErr():
          msg.responseChan[].sendSync(
            err(Result[Weather, string],
                "RequestBroker(Weather): provider threw: " &
                  catchedRes.error.msg))
        else:
          msg.responseChan[].sendSync(catchedRes.get())
    # After loop: Do NOT close or deallocShared the request channel.
    # A concurrent requester may still hold a raw pointer captured before
    # the bucket was removed from the registry.  AsyncChannel.close()
    # destroys the inner Channel (deallocShared + nil on .chan field), so
    # a late requester sendSync would dereference nil — a crash.
    # Leave the channel open; any late sendSync succeeds harmlessly
    # (writes into a channel nobody reads).  Intentional leak (~200 bytes
    # + OS signal handle) at teardown only.
    # TODO: upstream fix in nim-asyncchannels — need a safe abandon API
    # (e.g. trySendSync returning bool, or close that defers inner dealloc).

# ═══════════════════════════════════════════════════════════════════════════
#  setProvider — register a handler on the current thread.
#  Stores the closure in threadvar; shared bucket holds only metadata.
# ═══════════════════════════════════════════════════════════════════════════

proc setProvider*(
    _: typedesc[Weather],
    handler: WeatherProvider,
): Result[void, string] =
  return setProvider(Weather, DefaultBrokerContext, handler)

proc setProvider*(
    _: typedesc[Weather],
    brokerCtx: BrokerContext,
    handler: WeatherProvider,
): Result[void, string] =
  ensureInit()

  # Check if already registered on this thread for this context
  for i in 0 ..< tvProviderCtxs.len:
    if tvProviderCtxs[i] == brokerCtx:
      # Verify this entry is still backed by a global bucket.
      # If not, it's stale from a cross-thread clearProvider — remove it.
      var isStale = true
      withLock(gLock):
        for j in 0 ..< gBucketCount:
          if gBuckets[j].brokerCtx == brokerCtx and
             gBuckets[j].threadId == currentMtThreadId():
            isStale = false
            break
      if isStale:
        tvProviderCtxs.del(i)
        tvProviderHandlers.del(i)
        break  # removed stale entry, proceed with registration
      else:
        return err("Provider already set")

  # Store closure in GC-managed threadvar
  tvProviderCtxs.add(brokerCtx)
  tvProviderHandlers.add(handler)

  var spawnChan: ptr AsyncChannel[WeatherRequestMsg]
  withLock(gLock):
    # If a bucket already exists for this context, nothing more to do
    for i in 0 ..< gBucketCount:
      if gBuckets[i].brokerCtx == brokerCtx:
        return ok()

    # Create shared bucket + request channel
    if gBucketCount >= gBucketCap:
      growBuckets()
    spawnChan = cast[ptr AsyncChannel[WeatherRequestMsg]](
      createShared(AsyncChannel[WeatherRequestMsg], 1))
    discard spawnChan[].open()

    gBuckets[gBucketCount] = WeatherBucket(
      brokerCtx: brokerCtx,
      requestChan: spawnChan,
      threadId: currentMtThreadId(),
      active: true)
    gBucketCount += 1

  # asyncSpawn outside lock to prevent potential deadlock.
  # If Chronos eagerly steps the coroutine and the listener calls emit
  # (which acquires the same lock), we'd deadlock.
  if not spawnChan.isNil:
    asyncSpawn processLoop(spawnChan, brokerCtx)
  return ok()

# ═══════════════════════════════════════════════════════════════════════════
#  request — issue a typed request.
#  Same-thread calls provider directly (fast path);
#  cross-thread sends via AsyncChannel and awaits the response.
# ═══════════════════════════════════════════════════════════════════════════

proc request*(
    _: typedesc[Weather],
    city: string,
): Future[Result[Weather, string]] {.async: (raises: []).} =
  return await request(Weather, DefaultBrokerContext, city)

proc request*(
    _: typedesc[Weather],
    brokerCtx: BrokerContext,
    city: string,
): Future[Result[Weather, string]] {.async: (raises: []).} =
  ensureInit()

  var reqChan: ptr AsyncChannel[WeatherRequestMsg]
  var sameThread = false

  # Look up bucket for this BrokerContext
  withLock(gLock):
    for i in 0 ..< gBucketCount:
      if gBuckets[i].brokerCtx == brokerCtx:
        if gBuckets[i].threadId == currentMtThreadId():
          sameThread = true
        else:
          reqChan = gBuckets[i].requestChan
        break

  if sameThread:
    # ── Same-thread path: call provider directly from threadvar ──
    var provider: WeatherProvider
    for i in 0 ..< tvProviderCtxs.len:
      if tvProviderCtxs[i] == brokerCtx:
        provider = tvProviderHandlers[i]
        break

    if provider.isNil():
      return err("RequestBroker(Weather): no provider registered")

    let catchedRes = catch:
      await provider(city)
    if catchedRes.isErr():
      return err("RequestBroker(Weather): provider threw: " &
                 catchedRes.error.msg)
    return catchedRes.get()

  else:
    # ── Cross-thread path: send via channel, await response ──
    if reqChan.isNil():
      return err("RequestBroker(Weather): no provider registered for context")

    # Create a one-shot response channel
    let respChan = cast[ptr AsyncChannel[Result[Weather, string]]](
      createShared(AsyncChannel[Result[Weather, string]], 1))
    discard respChan[].open()

    # Send request message
    reqChan[].sendSync(WeatherRequestMsg(
      isShutdown: false,
      requestKind: 1,
      city: city,
      responseChan: respChan))

    # Await response with timeout
    let recvFut = respChan.recv()
    let completedRes = catch:
      await withTimeout(recvFut, gWeatherMtRequestTimeout)

    if completedRes.isErr():
      # withTimeout itself threw — provider may still hold respChan pointer.
      # Do NOT close: AsyncChannel.close() destroys the inner Channel
      # (deallocShared + nil on .chan field), so a later provider sendSync
      # would dereference nil — a crash.  Leave the channel open; the
      # provider's eventual sendSync succeeds harmlessly into a channel
      # nobody reads.  Intentional leak (~200 bytes + OS signal handle).
      # TODO: upstream fix in nim-asyncchannels — need a safe abandon API
      # (e.g. trySendSync returning bool, or close that defers inner dealloc).
      return err("RequestBroker(Weather): recv failed: " & completedRes.error.msg)
    if not completedRes.get():
      # Timed out — provider may still be running and will sendSync later.
      # Do NOT close: AsyncChannel.close() destroys the inner Channel
      # (deallocShared + nil on .chan field), so a later provider sendSync
      # would dereference nil — a crash.  Leave the channel open; the
      # provider's eventual sendSync succeeds harmlessly into a channel
      # nobody reads.  Intentional leak (~200 bytes + OS signal handle).
      # TODO: upstream fix in nim-asyncchannels — need a safe abandon API
      # (e.g. trySendSync returning bool, or close that defers inner dealloc).
      return err("RequestBroker(Weather): cross-thread request timed out after " &
                 $gWeatherMtRequestTimeout)
    # Success: provider already sent response. Safe to close + dealloc.
    respChan[].close()
    deallocShared(respChan)
    # Future completed — read the value
    let recvRes = catch:
      recvFut.read()
    if recvRes.isErr():
      return err("RequestBroker(Weather): recv failed: " & recvRes.error.msg)
    return recvRes.get()

# ═══════════════════════════════════════════════════════════════════════════
#  clearProvider — remove provider and stop the process loop.
# ═══════════════════════════════════════════════════════════════════════════

proc clearProvider*(_: typedesc[Weather]) =
  clearProvider(Weather, DefaultBrokerContext)

proc clearProvider*(_: typedesc[Weather], brokerCtx: BrokerContext) =
  ensureInit()

  var reqChan: ptr AsyncChannel[WeatherRequestMsg]
  var isProviderThread = false

  # Remove bucket from shared registry
  withLock(gLock):
    var foundIdx = -1
    for i in 0 ..< gBucketCount:
      if gBuckets[i].brokerCtx == brokerCtx:
        reqChan = gBuckets[i].requestChan
        isProviderThread = (gBuckets[i].threadId == currentMtThreadId())
        gBuckets[i].active = false
        foundIdx = i
        break
    if foundIdx >= 0:
      for i in foundIdx ..< gBucketCount - 1:
        gBuckets[i] = gBuckets[i + 1]
      gBucketCount -= 1

  # Only clean threadvar entries if called from the provider thread.
  # If called from another thread, processLoop will clean its own
  # threadvars when it receives the shutdown message.
  if isProviderThread:
    for i in countdown(tvProviderCtxs.len - 1, 0):
      if tvProviderCtxs[i] == brokerCtx:
        tvProviderCtxs.del(i)
        tvProviderHandlers.del(i)
        break
  elif not reqChan.isNil():
    warn "clearProvider called from non-provider thread; " &
         "threadvar entries on provider thread are stale but harmless " &
         "(next setProvider will detect and clean them)",
      brokerType = "Weather"

  # Send shutdown to stop process loop
  if not reqChan.isNil():
    reqChan[].sendSync(WeatherRequestMsg(isShutdown: true))

{.pop.}
