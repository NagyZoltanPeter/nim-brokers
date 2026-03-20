{.push raises: [].}

import std/[strutils, concurrency/atomics], chronos

type BrokerContext* = distinct uint32

func `==`*(a, b: BrokerContext): bool =
  uint32(a) == uint32(b)

func `!=`*(a, b: BrokerContext): bool =
  uint32(a) != uint32(b)

func `$`*(bc: BrokerContext): string =
  toHex(uint32(bc), 8)

const DefaultBrokerContext* = BrokerContext(0xCAFFE14E'u32)

# ---------------------------------------------------------------------------
# Thread-global broker context
# ---------------------------------------------------------------------------
#
# Each thread has its own BrokerContext value (threadvar).
# Defaults to DefaultBrokerContext until explicitly set via
# setThreadBrokerContext or initThreadBrokerContext.
#
# NOTE: Module-level threadvar assignments only execute on the main thread.
# Secondary threads get zero-initialized threadvars, so we use a flag to
# lazily initialize on first access.

var globalBrokerContextLock {.threadvar.}: AsyncLock
globalBrokerContextLock = newAsyncLock()
var globalBrokerContextValue {.threadvar.}: BrokerContext
globalBrokerContextValue = DefaultBrokerContext
var globalBrokerContextInitialized {.threadvar.}: bool
globalBrokerContextInitialized = true # main thread is initialized

proc threadGlobalBrokerContext*(): BrokerContext =
  ## Returns the currently active broker context for this thread.
  ##
  ## Defaults to `DefaultBrokerContext` until explicitly set via
  ## `setThreadBrokerContext` or `initThreadBrokerContext`.
  ## Lock-free threadvar read — safe to call from anywhere.
  if not globalBrokerContextInitialized:
    globalBrokerContextValue = DefaultBrokerContext
    globalBrokerContextInitialized = true
  globalBrokerContextValue

# Backward-compatible alias
template globalBrokerContext*(): BrokerContext =
  threadGlobalBrokerContext()

var gContextCounter: Atomic[uint32]

proc NewBrokerContext*(): BrokerContext =
  var nextId = gContextCounter.fetchAdd(1, moRelaxed)
  if nextId == uint32(DefaultBrokerContext):
    nextId = gContextCounter.fetchAdd(1, moRelaxed)
  return BrokerContext(nextId)

# ---------------------------------------------------------------------------
# Sync thread-context binding (usable from {.thread.} init, before event loop)
# ---------------------------------------------------------------------------

proc setThreadBrokerContext*(ctx: BrokerContext) =
  ## Installs an existing BrokerContext as this thread's global broker context.
  ##
  ## Use when the context was created elsewhere (e.g. on the main thread)
  ## and this thread should adopt it. Readable via `threadGlobalBrokerContext()`.
  ##
  ## This is sync and thread-safe (writes only to this thread's threadvar).
  globalBrokerContextValue = ctx
  globalBrokerContextInitialized = true

proc initThreadBrokerContext*(): BrokerContext =
  ## Generates a new BrokerContext and installs it as this thread's
  ## global broker context. Returns the new context so it can be
  ## propagated to other threads for cross-thread broker access.
  ##
  ## Convenience for: `let ctx = NewBrokerContext(); setThreadBrokerContext(ctx)`
  let ctx = NewBrokerContext()
  setThreadBrokerContext(ctx)
  return ctx

# ---------------------------------------------------------------------------
# Async scoped context (backward compat)
# ---------------------------------------------------------------------------

template lockGlobalBrokerContext*(brokerCtx: BrokerContext, body: untyped): untyped =
  ## Runs `body` while holding the global broker context lock with the provided
  ## `brokerCtx` installed as the globally accessible context.
  ##
  ## This template is intended for use from within `chronos` async procs.
  block:
    # Lazy init: threadvar is nil on secondary threads (module-level init
    # only runs on the main thread).
    if globalBrokerContextLock.isNil():
      globalBrokerContextLock = newAsyncLock()
    await noCancel(globalBrokerContextLock.acquire())
    let previousBrokerCtx = globalBrokerContextValue
    globalBrokerContextValue = brokerCtx
    globalBrokerContextInitialized = true
    try:
      body
    finally:
      globalBrokerContextValue = previousBrokerCtx
      try:
        globalBrokerContextLock.release()
      except AsyncLockError:
        doAssert false, "globalBrokerContextLock.release(): lock not held"

template lockNewGlobalBrokerContext*(body: untyped): untyped =
  ## Runs `body` while holding the global broker context lock with a freshly
  ## generated broker context installed as the global accessor.
  ##
  ## The previous global broker context (if any) is restored on exit.
  lockGlobalBrokerContext(NewBrokerContext()):
    body

{.pop.}
