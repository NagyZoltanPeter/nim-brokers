{.used.}

## EXTAPI lifecycle and at-most-once (review findings R1, R2.1, R2.2, R2.4).
## Plugin: test/ext/raw_life_plugin.c. Needs `-d:extTestHooks` for the
## start/stop counters and the worker-start failure injection.

import testutils/unittests
import chronos
import std/[atomics, os]

import brokers/[request_broker, ext_plugin, broker_context]
import brokers/internal/ext_runtime

{.passC: "-I" & currentSourcePath.parentDir.parentDir & "/brokers".}
{.compile: "ext/raw_life_plugin.c".}

type LifeHookFn = proc() {.cdecl, gcsafe, raises: [].}

proc life_open(h: ptr ExtHostTable, ctx: uint32): int32 {.importc, cdecl.}
proc life_provide(name: cstring): int32 {.importc, cdecl.}
proc life_withdraw(name: cstring): int32 {.importc, cdecl.}
proc life_close(): int32 {.importc, cdecl.}
proc life_work_invokes(): int32 {.importc, cdecl.}
proc life_cancels(): int32 {.importc, cdecl.}
proc life_set_gate(open: int32) {.importc, cdecl.}
proc life_set_hook(f: LifeHookFn) {.importc, cdecl.}
proc life_reset() {.importc, cdecl.}

RequestBroker(EXTAPI[life], dispatch = workers(1)):
  type LifeWork = object
    n*: int32

  proc signature*(): Future[Result[LifeWork, string]] {.async.}

RequestBroker(EXTAPI[life]):
  type LifeBridge = object
    n*: int32

  proc signature*(): Future[Result[LifeBridge, string]] {.async.}

RequestBroker(EXTAPI[life]):
  type LifeHookBridge = object
    n*: int32

  proc signature*(): Future[Result[LifeHookBridge, string]] {.async.}

RequestBroker(EXTAPI[life], dispatch = workers(1)):
  type LifeHookWorker = object
    n*: int32

  proc signature*(): Future[Result[LifeHookWorker, string]] {.async.}

registerExtPlugin(life)

# A second plugin with a two-thread pool: worker-start failure injection hits
# its second thread, after the bridge and `life`'s worker already started.
RequestBroker(EXTAPI[life2], dispatch = workers(2)):
  type Life2Idle = object
    n*: int32

  proc signature*(): Future[Result[Life2Idle, string]] {.async.}

registerExtPlugin(life2)

const Ctx = DefaultBrokerContext

proc pump(cond: proc(): bool {.gcsafe.}, ms = 3000): bool =
  var waited = 0
  while not cond():
    if waited >= ms:
      return false
    waitFor sleepAsync(chronos.milliseconds(5))
    waited += 5
  true

proc settle(ms = 100) =
  discard pump(
    proc(): bool =
      false,
    ms,
  )

proc startAndOpen(): bool =
  life_reset()
  ExtHost.start().isOk and life_open(ExtHost.table, uint32(Ctx)) == ExtOk

proc queueWork(n: int): seq[Future[Result[LifeWork, string]]] =
  ## One call parked inside the single worker, `n - 1` queued behind it.
  life_set_gate(0)
  for i in 0 ..< n:
    result.add(LifeWork.request(Ctx))
  doAssert pump(
    proc(): bool =
      life_work_invokes() == 1
  )
  settle() # let the remaining calls reach the worker queue

proc allFinished(fs: seq[Future[Result[LifeWork, string]]]): proc(): bool {.gcsafe.} =
  result = proc(): bool =
    for f in fs:
      if not f.finished():
        return false
    true

var gHookRes: Atomic[int] # 0 not run, 1 ok, 2 err

proc stopHook() {.cdecl, gcsafe, raises: [].} =
  let r = ExtHost.stop()
  gHookRes.store(if r.isOk: 1 else: 2)

proc unblockLater(ms: int) {.thread.} =
  os.sleep(ms)
  life_set_gate(1)

type HammerState = object
  stop: Atomic[int]
  done: Atomic[int]
  badRc: Atomic[int]
  lastBad: Atomic[int]

