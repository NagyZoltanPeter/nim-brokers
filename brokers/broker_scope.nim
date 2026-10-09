## BrokerScope — bundle a BrokerContext with the registrations made through it.
##
## A component that registers several listeners / signal handlers / providers
## creates one `BrokerScope` and passes it in place of a `BrokerContext` to the
## scope overloads every broker generates (`listen`, `onSignal`,
## `replaceSignalHandler`, `setProvider`, `replaceProvider`, and all their
## `...It` body sugars). A single `await scope.close()` then releases them all,
## last-registered first.
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
    undo: seq[tuple[key: string, fn: BrokerUndo]] ## key "" = unkeyed
    closing: Future[void].Raising([]) ## nil = open

proc newBrokerScope*(ctx: BrokerContext = NewBrokerContext()): BrokerScope =
  ## Create a scope on `ctx` (a fresh context by default) owned by the calling
  ## thread.
  result = BrokerScope(ctx: ctx)
  when compileOption("threads"):
    result.ownerId = currentMtThreadId()
    result.ownerGen = currentMtThreadGen()

func ctx*(s: BrokerScope): BrokerContext =
  s.ctx

func isOpen*(s: BrokerScope): bool =
  s.closing.isNil

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
  ## Low-level: append an undo (additive registrations — listeners, multi
  ## providers).
  s.undo.add((key: "", fn: u))

proc track*(s: BrokerScope, key: string, u: BrokerUndo) =
  ## Low-level: record the undo for a single-occupancy registration (provider
  ## slot, signal handler). Re-registering the same key overwrites its undo in
  ## place, keeping the original teardown position.
  for i in 0 ..< s.undo.len:
    if s.undo[i].key == key:
      s.undo[i].fn = u
      return
  s.undo.add((key: key, fn: u))

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

proc runUndos(undo: seq[tuple[key: string, fn: BrokerUndo]]) {.async: (raises: []).} =
  for i in countdown(undo.high, 0):
    await undo[i].fn()

proc close*(s: BrokerScope) {.async: (raises: []).} =
  ## Release every registration made through the scope, last first.
  ## Idempotent: repeated and concurrent callers all wait on the same teardown.
  ## Off the owning thread it logs an error and returns, leaving the scope open.
  if not s.onOwningThread("close"):
    return
  if s.closing.isNil:
    # Detach the list before the first await, so a handler closing its own
    # scope (or a racing registration) cannot mutate it mid-walk.
    s.closing = runUndos(move(s.undo))
  await s.closing

{.pop.}
