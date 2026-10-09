{.used.}

## BrokerScope (single-thread lanes): registrations bundled under one scope and
## released together, ownership-checked. See doc/design/BROKER_SCOPE_PLAN.md.
##
## The brokers are declared in this module, so the generated (unexported)
## `release*` procs are callable here to assert release outcomes directly.

import testutils/unittests
import chronos

import brokers/event_broker
import brokers/signal_broker
import brokers/request_broker
import brokers/multi_request_broker

EventBroker:
  type ScopeEvt = object
    n*: int

SignalBroker:
  type ScopeSig = object
    n*: int

RequestBroker:
  type ScopeReq = object
    v*: int

  proc signature*(): Future[Result[ScopeReq, string]] {.async.}

RequestBroker:
  type ScopeDual = object
    v*: int

  proc signature*(): Future[Result[ScopeDual, string]] {.async.}
  proc signature*(k: int): Future[Result[ScopeDual, string]] {.async.}

RequestBroker(sync):
  type ScopeSync = object
    v*: int

  proc signature*(): Result[ScopeSync, string]

MultiRequestBroker:
  type ScopeMulti = object
    v*: int

  proc signature*(): Future[Result[ScopeMulti, string]] {.async.}

proc drain() =
  waitFor sleepAsync(chronos.milliseconds(20))

suite "BrokerScope core":
  test "close runs undos last-first, once":
    let scope = newBrokerScope()
    var order: seq[int] = @[]
    for i in 1 .. 3:
      closureScope:
        let n = i
        scope.track(
          proc() {.async: (raises: []), gcsafe.} =
            order.add(n)
        )
    waitFor scope.close()
    waitFor scope.close() # empty now: runs nothing
    check order == @[3, 2, 1]
    check scope.isOpen

  test "concurrent closers wait on the same teardown":
    let scope = newBrokerScope()
    var done = false
    scope.track(
      proc() {.async: (raises: []), gcsafe.} =
        try:
          await sleepAsync(chronos.milliseconds(10))
        except CancelledError:
          discard
        done = true
    )
    let a = scope.close()
    let b = scope.close()
    waitFor b
    check done
    waitFor a

  test "registration is rejected while a close is running":
    let scope = newBrokerScope()
    var during: seq[bool] = @[]
    scope.track(
      proc() {.async: (raises: []), gcsafe.} =
        try:
          await sleepAsync(chronos.milliseconds(10))
        except CancelledError:
          discard
    )
    let closing = scope.close()
    check not scope.isOpen
    let l = ScopeEvt.listenIt(scope):
      discard
    during.add(l.isErr())
    let s = ScopeSig.onSignalIt(scope):
      discard
    during.add(s.isErr())
    let r = ScopeReq.provideIt(scope):
      return ok(ScopeReq(v: 1))
    during.add(r.isErr())
    check during == @[true, true, true]
    check l.error == "BrokerScope is closing"
    check not ScopeReq.isProvided(scope.ctx)
    waitFor closing
    check scope.isOpen

  test "re-open: register, close, register again, close again":
    let scope = newBrokerScope()
    for round in 1 .. 2:
      let v = round
      let r = ScopeReq.provideIt(scope):
        return ok(ScopeReq(v: v))
      check r.isOk()
      check (waitFor ScopeReq.request(scope.ctx)).get().v == round
      waitFor scope.close()
      check not ScopeReq.isProvided(scope.ctx)
      check scope.isOpen

  test "cancelling the starter's close() does not cancel the teardown":
    let scope = newBrokerScope()
    var sawCancel = false
    var done = false
    scope.track(
      proc() {.async: (raises: []), gcsafe.} =
        try:
          await sleepAsync(chronos.milliseconds(20))
        except CancelledError:
          sawCancel = true
        done = true
    )
    let f = scope.close()
    check not scope.isOpen
    waitFor f.cancelAndWait()
    check not sawCancel
    waitFor sleepAsync(chronos.milliseconds(50))
    check done
    check not sawCancel
    check scope.isOpen

  test "cancelling a concurrent waiter leaves the teardown intact":
    let scope = newBrokerScope()
    var sawCancel = false
    scope.track(
      proc() {.async: (raises: []), gcsafe.} =
        try:
          await sleepAsync(chronos.milliseconds(20))
        except CancelledError:
          sawCancel = true
    )
    let a = scope.close()
    let b = scope.close()
    waitFor b.cancelAndWait()
    check not a.finished()
    waitFor a
    check not sawCancel
    check scope.isOpen

  test "registration from the synchronous phase of close is rejected":
    let scope = newBrokerScope()
    var r: Result[void, string]
    scope.track(
      proc() {.async: (raises: []), gcsafe.} =
        # Runs synchronously inside close(), before any suspension.
        r = ScopeReq.setProvider(
          scope,
          proc(): Future[Result[ScopeReq, string]] {.async.} =
            ok(ScopeReq(v: 1)),
        )
    )
    waitFor scope.close()
    check r.isErr()
    check r.error == "BrokerScope is closing"
    check not ScopeReq.isProvided(scope.ctx)
    check scope.isOpen

  test "re-entrant close() from inside an undo returns without deadlock":
    let scope = newBrokerScope()
    var inner, outer = false
    scope.track(
      proc() {.async: (raises: []), gcsafe.} =
        try:
          await sleepAsync(chronos.milliseconds(5))
        except CancelledError:
          discard
        outer = true
    )
    scope.track(
      proc() {.async: (raises: []), gcsafe.} =
        await scope.close() # synchronous phase: must not wait on itself
        inner = true
    )
    let ok = waitFor withTimeout(scope.close(), chronos.seconds(2))
    check ok
    check inner
    check outer
    check scope.isOpen

  test "adopts an existing context":
    let ctx = NewBrokerContext()
    check newBrokerScope(ctx).ctx == ctx

