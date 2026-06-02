## Growth-path coverage for the two CBOR FFI courier rings (issue #21).
## Default capacities (64 slots / 256 events) are never hit by the other
## API tests, so this drives both rings past their initial capacity and
## checks: doubling growth, the `4 * orig` hard ceiling, the drop/`-1`
## contract at the ceiling, segmented slot reuse, and clean teardown.

{.used.}

import std/locks
import testutils/unittests
import ../brokers/internal/api_cbor_courier
import ../brokers/internal/api_cbor_event_courier

suite "CBOR courier dynamic growth (issue #21)":
  test "CborCourier slot pool grows by doubling up to 4x then returns -1":
    # origSlotCount = 2  ->  ceiling = 8.
    let c = newCborCourier(2)
    var claimed: seq[int]
    for _ in 0 ..< 9:
      claimed.add(claimSlot(c))
    # First 8 claims succeed with monotonically dense indices (0..7);
    # the 9th hits the 4x ceiling and is refused.
    check claimed == @[0, 1, 2, 3, 4, 5, 6, 7, -1]

    # A released slot from a grown segment is reused by the next claim.
    releaseSlot(c, 5)
    check claimSlot(c) == 5

    freeCborCourier(c)

  test "CborCourier ring grows in step so enqueue never backpressures":
    # With the pool grown to 8, the ring must accept 8 messages without a
    # false return (ring cap tracks the live slot count).
    let c = newCborCourier(2)
    for _ in 0 ..< 8:
      discard claimSlot(c)
    var ok = true
    for i in 0 ..< 8:
      var msg: CborCallMsg
      msg.slotIdx = int32(i)
      if not tryEnqueue(addr c.ring, msg):
        ok = false
    check ok
    freeCborCourier(c)

  test "CborEventRing grows by doubling up to 4x then drops":
    # origCap = 2  ->  ceiling = 8.
    let c = newCborEventCourier(2)
    var accepted = 0
    for _ in 0 ..< 9:
      var msg: CborEventMsg
      if tryEnqueue(addr c.ring, msg):
        inc accepted
    check accepted == 8 # 9th dropped at the ceiling

    # The grown ring still dequeues every retained message in FIFO order.
    var drained = 0
    var dst: CborEventMsg
    while tryDequeue(addr c.ring, dst):
      inc drained
    check drained == 8

    drainAndFree(c)
