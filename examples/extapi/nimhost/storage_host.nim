## EXTAPI example host (exe mode). Runs scenarios 1, 2 and 4 of
## doc/design/EXTAPI_PLAN.md §14 against a plugin library given on the command
## line, and asserts every outcome (a failed check exits non-zero).
##
##   storage_host <plugin library path>
##
## 1  external plugin implementation: requests, an unprovided name, a signal
##    that makes the plugin emit an event, cancel and timeout
## 2  runtime switching: a load generator keeps calling FetchBlob while the
##    host switches its own slot between plugin, Nim impl and fallback, and the
##    plugin detaches / re-attaches
## 4  C import: inplace direct call, workers(2) overlap, missing symbol

import std/[atomics, dynlib, os, strutils]
import chronos
import ./storage_api

var failures = 0

template expect(cond: bool, what: string) =
  if cond:
    echo "  ok    ", what
  else:
    echo "  FAIL  ", what
    inc failures

proc pump(cond: proc(): bool {.gcsafe.}, ms = 3000): bool =
  ## Drive this thread's loop (it owns FetchBlob's provider) until `cond`.
  var waited = 0
  while not cond():
    if waited >= ms:
      return false
    waitFor sleepAsync(chronos.milliseconds(5))
    waited += 5
  true

# Plugin control exports (example-specific, not part of the EXTAPI ABI).
type
  AttachFn =
    proc(host: ptr ExtHostTable, ctx: uint32): int32 {.cdecl, gcsafe, raises: [].}
  DetachFn = proc(): int32 {.cdecl, gcsafe, raises: [].}
  CountFn = proc(): int32 {.cdecl, gcsafe, raises: [].}

proc localFetch(key: string): Future[Result[FetchBlob, string]] {.async.} =
  var d = newSeq[byte]()
  for c in "nim:" & key:
    d.add(byte(c))
  return ok(FetchBlob(data: d))

proc text(b: seq[byte]): string =
  for x in b:
    result.add(char(x))

var gEvicted: Atomic[int]

type LoadState = object
  ctx: BrokerContext
  stop: Atomic[int]
  nim, plugin, errors, withdrawRaces, total: Atomic[int]

proc loadThread(st: ptr LoadState) {.thread.} =
  proc run() {.async.} =
    while st.stop.load() == 0:
      let r = await FetchBlob.request(st.ctx, "x")
      discard st.total.fetchAdd(1)
      if r.isErr:
        if "cleared while the request was outstanding" in r.error or
            "withdrawn" in r.error:
          discard st.withdrawRaces.fetchAdd(1)
        else:
          discard st.errors.fetchAdd(1)
      elif r.value.data.text.startsWith("nim:"):
        discard st.nim.fetchAdd(1)
      else:
        discard st.plugin.fetchAdd(1)

  waitFor run()

