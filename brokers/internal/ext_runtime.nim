## EXTAPI runtime — the Nim side of `broker_ext.h`.
##
## Holds the process-global plugin registry, the per-plugin port tables, the
## host function table handed to foreign plugins, and the bridge thread that
## owns every EXTAPI stub provider (see doc/design/EXTAPI_PLAN.md §5, §6).
##
## Threading / memory model:
## - Every `broker_ext_host` entry (`extOpen`, `extProvide`, `extReply`, …)
##   may run on a foreign, non-Nim thread. Those procs touch only atomics,
##   `Lock` / `Cond`, libc `c_malloc` / `c_free` and `fireBrokerSignal` —
##   never the Nim heap and never a threadvar — so they are safe under
##   `--mm:refc` (thread-local heaps) and `--mm:orc` alike.
## - All Nim-heap state (pending calls, source table, futures) lives in
##   threadvars of the bridge thread and is only touched there.
## - Messages crossing threads are POD; payload buffers are `c_malloc`ed by
##   the producer and `c_free`d by the consumer.

{.push raises: [].}

import std/[atomics, locks, tables, os, dynlib]
when not defined(windows):
  from std/posix import pthread_self
import system/ansi_c
import chronos, chronicles, results
import ../broker_context, ./mt_broker_common

export results

when defined(windows):
  proc extGetCurrentThreadId(): uint32 {.
    importc: "GetCurrentThreadId", stdcall, dynlib: "kernel32"
  .}

const
  ExtAbiVersion* = 1'u32
  ExtMaxPlugins* = 32
  ExtMaxPorts* = 64 ## per plugin
  ExtMaxNames* = 64 ## per plugin (provided-set bitmask width)
  ExtRingCap = 4096

  ExtOk* = 0'i32
  ExtBadArg* = -1'i32
  ExtUnknownName* = -4'i32
  ExtAgain* = -6'i32
  ExtShutdown* = -11'i32
  ExtSchemaMismatch* = -14'i32
  ExtStale* = -15'i32
  ExtAlreadyProvided* = -16'i32
  ExtNotProvided* = -17'i32
  ExtDispatchMismatch* = -18'i32

  ExtReplyOk* = 0'i32
  ExtReplyErr* = 1'i32

  ExtCapNonBlocking* = 1'u32
  ExtCapReplyInline* = 2'u32

type ExtRing[T] = object
  ## Fixed-capacity, mutex-protected MPSC ring of POD elements. Storage is
  ## libc-allocated so foreign threads never touch the Nim allocator.
  buf: ptr UncheckedArray[T]
  cap, head, count: int
  lock: Lock

