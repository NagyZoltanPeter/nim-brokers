{.used.}

import testutils/unittests
import chronos
import std/[atomics]

import brokers/event_broker
import brokers/request_broker

## ---------------------------------------------------------------------------
## Part 1 (flexible-mt-dispatch): payloadSize widened uint16 -> uint32.
##
## These tests round-trip payloads in the 64 KiB .. 2 MiB range — sizes that
## the previous `uint16 payloadSize` silently wrapped (e.g. a 64 KiB payload
## stored payloadSize = 0). A byte-exact round-trip here proves the wrap is
## gone. The fixed cell is configured large enough to hold the payload inline
## (Part 2 heap-spill is exercised by separate tests).
## ---------------------------------------------------------------------------

const
  BigLen = 1_500_000 ## 1.5 MiB — well past the old 64 KiB uint16 ceiling
  ## CellCap = 2 MiB inline cell. Broker kwargs require integer literals, so the
  ## value is written inline (2097152) at each macro call below.

# A simple deterministic byte pattern so we can verify content, not just length.
proc makePayload(n: int): string =
  result = newString(n)
  for i in 0 ..< n:
    result[i] = char((i * 31 + 7) and 0xFF)

EventBroker(mt, slabCapacity = 4, maxPayloadBytes = 2097152):
  type BigEvt = object
    tag*: int
    blob*: string

RequestBroker(
  mt, slabCapacity = 4, maxPayloadBytes = 2097152, maxResponseBytes = 2097152
):
  type BigResp = object
    blob*: string

  proc signature*(input: string): Future[Result[BigResp, string]] {.async.}

# Tiny request cell (256 B) and tiny response slot (256 B) so both the request
# arg and the response payload are forced onto the heap-spill path.
RequestBroker(
  mt, slabCapacity = 4, maxPayloadBytes = 256, responseSlots = 4, maxResponseBytes = 256
):
  type SpillResp = object
    blob*: string

  proc signature*(input: string): Future[Result[SpillResp, string]] {.async.}

# Small inline cell (256 B) so a >256 B payload is forced onto the heap-spill
# path (Part 2). The 1.5 MiB payload spills; round-trip must stay byte-exact.
EventBroker(mt, slabCapacity = 4, maxPayloadBytes = 256):
  type SpillEvt = object
    tag*: int
    blob*: string

# A tiny cell with a hard maxDynamicPayloadBytes ceiling, to prove oversized
# payloads above the ceiling are dropped (not delivered, not crashing).
EventBroker(mt, slabCapacity = 4, maxPayloadBytes = 64, maxDynamicPayloadBytes = 4096):
  type CappedEvt = object
    blob*: string

var gEvtLen: Atomic[int]
var gEvtOk: Atomic[bool]
var gEvtCount: Atomic[int]

proc bigEmitter() {.thread.} =
  waitFor BigEvt.emit(BigEvt(tag: 1, blob: makePayload(BigLen)))

proc spillEmitter() {.thread.} =
  waitFor SpillEvt.emit(SpillEvt(tag: 2, blob: makePayload(BigLen)))

# Cross-thread emitters for the cap test — the spill/drop logic only runs on
# the cross-thread slab path (same-thread emit dispatches directly, no marshal).
proc cappedOverEmitter() {.thread.} =
  waitFor CappedEvt.emit(CappedEvt(blob: makePayload(8192))) # > 4 KiB ceiling

proc cappedUnderEmitter() {.thread.} =
  waitFor CappedEvt.emit(CappedEvt(blob: makePayload(2048))) # < ceiling

