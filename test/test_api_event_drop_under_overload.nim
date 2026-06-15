## Evidence that outbound FFI events are DROPPED under overload.
##
## The CBOR event courier ring (`brokers/internal/api_cbor_event_courier.nim`)
## is the fire-and-forget transport between an event producer (the processing
## thread) and the foreign-callback consumer (the delivery thread). It is
## bounded: `api_library.nim:1283` seeds it at 256 slots and `tryEnqueue`
## grows it by doubling only up to a hard ceiling of `4 * origCap` (1024 for
## the production seed). Past that, `tryEnqueue` returns false and the event
## is dropped — no back-pressure reaches the producer.
##
## This test reproduces that at the REAL production capacity and prints the
## accepted/dropped counts as evidence. Two scenarios:
##   A. Stalled consumer  — delivery thread never drains (slow/blocked
##      callback). A burst of events floods the ring; everything past 1024
##      is dropped.
##   B. Slow consumer     — delivery thread drains, but slower than the
##      producer emits. The backlog crosses the ceiling and drops begin.

{.used.}

import testutils/unittests
import ../brokers/internal/api_cbor_event_courier

const
  ProdSeedCap = 256 ## matches `newCborEventCourier(256)` in api_library.nim
  ProdCeiling = ProdSeedCap * 4 ## the `4 * origCap` hard limit == 1024

proc mkEvent(): CborEventMsg =
  ## A faithful (POD) outbound event message. `buf` is nil here: the drop
  ## semantics depend only on ring occupancy, and on drop/dequeue the caller
  ## owns `buf` — keeping it nil keeps the test about capacity, not alloc.
  var m: CborEventMsg
  m.ctx = 1'u32
  m.bufLen = 0
  m

suite "Outbound FFI events drop under overload (production 256->1024 ring)":
  test "Scenario A: stalled consumer — burst floods, surplus is dropped":
    let c = newCborEventCourier(ProdSeedCap)
    const Burst = 5000 ## far exceeds the 1024 ceiling
    var accepted, dropped = 0
    for _ in 0 ..< Burst:
      if tryEnqueue(addr c.ring, mkEvent()):
        inc accepted
      else:
        inc dropped

    echo "[Scenario A] seed=", ProdSeedCap, " ceiling=", ProdCeiling,
      " emitted=", Burst, " accepted=", accepted, " DROPPED=", dropped

    # The ring accepts exactly the ceiling, then drops the rest.
    check accepted == ProdCeiling
    check dropped == Burst - ProdCeiling
    check dropped > 0 # the evidence: events were lost

    drainAndFree(c)

  test "Scenario B: slow consumer — producer outpaces drain, backlog drops":
    let c = newCborEventCourier(ProdSeedCap)
    const
      Rounds = 60
      EmitPerRound = 100 ## producer rate
      DrainPerRound = 10 ## consumer rate (10x slower)
    var accepted, dropped, drained = 0
    for _ in 0 ..< Rounds:
      for _ in 0 ..< EmitPerRound:
        if tryEnqueue(addr c.ring, mkEvent()):
          inc accepted
        else:
          inc dropped
      var dst: CborEventMsg
      for _ in 0 ..< DrainPerRound:
        if tryDequeue(addr c.ring, dst):
          inc drained

    echo "[Scenario B] emitted=", Rounds * EmitPerRound, " accepted=", accepted,
      " DROPPED=", dropped, " drained=", drained

    # Once the backlog reaches 1024 the slow consumer can't keep up and the
    # producer's surplus is dropped — proving overload loses outbound events.
    check dropped > 0
    # Accounting sanity: every emitted event was either accepted or dropped.
    check accepted + dropped == Rounds * EmitPerRound

    drainAndFree(c)
