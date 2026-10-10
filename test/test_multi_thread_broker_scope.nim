{.used.}

## BrokerScope on the multi-thread lanes: same-thread release, per-slot
## release, off-thread misuse (logged no-op), and a foreign thread clearing a
## scope's registration and then re-providing / re-handling the same ctx (the
## scope's stale threadvar entry must not tear the new owner down).
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
var gDone: Atomic[bool]
var gSigHits: Atomic[int]

var gScopePtr: pointer
var gOffListenErr: Atomic[bool]
var gOffSignalErr: Atomic[bool]
var gOffClosed: Atomic[bool]

proc waitReady() =
  while not gReady.load():
    waitFor sleepAsync(chronos.milliseconds(1))

# Takes the scope's provider away from another thread, then provides the same
# ctx itself and serves until told to stop.
proc providerThiefThread() {.thread.} =
  proc inner() {.async.} =
    ScopeMtReq.clearProvider(gCtx)
    let r = ScopeMtReq.setProvider(
      gCtx,
      proc(): Future[Result[ScopeMtReq, string]] {.async.} =
        ok(ScopeMtReq(v: 2)),
    )
    doAssert r.isOk()
    gReady.store(true)
    while not gDone.load():
      await sleepAsync(chronos.milliseconds(1))
    ScopeMtReq.clearProvider(gCtx)

  waitFor inner()

# Same for the signal handler.
proc handlerThiefThread() {.thread.} =
  proc inner() {.async.} =
    await ScopeMtSig.dropSignalHandler(gCtx)
    let r = ScopeMtSig.onSignal(
      gCtx,
      proc(s: ScopeMtSig): Future[void] {.async: (raises: []).} =
        discard gSigHits.fetchAdd(1),
    )
    doAssert r.isOk()
    gReady.store(true)
    while not gDone.load():
      await sleepAsync(chronos.milliseconds(1))
    await ScopeMtSig.dropSignalHandler(gCtx)

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

  test "H2: foreign clear + re-provide survives the scope's close":
    let scope = newBrokerScope()
    let mine: ScopeMtReqProviderNoArgs = proc(): Future[Result[ScopeMtReq, string]] {.
        async
    .} =
      ok(ScopeMtReq(v: 1))
    check ScopeMtReq.setProvider(scope, mine).isOk()
    gCtx = scope.ctx
    gReady.store(false)
    gDone.store(false)
    var th: Thread[void]
    createThread(th, providerThiefThread)
    waitReady()
    # Our threadvar still holds `mine` (the foreign clear cannot reach it), so
    # only the shared bucket's owner check keeps us off the thief's provider.
    check ScopeMtReq.getCurrentProviderNoArgs(scope.ctx).isSome()
    check waitFor(releaseScopeMtReqProvider(scope.ctx, mine)) == broOwnerChanged
    check ScopeMtReq.getCurrentProviderNoArgs(scope.ctx).isNone() # stale purged
    waitFor scope.close() # -> alreadyGone now (debug)
    check (waitFor ScopeMtReq.request(scope.ctx)).get().v == 2
    gDone.store(true)
    joinThread(th)

  test "H3: foreign drop + re-handle survives the scope's close":
    let scope = newBrokerScope()
    let mine = ScopeMtSig.onSignalIt(scope):
      discard
    check mine.isOk()
    gCtx = scope.ctx
    gReady.store(false)
    gDone.store(false)
    gSigHits.store(0)
    var th: Thread[void]
    createThread(th, handlerThiefThread)
    waitReady()
    waitFor scope.close() # ownerChanged -> warn, left in place
    check ScopeMtSig.hasSignalHandler(scope.ctx)
    check ScopeMtSig.signal(scope.ctx, ScopeMtSig(n: 1)).isOk()
    waitFor sleepAsync(chronos.milliseconds(100))
    check gSigHits.load() == 1
    gDone.store(true)
    joinThread(th)
