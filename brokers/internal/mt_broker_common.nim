## Multi-Thread Broker Common
## --------------------------
## Shared runtime helpers used by both mt_request_broker and mt_event_broker.
## These are not generated — they are used directly by generated code.

{.push raises: [].}

import chronos, chronos/threadsync
import std/atomics
export chronos, threadsync, atomics

# ---------------------------------------------------------------------------
# Thread identity
# ---------------------------------------------------------------------------

var mtThreadIdMarker* {.threadvar.}: bool
  ## Each thread gets its own copy; `addr mtThreadIdMarker` is a unique thread id.

template currentMtThreadId*(): pointer =
  addr mtThreadIdMarker

# ---------------------------------------------------------------------------
# Thread generation — monotonically increasing, unique per thread incarnation.
# Under refc, threadvar addresses can be reused when threads exit and new
# ones are created. The generation counter disambiguates reused addresses.
# ---------------------------------------------------------------------------

var gMtThreadGenCounter: Atomic[uint64]

var mtThreadGen* {.threadvar.}: uint64
var mtThreadGenInitialized {.threadvar.}: bool

proc currentMtThreadGen*(): uint64 =
  if not mtThreadGenInitialized:
    mtThreadGen = gMtThreadGenCounter.fetchAdd(1, moRelaxed)
    mtThreadGenInitialized = true
  mtThreadGen

# ---------------------------------------------------------------------------
# Blocking await for {.thread.} procs
# ---------------------------------------------------------------------------

template blockingAwait*[T](f: Future[T]): T =
  ## Blocking await for use inside non-async `{.thread.}` procs.
  ## Use this instead of `await` (which conflicts with chronos's async-only
  ## `await`) or call `waitFor` directly.
  waitFor(f)

# ---------------------------------------------------------------------------
# Per-thread shared signal + dispatcher
# ---------------------------------------------------------------------------
# Instead of one ThreadSignalPtr (2 fds on macOS, 1 on Linux) per broker
# type per thread, every broker type on the same thread shares a single
# ThreadSignalPtr.  Fd count drops from O(broker_types × threads) to
# O(threads).
#
# Each broker type registers a poll proc (ThreadDispatchPollFn).  The
# shared brokerDispatchLoop coroutine fires whenever ANY channel on this
# thread has a new message, then drains all registered poll procs.
# Poll proc return values:
#   0  — nothing to process; keep registered
#   1  — message processed; keep registered
#   2  — done (shutdown or one-shot complete); remove from dispatcher
# ---------------------------------------------------------------------------

type ThreadDispatchPollFn* = proc(): int {.gcsafe, raises: [].}

var gBrokerThreadSignal* {.threadvar.}: ThreadSignalPtr
var gBrokerThreadPollers* {.threadvar.}: seq[ThreadDispatchPollFn]
var gBrokerDispatchStarted* {.threadvar.}: bool

proc getOrInitBrokerSignal*(): ThreadSignalPtr =
  ## Get (or lazily create) the per-thread signal shared by all broker types.
  if gBrokerThreadSignal.isNil:
    let res = ThreadSignalPtr.new()
    if res.isErr():
      raiseAssert "BrokerDispatcher: failed to create thread signal: " & res.error
    gBrokerThreadSignal = res.get()
  gBrokerThreadSignal

proc fireBrokerSignal*(signal: ThreadSignalPtr) {.gcsafe, raises: [].} =
  ## Wake the target thread's broker dispatcher. Safe to call from any thread.
  discard signal.fireSync()

proc registerBrokerPoller*(fn: ThreadDispatchPollFn) =
  ## Register a poll function with this thread's dispatcher.
  ## Must be called from the owning thread.
  gBrokerThreadPollers.add(fn)

proc brokerDispatchLoop*(signal: ThreadSignalPtr) {.async: (raises: []).} =
  ## Single dispatch loop per chronos thread.  Drains all registered broker
  ## channel pollers whenever the shared signal fires.
  while true:
    # Drain: keep polling until every channel is empty.
    var anyWork = true
    while anyWork:
      anyWork = false
      var i = 0
      while i < gBrokerThreadPollers.len:
        let r = gBrokerThreadPollers[i]()
        case r
        of 2:
          # Poller is done — remove it.
          gBrokerThreadPollers.del(i)
        of 1:
          anyWork = true
          inc i
        else:
          inc i
    # Wait for next signal.
    let waitRes = catch:
      await signal.wait()
    if waitRes.isErr():
      break

proc ensureBrokerDispatchStarted*() =
  ## Start the per-thread dispatch loop if not already running.
  ## Must be called from within a chronos async context.
  if not gBrokerDispatchStarted:
    gBrokerDispatchStarted = true
    asyncSpawn brokerDispatchLoop(getOrInitBrokerSignal())