proc main() =
  if paramCount() < 1:
    quit("usage: storage_host <plugin library>", 2)
  let pluginPath = paramStr(1)
  doAssert ExtHost.start().isOk
  let ctx = DefaultBrokerContext

  echo "== scenario 1: external plugin implementation (", pluginPath, ")"
  let lib = loadLib(pluginPath)
  doAssert not lib.isNil, "cannot dlopen " & pluginPath
  let attach = cast[AttachFn](lib.symAddr("storage_plugin_attach"))
  let detach = cast[DetachFn](lib.symAddr("storage_plugin_detach"))
  let cancels = cast[CountFn](lib.symAddr("storage_plugin_cancels"))
  doAssert not attach.isNil and not detach.isNil and not cancels.isNil
  # The ordinary exe-mode loader: dlopen (again, refcounted) + entry point.
  expect ExtHost.loadPlugin(pluginPath).isOk,
    "ExtHost.loadPlugin + broker_ext_plugin_entry"
  # FetchBlob is not auto-wired: this thread owns it.
  doAssert FetchBlob.setProvider(ctx, FetchBlob.extFallback(ctx, localFetch)).isOk

  let st = waitFor StoreBlob.request(ctx, "k1", @[byte 1, 2, 3])
  expect st.isOk and st.value.etag == "etag-k1-3", "StoreBlob served by the plugin"
  let lk = waitFor ListKeys.request(ctx)
  expect lk.isErr and "provider" in lk.error, "ListKeys unprovided → \"no provider\""
  let fb = waitFor FetchBlob.request(ctx, "a")
  expect fb.isOk and fb.value.data.text.endsWith(":a") and
    not fb.value.data.text.startsWith("nim:"), "FetchBlob via extFallback → plugin"

  expect BlobEvicted.listen(
    ctx,
    proc(e: BlobEvicted): Future[void] {.async: (raises: []).} =
      if e.reason == "compact":
        discard gEvicted.fetchAdd(1)
    ,
  ).isOk, "listen BlobEvicted"
  expect CompactHint.signal(ctx, CompactHint(urgency: 3)).isOk,
    "CompactHint signal accepted"
  expect pump(
    proc(): bool =
      gEvicted.load() >= 1
  ), "plugin emitted BlobEvicted from its own thread"

  let (cid, cfut) = Compact.requestCancellable(ctx, 9)
  waitFor sleepAsync(chronos.milliseconds(100))
  discard Compact.cancel(ctx, cid)
  expect (waitFor cfut).isErr, "cancelled Compact resolves at once"
  expect pump(
    proc(): bool =
      cancels() >= 1
  ), "plugin observed the cancel"
  Compact.setRequestTimeout(chronos.milliseconds(150))
  expect (waitFor Compact.request(ctx, 1)).isErr, "Compact times out"
  expect pump(
    proc(): bool =
      cancels() >= 2
  ), "timeout reached the plugin as a cancel"
  Compact.setRequestTimeout(chronos.seconds(20))

  echo "== scenario 2: runtime switching between plugin and Nim implementation"
  var ls: LoadState
  ls.ctx = ctx
  var lt: Thread[ptr LoadState]
  createThread(lt, loadThread, addr ls)
  proc served(n: int): bool =
    let target = ls.total.load() + n
    pump(
      proc(): bool =
        ls.total.load() >= target
    )

  doAssert served(20) # (a) fallback, plugin attached → plugin
  doAssert FetchBlob.replaceProvider(ctx, localFetch).isOk
  doAssert served(20) # (b) forced Nim impl
  doAssert FetchBlob.replaceProvider(ctx, FetchBlob.extProvider(ctx)).isOk
  doAssert served(20) # (c) forced plugin
  doAssert FetchBlob.replaceProvider(ctx, FetchBlob.extFallback(ctx, localFetch)).isOk
  doAssert served(20)
  doAssert detach() == ExtOk # (d) plugin gone → fallback serves Nim
  doAssert served(20)
  doAssert attach(ExtHost.table(), uint32(ctx)) == ExtOk # (e) back
  doAssert served(20)
  ls.stop.store(1)
  while lt.running:
    waitFor sleepAsync(chronos.milliseconds(5))
  joinThread(lt)
  expect ls.errors.load() == 0,
    "no call lost across owner switches (" & $ls.total.load() & " calls)"
  expect ls.nim.load() > 0 and ls.plugin.load() > 0, "both sources served"
  echo "        (",
    ls.withdrawRaces.load(), " calls raced the plugin's own detach — by design)"

  echo "== scenario 4: C import (", codecLib, ")"
  expect ExtPlugin.load("codec", ctx).isOk, "ExtPlugin.load(codec)"
  expect "codec_not_exported" in ExtPlugin.loadError("codec"), "missing symbol reported"
  let data = @[byte 1, 2, 3, 250]
  let c = waitFor Crc.request(ctx, 7, unsafeAddr data[0], 4)
  expect c.isOk and c.value.value == nimCrc(7, data), "Crc: inplace direct C call"
  let t0 = Moment.now()
  let fa = SlowSum.request(ctx, @[byte 1, 2, 3], 300)
  let fbb = SlowSum.request(ctx, @[byte 4, 5], 300)
  let ra = waitFor fa
  let rb = waitFor fbb
  expect ra.isOk and ra.value.total == 6 and rb.isOk and rb.value.total == 9,
    "SlowSum results"
  expect Moment.now() - t0 < chronos.milliseconds(550),
    "workers(2): the two blocking calls overlapped"
  proc nimMixed(x: uint32): Future[Result[Mixed, string]] {.async.} =
    return ok(Mixed(value: x + 1000))

  doAssert Mixed.setProvider(ctx, Mixed.extFallback(ctx, nimMixed)).isOk
  let m = waitFor Mixed.request(ctx, 1)
  expect m.isOk and m.value.value == 1001, "missing symbol → Nim fallback"

  ExtHost.stop()
  if failures > 0:
    quit("storage_host: " & $failures & " check(s) failed", 1)
  echo "storage_host: all scenarios passed"

main()
