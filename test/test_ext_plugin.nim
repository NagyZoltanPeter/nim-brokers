{.used.}

## EXTAPI phase 1a — a raw C plugin (test/ext/raw_storage_plugin.c, written
## against brokers/broker_ext.h only) provides brokers declared with
## `RequestBroker(EXTAPI[storage])`; Nim calls them with the ordinary verbs.

import testutils/unittests
import chronos
import std/[os, strutils]

import std/atomics
import brokers/[request_broker, event_broker, signal_broker, ext_plugin]

{.passC: "-I" & currentSourcePath.parentDir.parentDir & "/brokers".}
{.compile: "ext/raw_storage_plugin.c".}
{.compile: "ext/raw_calc_plugin.c".}

proc raw_calc_open(
  h: ptr ExtHostTable, ctx: uint32, caps: uint32
): int32 {.importc, cdecl.}

proc raw_calc_provide(name: cstring): int32 {.importc, cdecl.}
proc raw_calc_close(): int32 {.importc, cdecl.}
proc raw_calc_withdraw(name: cstring): int32 {.importc, cdecl.}
proc raw_calc_cancel_count(): int32 {.importc, cdecl.}
proc raw_calc_sleepy_started(): int32 {.importc, cdecl.}

proc raw_storage_open(
  h: ptr ExtHostTable, ctx: uint32, schemaHash: cstring
): int32 {.importc, cdecl.}

proc raw_storage_provide(name: cstring): int32 {.importc, cdecl.}
proc raw_storage_withdraw(name: cstring): int32 {.importc, cdecl.}
proc raw_storage_close(): int32 {.importc, cdecl.}
proc raw_storage_release_slow(): int32 {.importc, cdecl.}
proc raw_storage_parked(): int32 {.importc, cdecl.}
proc raw_storage_cancel_count(): int32 {.importc, cdecl.}
proc raw_storage_release_count(): int32 {.importc, cdecl.}
proc raw_storage_hint_count(): int32 {.importc, cdecl.}
proc raw_storage_last_urgency(): int32 {.importc, cdecl.}
proc raw_storage_emit_evicted(key: cstring): int32 {.importc, cdecl.}

RequestBroker(EXTAPI[storage]):
  type FetchBlob = object
    data*: seq[byte]

  proc signature*(key: string): Future[Result[FetchBlob, string]] {.async.}

RequestBroker(EXTAPI[storage]):
  type FailOp = object
    n*: int32

  proc signature*(): Future[Result[FailOp, string]] {.async.}

RequestBroker(EXTAPI[storage]):
  type SlowOp = object
    n*: int32

  proc signature*(): Future[Result[SlowOp, string]] {.async.}

RequestBroker(EXTAPI[storage]):
  type NotProvided = object
    n*: int32

  proc signature*(): Future[Result[NotProvided, string]] {.async.}

EventBroker(EXTAPI[storage]):
  type BlobEvicted = object
    key*: string

SignalBroker(EXTAPI[storage]):
  type CompactHint = object
    urgency*: int32

registerExtPlugin(storage, version = "1.0.0")

var gEvicted: Atomic[int]

RequestBroker(EXTAPI[calc], dispatch = inplace):
  type Square = object
    v*: int64

  proc signature*(x: int64): Future[Result[Square, string]] {.async.}

RequestBroker(EXTAPI[calc], dispatch = inplace):
  type Lazy = object
    v*: int64

  proc signature*(): Future[Result[Lazy, string]] {.async.}

RequestBroker(EXTAPI[calc], dispatch = workers(2)):
  type Sleepy = object
    v*: int64

  proc signature*(ms: int64): Future[Result[Sleepy, string]] {.async.}

RequestBroker(EXTAPI[calc], dispatch = inplace):
  proc Counter*(): Future[Result[int64, string]] {.async.}
  proc Counter*(add: int64): Future[Result[int64, string]] {.async.}

registerExtPlugin(calc)

RequestBroker(EXTAPI[echo]):
  type EchoMsg = object
    text*: string

  proc signature*(text: string): Future[Result[EchoMsg, string]] {.async.}