type
  ExtInvokeFn* = proc(
    user: pointer,
    id: uint64,
    nameIdx: uint32,
    name: cstring,
    buf: ptr uint8,
    len: csize_t,
  ) {.cdecl, gcsafe, raises: [].}
  ExtCancelFn* = proc(user: pointer, id: uint64) {.cdecl, gcsafe, raises: [].}
  ExtReleaseFn* = proc(user: pointer) {.cdecl, gcsafe, raises: [].}

  ExtImplDesc* {.bycopy.} = object ## Mirrors `broker_ext_impl` in broker_ext.h.
    abiVersion*: uint32
    plugin*: cstring
    schemaHash*: cstring
    caps*: uint32
    invoke*: ExtInvokeFn
    cancel*: ExtCancelFn
    release*: ExtReleaseFn
    user*: pointer

  ExtHostTable* {.bycopy.} = object
    ## Mirrors `broker_ext_host` in broker_ext.h — field order is ABI.
    abiVersion*: uint32
    host*: pointer
    open*: proc(
      host: pointer, ctx: uint32, impl: ptr ExtImplDesc, outPort: ptr uint64
    ): int32 {.cdecl, gcsafe, raises: [].}
    close*: proc(host: pointer, port: uint64): int32 {.cdecl, gcsafe, raises: [].}
    provide*: proc(host: pointer, port: uint64, name: cstring): int32 {.
      cdecl, gcsafe, raises: []
    .}
    withdraw*: proc(host: pointer, port: uint64, name: cstring): int32 {.
      cdecl, gcsafe, raises: []
    .}
    reply*: proc(
      host: pointer,
      port: uint64,
      id: uint64,
      status: int32,
      buf: ptr uint8,
      len: csize_t,
    ): int32 {.cdecl, gcsafe, raises: [].}
    emit*: proc(
      host: pointer, port: uint64, name: cstring, buf: ptr uint8, len: csize_t
    ): int32 {.cdecl, gcsafe, raises: [].}
    listApis*: proc(
      host: pointer, plugin: cstring, outBuf: ptr ptr uint8, outLen: ptr csize_t
    ): int32 {.cdecl, gcsafe, raises: [].}
    getSchema*: proc(
      host: pointer, plugin: cstring, outBuf: ptr ptr uint8, outLen: ptr csize_t
    ): int32 {.cdecl, gcsafe, raises: [].}
    freeBuffer*: proc(host: pointer, buf: ptr uint8) {.cdecl, gcsafe, raises: [].}
    schemaHash*: proc(host: pointer, plugin: cstring, hashOut: ptr char): int32 {.
      cdecl, gcsafe, raises: []
    .}

  ExtDispatch* = enum
    edBridge
    edWorkers
    edInplace

  ExtNameKind* = enum
    enkRequest
    enkSignal
    enkEvent

  ExtInstallFn* =
    proc(ctx: BrokerContext): Result[void, string] {.nimcall, gcsafe, raises: [].}
    ## Runs on the bridge thread when the first port provides this name on
    ## `ctx`: wires the public broker slot (autoWire).
  ExtUninstallFn* =
    proc(ctx: BrokerContext, siblingWired: bool) {.nimcall, gcsafe, raises: [].}
    ## Runs on the bridge thread when the providing port withdraws the name.
    ## `siblingWired`: the other signature slot of the same request broker is
    ## still auto-wired, so the broker must not be cleared as a whole.
  ExtEmitFn* = proc(ctx: BrokerContext, buf: ptr uint8, len: int): Result[void, string] {.
    nimcall, gcsafe, raises: []
  .} ## Runs on the bridge thread: decode an event payload and emit it.

  ExtNameDesc* = object
    name*: cstring
    kind*: ExtNameKind
    dispatch*: ExtDispatch
    install*: ExtInstallFn
    uninstall*: ExtUninstallFn
    emitFn*: ExtEmitFn
    sibling*: int ## nameIdx of the other slot of a dual-slot request, or -1

  ExtPluginDesc* = object
    name*: cstring
    version*: cstring
    schemaHash*: cstring
    names*: ptr UncheckedArray[ExtNameDesc]
    nameCount*: int
    workers*: int ## size of the plugin's worker pool (0 = no `workers` names)
    listApisBuf*: cstring ## CBOR, static storage
    listApisLen*: int
    schemaBuf*: cstring ## CBOR, static storage
    schemaLen*: int

  ExtImplRef = object
    refs: Atomic[int]
    impl: ExtImplDesc

  ExtPortSlot = object
    gen: Atomic[uint32]
    open: Atomic[bool]
    ctx: uint32
    impl: ptr ExtImplRef
    provided: Atomic[uint64]

  ExtCallState = object
    ## Shared by the bridge and a worker for one queued call: 0 queued,
    ## 1 running, 2 cancelled. Two refs (bridge + worker), libc-allocated.
    state: Atomic[int]
    refs: Atomic[int]

  ExtCallMsg = object
    impl: ptr ExtImplRef ## one ref held for the worker
    id: uint64
    nameIdx: uint32
    name: cstring
    buf: ptr uint8 ## c_malloc, worker frees
    len: int
    st: ptr ExtCallState

  ExtWorkerPool = object
    q: ExtRing[ExtCallMsg]
    lock: Lock
    cond: Cond
    stop: bool
    n: int
    threads: pointer ## ptr UncheckedArray[Thread[ptr ExtWorkerPool]]

  ExtInplaceSlot = object
    ## A synchronous `inplace` call waiting for its reply inside `invoke`.
    id: Atomic[uint64]
    filled: Atomic[bool]
    status: int32
    buf: ptr uint8
    len: int

  ExtPluginRt = object
    desc: ptr ExtPluginDesc
    lock: Lock
    ports: array[ExtMaxPorts, ExtPortSlot]
    pool: ptr ExtWorkerPool

  ExtCtlOp = enum
    ecoProvide
    ecoWithdraw
    ecoClose

  ExtCtlMsg = object
    ## Lives on the waiting caller's stack; the caller blocks on `cond` until
    ## the bridge sets `done`.
    op: ExtCtlOp
    pluginIdx: int
    portSlot: int
    gen: uint32
    nameIdx: int
    rc: int32
    done: bool
    lock: Lock
    cond: Cond

  ExtReplyMsg = object
    callId: uint64
    status: int32
    buf: ptr uint8 ## c_malloc, consumer frees
    len: int

  ExtEventMsg = object
    pluginIdx: int
    nameIdx: int
    ctx: uint32
    buf: ptr uint8 ## c_malloc, consumer frees
    len: int

  ExtHostRt = object
    running: Atomic[bool]
    ready: Atomic[int]
    stopFlag: Atomic[int]
    signal: ptr BrokerSignalShared
    bridgeTid: Atomic[uint64]
    ctlRing: ExtRing[ptr ExtCtlMsg]
    replyRing: ExtRing[ExtReplyMsg]
    eventRing: ExtRing[ExtEventMsg]

  PendingCall = object
    fut: Future[ExtRawReply]
    pluginIdx: int
    portSlot: int
    nameIdx: int

  ExtRawReply* = object
    status*: int32
    data*: seq[byte]

  SourceKey = tuple[pluginIdx: int, nameIdx: int, ctx: uint32]
  Source = object
    portSlot: int
    gen: uint32

# ---------------------------------------------------------------------------
# Ring
# ---------------------------------------------------------------------------

proc init[T](r: var ExtRing[T], cap: int) =
  r.buf = cast[ptr UncheckedArray[T]](c_calloc(csize_t(cap), csize_t(sizeof(T))))
  r.cap = cap
  r.head = 0
  r.count = 0
  initLock(r.lock)

proc tryPush[T](r: var ExtRing[T], v: T): bool =
  withLock(r.lock):
    if r.count >= r.cap:
      return false
    r.buf[(r.head + r.count) mod r.cap] = v
    inc r.count
  true

proc tryPop[T](r: var ExtRing[T], dst: var T): bool =
  withLock(r.lock):
    if r.count == 0:
      return false
    dst = r.buf[r.head]
    r.head = (r.head + 1) mod r.cap
    dec r.count
  true

# ---------------------------------------------------------------------------
# Process-global state (shared heap / plain globals, no GC'd fields)
# ---------------------------------------------------------------------------

var gExtPlugins: array[ExtMaxPlugins, ptr ExtPluginRt]
var gExtPluginCount: Atomic[int]
var gExtRegLock: Lock
var gExtRegLockInit: Atomic[int]
var gExtHost: ptr ExtHostRt
var gExtHostTable: ExtHostTable
var gExtCallSeq: Atomic[uint64]
var gExtBridgeThread: Thread[ptr ExtHostRt]
const ExtMaxInplace = 256
var gExtInplace: array[ExtMaxInplace, ExtInplaceSlot]

# Bridge-thread-local state.
var gExtPending {.threadvar.}: Table[uint64, PendingCall]
var gExtSources {.threadvar.}: Table[SourceKey, Source]
var gExtWired {.threadvar.}: Table[SourceKey, bool]

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

