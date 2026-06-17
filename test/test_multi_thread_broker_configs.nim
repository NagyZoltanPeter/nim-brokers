{.used.}

## Showcases the configuration surface added in Phase 6a-6e:
##
##   - kwargs (`queueDepth`, `slabCapacity`, `maxPayloadBytes`,
##     `responseSlots`, `maxResponseBytes`, `freeListShards`)
##   - named presets (defaultBalanced / fastBurst / largePayload /
##     tinyFootprint)
##   - type-driven default sizing (scalar / string / seq[byte] / ...)
##   - preset + kwarg override
##
## Each broker definition compiles and is exercised with a small
## same-thread + cross-thread round-trip, asserting the wiring is
## intact end-to-end. The compile-time `hint` lines from
## mt_event_broker / mt_request_broker provide visible confirmation of
## the resolved configuration.

import testutils/unittests
import chronos
import std/[atomics]

import brokers/event_broker
import brokers/request_broker

# ---------------------------------------------------------------------------
# Event broker — one definition per preset / type class
# ---------------------------------------------------------------------------

# Scalar payload, defaults — type classifier should pick 64 B.
EventBroker(mt):
  type ScalarTick = object
    n*: int64

# String payload, fastBurst preset overridden to 1 KB cells.
EventBroker(mt, preset = fastBurst, maxPayloadBytes = 1024):
  type FastEvt = object
    note*: string

# seq[byte] payload, largePayload preset.
EventBroker(mt, preset = largePayload):
  type BlobEvt = object
    blob*: seq[byte]

# Manual tiny config — sanity-checks that arbitrary small power-of-2
# values are accepted.
EventBroker(mt, queueDepth = 8, slabCapacity = 8, maxPayloadBytes = 64):
  type WeeEvt = object
    flag*: bool

# tinyFootprint preset.
EventBroker(mt, preset = tinyFootprint):
  type EmbeddedEvt = object
    on*: bool

# ---------------------------------------------------------------------------
# Request broker — one definition per preset
# ---------------------------------------------------------------------------

# Defaults — scalar response, scalar param. Classifier should pick 64 B.
RequestBroker(mt):
  type ScalarRes = object
    value*: int32

  proc signature*(key: int32): Future[Result[ScalarRes, string]] {.async.}

# fastBurst preset.
RequestBroker(mt, preset = fastBurst):
  type FastRes = object
    note*: string

  proc signature*(key: string): Future[Result[FastRes, string]] {.async.}

# largePayload preset with explicit responseSlots override.
RequestBroker(mt, preset = largePayload, responseSlots = 16):
  type BlobRes = object
    blob*: seq[byte]

  proc signature*(key: string): Future[Result[BlobRes, string]] {.async.}

# tinyFootprint preset.
RequestBroker(mt, preset = tinyFootprint):
  type TinyRes = object
    ok*: bool

  proc signature*(id: uint8): Future[Result[TinyRes, string]] {.async.}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "Multi-thread broker config showcase":
  asyncTest "EventBroker(mt) — scalar default (type classifier)":
    var seen: Atomic[int]
    seen.store(0)
    let handle = ScalarTick.listen(
      proc(evt: ScalarTick): Future[void] {.async: (raises: []).} =
        discard seen.fetchAdd(1)
    )
    check handle.isOk()
    ScalarTick.emit(ScalarTick(n: 42))
    await sleepAsync(chronos.milliseconds(10))
    check seen.load() == 1
    await ScalarTick.dropAllListeners()

  asyncTest "EventBroker(mt) — fastBurst preset + payload override":
    var seen: Atomic[int]
    seen.store(0)
    let handle = FastEvt.listen(
      proc(evt: FastEvt): Future[void] {.async: (raises: []).} =
        discard seen.fetchAdd(1)
    )
    check handle.isOk()
    FastEvt.emit(FastEvt(note: "hello"))
    await sleepAsync(chronos.milliseconds(10))
    check seen.load() == 1
    await FastEvt.dropAllListeners()

  asyncTest "EventBroker(mt) — largePayload preset (seq[byte])":
    var seen: Atomic[int]
    seen.store(0)
    let handle = BlobEvt.listen(
      proc(evt: BlobEvt): Future[void] {.async: (raises: []).} =
        discard seen.fetchAdd(1)
    )
    check handle.isOk()
    let payload = newSeq[byte](32 * 1024) # well under 64 KB cap
    BlobEvt.emit(BlobEvt(blob: payload))
    await sleepAsync(chronos.milliseconds(10))
    check seen.load() == 1
    await BlobEvt.dropAllListeners()

  asyncTest "EventBroker(mt) — explicit tiny manual config":
    var seen: Atomic[int]
    seen.store(0)
    let handle = WeeEvt.listen(
      proc(evt: WeeEvt): Future[void] {.async: (raises: []).} =
        discard seen.fetchAdd(1)
    )
    check handle.isOk()
    WeeEvt.emit(WeeEvt(flag: true))
    await sleepAsync(chronos.milliseconds(10))
    check seen.load() == 1
    await WeeEvt.dropAllListeners()

  asyncTest "EventBroker(mt) — tinyFootprint preset":
    var seen: Atomic[int]
    seen.store(0)
    let handle = EmbeddedEvt.listen(
      proc(evt: EmbeddedEvt): Future[void] {.async: (raises: []).} =
        discard seen.fetchAdd(1)
    )
    check handle.isOk()
    EmbeddedEvt.emit(EmbeddedEvt(on: true))
    await sleepAsync(chronos.milliseconds(10))
    check seen.load() == 1
    await EmbeddedEvt.dropAllListeners()

  asyncTest "RequestBroker(mt) — scalar default":
    let setRes = ScalarRes.setProvider(
      proc(key: int32): Future[Result[ScalarRes, string]] {.async.} =
        ok(ScalarRes(value: key * 2))
    )
    check setRes.isOk()
    let res = await ScalarRes.request(21'i32)
    check res.isOk()
    check res.get.value == 42
    ScalarRes.clearProvider()

  asyncTest "RequestBroker(mt) — fastBurst preset":
    let setRes = FastRes.setProvider(
      proc(key: string): Future[Result[FastRes, string]] {.async.} =
        ok(FastRes(note: "got:" & key))
    )
    check setRes.isOk()
    let res = await FastRes.request("hello")
    check res.isOk()
    check res.get.note == "got:hello"
    FastRes.clearProvider()

  asyncTest "RequestBroker(mt) — largePayload preset + responseSlots override":
    let setRes = BlobRes.setProvider(
      proc(key: string): Future[Result[BlobRes, string]] {.async.} =
        ok(BlobRes(blob: newSeq[byte](16 * 1024)))
    )
    check setRes.isOk()
    let res = await BlobRes.request("anything")
    check res.isOk()
    check res.get.blob.len == 16 * 1024
    BlobRes.clearProvider()

  asyncTest "RequestBroker(mt) — tinyFootprint preset":
    let setRes = TinyRes.setProvider(
      proc(id: uint8): Future[Result[TinyRes, string]] {.async.} =
        ok(TinyRes(ok: id mod 2 == 0))
    )
    check setRes.isOk()
    let res = await TinyRes.request(2'u8)
    check res.isOk()
    check res.get.ok == true
    TinyRes.clearProvider()
