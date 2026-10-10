{.used.}

## BrokerScope on the multi-thread lanes: same-thread release, per-slot
## release, off-thread misuse (logged no-op), and a foreign thread trying to
## clear a scope's registration and take the ctx over — refused, since clears
## are owner-only (doc/design/MT_OWNER_ONLY_CLEAR_PLAN.md), so the scope keeps
## and later releases its own registration.
## See doc/design/BROKER_SCOPE_PLAN.md §3 (H2/H3) and §7.

import testutils/unittests
import chronos
import std/[atomics, options]

import brokers/event_broker
import brokers/signal_broker
import brokers/request_broker

EventBroker(mt):
  type ScopeMtEvt = object
    n*: int

SignalBroker(mt):
  type ScopeMtSig = object
    n*: int

RequestBroker(mt):
  type ScopeMtReq = object
    v*: int

  proc signature*(): Future[Result[ScopeMtReq, string]] {.async.}

RequestBroker(mt):
  type ScopeMtDual = object
    v*: int

  proc signature*(): Future[Result[ScopeMtDual, string]] {.async.}
  proc signature*(k: int): Future[Result[ScopeMtDual, string]] {.async.}

proc drain() =
  waitFor sleepAsync(chronos.milliseconds(20))

# ── Cross-thread plumbing ─────────────────────────────────────────────────

var gCtx: BrokerContext
var gReady: Atomic[bool]
var gSigHits: Atomic[int]

var gScopePtr: pointer
var gOffListenErr: Atomic[bool]
var gOffSignalErr: Atomic[bool]
var gOffClosed: Atomic[bool]
var gThiefTookOver: Atomic[bool]

proc waitReady() =
  while not gReady.load():
    waitFor sleepAsync(chronos.milliseconds(1))

# Tries to take the scope's provider away from another thread and provide the
# same ctx itself. Both steps are refused: clears are owner-only.
proc providerThiefThread() {.thread.} =
  proc inner() {.async.} =
    ScopeMtReq.clearProvider(gCtx) # not the owner: logged no-op
    let r = ScopeMtReq.setProvider(
      gCtx,
      proc(): Future[Result[ScopeMtReq, string]] {.async.} =
        ok(ScopeMtReq(v: 2)),
    )
    gThiefTookOver.store(r.isOk())
    gReady.store(true)

  waitFor inner()

# Same for the signal handler.
proc handlerThiefThread() {.thread.} =
  proc inner() {.async.} =
    await ScopeMtSig.dropSignalHandler(gCtx) # not the owner: logged no-op
    let r = ScopeMtSig.onSignal(
      gCtx,
      proc(s: ScopeMtSig): Future[void] {.async: (raises: []).} =
        discard,
    )
    gThiefTookOver.store(r.isOk())
    gReady.store(true)

  waitFor inner()

# Misuses a scope owned by the main thread.
proc offThread() {.thread.} =
  let scope {.cursor.} = cast[BrokerScope](gScopePtr)
  let l = ScopeMtEvt.listen(
    scope,
    proc(e: ScopeMtEvt): Future[void] {.async: (raises: []).} =
      discard,
  )
  gOffListenErr.store(l.isErr())
  let s = ScopeMtSig.onSignal(
    scope,
    proc(s: ScopeMtSig): Future[void] {.async: (raises: []).} =
      discard,
  )
  gOffSignalErr.store(s.isErr())
  waitFor scope.close()
  gOffClosed.store(true)