proc fromBytes(b: seq[byte]): string =
  result = newString(b.len)
  if b.len > 0:
    copyMem(addr result[0], unsafeAddr b[0], b.len)

proc osThreadId(): uint64 =
  when defined(windows):
    uint64(extGetCurrentThreadId())
  else:
    cast[uint64](pthread_self())

proc ensureRegLock() =
  var expected = 0
  if gExtRegLockInit.compareExchange(expected, 1):
    initLock(gExtRegLock)
    gExtRegLockInit.store(2, moRelease)
  else:
    while gExtRegLockInit.load(moAcquire) != 2:
      discard

proc extRegisterPlugin*(desc: ptr ExtPluginDesc): int =
  ## Called once per `registerExtPlugin` at module init. Returns the plugin
  ## index used by the generated stubs.
  ensureRegLock()
  withLock(gExtRegLock):
    let idx = gExtPluginCount.load(moAcquire)
    if idx >= ExtMaxPlugins:
      error "EXTAPI: too many plugins", max = ExtMaxPlugins
      return -1
    if desc.nameCount > ExtMaxNames:
      error "EXTAPI: too many names in plugin", plugin = $desc.name, max = ExtMaxNames
      return -1
    let rt = cast[ptr ExtPluginRt](createShared(ExtPluginRt, 1))
    rt.desc = desc
    initLock(rt.lock)
    gExtPlugins[idx] = rt
    gExtPluginCount.store(idx + 1, moRelease)
    return idx

proc findPlugin(name: cstring): int =
  if name.isNil:
    return -1
  let n = gExtPluginCount.load(moAcquire)
  for i in 0 ..< n:
    let rt = gExtPlugins[i]
    if not rt.isNil and c_strcmp(rt.desc.name, name) == 0:
      return i
  -1

proc findName(desc: ptr ExtPluginDesc, name: cstring): int =
  if name.isNil:
    return -1
  for i in 0 ..< desc.nameCount:
    if c_strcmp(desc.names[i].name, name) == 0:
      return i
  -1

proc makePort(pluginIdx, slot: int, gen: uint32): uint64 =
  (uint64(pluginIdx) shl 48) or (uint64(slot) shl 32) or uint64(gen)