suite "MT large payload (uint32 payloadSize)":
  asyncTest "cross-thread event round-trips 1.5 MiB byte-exact":
    gEvtLen.store(0)
    gEvtOk.store(false)
    gEvtCount.store(0)
    let expected = makePayload(BigLen)

    let handle = BigEvt.listen(
      proc(evt: BigEvt): Future[void] {.async: (raises: []).} =
        gEvtLen.store(evt.blob.len)
        gEvtOk.store(evt.blob == expected)
        discard gEvtCount.fetchAdd(1)
    )
    check handle.isOk()

    var t: Thread[void]
    t.createThread(bigEmitter)
    while gEvtCount.load() < 1:
      await sleepAsync(chronos.milliseconds(1))
    t.joinThread()

    check gEvtLen.load() == BigLen
    check gEvtOk.load() # byte-exact: old uint16 wrap would corrupt/truncate
    BigEvt.dropAllListeners()
    await sleepAsync(chronos.milliseconds(50))

  asyncTest "auto heap-spill: 1.5 MiB through a 256 B cell, byte-exact":
    gEvtLen.store(0)
    gEvtOk.store(false)
    gEvtCount.store(0)
    let expected = makePayload(BigLen)

    let handle = SpillEvt.listen(
      proc(evt: SpillEvt): Future[void] {.async: (raises: []).} =
        gEvtLen.store(evt.blob.len)
        gEvtOk.store(evt.blob == expected)
        discard gEvtCount.fetchAdd(1)
    )
    check handle.isOk()

    var t: Thread[void]
    t.createThread(spillEmitter)
    while gEvtCount.load() < 1:
      await sleepAsync(chronos.milliseconds(1))
    t.joinThread()

    check gEvtLen.load() == BigLen # spilled to heap, not dropped
    check gEvtOk.load() # byte-exact through the spill buffer
    SpillEvt.dropAllListeners()
    await sleepAsync(chronos.milliseconds(50))

  asyncTest "payload above maxDynamicPayloadBytes is dropped, not delivered":
    gEvtCount.store(0)

    let handle = CappedEvt.listen(
      proc(evt: CappedEvt): Future[void] {.async: (raises: []).} =
        discard gEvtCount.fetchAdd(1)
    )
    check handle.isOk()

    # 8 KiB payload, ceiling is 4 KiB → must be dropped (no delivery, no crash).
    var tOver: Thread[void]
    tOver.createThread(cappedOverEmitter)
    tOver.joinThread()
    await sleepAsync(chronos.milliseconds(50))
    check gEvtCount.load() == 0

    # A payload under the ceiling still delivers via spill.
    var tUnder: Thread[void]
    tUnder.createThread(cappedUnderEmitter)
    while gEvtCount.load() < 1:
      await sleepAsync(chronos.milliseconds(1))
    tUnder.joinThread()
    check gEvtCount.load() == 1
    CappedEvt.dropAllListeners()
    await sleepAsync(chronos.milliseconds(50))

  asyncTest "request/response round-trips 1.5 MiB byte-exact":
    let expected = makePayload(BigLen)

    let prov = BigResp.setProvider(
      proc(input: string): Future[Result[BigResp, string]] {.async.} =
        if input.len == BigLen and input == expected:
          return ok(BigResp(blob: makePayload(BigLen))) # echo a fresh big response
        return err("mismatch on request blob")
    )
    check prov.isOk()

    let resp = await BigResp.request(makePayload(BigLen))
    check resp.isOk()
    check resp.get().blob.len == BigLen
    check resp.get().blob == expected
    BigResp.clearProvider()
    await sleepAsync(chronos.milliseconds(50))

  asyncTest "auto heap-spill: large request AND response through 256 B cells":
    let expected = makePayload(BigLen)

    let prov = SpillResp.setProvider(
      proc(input: string): Future[Result[SpillResp, string]] {.async.} =
        # input arrives via a spilled request cell; echo a spilled response.
        if input.len == BigLen and input == expected:
          return ok(SpillResp(blob: makePayload(BigLen)))
        return err("mismatch on spilled request blob, len=" & $input.len)
    )
    check prov.isOk()

    let resp = await SpillResp.request(makePayload(BigLen))
    check resp.isOk()
    check resp.get().blob.len == BigLen
    check resp.get().blob == expected
    SpillResp.clearProvider()
    await sleepAsync(chronos.milliseconds(50))