suite "BrokerScope MT — same thread":
  test "listen / onSignal / provide through a scope; close releases all":
    let scope = newBrokerScope()
    var evts, sigs = 0
    let l = ScopeMtEvt.listenIt(scope):
      inc evts
    check l.isOk()
    let s = ScopeMtSig.onSignalIt(scope):
      inc sigs
    check s.isOk()
    let p = ScopeMtReq.provideIt(scope):
      return ok(ScopeMtReq(v: 1))
    check p.isOk()

    ScopeMtEvt.emit(scope.ctx, ScopeMtEvt(n: 1))
    check ScopeMtSig.signal(scope.ctx, ScopeMtSig(n: 1)).isOk()
    drain()
    check evts == 1
    check sigs == 1
    check (waitFor ScopeMtReq.request(scope.ctx)).get().v == 1

    waitFor scope.close()
    ScopeMtEvt.emit(scope.ctx, ScopeMtEvt(n: 2))
    drain()
    check evts == 1
    check not ScopeMtSig.hasSignalHandler(scope.ctx)
    check not ScopeMtReq.isProvided(scope.ctx)

  test "reprovideIt twice + replaceSignalHandler: close clears":
    let scope = newBrokerScope()
    let r1 = ScopeMtReq.reprovideIt(scope):
      return ok(ScopeMtReq(v: 1))
    check r1.isOk()
    let r2 = ScopeMtReq.reprovideIt(scope):
      return ok(ScopeMtReq(v: 2))
    check r2.isOk()
    check (waitFor ScopeMtReq.request(scope.ctx)).get().v == 2
    check ScopeMtSig
      .replaceSignalHandler(
        scope,
        proc(s: ScopeMtSig): Future[void] {.async: (raises: []).} =
          discard,
      )
      .isOk()
    waitFor scope.close()
    check not ScopeMtReq.isProvided(scope.ctx)
    check not ScopeMtSig.hasSignalHandler(scope.ctx)

  test "dual slot: only the scope's slot is released; bucket kept":
    let scope = newBrokerScope()
    let mine = ScopeMtDual.provideItNoArgs(scope):
      return ok(ScopeMtDual(v: 0))
    check mine.isOk()
    let theirs = ScopeMtDual.provideIt(scope.ctx):
      return ok(ScopeMtDual(v: k))
    check theirs.isOk()
    waitFor scope.close()
    check ScopeMtDual.isProvided(scope.ctx)
    check (waitFor ScopeMtDual.request(scope.ctx, 7)).get().v == 7
    check (waitFor ScopeMtDual.request(scope.ctx)).isErr()
    check ScopeMtDual.getCurrentProviderNoArgs(scope.ctx).isNone()
    ScopeMtDual.clearProvider(scope.ctx)

  test "release outcomes":
    let ctx = NewBrokerContext()
    let h: ScopeMtEvtListenerProc = proc(
        e: ScopeMtEvt
    ): Future[void] {.async: (raises: []).} =
      discard
    let lh = ScopeMtEvt.listen(ctx, h).get()
    check waitFor(releaseScopeMtEvtListener(ctx, lh, h)) == broReleased
    check waitFor(releaseScopeMtEvtListener(ctx, lh, h)) == broAlreadyGone

    let sh: ScopeMtSigSignalHandler = proc(
        s: ScopeMtSig
    ): Future[void] {.async: (raises: []).} =
      discard
    let other: ScopeMtSigSignalHandler = proc(
        s: ScopeMtSig
    ): Future[void] {.async: (raises: []).} =
      discard
    check ScopeMtSig.onSignal(ctx, sh).isOk()
    check ScopeMtSig.replaceSignalHandler(ctx, other).isOk()
    check waitFor(releaseScopeMtSigSignalHandler(ctx, sh)) == broTakenOver
    check waitFor(releaseScopeMtSigSignalHandler(ctx, other)) == broReleased
    check waitFor(releaseScopeMtSigSignalHandler(ctx, other)) == broAlreadyGone

suite "BrokerScope MT — cross thread":
  test "off-thread use is a logged no-op; owner can still close":
    let scope = newBrokerScope()
    let mine = ScopeMtSig.onSignalIt(scope):
      discard
    check mine.isOk()
    gScopePtr = cast[pointer](scope)
    var th: Thread[void]
    createThread(th, offThread)
    joinThread(th)
    check gOffListenErr.load()
    check gOffSignalErr.load()
    check gOffClosed.load()
    check scope.isOpen # off-thread close did nothing
    check ScopeMtSig.hasSignalHandler(scope.ctx)
    waitFor scope.close()
    check not ScopeMtSig.hasSignalHandler(scope.ctx)

  test "H2: a foreign clear cannot take the scope's provider; close releases it":
    let scope = newBrokerScope()
    let mine: ScopeMtReqProviderNoArgs = proc(): Future[Result[ScopeMtReq, string]] {.
        async
    .} =
      ok(ScopeMtReq(v: 1))
    check ScopeMtReq.setProvider(scope, mine).isOk()
    gCtx = scope.ctx
    gReady.store(false)
    gThiefTookOver.store(true)
    var th: Thread[void]
    createThread(th, providerThiefThread)
    waitReady()
    joinThread(th)
    check not gThiefTookOver.load()
    check ScopeMtReq.getCurrentProviderNoArgs(scope.ctx).isSome()
    check (waitFor ScopeMtReq.request(scope.ctx)).get().v == 1
    waitFor scope.close()
    check not ScopeMtReq.isProvided(scope.ctx)

  test "H3: a foreign drop cannot take the scope's handler; close releases it":
    let scope = newBrokerScope()
    let mine = ScopeMtSig.onSignalIt(scope):
      discard gSigHits.fetchAdd(1)
    check mine.isOk()
    gCtx = scope.ctx
    gReady.store(false)
    gThiefTookOver.store(true)
    gSigHits.store(0)
    var th: Thread[void]
    createThread(th, handlerThiefThread)
    waitReady()
    joinThread(th)
    check not gThiefTookOver.load()
    check ScopeMtSig.signal(scope.ctx, ScopeMtSig(n: 1)).isOk()
    waitFor sleepAsync(chronos.milliseconds(100))
    check gSigHits.load() == 1
    waitFor scope.close()
    check not ScopeMtSig.hasSignalHandler(scope.ctx)
