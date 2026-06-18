## Tripwire for the "drop* async all-round" change (see
## doc/design/DROP_ASYNC_EMIT_SYNC_PLAN.md §R2 / §1e).
##
## The MT dropListener/dropAllListeners overloads are async only for
## cross-lane shape parity; their impl bodies MUST stay suspension-free so
## chronos runs them eagerly. That eager execution is what lets the FFI
## teardown path `discard <Evt>.dropAllListeners(ctx)` actually clear
## listeners (and fire the Part D-3 hook) even though the returned Future is
## never polled.
##
## This test exercises the DISCARD form directly: if anyone adds an `await`
## into the MT drop impl, `discard EagerEvt.dropAllListeners()` would return a
## pending, never-polled Future WITHOUT clearing the listener table, so the
## follow-up emit would still deliver and the `delivered == 1` assertion below
## would fail. That is the regression tripwire.

import std/atomics
import results
import testutils/unittests
import chronos
import brokers/[event_broker, broker_context]

EventBroker(mt):
  type EagerEvt = object
    n*: int32

var delivered: Atomic[int]

proc install(): EagerEvtListener =
  let h = EagerEvt.listen(
    proc(evt: EagerEvt): Future[void] {.async: (raises: []).} =
      discard delivered.fetchAdd(1, moRelease)
  )
  doAssert h.isOk()
  h.get()

suite "MT drop* async eager-execution tripwire":
  asyncTest "discard dropAllListeners clears listeners eagerly (no poll)":
    delivered.store(0)
    discard install()

    EagerEvt.emit(EagerEvt(n: 1))
    await sleepAsync(chronos.milliseconds(10))
    check delivered.load(moAcquire) == 1

    # DISCARD form — the FFI-teardown shape. The async body is
    # suspension-free, so the drop must complete eagerly here even though we
    # never await/poll the returned Future.
    discard EagerEvt.dropAllListeners()

    EagerEvt.emit(EagerEvt(n: 2))
    await sleepAsync(chronos.milliseconds(10))
    # If an `await` were added to the impl, the discarded Future would not have
    # cleared listeners and this would be 2.
    check delivered.load(moAcquire) == 1

    # State intact: re-listen and confirm delivery resumes.
    discard install()
    EagerEvt.emit(EagerEvt(n: 3))
    await sleepAsync(chronos.milliseconds(10))
    check delivered.load(moAcquire) == 2

    await EagerEvt.dropAllListeners()

  asyncTest "awaited dropListener removes one, keeps others (uniform shape)":
    delivered.store(0)
    let h1 = install()
    discard install()

    EagerEvt.emit(EagerEvt(n: 1))
    await sleepAsync(chronos.milliseconds(10))
    check delivered.load(moAcquire) == 2 # both listeners fired

    await EagerEvt.dropListener(h1)

    EagerEvt.emit(EagerEvt(n: 2))
    await sleepAsync(chronos.milliseconds(10))
    check delivered.load(moAcquire) == 3 # only the surviving listener fired

    await EagerEvt.dropAllListeners()
