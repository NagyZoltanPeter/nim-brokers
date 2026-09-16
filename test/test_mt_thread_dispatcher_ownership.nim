{.used.}

import testutils/unittests
import chronos
import std/atomics

import brokers/signal_broker

## ---------------------------------------------------------------------------
## Broker teardown must leave the thread's chronos dispatcher usable
## ---------------------------------------------------------------------------
##
## A thread that merely *uses* brokers — an FFI library's worker, the main
## thread — belongs to someone else, who may still drive its dispatcher after
## the broker teardown: code after an explicit `teardownBrokerThread()`, or a
## destruction hook registered before broker use (Nim runs those last). The
## teardown must not close the dispatcher under them.

SignalBroker(mt):
  type OwnershipPulse = void

const
  NotRun = 0
  Polled = 1
  Raised = 2

var gOutcome: Atomic[int]

proc pollDispatcher() {.gcsafe, raises: [].} =
  try:
    waitFor sleepAsync(chronos.milliseconds(1))
    gOutcome.store(Polled)
  except CatchableError:
    gOutcome.store(Raised)
  except Defect:
    gOutcome.store(Raised)

proc useBrokers() =
  let r = OwnershipPulse.onSignal(
    proc(): Future[void] {.async: (raises: []).} =
      discard
  )
  doAssert r.isOk()
  waitFor OwnershipPulse.dropSignalHandler()

proc hookedThread() {.thread.} =
  # Registered before broker use, so it runs after the broker teardown hook.
  onThreadDestruction(pollDispatcher)
  useBrokers()

proc explicitTeardownThread() {.thread.} =
  useBrokers()
  teardownBrokerThread()
  pollDispatcher()

suite "broker teardown and the thread's dispatcher":
  setup:
    gOutcome.store(NotRun)

  test "a later destruction hook can still poll the dispatcher":
    var t: Thread[void]
    createThread(t, hookedThread)
    joinThread(t)
    check gOutcome.load() == Polled

  test "the thread can still poll after an explicit teardownBrokerThread":
    var t: Thread[void]
    createThread(t, explicitTeardownThread)
    joinThread(t)
    check gOutcome.load() == Polled