suite "BrokerScope EventBroker":
  test "listenIt through a scope; close stops delivery":
    let scope = newBrokerScope()
    var seen: seq[int] = @[]
    let r14 = ScopeEvt.listenIt(scope):
      seen.add(it.n)
    check r14.isOk()
    check ScopeEvt
      .listen(
        scope,
        proc(e: ScopeEvt) {.async: (raises: []), gcsafe.} =
          seen.add(-e.n),
      )
      .isOk()
    ScopeEvt.emit(scope.ctx, ScopeEvt(n: 1))
    drain()
    check seen.len == 2
    waitFor scope.close()
    ScopeEvt.emit(scope.ctx, ScopeEvt(n: 2))
    drain()
    check seen.len == 2

  test "released / alreadyGone outcomes":
    let ctx = NewBrokerContext()
    let handler: ScopeEvtListenerProc = proc(
        e: ScopeEvt
    ) {.async: (raises: []), gcsafe.} =
      discard
    let h = ScopeEvt.listen(ctx, handler).get()
    check waitFor(releaseScopeEvtListener(ctx, h, handler)) == broReleased
    check waitFor(releaseScopeEvtListener(ctx, h, handler)) == broAlreadyGone

  test "id reuse (ABA): another owner's listener survives close":
    let scope = newBrokerScope()
    var mine, theirs = 0
    let h = ScopeEvt.listenIt(scope):
      inc mine
    check h.isOk()
    waitFor ScopeEvt.dropAllListeners(scope.ctx) # bucket deleted, ids restart
    let other = ScopeEvt.listenIt(scope.ctx):
      inc theirs
    check other.get().id == h.get().id # same id, different closure
    waitFor scope.close() # takenOver -> left in place
    ScopeEvt.emit(scope.ctx, ScopeEvt(n: 1))
    drain()
    check mine == 0
    check theirs == 1
    waitFor ScopeEvt.dropAllListeners(scope.ctx)

suite "BrokerScope SignalBroker":
  test "onSignalIt through a scope; close drops the handler":
    let scope = newBrokerScope()
    var got = 0
    let r15 = ScopeSig.onSignalIt(scope):
      got = it.n
    check r15.isOk()
    check ScopeSig.signal(scope.ctx, ScopeSig(n: 5)).isOk()
    drain()
    check got == 5
    waitFor scope.close()
    check not ScopeSig.hasSignalHandler(scope.ctx)
    check ScopeSig.signal(scope.ctx, ScopeSig(n: 6)).isErr()

  test "duplicate onSignal is not tracked; the original owner survives close":
    let ctx = NewBrokerContext()
    let first = ScopeSig.onSignalIt(ctx):
      discard
    check first.isOk()
    let scope = newBrokerScope(ctx)
    let second = ScopeSig.onSignalIt(scope):
      discard
    check second.isErr()
    waitFor scope.close()
    check ScopeSig.hasSignalHandler(ctx)
    waitFor ScopeSig.dropSignalHandler(ctx)

  test "replaceSignalHandler through a scope: close is a full drop":
    let scope = newBrokerScope()
    check ScopeSig
      .replaceSignalHandler(
        scope,
        proc(s: ScopeSig) {.async: (raises: []), gcsafe.} =
          discard,
      )
      .isOk()
    waitFor scope.close()
    check not ScopeSig.hasSignalHandler(scope.ctx)

  test "taken over by another replace: survives close":
    let scope = newBrokerScope()
    let mine: ScopeSigSignalHandler = proc(
        s: ScopeSig
    ) {.async: (raises: []), gcsafe.} =
      discard
    let theirs: ScopeSigSignalHandler = proc(
        s: ScopeSig
    ) {.async: (raises: []), gcsafe.} =
      discard
    check ScopeSig.onSignal(scope, mine).isOk()
    check ScopeSig.replaceSignalHandler(scope.ctx, theirs).isOk()
    check waitFor(releaseScopeSigSignalHandler(scope.ctx, mine)) == broTakenOver
    waitFor scope.close()
    check ScopeSig.hasSignalHandler(scope.ctx)
    waitFor ScopeSig.dropSignalHandler(scope.ctx)

