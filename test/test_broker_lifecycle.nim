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
  proc init() =
    inc gAlive

  method ping(self: LifeImpl): Future[Result[int, string]] {.async.} =
    ok(1)

suite "BrokerImplement: close() releases the instance":
  test "instance is freed after close() + collection":
    proc scope() =
      let g = LifeImpl.new()
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
      let g = LifeImpl.new()
      ctx = g.brokerCtx
      # no close()

    scope2()
    GC_fullCollect()
    check gAlive == 1 # still alive — provider closure in the table pins it
    # now clear it and confirm release
    Ping.clearProvider(ctx)
    GC_fullCollect()
    check gAlive == 0
