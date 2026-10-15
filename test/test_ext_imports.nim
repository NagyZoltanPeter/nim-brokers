{.used.}

## EXTAPI phase 2 / K1 — native C imports. A plain C library
## (test/ext/libcodec.c, built at test time) serves EXTAPI request brokers:
## short form (`importc`) under `inplace`, body form under `workers(2)`, a
## missing symbol falling back to the Nim implementation.

import testutils/unittests
import chronos
import std/[os, osproc, strutils, dynlib]

import std/atomics
import brokers/[request_broker, event_broker, signal_broker, ext_plugin]

const repoRoot = currentSourcePath.parentDir.parentDir
when defined(macosx):
  const codecLib = repoRoot & "/build/libcodec.dylib"
else:
  const codecLib = repoRoot & "/build/libcodec.so"

when not defined(windows):
  from std/posix import pthread_self

RequestBroker(
  EXTAPI[codec], importc = "codec_crc", dynlib = codecLib, dispatch = inplace
):
  type CodecCrc = object
    value*: uint32

  proc signature*(
    seed: uint32, buf: ptr uint8, len: uint32
  ): Future[Result[CodecCrc, string]] {.async.}

RequestBroker(EXTAPI[codec], dynlib = codecLib, dispatch = workers(2)):
  type SlowSum = object
    total*: uint64

  proc codec_slow_sum(
    src: ptr uint8, len: uint32, ms: uint32, outp: ptr uint64
  ): int32 {.importc, cdecl.}

  proc signature*(
      data: seq[byte], ms: uint32
  ): Future[Result[SlowSum, string]] {.async.} =
    var total: uint64
    let p = (if data.len > 0: unsafeAddr data[0] else: nil)
    let rc = codec_slow_sum(p, uint32(data.len), ms, addr total)
    if rc != 0:
      return err("codec_slow_sum rc=" & $rc)
    return ok(SlowSum(total: total))

RequestBroker(
  EXTAPI[codec], importc = "codec_missing", dynlib = codecLib, dispatch = inplace
):
  type Missing = object
    v*: int32

  proc signature*(x: int32): Future[Result[Missing, string]] {.async.}

registerExtPlugin(codec)

# --- K2: a nim-brokers peer library (test/ext/peerlib.nim) --------------------
when defined(macosx):
  const peerLib = repoRoot & "/build/libpeerlib.dylib"
else:
  const peerLib = repoRoot & "/build/libpeerlib.so"

RequestBroker(EXTAPI[peer], importLib = "peerlib", dynlib = peerLib):
  type PeerEcho = object
    text*: string

  proc signature*(text: string): Future[Result[PeerEcho, string]] {.async.}

RequestBroker(EXTAPI[peer], importLib = "peerlib", dynlib = peerLib):
  type PeerFail = object
    n*: int32

  proc signature*(): Future[Result[PeerFail, string]] {.async.}

EventBroker(EXTAPI[peer], importLib = "peerlib", dynlib = peerLib):
  type PeerTick = object
    n*: int32

SignalBroker(EXTAPI[peer], importLib = "peerlib", dynlib = peerLib):
  type PeerPoke = object
    n*: int32

registerExtPlugin(peer)

var gTicks: Atomic[int]
var gLastTick: Atomic[int]

proc nimCrc(seed: uint32, data: openArray[byte]): uint32 =
  result = seed
  for b in data:
    result = result * 31'u32 + uint32(b)

proc lastCrcThread(): uint =
  # Lazy, like EXTAPI imports: a `{.dynlib.}` pragma would load at program
  # start, before the test has built the library.
  let lib = loadLib(codecLib)
  doAssert not lib.isNil
  type Fn = proc(): uint {.cdecl, gcsafe, raises: [].}
  cast[Fn](symAddr(lib, "codec_last_crc_thread"))()

