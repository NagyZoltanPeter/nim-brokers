{.used.}

## Issue #51 regression: `listenIt` / `onSignalIt` inside an implicitly generic
## proc, instantiated from a module that does NOT import the event's own
## module.
##
## Before the fix the sugars were single module-global templates reaching their
## `listen` / `onSignal` through `mixin`, which resolves at the *instantiation*
## site. A `typedesc` parameter makes a proc implicitly generic, so its body is
## sem-checked here — where no matching `listen` overload is in scope — and the
## call failed with a type mismatch raised inside `brokers/event_broker.nim`.
## The sugars are now emitted per broker type, next to the verb they forward
## to, so the verb binds at the template's definition site.
##
## THE IMPORT LIST BELOW IS THE TEST. Do not add `sugar_scope_events` to it.

import testutils/unittests
import chronos

import ./issue51_helpers/sugar_scope_impl

suite "handler sugar: generic instantiation scope (issue #51)":
  test "listenIt / onSignalIt inside a generic proc reach the right overload":
    let c = Counter.wire()

    fireEvent(3)
    waitFor sleepAsync(20.milliseconds)
    check c.seen == 3

    fireSignal(4)
    waitFor sleepAsync(20.milliseconds)
    check c.seen == 43

    waitFor unwire()

  test "listenIt / onSignalIt inside a BrokerImplement constructor":
    let impl = ScopedImpl.create()

    fireEventIn(impl.nodeCtx, 5)
    waitFor sleepAsync(20.milliseconds)
    check (waitFor Total.request(impl.brokerCtx)).value == 5

    fireSignalIn(impl.nodeCtx, 6)
    waitFor sleepAsync(20.milliseconds)
    check (waitFor Total.request(impl.brokerCtx)).value == 65

    impl.close()

  when compileOption("threads"):
    test "multi-thread lane, same generic shape":
      let c = Counter.wireMt()

      fireMtEvent(7)
      waitFor sleepAsync(20.milliseconds)
      check c.seen == 7

      fireMtSignal(8)
      waitFor sleepAsync(20.milliseconds)
      check c.seen == 87

      waitFor unwireMt()
