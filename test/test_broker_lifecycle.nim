{.used.}

## D2 — close() must release the instance. A BrokerImplement instance is kept
## alive by the per-instance provider closures registered in the (global)
## broker tables (they capture `self`). `close()` clears those providers, so
## the instance becomes collectable. This holds under both --mm:refc and
## --mm:orc (it is retention via registration, not a GC cycle).
##
## The property has two halves, and they are **not** equally observable:
##
##   1. *the registration was dropped* — precisely observable everywhere, with
##      no GC involved at all: a request on that context must now fail with
##      "no provider registered".
##   2. *the instance was freed* — observed through `=destroy` on a marker
##      field after `GC_fullCollect()`. Exact under ORC, which is precise.
##      Under `--mm:refc` it is not: refc scans the C stack conservatively, so
##      a pointer-shaped value left in a stack slot or a callee-saved register
##      by the scope that just returned still roots the instance, `=destroy`
##      never runs, and the test reports a leak that is not there.
##
## Earlier revisions asserted (2) exactly under refc too, and papered over the
## fallout with a skip list keyed on Nim version and OS. That hid (1) as well —
## on the skipped cells nothing was checked at all — and the list had to be
## amended for every new toolchain that tripped it.
##
## So (2) is asserted in **bulk** instead. A conservative false root can only
## pin an instance whose address is still lying in a stale stack slot, and a
## tight create/close loop overwrites the previous iteration's frame — so the
## survivor count is bounded by a small constant no matter how large the loop
## is, while a genuine retention scales with it. Measured with
## `test/probe_refc_destroy.nim` on Linux amd64 under `--mm:refc -d:release`,
## the survivor count is exactly 1 and flat from N=1 to N=500, on Nim 2.2.4,
## 2.2.10 and 2.2.12 alike; refc debug and every ORC cell are clean at 0.
## `RefcSurvivorLimit` carries headroom over that measurement for the extra
## frames the broker and chronos machinery leave behind.
##
## The result needs no version or platform list, and it checks strictly more
## than the old form did.

import std/strutils
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
  proc new(T: typedesc[LifeImpl]): LifeImpl =
    inc gAlive
    LifeImpl()

  method ping(self: LifeImpl): Future[Result[int, string]] {.async.} =
    ok(1)

const
  BulkN = 200
    ## Loop length for the bulk release checks. A real retention would leave
    ## BulkN instances alive; a conservative false root leaves ~1.

  RefcSurvivorLimit = 5
    ## Tolerance for refc's conservative stack scan. Measured at 1; 5 gives
    ## headroom while staying 40x below what a genuine leak would produce.

proc aliveSince(base: int): int =
  ## Collect, then report how many marked instances appeared since `base`.
  GC_fullCollect()
  gAlive - base

suite "BrokerImplement: close() releases the instance":
  test "close() removes the provider registration":
    # Half (1): no GC involved, so this is exact on every memory manager,
    # every Nim version and every platform.
    var ctx: BrokerContext

    proc scope() =
      let g = LifeImpl.create()
      ctx = g.brokerCtx
      check (waitFor Ping.request(ctx)).value == 1
      g.close()

    scope()
    let r = waitFor Ping.request(ctx)
    check r.isErr()
    check "no provider" in r.error

  test "the provider table retains the instance until it is cleared":
    var ctxs: seq[BrokerContext]

    proc register(): BrokerContext {.noinline.} =
      let g = LifeImpl.create()
      g.brokerCtx

    let base = gAlive
    for _ in 0 ..< BulkN:
      ctxs.add(register())

    # Every instance is pinned by its provider closure in the table. A false
    # root can only ever add to this count, never subtract — but a straggler
    # left over from an earlier test can be reclaimed while this one runs, so
    # the lower bound carries the same tolerance as the survivor checks.
    check aliveSince(base) >= BulkN - RefcSurvivorLimit

    for c in ctxs:
      Ping.clearProvider(c)

    let survivors = aliveSince(base)
    when compileOption("mm", "refc"):
      check survivors <= RefcSurvivorLimit
    else:
      check survivors == 0

  test "close() releases the instances":
    proc cycle() {.noinline.} =
      let g = LifeImpl.create()
      check (waitFor Ping.request(g.brokerCtx)).value == 1
      g.close()

    let base = gAlive
    for _ in 0 ..< BulkN:
      cycle()

    let survivors = aliveSince(base)
    when compileOption("mm", "refc"):
      check survivors <= RefcSurvivorLimit
    else:
      check survivors == 0