proc hammer(st: ptr HammerState) {.thread.} =
  while st.stop.load() == 0:
    for name in ["life_bridge", "life_hook_bridge"]:
      let rc = life_provide(cstring(name))
      if rc notin [ExtOk, ExtShutdown, ExtStale, ExtAlreadyProvided]:
        discard st.badRc.fetchAdd(1)
        st.lastBad.store(int(rc))
      let wc = life_withdraw(cstring(name))
      if wc notin [ExtOk, ExtShutdown, ExtStale, ExtNotProvided]:
        discard st.badRc.fetchAdd(1)
        st.lastBad.store(1000 + int(wc))
  st.done.store(1)

proc startConcurrently(res: ptr Atomic[int]) {.thread.} =
  {.cast(gcsafe).}: # as in `<lib>_extHost()`, which starts from any thread
    if ExtHost.start().isOk:
      discard res[].fetchAdd(1)

suite "EXTAPI lifecycle":
  test "withdraw drops calls queued for a worker (R1)":
    check startAndOpen()
    check life_provide("life_work") == ExtOk
    let futs = queueWork(5)
    check life_withdraw("life_work") == ExtOk
    check pump(allFinished(futs))
    for f in futs[1 ..^ 1]:
      check f.read().isErr
    life_set_gate(1)
    settle(200)
    check life_work_invokes() == 1 # the queued four never ran
    check ExtHost.stop().isOk

  test "close drops calls queued for a worker (R1)":
    check startAndOpen()
    check life_provide("life_work") == ExtOk
    let futs = queueWork(5)
    check life_close() == ExtOk
    check pump(allFinished(futs))
    for f in futs[1 ..^ 1]:
      check f.read().isErr
    life_set_gate(1)
    settle(200)
    check life_work_invokes() == 1
    check ExtHost.stop().isOk

  test "stop drops calls queued for a worker (R1)":
    check startAndOpen()
    check life_provide("life_work") == ExtOk
    discard queueWork(5)
    var t: Thread[int]
    createThread(t, unblockLater, 300) # the parked call ends during stop's join
    check ExtHost.stop().isOk
    joinThread(t)
    settle(200)
    check life_work_invokes() == 1

  test "stop from the bridge or a worker is refused (R2.2)":
    check startAndOpen()
    check life_provide("life_hook_bridge") == ExtOk
    check life_provide("life_hook_worker") == ExtOk
    life_set_hook(stopHook)
    gHookRes.store(0)
    check (waitFor LifeHookBridge.request(Ctx)).isOk
    check gHookRes.load() == 2
    gHookRes.store(0)
    check (waitFor LifeHookWorker.request(Ctx)).isOk
    check gHookRes.load() == 2
    life_set_hook(nil)
    check ExtHost.stop().isOk # the main thread may stop

  test "stop races control calls without hanging (R2.1)":
    for i in 0 ..< 50:
      check startAndOpen()
      var st: HammerState
      var t: Thread[ptr HammerState]
      createThread(t, hammer, addr st)
      os.sleep(i mod 5)
      check ExtHost.stop().isOk
      st.stop.store(1)
      var waited = 0
      while st.done.load() == 0 and waited < 3000:
        os.sleep(5)
        waited += 5
      if st.done.load() == 0:
        echo "control call hung across stop (iteration ", i, ")"
        quit(1) # a hung thread cannot be joined; fail loudly instead
      joinThread(t)
      check st.badRc.load() == 0
      if st.badRc.load() != 0:
        echo "unexpected rc: ", st.lastBad.load()

  test "concurrent start runs one bridge (R2.4)":
    let before = extTestBridgeStarts.load()
    var oks: Atomic[int]
    var ts: array[8, Thread[ptr Atomic[int]]]
    for i in 0 ..< ts.len:
      createThread(ts[i], startConcurrently, addr oks)
    joinThreads(ts)
    check oks.load() == ts.len
    check extTestBridgeStarts.load() - before == 1
    check ExtHost.stop().isOk
    check extTestBridgeStarts.load() == extTestBridgeExits.load()

  test "a failed start rolls back and can be retried (R2.4)":
    # Third worker thread overall: life's one, life2's first, life2's second.
    extTestFailWorkerAt.store(3)
    check ExtHost.start().isErr
    extTestFailWorkerAt.store(0)
    check extTestBridgeStarts.load() == extTestBridgeExits.load() # bridge joined
    check startAndOpen()
    check life_provide("life_work") == ExtOk
    check (waitFor LifeWork.request(Ctx)).isOk
    check ExtHost.stop().isOk
