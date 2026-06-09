{.used.}

## D2 — close() must release the instance. A BrokerImplement instance is kept
## alive by the per-instance provider closures registered in the (global)
## broker tables (they capture `self`). `close()` clears those providers, so
## the instance becomes collectable. This holds under both --mm:refc and
## --mm:orc (it is retention via registration, not a GC cycle). A `=destroy`
## on a marker field lets us observe the instance actually being freed.

import testutils/unittests
import chronos

import brokers/broker_interface
import brokers/broker_implement

# Nim 2.2.4 + --mm:refc on Linux/Windows leaves stale pointer-shaped values on
# the C stack after `scope()`/`scope2()` return. refc's conservative stack
# scanner sees them, keeps the LifeImpl alive, and =destroy never fires — so
# `gAlive` stays at 1. Observed failures:
#   - Linux + refc + -d:release  : both tests fail (release-mode codegen)
#   - Windows + refc + debug     : test 2 fails (clearProvider path)
# The semantic the test verifies (close()/clearProvider break the closure
# cycle) is correct on these configs — only the =destroy observation
# mechanism is unreliable because it relies on deterministic destruction.
# Fixed in Nim 2.2.10 (codegen fix upstream); macOS arm64 unaffected due to
# a different ABI. Skip the whole test for Nim 2.2.4 + refc on Linux/Windows.
const SkipRefcLifecycle {.used.} =
  NimMajor == 2 and NimMinor == 2 and NimPatch == 4 and
  (defined(linux) or defined(windows)) and compileOption("mm", "refc")

when SkipRefcLifecycle:
  echo "test_broker_lifecycle: skipped (Nim 2.2.4 + refc on Linux/Windows; fixed in 2.2.10)"
else:
  var gAlive {.global.} = 0

  type LifeMark = object

  proc `=destroy`(m: var LifeMark) =
    dec gAlive

  BrokerInterface(ILife):
    RequestBroker:
      proc ping(): Future[Result[int, string]] {.async.}

  type LifeImpl = ref object of ILife
    mark: LifeMark

  BrokerImplement LifeImpl of ILife:
    proc new(T: typedesc[LifeImpl]): LifeImpl =
      inc gAlive
      LifeImpl()

    method ping(self: LifeImpl): Future[Result[int, string]] {.async.} =
      ok(1)

  suite "BrokerImplement: close() releases the instance":
    test "instance is freed after close() + collection":
      proc scope() =
        let g = LifeImpl.create()
        check gAlive == 1
        # exercise the provider (closure captures `self`)
        check (waitFor Ping.request(g.brokerCtx)).value == 1
        g.close()

      # g is created, used, and closed inside scope(); its local ref is gone
      # once scope() returns.
      scope()
      GC_fullCollect()
      check gAlive == 0 # freed -> LifeMark =destroy ran

    test "without close(), the instance is retained by the provider table":
      var ctx: BrokerContext
      proc scope2() =
        let g = LifeImpl.create()
        ctx = g.brokerCtx
        # no close()

      scope2()
      GC_fullCollect()
      check gAlive == 1 # still alive — provider closure in the table pins it
      # now clear it and confirm release
      Ping.clearProvider(ctx)
      GC_fullCollect()
      check gAlive == 0