registerExtPlugin(echo, version = "2.1.0")

const repoRoot = currentSourcePath.parentDir.parentDir

proc buildEchoPlugin(): string =
  ## Build test/ext/raw_echo_plugin.c as a shared library with the system C
  ## compiler; returns its path.
  when defined(macosx):
    let ext = "dylib"
  else:
    let ext = "so"
  result = repoRoot / "build" / ("libraw_echo." & ext)
  let cmd =
    "cc -shared -fPIC -I" & repoRoot / "brokers" & " -o " & result & " " &
    repoRoot / "test" / "ext" / "raw_echo_plugin.c"
  doAssert execShellCmd(cmd) == 0, cmd

proc cborTextValues(b: seq[byte]): seq[string] =
  ## Every definite-length text string in a CBOR blob (enough to spot names).
  var i = 0
  while i < b.len:
    let major = int(b[i]) shr 5
    let ai = int(b[i]) and 31
    var n = 0
    var hdr = 1
    if ai < 24:
      n = ai
    elif ai == 24:
      n = int(b[i + 1])
      hdr = 2
    elif ai == 25:
      n = (int(b[i + 1]) shl 8) or int(b[i + 2])
      hdr = 3
    if major == 3:
      var s = newString(n)
      for k in 0 ..< n:
        s[k] = char(b[i + hdr + k])
      result.add(s)
      i += hdr + n
    elif major == 2:
      i += hdr + n
    else:
      i += hdr

proc waitUntil(cond: proc(): bool {.gcsafe.}, ms = 2000): bool =
  var waited = 0
  while not cond():
    if waited >= ms:
      return false
    sleep(5)
    waited += 5
  true

