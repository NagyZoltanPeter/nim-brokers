{.used.}

## EXTAPI phase 1b — the Nim implementation is an ordinary MT provider; the
## generated `extProvider` / `extFallback` forwarders reach the plugin from
## any thread (hidden `<T>ExtLane`), the slot owner switches gaplessly with
## `replaceProvider`, `withMockProvider` works unchanged, `inplace` runs on
## the caller's own thread, and `ExtTunnel` drives brokers by name with raw
## CBOR. Plugin: test/ext/raw_kv_plugin.c (no generated wrapper).

import testutils/unittests
import chronos
import std/[atomics, os, strutils]

import brokers/[request_broker, event_broker, signal_broker, ext_plugin]

{.passC: "-I" & currentSourcePath.parentDir.parentDir & "/brokers".}
{.compile: "ext/raw_kv_plugin.c".}

proc raw_kv_open(h: ptr ExtHostTable, ctx: uint32): int32 {.importc, cdecl.}
proc raw_kv_provide(name: cstring): int32 {.importc, cdecl.}
proc raw_kv_withdraw(name: cstring): int32 {.importc, cdecl.}
proc raw_kv_close(): int32 {.importc, cdecl.}
proc raw_kv_note_count(): int32 {.importc, cdecl.}
proc raw_kv_cancel_count(): int32 {.importc, cdecl.}
proc raw_kv_parked(): int32 {.importc, cdecl.}
proc raw_kv_release(): int32 {.importc, cdecl.}
proc raw_kv_square_thread(): uint {.importc, cdecl.}
proc raw_kv_self_thread(): uint {.importc, cdecl.}
proc raw_kv_emit_tick(n: uint32): int32 {.importc, cdecl.}

RequestBroker(EXTAPI[kv], autoWire = false):
  type KvGet = object
    value*: string

  proc signature*(key: string): Future[Result[KvGet, string]] {.async.}

RequestBroker(EXTAPI[kv], autoWire = false):
  type KvSlow = object
    n*: int32

  proc signature*(): Future[Result[KvSlow, string]] {.async.}

SignalBroker(EXTAPI[kv], autoWire = false):
  type KvNote = object
    text*: string

RequestBroker(EXTAPI[kv], dispatch = inplace):
  type KvSquare = object
    v*: int64

  proc signature*(x: int64): Future[Result[KvSquare, string]] {.async.}

EventBroker(EXTAPI[kv]):
  type KvTick = object
    n*: int32

registerExtPlugin(kv)

type KvGetArgs = object
  key*: string

proc localGet(key: string): Future[Result[KvGet, string]] {.async.} =
  return ok(KvGet(value: "nim:" & key))

proc pump(cond: proc(): bool {.gcsafe.}, ms = 2000): bool =
  ## Drive this thread's chronos loop (it may own providers) until `cond`.
  var waited = 0
  while not cond():
    if waited >= ms:
      return false
    waitFor sleepAsync(chronos.milliseconds(5))
    waited += 5
  true

type LoadState = object
  ctx: BrokerContext
  stop: Atomic[int]
  nim, plugin, errors, withdrawRaces, total: Atomic[int]

proc loadThread(st: ptr LoadState) {.thread.} =
  proc run() {.async.} =
    while st.stop.load() == 0:
      let r = await KvGet.request(st.ctx, "x")
      discard st.total.fetchAdd(1)
      if r.isErr:
        # A call already routed to the plugin when the plugin itself withdraws
        # fails by design (it may have acted; no silent retry). Any other
        # error is a switching gap.
        if "cleared while the request was outstanding" in r.error or
            "withdrawn" in r.error:
          discard st.withdrawRaces.fetchAdd(1)
        else:
          discard st.errors.fetchAdd(1)
      elif r.value.value.startsWith("plugin:"):
        discard st.plugin.fetchAdd(1)
      else:
        discard st.nim.fetchAdd(1)

  waitFor run()

type CancelState = object
  ctx: BrokerContext
  done: Atomic[int]
  gotErr: Atomic[int]

proc cancelThread(st: ptr CancelState) {.thread.} =
  proc run() {.async.} =
    let (id, f) = KvSlow.requestCancellable(st.ctx)
    while raw_kv_parked() < 1:
      await sleepAsync(chronos.milliseconds(2))
    discard KvSlow.cancel(st.ctx, id)
    let r = await f
    if r.isErr:
      st.gotErr.store(1)

  waitFor run()
  st.done.store(1)