suite "EXTAPI native C imports (K1)":
  test "load, inplace fast path, workers(2), missing symbol":
    when defined(windows):
      skip()
    else:
      let cmd =
        "cc -shared -fPIC -o " & codecLib & " " & repoRoot & "/test/ext/libcodec.c"
      check execCmd(cmd) == 0
      check ExtHost.start().isOk
      let ctx = DefaultBrokerContext

      # Not loaded yet: the ordinary "no provider".
      let data = @[byte 1, 2, 3, 250]
      check (waitFor CodecCrc.request(ctx, 7, unsafeAddr data[0], 4)).isErr

      check ExtPlugin.load("codec", ctx).isOk
      check "codec_missing" in ExtPlugin.loadError("codec")

      # Short form, inplace: direct C call on this thread, no CBOR.
      let c = waitFor CodecCrc.request(ctx, 7, unsafeAddr data[0], 4)
      check c.isOk
      check c.get(CodecCrc()).value == nimCrc(7, data)
      check lastCrcThread() == cast[uint](pthread_self())

      # Body form, workers(2): two blocking calls overlap.
      let t0 = Moment.now()
      let fa = SlowSum.request(ctx, @[byte 1, 2, 3], 300)
      let fb = SlowSum.request(ctx, @[byte 4, 5], 300)
      let ra = waitFor fa
      let rb = waitFor fb
      check ra.get(SlowSum()).total == 6
      check rb.get(SlowSum()).total == 9
      check Moment.now() - t0 < chronos.milliseconds(550)

      # Deadline while running: resolves at once, the C call finishes on its
      # worker and its result is dropped.
      let saved = gSlowSumMtTimeout
      gSlowSumMtTimeout = chronos.milliseconds(100)
      check (waitFor SlowSum.request(ctx, @[byte 1], 400)).isErr
      gSlowSumMtTimeout = saved
      sleep(450)

      # Missing symbol: unprovided; a Nim fallback serves it.
      check (waitFor Missing.request(ctx, 3)).isErr
      check not Missing.extAvailable(ctx)
      let nimMissing: MissingProviderWithArgs = proc(
          x: int32
      ): Future[Result[Missing, string]] {.async.} =
        return ok(Missing(v: x * 2))
      check Missing.setProvider(ctx, Missing.extFallback(ctx, nimMissing)).isOk
      check (waitFor Missing.request(ctx, 3)).get(Missing()).v == 6

      # Unknown library: nothing loads.
      check ExtPlugin.load("nope", ctx).isErr

      ExtHost.stop()

  test "peer nim-brokers library (K2)":
    when defined(windows):
      skip()
    else:
      let mm = (when defined(gcOrc): "orc" else: "refc")
      let cmd =
        "nim c --hints:off --app:lib -d:BrokerFfiApi --threads:on --mm:" & mm &
        " --nimMainPrefix:peerlib --path:" & repoRoot & " --outdir:" & repoRoot &
        "/build/peerlib_out -o:" & peerLib & " " & repoRoot & "/test/ext/peerlib.nim"
      check execCmd(cmd) == 0
      check ExtHost.start().isOk
      let ctx = NewBrokerContext()
      check (waitFor PeerEcho.request(ctx, "hi")).isErr # not loaded yet

      let lr = ExtPlugin.load("peer", ctx)
      check lr.isOk
      if lr.isErr:
        echo "peer load: ", lr.error
      check ExtPlugin.loadError("peer") == ""

      check PeerTick.listen(
        ctx,
        proc(t: PeerTick): Future[void] {.async: (raises: []).} =
          gLastTick.store(int(t.n))
          discard gTicks.fetchAdd(1),
      ).isOk

      let r = waitFor PeerEcho.request(ctx, "hi")
      check r.isOk
      check r.get(PeerEcho()).text == "peer:hi"
      proc pump(cond: proc(): bool {.gcsafe.}): bool =
        var waited = 0
        while not cond() and waited < 3000:
          waitFor sleepAsync(chronos.milliseconds(5))
          waited += 5
        cond()

      check pump(
        proc(): bool =
          gTicks.load() >= 1
      )
      check gLastTick.load() == 2

      let f = waitFor PeerFail.request(ctx)
      check f.isErr
      if f.isErr:
        check f.error == "nope"

      check PeerPoke.signal(ctx, PeerPoke(n: 5)).isOk
      check pump(
        proc(): bool =
          gLastTick.load() == 105
      )

      ExtHost.stop()