suite "EXTAPI raw C plugin (bridge dispatch)":
  test "full lifecycle":
    check ExtHost.start().isOk
    let ctx = DefaultBrokerContext

    # Nothing wired yet: the ordinary MT "no provider" error.
    let r0 = waitFor FetchBlob.request(ctx, "abc")
    check r0.isErr
    check "no" in r0.error and "provider" in r0.error

    check raw_storage_open(ExtHost.table(), uint32(ctx), nil) == ExtOk
    check raw_storage_provide("fetch_blob") == ExtOk
    check raw_storage_provide("fail_op") == ExtOk
    check raw_storage_provide("slow_op") == ExtOk
    check raw_storage_provide("fetch_blob") == ExtAlreadyProvided
    check raw_storage_provide("no_such_name") == ExtUnknownName

    # Request round-trip through the CBOR tunnel.
    let r1 = waitFor FetchBlob.request(ctx, "abc")
    check r1.isOk
    if r1.isOk:
      check r1.value.data == @[byte('c'), byte('b'), byte('a')]

    # Plugin-side failure → err with the plugin's message.
    let r2 = waitFor FailOp.request(ctx)
    check r2.isErr
    if r2.isErr:
      check r2.error == "boom"

    # Unprovided name of a declared broker → "no provider".
    let r3 = waitFor NotProvided.request(ctx)
    check r3.isErr

    # Deferred reply from another thread (here: the test thread).
    let f4 = SlowOp.request(ctx)
    check waitUntil(
      proc(): bool =
        raw_storage_parked() == 1
    )
    check raw_storage_release_slow() == 1
    let r4 = waitFor f4
    check r4.isOk
    if r4.isOk:
      check r4.value.n == 7

    # Cancel while the plugin holds the call → cancel hint reaches the plugin,
    # the caller resolves at once, the late reply is dropped.
    let (id5, f5) = SlowOp.requestCancellable(ctx)
    check waitUntil(
      proc(): bool =
        raw_storage_parked() == 1
    )
    check SlowOp.cancel(ctx, id5)
    let r5 = waitFor f5
    check r5.isErr
    check waitUntil(
      proc(): bool =
        raw_storage_cancel_count() == 1
    )
    discard raw_storage_release_slow() # late reply: dropped, no crash

    # Timeout → the same cancel path.
    let saved = gSlowOpMtTimeout
    gSlowOpMtTimeout = chronos.milliseconds(100)
    let r6 = waitFor SlowOp.request(ctx)
    gSlowOpMtTimeout = saved
    check r6.isErr
    check waitUntil(
      proc(): bool =
        raw_storage_cancel_count() == 2
    )
    discard raw_storage_release_slow()

    # Signal: unprovided → the ordinary SignalBroker error; provided → the
    # plugin receives it one-way.
    let s0 = CompactHint.signal(ctx, CompactHint(urgency: 3))
    check s0.isErr
    check raw_storage_provide("compact_hint") == ExtOk
    check CompactHint.signal(ctx, CompactHint(urgency: 5)).isOk
    check waitUntil(
      proc(): bool =
        raw_storage_hint_count() == 1
    )
    check raw_storage_last_urgency() == 5

    # Event: the plugin emits from a foreign thread, Nim listeners fire.
    let lr = BlobEvicted.listen(
      ctx,
      proc(e: BlobEvicted): Future[void] {.async: (raises: []).} =
        if e.key == "k9":
          discard gEvicted.fetchAdd(1)
      ,
    )
    check lr.isOk
    check raw_storage_emit_evicted("k9") == ExtOk
    check raw_storage_provide("blob_evicted") == ExtBadArg # events are not provided
    proc pumpUntil(n: int): bool =
      var waited = 0
      while gEvicted.load() < n and waited < 2000:
        waitFor sleepAsync(chronos.milliseconds(5))
        waited += 5
      gEvicted.load() >= n

    check pumpUntil(1)

    # Withdraw one name → back to "no provider" for it only.
    check raw_storage_withdraw("fetch_blob") == ExtOk
    check raw_storage_withdraw("fetch_blob") == ExtNotProvided
    let r7 = waitFor FetchBlob.request(ctx, "abc")
    check r7.isErr
    check (waitFor FailOp.request(ctx)).isErr # still provided, still "boom"

    # Close: everything unwired, impl released exactly once.
    check raw_storage_emit_evicted("k9") == ExtOk # still open here
    check raw_storage_close() == ExtOk
    check raw_storage_close() == ExtStale
    check waitUntil(
      proc(): bool =
        raw_storage_release_count() == 1
    )
    let r8 = waitFor FailOp.request(ctx)
    check r8.isErr
    if r8.isErr:
      check r8.error != "boom"

    check raw_storage_emit_evicted("k9") == ExtStale
    check CompactHint.signal(ctx, CompactHint(urgency: 1)).isErr
    ExtHost.stop()
    check raw_storage_open(ExtHost.table(), uint32(ctx), nil) == ExtShutdown

  test "dispatch policies: inplace, workers(n), caps check":
    check ExtHost.start().isOk
    let ctx = NewBrokerContext()

    # A NONBLOCKING-only port cannot serve inplace names, but can serve workers.
    check raw_calc_open(ExtHost.table(), uint32(ctx), ExtCapNonBlocking) == ExtOk
    check raw_calc_provide("square") == ExtDispatchMismatch
    check raw_calc_provide("sleepy") == ExtOk
    check raw_calc_close() == ExtOk

    check raw_calc_open(ExtHost.table(), uint32(ctx), ExtCapReplyInline) == ExtOk
    check raw_calc_provide("square") == ExtOk
    check raw_calc_provide("lazy") == ExtOk
    check raw_calc_provide("sleepy") == ExtOk

    # inplace: synchronous reply.
    let sq = waitFor Square.request(ctx, 12)
    check sq.isOk
    if sq.isOk:
      check sq.value.v == 144

    # inplace contract violation: no reply before invoke returned.
    let lz = waitFor Lazy.request(ctx)
    check lz.isErr
    if lz.isErr:
      check "without reply" in lz.error

    # Dual-slot broker: two wire names, provided and withdrawn independently.
    check raw_calc_provide("counter") == ExtOk
    check raw_calc_provide("counter_arg") == ExtOk
    check (waitFor Counter.request(ctx)).get(-1) == 41
    check (waitFor Counter.request(ctx, 1'i64)).get(-1) == 42
    check raw_calc_withdraw("counter_arg") == ExtOk
    check (waitFor Counter.request(ctx)).get(-1) == 41 # zero slot still served
    check (waitFor Counter.request(ctx, 1'i64)).isErr
    check raw_calc_withdraw("counter") == ExtOk
    check (waitFor Counter.request(ctx)).isErr

    # workers(2): two blocking 300 ms calls overlap.
    let t0 = Moment.now()
    let fa = Sleepy.request(ctx, 300)
    let fb = Sleepy.request(ctx, 300)
    let ra = waitFor fa
    let rb = waitFor fb
    let elapsed = Moment.now() - t0
    check ra.isOk and rb.isOk
    check elapsed < chronos.milliseconds(550)

    # workers: timeout while running → cancel hint, late reply dropped.
    let saved = gSleepyMtTimeout
    gSleepyMtTimeout = chronos.milliseconds(100)
    let rt = waitFor Sleepy.request(ctx, 400)
    gSleepyMtTimeout = saved
    check rt.isErr
    # The hint is sent by the bridge when its own deadline fires, which may
    # land just after the caller's (equal) MT timeout returned.
    check waitUntil(
      proc(): bool =
        raw_calc_cancel_count() >= 1
    )
    sleep(450) # let the worker finish and post its (dropped) reply

    check raw_calc_close() == ExtOk
    ExtHost.stop()

  test "loader, schema hash, discovery, generated header":
    when defined(windows):
      skip()
    else:
      check ExtHost.start().isOk
      let h = ExtHost.table()

      var hash: array[33, char]
      check h.schemaHash(h.host, "echo", addr hash[0]) == ExtOk
      let hashStr = $cast[cstring](addr hash[0])
      check hashStr.len == 32

      # The generated header carries the same hash and the name constants.
      let hdr = readFile(repoRoot / "build" / "echo_ext.h")
      check ("ECHO_EXT_SCHEMA_HASH \"" & hashStr & "\"") in hdr
      check "ECHO_EXT_ECHO_MSG \"echo_msg\"" in hdr
      check fileExists(repoRoot / "build" / "echo_ext.cddl")
      check fileExists(repoRoot / "build" / "broker_ext.h")

      # Discovery.
      var buf: ptr uint8
      var blen: csize_t
      check h.listApis(h.host, "echo", addr buf, addr blen) == ExtOk
      var blob = newSeq[byte](int(blen))
      copyMem(addr blob[0], buf, int(blen))
      h.freeBuffer(h.host, buf)
      let texts = cborTextValues(blob)
      check "echo_msg" in texts
      check "2.1.0" in texts
      check hashStr in texts
      check h.getSchema(h.host, "echo", addr buf, addr blen) == ExtOk
      blob.setLen(int(blen))
      copyMem(addr blob[0], buf, int(blen))
      h.freeBuffer(h.host, buf)
      check "text" in cborTextValues(blob)
      check h.listApis(h.host, "nope", addr buf, addr blen) == ExtUnknownName

      # Wrong hash is refused at open.
      var impl = ExtImplDesc(
        abiVersion: ExtAbiVersion,
        plugin: "echo",
        schemaHash: "0123456789abcdef0123456789abcdef",
      )
      impl.invoke = proc(
          user: pointer,
          id: uint64,
          nameIdx: uint32,
          name: cstring,
          buf: ptr uint8,
          len: csize_t,
      ) {.cdecl, gcsafe, raises: [].} =
        discard
      var port: uint64
      check h.open(h.host, 1, addr impl, addr port) == ExtSchemaMismatch

      # Load the shared-library plugin; it pins the host's hash and provides.
      let path = buildEchoPlugin()
      check ExtHost.loadPlugin(path).isOk
      let r = waitFor EchoMsg.request("hello")
      check r.isOk
      if r.isOk:
        check r.value.text == "hello"
      check ExtHost.loadPlugin(repoRoot / "build" / "nope.so").isErr

      ExtHost.stop()