suite "BrokerScope RequestBroker":
  test "provideIt through a scope; close clears it":
    let scope = newBrokerScope()
    let r2 = ScopeReq.provideIt(scope):
      return ok(ScopeReq(v: 1))
    check r2.isOk()
    check (waitFor ScopeReq.request(scope.ctx)).get().v == 1
    waitFor scope.close()
    check not ScopeReq.isProvided(scope.ctx)

  test "default context works too":
    let scope = newBrokerScope(DefaultBrokerContext)
    let r3 = ScopeReq.provideIt(scope):
      return ok(ScopeReq(v: 2))
    check r3.isOk()
    waitFor scope.close()
    check not ScopeReq.isProvided()

  test "already provided: nothing tracked, the other owner survives":
    let ctx = NewBrokerContext()
    let r4 = ScopeReq.provideIt(ctx):
      return ok(ScopeReq(v: 1))
    check r4.isOk()
    let scope = newBrokerScope(ctx)
    let r5 = ScopeReq.provideIt(scope):
      return ok(ScopeReq(v: 2))
    check r5.isErr()
    waitFor scope.close()
    check (waitFor ScopeReq.request(ctx)).get().v == 1
    ScopeReq.clearProvider(ctx)

  test "mock active at close survives":
    let scope = newBrokerScope()
    let r6 = ScopeReq.provideIt(scope):
      return ok(ScopeReq(v: 1))
    check r6.isOk()
    let mock: ScopeReqProviderNoArgs = proc(): Future[Result[ScopeReq, string]] {.
        async
    .} =
      ok(ScopeReq(v: 99))
    ScopeReq.withMockProvider(scope.ctx, mock):
      waitFor scope.close()
      check (waitFor ScopeReq.request(scope.ctx)).get().v == 99
    ScopeReq.clearProvider(scope.ctx)

  test "reprovideIt twice: one undo, close clears":
    let scope = newBrokerScope()
    let r7 = ScopeReq.reprovideIt(scope):
      return ok(ScopeReq(v: 1))
    check r7.isOk()
    let r8 = ScopeReq.reprovideIt(scope):
      return ok(ScopeReq(v: 2))
    check r8.isOk()
    check (waitFor ScopeReq.request(scope.ctx)).get().v == 2
    waitFor scope.close()
    check not ScopeReq.isProvided(scope.ctx)

  test "dual slot: release clears only the scope's slot":
    let scope = newBrokerScope()
    let r9 = ScopeDual.provideItNoArgs(scope):
      return ok(ScopeDual(v: 0))
    check r9.isOk()
    let r10 = ScopeDual.provideIt(scope.ctx):
      return ok(ScopeDual(v: k))
    check r10.isOk()
    waitFor scope.close()
    check (waitFor ScopeDual.request(scope.ctx, 7)).get().v == 7
    check (waitFor ScopeDual.request(scope.ctx)).isErr()
    ScopeDual.clearProvider(scope.ctx)

  test "provider outcomes":
    let ctx = NewBrokerContext()
    let p: ScopeReqProviderNoArgs = proc(): Future[Result[ScopeReq, string]] {.async.} =
      ok(ScopeReq(v: 1))
    let q: ScopeReqProviderNoArgs = proc(): Future[Result[ScopeReq, string]] {.async.} =
      ok(ScopeReq(v: 2))
    check waitFor(releaseScopeReqProvider(ctx, p)) == broAlreadyGone
    check ScopeReq.setProvider(ctx, q).isOk()
    check waitFor(releaseScopeReqProvider(ctx, p)) == broTakenOver
    check waitFor(releaseScopeReqProvider(ctx, q)) == broReleased
    check not ScopeReq.isProvided(ctx)

  test "sync RequestBroker":
    let scope = newBrokerScope()
    let r11 = ScopeSync.provideIt(scope):
      return ok(ScopeSync(v: 3))
    check r11.isOk()
    check ScopeSync.request(scope.ctx).get().v == 3
    waitFor scope.close()
    check not ScopeSync.isProvided(scope.ctx)

suite "BrokerScope MultiRequestBroker":
  test "provideIt through a scope, twice; close removes both":
    let scope = newBrokerScope()
    let r12 = ScopeMulti.provideIt(scope):
      return ok(ScopeMulti(v: 1))
    check r12.isOk()
    let r13 = ScopeMulti.provideIt(scope):
      return ok(ScopeMulti(v: 2))
    check r13.isOk()
    check (waitFor ScopeMulti.request(scope.ctx)).get().len == 2
    waitFor scope.close()
    check (waitFor ScopeMulti.request(scope.ctx)).get().len == 0

  test "index reuse: another owner's provider survives close":
    let scope = newBrokerScope()
    let h = ScopeMulti.provideIt(scope):
      return ok(ScopeMulti(v: 1))
    check h.isOk()
    ScopeMulti.removeProvider(scope.ctx, h.get()) # bucket deleted
    let other = ScopeMulti.provideIt(scope.ctx):
      return ok(ScopeMulti(v: 2))
    check other.get().id == h.get().id
    waitFor scope.close() # takenOver -> left in place
    let r = (waitFor ScopeMulti.request(scope.ctx)).get()
    check r.len == 1
    check r[0].v == 2
    ScopeMulti.clearProviders(scope.ctx)
