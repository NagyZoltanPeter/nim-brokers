## BrokerScope — bundle a BrokerContext with the registrations made through it.
##
## A component that registers several listeners / signal handlers / providers
## creates one `BrokerScope` and passes it in place of a `BrokerContext` to the
## scope overloads every broker generates (`listen`, `onSignal`,
## `replaceSignalHandler`, `setProvider`, `replaceProvider`, and all their
## `...It` body sugars). A single `await scope.close()` then releases them all,
## last-registered first, and leaves the scope empty and open for reuse.
## Registrations attempted *while* a close is running are rejected.
##
## Release, not clear: each undo removes *exactly the closure this scope
## installed*, and only while it is still installed (and, for the MT lanes,
## still owned by this thread). Lifecycle managed outside the scope always
## wins — a listener dropped early, a mock or another owner that took over a
## provider — and is logged, never treated as an error (`alreadyGone` at
## `debug`, `takenOver` / `ownerChanged` at `warn`).
##
## A scope belongs to the thread that created it. Use from another thread is
## logged at `error` and has no effect.
##
## See doc/design/BROKER_SCOPE_PLAN.md.

{.push raises: [].}

import chronos, chronicles
import ./broker_context

when compileOption("threads"):
  import ./internal/mt_broker_common

type
  BrokerReleaseOutcome* = enum
    ## Result of one scope undo. Anything but `broReleased` is logged.
    broReleased ## ours, removed
    broAlreadyGone ## nothing installed any more (dropped / cleared out of scope)
    broTakenOver ## something else is installed (mock, replace, re-registration)
    broOwnerChanged
      ## MT: our thread-local entry is stale; bucket gone or owned elsewhere

  BrokerUndo* = proc(): Future[void] {.async: (raises: []), gcsafe.}
    ## One recorded undo. Generated scope overloads build these; prefer them
    ## over calling `track` by hand.

  BrokerScope* = ref object
    ctx: BrokerContext
    when compileOption("threads"):
      ownerId: pointer
      ownerGen: uint64
    undo: seq[BrokerUndo]
    tearingDown: bool ## true for the whole close, synchronous phase included
    closing: Future[void].Raising([]) ## set only once the teardown has suspended

proc newBrokerScope*(ctx: BrokerContext = NewBrokerContext()): BrokerScope =
  ## Create a scope on `ctx` (a fresh context by default) owned by the calling
  ## thread.
  result = BrokerScope(ctx: ctx)
  when compileOption("threads"):
    result.ownerId = currentMtThreadId()
    result.ownerGen = currentMtThreadGen()

func ctx*(s: BrokerScope): BrokerContext =
  ## Immutable; safe to read from any thread.
  s.ctx

func isOpen*(s: BrokerScope): bool =
  ## False only while a `close()` is running. Owning thread only.
  not s.tearingDown

proc onOwningThread*(s: BrokerScope, op: string): bool =
  ## True when called on the scope's owning thread; otherwise logs an error.
  when compileOption("threads"):
    if s.ownerId == currentMtThreadId() and s.ownerGen == currentMtThreadGen():
      return true
    error "BrokerScope used off its owning thread; ignored", op = op, brokerCtx = $s.ctx
    false
  else:
    true

proc track*(s: BrokerScope, u: BrokerUndo) =
  ## Low-level: record an undo (used by generated code). A slot registered twice
  ## through one scope records two undos; run newest-first, the older one finds
  ## its closure already gone and is a no-op.
  s.undo.add(u)

proc reportBrokerRelease*(
    outcome: BrokerReleaseOutcome, brokerType, kind: string, brokerCtx: BrokerContext
) =
  ## Low-level: log a non-`broReleased` undo outcome (used by generated code).
  case outcome
  of broReleased:
    discard
  of broAlreadyGone:
    debug "BrokerScope.close: registration already removed outside the scope",
      brokerType = brokerType, kind = kind, brokerCtx = $brokerCtx
  of broTakenOver:
    warn "BrokerScope.close: registration taken over outside the scope; left in place",
      brokerType = brokerType, kind = kind, brokerCtx = $brokerCtx
  of broOwnerChanged:
    warn "BrokerScope.close: registration now owned by another thread; left in place",
      brokerType = brokerType, kind = kind, brokerCtx = $brokerCtx

proc runTeardown(s: BrokerScope, undo: seq[BrokerUndo]) {.async: (raises: []).} =
  ## Never awaited directly (callers `join` it), so a cancelled `close()` caller
  ## cannot cancel undos mid-way. Resets the scope's state itself, whatever
  ## happens to the waiters.
  for i in countdown(undo.high, 0):
    await undo[i]()
  s.closing = nil
  s.tearingDown = false

proc close*(s: BrokerScope) {.async: (raises: []).} =
  ## Release every registration made through the scope, last first. When the
  ## teardown finishes the scope is empty and open again. Concurrent callers
  ## wait on the same teardown; cancelling a caller only stops its wait. Off the
  ## owning thread it logs an error and returns.
  if not s.onOwningThread("close"):
    return
  if not s.tearingDown:
    # Flag first: registrations are rejected from the very first undo on, and
    # the list is detached before anything can mutate it.
    s.tearingDown = true
    let teardown = runTeardown(s, move(s.undo))
    if teardown.finished():
      return # every undo was suspension-free; state already reset
    s.closing = teardown
  elif s.closing.isNil:
    # Re-entered from the synchronous part of our own teardown: waiting here
    # would wait on ourselves.
    return
  try:
    await s.closing.join()
  except CancelledError:
    discard # this caller gave up waiting; the teardown carries on

{.pop.}