suite "EXTAPI phase 1b: Nim impl, switching, mocking, inplace, tunnel":
  test "all":
    check ExtHost.start().isOk
    let ctx = NewBrokerContext()
    check raw_kv_open(ExtHost.table(), uint32(ctx)) == ExtOk

    # --- extFallback / extAvailable, author-owned slot on this thread -----
    check KvGet.setProvider(ctx, KvGet.extFallback(ctx, localGet)).isOk
    check not KvGet.extAvailable(ctx)
    check (waitFor KvGet.request(ctx, "a")).get(KvGet()).value == "nim:a"
    check raw_kv_provide("kv_get") == ExtOk # autoWire = false: slot stays ours
    check KvGet.extAvailable(ctx)
    # off-bridge forwarder → hidden lane → bridge → plugin
    check (waitFor KvGet.request(ctx, "a")).get(KvGet()).value == "plugin:a"
    check raw_kv_withdraw("kv_get") == ExtOk
    check (waitFor KvGet.request(ctx, "a")).get(KvGet()).value == "nim:a"
    check raw_kv_provide("kv_get") == ExtOk

    # --- gapless switching under concurrent load -----------------------------
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

    check served(20)
    check KvGet.replaceProvider(ctx, localGet).isOk
    check served(20)
    check KvGet.replaceProvider(ctx, KvGet.extProvider(ctx)).isOk
    check served(20)
    check KvGet.replaceProvider(ctx, KvGet.extFallback(ctx, localGet)).isOk
    check served(20)
    check raw_kv_withdraw("kv_get") == ExtOk # fallback → Nim impl, no gap
    check served(20)
    check raw_kv_provide("kv_get") == ExtOk
    check served(20)
    ls.stop.store(1)
    while true: # let the last in-flight request finish on this (owner) thread
      waitFor sleepAsync(chronos.milliseconds(5))
      if not lt.running:
        break
    joinThread(lt)
    check ls.errors.load() == 0 # owner replaceProvider switches lose nothing
    check ls.nim.load() > 0
    check ls.plugin.load() > 0

    # --- mocking: plain withMockProvider on the owner thread ------------------
    var hits = 0
    let mock: KvGetProviderWithArgs = proc(
        key: string
    ): Future[Result[KvGet, string]] {.async.} =
      inc hits
      return ok(KvGet(value: "mock"))
    KvGet.withMockProvider(ctx, mock):
      check (waitFor KvGet.request(ctx, "a")).get(KvGet()).value == "mock"
    check hits == 1
    check (waitFor KvGet.request(ctx, "a")).get(KvGet()).value == "plugin:a"

    # --- cancel through the lane reaches the plugin ---------------------------
    check KvSlow.setProvider(ctx, KvSlow.extProvider(ctx)).isOk
    check raw_kv_provide("kv_slow") == ExtOk
    var cs: CancelState
    cs.ctx = ctx
    var ct: Thread[ptr CancelState]
    createThread(ct, cancelThread, addr cs)
    check pump(
      proc(): bool =
        cs.done.load() == 1 and raw_kv_cancel_count() >= 1
    )
    joinThread(ct)
    check cs.gotErr.load() == 1
    discard raw_kv_release() # late reply: dropped by id

    # --- signals off the bridge: extFallback handler on this thread ----------
    var nimNotes = 0
    let nimNote: KvNoteSignalHandler = proc(
        v: KvNote
    ): Future[void] {.async: (raises: []), gcsafe.} =
      {.cast(gcsafe).}:
        inc nimNotes
    check KvNote.onSignal(ctx, KvNote.extFallback(ctx, nimNote)).isOk
    check KvNote.signal(ctx, KvNote(text: "x")).isOk
    check pump(
      proc(): bool =
        nimNotes == 1
    )
    check raw_kv_provide("kv_note") == ExtOk
    check KvNote.signal(ctx, KvNote(text: "y")).isOk
    check pump(
      proc(): bool =
        raw_kv_note_count() == 1
    )
    check nimNotes == 1

    # --- inplace runs on the caller's own thread (auto-wired) -----------------
    check raw_kv_provide("kv_square") == ExtOk
    let sq = waitFor KvSquare.request(ctx, 9)
    check sq.isOk and sq.get(KvSquare()).v == 81
    check raw_kv_square_thread() == raw_kv_self_thread()
    check KvSquare.blockingRequest(ctx, 3).get(KvSquare()).v == 9

    # --- ExtTunnel: by name, raw CBOR, through whatever provider is in place --
    let req = cborEncode(KvGetArgs(key: "t")).get(@[])
    let tr = waitFor ExtTunnel.call(ctx, "kv", "kv_get", req)
    check tr.isOk
    if tr.isOk:
      check cborDecode(tr.value, KvGet).get(KvGet()).value == "plugin:t"
    check (waitFor ExtTunnel.call(ctx, "kv", "nope", @[])).isErr
    check ExtTunnel.signal(ctx, "kv", "kv_note", cborEncode(KvNote(text: "z")).get(@[])).isOk
    check pump(
      proc(): bool =
        raw_kv_note_count() == 2
    )
    var ticks: seq[int32]
    check ExtTunnel.listen(
      ctx,
      "kv",
      "kv_tick",
      proc(b: seq[byte]) {.gcsafe, raises: [].} =
        {.cast(gcsafe).}:
          ticks.add(cborDecode(b, KvTick).get(KvTick()).n),
    ).isOk
    check raw_kv_emit_tick(4) == ExtOk
    check pump(
      proc(): bool =
        ticks == @[4'i32]
    )

    check raw_kv_close() == ExtOk
    # Plugin gone: fallback serves, forwarder reports the missing source.
    check (waitFor KvGet.request(ctx, "a")).get(KvGet()).value == "nim:a"
    check (waitFor KvSlow.request(ctx)).isErr
    ExtHost.stop()