proc splitPort(port: uint64): tuple[pluginIdx, slot: int, gen: uint32] =
  (
    int(port shr 48),
    int((port shr 32) and 0xFFFF'u64),
    uint32(port and 0xFFFF_FFFF'u64),
  )

proc lookupPort(
    port: uint64
): tuple[rt: ptr ExtPluginRt, slot: int, gen: uint32, ok: bool] =
  let (p, s, g) = splitPort(port)
  if p >= gExtPluginCount.load(moAcquire) or s >= ExtMaxPorts or g == 0:
    return (nil, 0, 0'u32, false)
  let rt = gExtPlugins[p]
  if rt.isNil:
    return (nil, 0, 0'u32, false)
  let ps = addr rt.ports[s]
  if not ps.open.load(moAcquire) or ps.gen.load(moAcquire) != g:
    return (rt, s, g, false)
  (rt, s, g, true)

proc implAcquire(r: ptr ExtImplRef) =
  discard r.refs.fetchAdd(1, moAcquireRelease)

proc implRelease(r: ptr ExtImplRef) =
  if r.refs.fetchSub(1, moAcquireRelease) == 1:
    if not r.impl.release.isNil:
      r.impl.release(r.impl.user)
    c_free(r)

proc stRelease(st: ptr ExtCallState) =
  if not st.isNil and st.refs.fetchSub(1, moAcquireRelease) == 1:
    c_free(st)

proc newCallState(): ptr ExtCallState =
  result = cast[ptr ExtCallState](c_calloc(1, csize_t(sizeof(ExtCallState))))
  result.refs.store(2, moRelease)

proc copyToC(p: seq[byte]): ptr uint8 =
  if p.len == 0:
    return nil
  result = cast[ptr uint8](c_malloc(csize_t(p.len)))
  copyMem(result, unsafeAddr p[0], p.len)

proc poolPush(pool: ptr ExtWorkerPool, m: ExtCallMsg): bool =
  withLock(pool.lock):
    if pool.stop or not pool.q.tryPush(m):
      return false
    signal(pool.cond)
  true

proc workerProc(pool: ptr ExtWorkerPool) {.thread.} =
  ## Plain worker: no chronos loop, never touches broker state. Runs the
  ## foreign `invoke` (which may block this thread only).
  while true:
    var m: ExtCallMsg
    var got = false
    withLock(pool.lock):
      while true:
        if pool.q.tryPop(m):
          got = true
          break
        if pool.stop:
          break
        wait(pool.cond, pool.lock)
    if not got:
      break
    var expected = 0
    if m.st.isNil or m.st.state.compareExchange(expected, 1):
      m.impl.impl.invoke(
        m.impl.impl.user, m.id, m.nameIdx, m.name, m.buf, csize_t(m.len)
      )
    if not m.buf.isNil:
      c_free(m.buf)
    stRelease(m.st)
    implRelease(m.impl)

proc inplaceClaim(id: uint64): int =
  for i in 0 ..< ExtMaxInplace:
    var expected = 0'u64
    if gExtInplace[i].id.compareExchange(expected, id):
      gExtInplace[i].filled.store(false, moRelease)
      gExtInplace[i].buf = nil
      gExtInplace[i].len = 0
      return i
  -1

proc inplaceFill(id: uint64, status: int32, buf: ptr uint8, len: int): bool =
  ## Called from `extReply`: if `id` is a synchronous inplace call, store the
  ## reply in its slot instead of the bridge ring.
  for i in 0 ..< ExtMaxInplace:
    if gExtInplace[i].id.load(moAcquire) == id:
      if gExtInplace[i].filled.load(moAcquire):
        return true # first reply wins; later ones are dropped
      gExtInplace[i].status = status
      gExtInplace[i].len = len
      if len > 0:
        gExtInplace[i].buf = cast[ptr uint8](c_malloc(csize_t(len)))
        copyMem(gExtInplace[i].buf, buf, len)
      gExtInplace[i].filled.store(true, moRelease)
      return true
  false

proc hostRunning(): bool =
  not gExtHost.isNil and gExtHost.running.load(moAcquire)

proc onBridgeThread(): bool =
  not gExtHost.isNil and gExtHost.bridgeTid.load(moAcquire) == osThreadId()

# ---------------------------------------------------------------------------
# Bridge-side operations (run on the bridge thread only)
# ---------------------------------------------------------------------------

proc failPending(pred: proc(c: PendingCall): bool {.gcsafe, raises: [].}, msg: string) =
  var ids: seq[uint64]
  for id, c in gExtPending:
    if pred(c):
      ids.add(id)
  for id in ids:
    var c: PendingCall
    if gExtPending.pop(id, c):
      if not c.fut.finished():
        c.fut.complete(ExtRawReply(status: ExtReplyErr, data: toBytes(msg)))

proc bridgeWithdraw(pluginIdx, slot, nameIdx: int, ctx: uint32): int32 =
  let key: SourceKey = (pluginIdx, nameIdx, ctx)
  var src: Source
  if not gExtSources.pop(key, src) or src.portSlot != slot:
    return ExtNotProvided
  let rt = gExtPlugins[pluginIdx]
  let nd = rt.desc.names[nameIdx]
  if gExtWired.getOrDefault(key, false):
    gExtWired.del(key)
    var siblingWired = false
    if nd.sibling >= 0:
      siblingWired = gExtWired.getOrDefault((pluginIdx, nd.sibling, ctx), false)
    if not nd.uninstall.isNil:
      nd.uninstall(BrokerContext(ctx), siblingWired)
  discard rt.ports[slot].provided.fetchAnd(not (1'u64 shl nameIdx), moAcquireRelease)
  failPending(
    proc(c: PendingCall): bool =
      c.pluginIdx == pluginIdx and c.portSlot == slot and c.nameIdx == nameIdx,
    "EXTAPI: provider withdrawn",
  )
  ExtOk

proc bridgeProvide(pluginIdx, slot, nameIdx: int, ctx: uint32, gen: uint32): int32 =
  let key: SourceKey = (pluginIdx, nameIdx, ctx)
  if gExtSources.hasKey(key):
    return ExtAlreadyProvided
  gExtSources[key] = Source(portSlot: slot, gen: gen)
  let rt = gExtPlugins[pluginIdx]
  discard rt.ports[slot].provided.fetchOr(1'u64 shl nameIdx, moAcquireRelease)
  let nd = rt.desc.names[nameIdx]
  if not nd.install.isNil:
    let r = nd.install(BrokerContext(ctx))
    if r.isOk:
      gExtWired[key] = true
    else:
      # The public slot is held by someone else (e.g. a Nim provider). The
      # foreign source stays registered (standby); see EXTAPI_PLAN §5.8.
      info "EXTAPI: provided name not auto-wired",
        plugin = $rt.desc.name, name = $nd.name, reason = r.error
  ExtOk

proc bridgeClose(pluginIdx, slot: int, gen: uint32): int32 =
  let rt = gExtPlugins[pluginIdx]
  let ps = addr rt.ports[slot]
  let ctx = ps.ctx
  for n in 0 ..< rt.desc.nameCount:
    if (ps.provided.load(moAcquire) and (1'u64 shl n)) != 0:
      discard bridgeWithdraw(pluginIdx, slot, n, ctx)
  failPending(
    proc(c: PendingCall): bool =
      c.pluginIdx == pluginIdx and c.portSlot == slot,
    "EXTAPI: port closed",
  )
  var impl: ptr ExtImplRef
  withLock(rt.lock):
    if ps.gen.load(moAcquire) == gen and ps.open.load(moAcquire):
      ps.open.store(false, moRelease)
      impl = ps.impl
      ps.impl = nil
  if not impl.isNil:
    implRelease(impl)
  ExtOk

proc runCtl(m: ptr ExtCtlMsg) =
  let rt = gExtPlugins[m.pluginIdx]
  let ps = addr rt.ports[m.portSlot]
  if not ps.open.load(moAcquire) or ps.gen.load(moAcquire) != m.gen:
    m.rc = ExtStale
    return
  m.rc =
    case m.op
    of ecoProvide:
      bridgeProvide(m.pluginIdx, m.portSlot, m.nameIdx, ps.ctx, m.gen)
    of ecoWithdraw:
      bridgeWithdraw(m.pluginIdx, m.portSlot, m.nameIdx, ps.ctx)
    of ecoClose:
      bridgeClose(m.pluginIdx, m.portSlot, m.gen)

proc ctlPoll(): int {.gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    var did = 0
    var m: ptr ExtCtlMsg
    while gExtHost.ctlRing.tryPop(m):
      did = 1
      runCtl(m)
      withLock(m.lock):
        m.done = true
        signal(m.cond)
    did

proc replyPoll(): int {.gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    var did = 0
    var r: ExtReplyMsg
    while gExtHost.replyRing.tryPop(r):
      did = 1
      var c: PendingCall
      if gExtPending.pop(r.callId, c):
        var data = newSeq[byte](r.len)
        if r.len > 0:
          copyMem(addr data[0], r.buf, r.len)
        if not c.fut.finished():
          c.fut.complete(ExtRawReply(status: r.status, data: move data))
      else:
        debug "EXTAPI: reply for unknown / finished call dropped", callId = r.callId
      if not r.buf.isNil:
        c_free(r.buf)
    did

proc eventPoll(): int {.gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    var did = 0
    var e: ExtEventMsg
    while gExtHost.eventRing.tryPop(e):
      did = 1
      let nd = gExtPlugins[e.pluginIdx].desc.names[e.nameIdx]
      if not nd.emitFn.isNil:
        let r = nd.emitFn(BrokerContext(e.ctx), e.buf, e.len)
        if r.isErr:
          warn "EXTAPI: event payload dropped", name = $nd.name, reason = r.error
      if not e.buf.isNil:
        c_free(e.buf)
    did

# ---------------------------------------------------------------------------
# The call path used by generated forwarders (bridge thread)
# ---------------------------------------------------------------------------

proc extCall*(
    pluginIdx, nameIdx: int, ctx: BrokerContext, payload: seq[byte], timeout: Duration
): Future[Result[seq[byte], string]] {.async.} =
  ## Invoke the foreign source of `(pluginIdx, nameIdx, ctx)` and await its
  ## reply. Must run on the bridge thread. Cancellation (`cancel(id)` of the
  ## public request) and `timeout` (the public broker's request timeout —
  ## an MT timeout alone only abandons the response slot and never stops a
  ## running provider) both forward the plugin's cancel hint and drop the
  ## late reply by id.
  if pluginIdx < 0 or nameIdx < 0:
    return err("EXTAPI: plugin not registered")
  if not onBridgeThread():
    # Off-bridge forwarders reach the foreign source through the hidden
    # `<T>Ext` MT lane (EXTAPI_PLAN §5.8, phase 1b); until then only the
    # auto-wired, bridge-owned forwarder may call in.
    return
      err("EXTAPI: extProvider installed off the bridge thread is not supported yet")
  var src: Source
  var rt: ptr ExtPluginRt
  var impl: ptr ExtImplRef
  {.cast(gcsafe).}:
    let key: SourceKey = (pluginIdx, nameIdx, uint32(ctx))
    if not gExtSources.hasKey(key):
      return err("EXTAPI: no provider registered (not provided by any plugin port)")
    src = gExtSources.getOrDefault(key)
    rt = gExtPlugins[pluginIdx]
    withLock(rt.lock):
      let ps = addr rt.ports[src.portSlot]
      if ps.open.load(moAcquire) and ps.gen.load(moAcquire) == src.gen:
        impl = ps.impl
        if not impl.isNil:
          implAcquire(impl)
  if impl.isNil:
    return err("EXTAPI: plugin port closed")
  defer:
    implRelease(impl)
  let nd = rt.desc.names[nameIdx]
  let id = gExtCallSeq.fetchAdd(1, moAcquireRelease) + 1
  let fut = newFuture[ExtRawReply]("extCall")
  {.cast(gcsafe).}:
    gExtPending[id] = PendingCall(
      fut: fut, pluginIdx: pluginIdx, portSlot: src.portSlot, nameIdx: nameIdx
    )
  let bufPtr =
    if payload.len > 0:
      cast[ptr uint8](unsafeAddr payload[0])
    else:
      nil
  var st: ptr ExtCallState = nil
  defer:
    stRelease(st)
  case nd.dispatch
  of edInplace:
    # Synchronous contract: the reply must arrive before `invoke` returns.
    {.cast(gcsafe).}:
      gExtPending.del(id)
    let slot = inplaceClaim(id)
    if slot < 0:
      return err("EXTAPI: too many concurrent inplace calls")
    impl.impl.invoke(
      impl.impl.user, id, uint32(nameIdx), nd.name, bufPtr, csize_t(payload.len)
    )
    let filled = gExtInplace[slot].filled.load(moAcquire)
    let status = gExtInplace[slot].status
    var data = newSeq[byte](gExtInplace[slot].len)
    if data.len > 0:
      copyMem(addr data[0], gExtInplace[slot].buf, data.len)
    if not gExtInplace[slot].buf.isNil:
      c_free(gExtInplace[slot].buf)
      gExtInplace[slot].buf = nil
    gExtInplace[slot].id.store(0, moRelease)
    if not filled:
      return err("EXTAPI: inplace impl returned without reply")
    if status == ExtReplyOk:
      return ok(data)
    return err(fromBytes(data))
  of edWorkers:
    if rt.pool.isNil:
      {.cast(gcsafe).}:
        gExtPending.del(id)
      return err("EXTAPI: worker pool not running")
    st = newCallState()
    implAcquire(impl) # the worker's ref
    let m = ExtCallMsg(
      impl: impl,
      id: id,
      nameIdx: uint32(nameIdx),
      name: nd.name,
      buf: copyToC(payload),
      len: payload.len,
      st: st,
    )
    if not poolPush(rt.pool, m):
      if not m.buf.isNil:
        c_free(m.buf)
      stRelease(st) # the worker's ref, never handed over
      implRelease(impl)
      {.cast(gcsafe).}:
        gExtPending.del(id)
      return err("EXTAPI: worker queue full")
  of edBridge:
    # Invoke synchronously on this thread; the args buffer is borrowed for
    # the duration of the call only.
    impl.impl.invoke(
      impl.impl.user, id, uint32(nameIdx), nd.name, bufPtr, csize_t(payload.len)
    )
  proc abandon() =
    {.cast(gcsafe).}:
      gExtPending.del(id)
    if not st.isNil:
      var expected = 0
      if st.state.compareExchange(expected, 2):
        return # still queued: the worker drops it, `invoke` never runs
    if not impl.impl.cancel.isNil:
      impl.impl.cancel(impl.impl.user, id)

  var completed = false
  try:
    completed = await withTimeout(fut, timeout)
  except CancelledError as e:
    abandon()
    raise e
  if not completed:
    abandon()
    return err("EXTAPI: request timed out after " & $timeout)
  let rep = fut.read()
  if rep.status == ExtReplyOk:
    return ok(rep.data)
  return err(fromBytes(rep.data))

proc extSignal*(
    pluginIdx, nameIdx: int, ctx: BrokerContext, payload: seq[byte]
): Result[void, string] =
  ## One-way delivery of a signal to its foreign handler (`id = 0`, no reply).
  ## Runs on the bridge thread, inside the auto-wired signal handler.
  if pluginIdx < 0 or nameIdx < 0:
    return err("EXTAPI: plugin not registered")
  if not onBridgeThread():
    return
      err("EXTAPI: extHandler installed off the bridge thread is not supported yet")
  var impl: ptr ExtImplRef
  var rt: ptr ExtPluginRt
  {.cast(gcsafe).}:
    let key: SourceKey = (pluginIdx, nameIdx, uint32(ctx))
    if not gExtSources.hasKey(key):
      return err("EXTAPI: signal not provided by any plugin port")
    let src = gExtSources.getOrDefault(key)
    rt = gExtPlugins[pluginIdx]
    withLock(rt.lock):
      let ps = addr rt.ports[src.portSlot]
      if ps.open.load(moAcquire) and ps.gen.load(moAcquire) == src.gen:
        impl = ps.impl
        if not impl.isNil:
          implAcquire(impl)
  if impl.isNil:
    return err("EXTAPI: plugin port closed")
  let bufPtr =
    if payload.len > 0:
      cast[ptr uint8](unsafeAddr payload[0])
    else:
      nil
  let nd = rt.desc.names[nameIdx]
  if nd.dispatch == edWorkers:
    if rt.pool.isNil:
      implRelease(impl)
      return err("EXTAPI: worker pool not running")
    let m = ExtCallMsg(
      impl: impl, # the worker releases it
      id: 0,
      nameIdx: uint32(nameIdx),
      name: nd.name,
      buf: copyToC(payload),
      len: payload.len,
      st: nil,
    )
    if not poolPush(rt.pool, m):
      if not m.buf.isNil:
        c_free(m.buf)
      implRelease(impl)
      return err("EXTAPI: worker queue full")
    return ok()
  impl.impl.invoke(
    impl.impl.user, 0, uint32(nameIdx), nd.name, bufPtr, csize_t(payload.len)
  )
  implRelease(impl)
  ok()

proc extWarnSignalDropped*(name: string, reason: string) =
  ## Real-source logging helper for generated handlers (parseStmt code must
  ## not inline chronicles calls).
  warn "EXTAPI: signal not delivered", name = name, reason = reason

# ---------------------------------------------------------------------------
# Host function table (foreign threads)
# ---------------------------------------------------------------------------

proc postCtl(op: ExtCtlOp, pluginIdx, slot: int, gen: uint32, nameIdx: int): int32 =
  if not hostRunning():
    return ExtShutdown
  var m: ExtCtlMsg
  m.op = op
  m.pluginIdx = pluginIdx
  m.portSlot = slot
  m.gen = gen
  m.nameIdx = nameIdx
  if onBridgeThread():
    # Re-entrant call from an inline invoke: run directly, never wait on
    # ourselves.
    {.cast(gcsafe).}:
      runCtl(addr m)
    return m.rc
  initLock(m.lock)
  initCond(m.cond)
  defer:
    deinitCond(m.cond)
    deinitLock(m.lock)
  if not gExtHost.ctlRing.tryPush(addr m):
    return ExtAgain
  fireBrokerSignal(gExtHost.signal)
  withLock(m.lock):
    while not m.done:
      wait(m.cond, m.lock)
  m.rc

proc extOpen(
    host: pointer, ctx: uint32, impl: ptr ExtImplDesc, outPort: ptr uint64
): int32 {.cdecl, gcsafe, raises: [].} =
  if impl.isNil or outPort.isNil or impl.invoke.isNil:
    return ExtBadArg
  if impl.abiVersion != ExtAbiVersion:
    return ExtBadArg
  if not hostRunning():
    return ExtShutdown
  let p = findPlugin(impl.plugin)
  if p < 0:
    return ExtUnknownName
  let rt = gExtPlugins[p]
  if not impl.schemaHash.isNil and not rt.desc.schemaHash.isNil and
      c_strcmp(impl.schemaHash, rt.desc.schemaHash) != 0:
    return ExtSchemaMismatch
  withLock(rt.lock):
    for s in 0 ..< ExtMaxPorts:
      let ps = addr rt.ports[s]
      if not ps.open.load(moAcquire) and ps.impl.isNil:
        var g = ps.gen.load(moAcquire) + 1
        if g == 0:
          g = 1
        ps.gen.store(g, moRelease)
        let r = cast[ptr ExtImplRef](c_calloc(1, csize_t(sizeof(ExtImplRef))))
        r.refs.store(1, moRelease)
        r.impl = impl[]
        r.impl.plugin = nil # not retained
        r.impl.schemaHash = nil
        ps.impl = r
        ps.ctx = ctx
        ps.provided.store(0, moRelease)
        ps.open.store(true, moRelease)
        outPort[] = makePort(p, s, g)
        return ExtOk
  ExtAgain

proc extClose(host: pointer, port: uint64): int32 {.cdecl, gcsafe, raises: [].} =
  let lp = lookupPort(port)
  if not lp.ok:
    return ExtStale
  postCtl(ecoClose, splitPort(port).pluginIdx, lp.slot, lp.gen, -1)

proc nameOp(port: uint64, name: cstring, op: ExtCtlOp): int32 =
  let lp = lookupPort(port)
  if not lp.ok:
    return ExtStale
  let n = findName(lp.rt.desc, name)
  if n < 0:
    return ExtUnknownName
  if lp.rt.desc.names[n].kind == enkEvent:
    return ExtBadArg
  if op == ecoProvide:
    var caps = 0'u32
    withLock(lp.rt.lock):
      let impl = lp.rt.ports[lp.slot].impl
      if not impl.isNil:
        caps = impl.impl.caps
    let ok =
      case lp.rt.desc.names[n].dispatch
      of edInplace:
        (caps and ExtCapReplyInline) != 0
      of edBridge:
        (caps and ExtCapNonBlocking) != 0
      of edWorkers:
        true
    if not ok:
      return ExtDispatchMismatch
  postCtl(op, splitPort(port).pluginIdx, lp.slot, lp.gen, n)

proc extProvide(
    host: pointer, port: uint64, name: cstring
): int32 {.cdecl, gcsafe, raises: [].} =
  nameOp(port, name, ecoProvide)

proc extWithdraw(
    host: pointer, port: uint64, name: cstring
): int32 {.cdecl, gcsafe, raises: [].} =
  nameOp(port, name, ecoWithdraw)

proc extReply(
    host: pointer, port: uint64, id: uint64, status: int32, buf: ptr uint8, len: csize_t
): int32 {.cdecl, gcsafe, raises: [].} =
  if len > 0 and buf.isNil:
    return ExtBadArg
  if not hostRunning():
    return ExtShutdown
  let lp = lookupPort(port)
  if not lp.ok or id == 0:
    return ExtStale
  if inplaceFill(id, status, buf, int(len)):
    return ExtOk
  var m = ExtReplyMsg(callId: id, status: status, len: int(len))
  if len > 0:
    m.buf = cast[ptr uint8](c_malloc(len))
    copyMem(m.buf, buf, int(len))
  if not gExtHost.replyRing.tryPush(m):
    if not m.buf.isNil:
      c_free(m.buf)
    return ExtAgain
  fireBrokerSignal(gExtHost.signal)
  ExtOk

proc extEmit(
    host: pointer, port: uint64, name: cstring, buf: ptr uint8, len: csize_t
): int32 {.cdecl, gcsafe, raises: [].} =
  if len > 0 and buf.isNil:
    return ExtBadArg
  if not hostRunning():
    return ExtShutdown
  let lp = lookupPort(port)
  if not lp.ok:
    return ExtStale
  let n = findName(lp.rt.desc, name)
  if n < 0:
    return ExtUnknownName
  if lp.rt.desc.names[n].kind != enkEvent:
    return ExtBadArg
  var m = ExtEventMsg(
    pluginIdx: splitPort(port).pluginIdx,
    nameIdx: n,
    ctx: lp.rt.ports[lp.slot].ctx,
    len: int(len),
  )
  if len > 0:
    m.buf = cast[ptr uint8](c_malloc(len))
    copyMem(m.buf, buf, int(len))
  if not gExtHost.eventRing.tryPush(m):
    if not m.buf.isNil:
      c_free(m.buf)
    return ExtAgain
  fireBrokerSignal(gExtHost.signal)
  ExtOk

proc copyOut(src: cstring, n: int, outBuf: ptr ptr uint8, outLen: ptr csize_t): int32 =
  if outBuf.isNil or outLen.isNil:
    return ExtBadArg
  let b = cast[ptr uint8](c_malloc(csize_t(max(n, 1))))
  if n > 0:
    copyMem(b, src, n)
  outBuf[] = b
  outLen[] = csize_t(n)
  ExtOk

proc extListApis(
    host: pointer, plugin: cstring, outBuf: ptr ptr uint8, outLen: ptr csize_t
): int32 {.cdecl, gcsafe, raises: [].} =
  let p = findPlugin(plugin)
  if p < 0:
    return ExtUnknownName
  let d = gExtPlugins[p].desc
  copyOut(d.listApisBuf, d.listApisLen, outBuf, outLen)

proc extGetSchema(
    host: pointer, plugin: cstring, outBuf: ptr ptr uint8, outLen: ptr csize_t
): int32 {.cdecl, gcsafe, raises: [].} =
  let p = findPlugin(plugin)
  if p < 0:
    return ExtUnknownName
  let d = gExtPlugins[p].desc
  copyOut(d.schemaBuf, d.schemaLen, outBuf, outLen)

proc extFreeBuffer(host: pointer, buf: ptr uint8) {.cdecl, gcsafe, raises: [].} =
  if not buf.isNil:
    c_free(buf)

proc extSchemaHash(
    host: pointer, plugin: cstring, hashOut: ptr char
): int32 {.cdecl, gcsafe, raises: [].} =
  if hashOut.isNil:
    return ExtBadArg
  let p = findPlugin(plugin)
  if p < 0:
    return ExtUnknownName
  let h = gExtPlugins[p].desc.schemaHash
  let n = (if h.isNil: 0 else: int(c_strlen(h)))
  if n > 0:
    copyMem(hashOut, h, min(n, 32))
  cast[ptr UncheckedArray[char]](hashOut)[min(n, 32)] = '\0'
  ExtOk

proc extHostTable*(): ptr ExtHostTable =
  ## The function table handed to foreign plugins (`broker_ext_host`).
  addr gExtHostTable

# ---------------------------------------------------------------------------
# Bridge thread lifecycle (exe mode)
# ---------------------------------------------------------------------------

proc bridgeThreadProc(h: ptr ExtHostRt) {.thread.} =
  h.signal = getOrInitBrokerSignal()
  h.bridgeTid.store(osThreadId(), moRelease)
  registerBrokerPoller(ctlPoll)
  registerBrokerPoller(replyPoll)
  registerBrokerPoller(eventPoll)
  ensureBrokerDispatchStarted()
  h.ready.store(1, moRelease)

  proc awaitStop(flag: ptr Atomic[int]) {.async: (raises: []).} =
    while flag[].load(moAcquire) != 1:
      let s = catch:
        await sleepAsync(milliseconds(5))
      if s.isErr():
        discard

  waitFor awaitStop(addr h.stopFlag)
  # Close every open port: withdraws all names, fails pending calls.
  {.cast(gcsafe).}:
    let n = gExtPluginCount.load(moAcquire)
    for p in 0 ..< n:
      let rt = gExtPlugins[p]
      for s in 0 ..< ExtMaxPorts:
        let ps = addr rt.ports[s]
        if ps.open.load(moAcquire):
          discard bridgeClose(p, s, ps.gen.load(moAcquire))
    failPending(
      proc(c: PendingCall): bool =
        true,
      "EXTAPI: host shut down",
    )
  # Drain any ctl message that raced the stop so its caller does not hang.
  discard ctlPoll()
  teardownBrokerThread()
  closeThreadDispatcherSelector()

proc extLoadPlugin*(path: string): Result[void, string] =
  ## Exe mode: load a plugin shared library and call its
  ## `broker_ext_plugin_entry(host)`. The handle is intentionally never
  ## unloaded: foreign threads or callbacks may outlive any unload point.
  if not hostRunning():
    return err("EXTAPI: host not started (call ExtHost.start() first)")
  let lib = loadLib(path)
  if lib.isNil:
    return err("EXTAPI: cannot load plugin library '" & path & "'")
  let sym = symAddr(lib, "broker_ext_plugin_entry")
  if sym.isNil:
    return err("EXTAPI: '" & path & "' does not export broker_ext_plugin_entry")
  type EntryFn = proc(host: ptr ExtHostTable): int32 {.cdecl, gcsafe, raises: [].}
  let rc = cast[EntryFn](sym)(addr gExtHostTable)
  if rc != ExtOk:
    return err("EXTAPI: plugin entry of '" & path & "' failed with " & $rc)
  ok()

proc extHostStart*(): Result[void, string] =
  ## Start the shared EXTAPI bridge thread (exe mode). Idempotent.
  if hostRunning():
    return ok()
  if gExtHost.isNil:
    gExtHost = cast[ptr ExtHostRt](createShared(ExtHostRt, 1))
    gExtHost.ctlRing.init(ExtRingCap)
    gExtHost.replyRing.init(ExtRingCap)
    gExtHost.eventRing.init(ExtRingCap)
  gExtHost.ready.store(0, moRelease)
  gExtHost.stopFlag.store(0, moRelease)
  gExtHostTable = ExtHostTable(
    abiVersion: ExtAbiVersion,
    host: gExtHost,
    open: extOpen,
    close: extClose,
    provide: extProvide,
    withdraw: extWithdraw,
    reply: extReply,
    emit: extEmit,
    listApis: extListApis,
    getSchema: extGetSchema,
    freeBuffer: extFreeBuffer,
    schemaHash: extSchemaHash,
  )
  try:
    createThread(gExtBridgeThread, bridgeThreadProc, gExtHost)
  except ResourceExhaustedError as e:
    return err("EXTAPI: cannot start bridge thread: " & e.msg)
  # Worker pools: one per plugin that has `workers` names.
  for p in 0 ..< gExtPluginCount.load(moAcquire):
    let rt = gExtPlugins[p]
    let n = rt.desc.workers
    if n <= 0 or not rt.pool.isNil:
      continue
    let pool = cast[ptr ExtWorkerPool](createShared(ExtWorkerPool, 1))
    pool.q.init(ExtRingCap)
    initLock(pool.lock)
    initCond(pool.cond)
    pool.n = n
    let threads = cast[ptr UncheckedArray[Thread[ptr ExtWorkerPool]]](createShared(
      Thread[ptr ExtWorkerPool], n
    ))
    pool.threads = threads
    for i in 0 ..< n:
      try:
        createThread(threads[i], workerProc, pool)
      except ResourceExhaustedError as e:
        return err("EXTAPI: cannot start worker thread: " & e.msg)
    rt.pool = pool
  while gExtHost.ready.load(moAcquire) != 1:
    os.sleep(1)
  gExtHost.running.store(true, moRelease)
  ok()

proc extHostStop*() =
  ## Stop the bridge thread: closes every port, fails pending calls, clears
  ## every auto-wired provider. Foreign calls afterwards return SHUTDOWN.
  if not hostRunning():
    return
  gExtHost.running.store(false, moRelease)
  gExtHost.stopFlag.store(1, moRelease)
  fireBrokerSignal(gExtHost.signal)
  joinAndReleaseThread(gExtBridgeThread)
  gExtHost.bridgeTid.store(0, moRelease)
  # Stop worker pools after the bridge: no new work can be queued now.
  # A worker blocked inside a foreign `invoke` delays this join (documented
  # in EXTAPI_PLAN §11; a join timeout + leak is a follow-up).
  for p in 0 ..< gExtPluginCount.load(moAcquire):
    let rt = gExtPlugins[p]
    let pool = rt.pool
    if pool.isNil:
      continue
    withLock(pool.lock):
      pool.stop = true
      broadcast(pool.cond)
    let threads = cast[ptr UncheckedArray[Thread[ptr ExtWorkerPool]]](pool.threads)
    for i in 0 ..< pool.n:
      joinAndReleaseThread(threads[i])
    var m: ExtCallMsg
    while pool.q.tryPop(m):
      if not m.buf.isNil:
        c_free(m.buf)
      stRelease(m.st)
      implRelease(m.impl)
    deallocShared(pool.threads)
    deinitCond(pool.cond)
    deinitLock(pool.lock)
    rt.pool = nil
    deallocShared(pool)
  # Payloads that raced the stop: free them.
  var rm: ExtReplyMsg
  while gExtHost.replyRing.tryPop(rm):
    if not rm.buf.isNil:
      c_free(rm.buf)
  var em: ExtEventMsg
  while gExtHost.eventRing.tryPop(em):
    if not em.buf.isNil:
      c_free(em.buf)
  # A control call that raced the stop: answer it so its caller never hangs.
  var m: ptr ExtCtlMsg
  while gExtHost.ctlRing.tryPop(m):
    withLock(m.lock):
      m.rc = ExtShutdown
      m.done = true
      signal(m.cond)

{.pop.}
