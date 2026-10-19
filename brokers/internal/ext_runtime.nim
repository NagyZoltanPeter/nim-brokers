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
##   never the Nim heap. They are compiled with checks, stack traces and line
##   traces off (marked `foreign-thread path (M2)`), so they never push a Nim
##   frame and never raise (raising would allocate on an unregistered thread).
##   The only Nim runtime state they touch is the goto-exceptions error flag
##   (ORC), a native-TLS read of a zero-initialised per-thread variable, which
##   is valid on any OS thread; `--tlsEmulation:on` is therefore rejected. All
##   of that holds under
##   `--mm:refc` (thread-local heaps) and `--mm:orc` alike.
## - All Nim-heap state (pending calls, futures) lives in threadvars of the
##   bridge thread and is only touched there. The source table (which port
##   serves which name on which ctx) is a fixed, lock-protected array so any
##   thread can check availability or run an `inplace` / one-way call.
## - Messages crossing threads are POD; payload buffers are `c_malloc`ed by
##   the producer and `c_free`d by the consumer.

{.push raises: [].}

when compileOption("tlsEmulation"):
  {.
    error:
      "EXTAPI needs native thread-local storage: foreign plugin threads call " &
      "into ext_runtime, which emulated TLS cannot serve (drop --tlsEmulation:on)"
  .}

import std/[atomics, locks, tables, os, dynlib, strutils, algorithm, json]
when not defined(windows):
  from std/posix import pthread_self
import system/ansi_c
import chronos, chronicles, results
import ../broker_context, ./mt_broker_common, ./ext_shapes, ./ext_types

export ext_types

export results, dynlib

when defined(windows):
  proc extGetEnvVarA(
    name: cstring, buf: ptr char, size: uint32
  ): uint32 {.importc: "GetEnvironmentVariableA", stdcall, header: "<windows.h>".}

else:
  proc extCGetEnv(name: cstring): cstring {.importc: "getenv", header: "<stdlib.h>".}

template extEnvFlagSet(name: cstring): bool =
  ## Env var `name` set to a non-empty value other than "0" — libc only, safe
  ## on a foreign thread (same rule as `<lib>_verifySchema`).
  when defined(windows):
    var buf: array[2, char]
    let n = extGetEnvVarA(name, addr buf[0], 2)
    n >= 2'u32 or (n == 1'u32 and buf[0] != '0')
  else:
    let p = extCGetEnv(name)
    not p.isNil and p[0] != '\0' and not (p[0] == '0' and p[1] == '\0')

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
  ExtCapNative* = 1'u32 shl 31
    ## Internal: the port is a native import (K1) loaded by `extImportLoad`;
    ## an auto-wired `inplace` name may then skip CBOR entirely.

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

  ExtInstallFn* = proc(ctx: BrokerContext, wirePublic: bool): Result[void, string] {.
    nimcall, gcsafe, raises: []
  .}
    ## Runs on the bridge thread when a port provides this name on `ctx`:
    ## installs the hidden `<T>ExtLane` provider (requests) and, with
    ## `wirePublic` (autoWire), the forwarder into the public slot. `err` only
    ## when the public slot could not be wired (it is held by someone else).
  ExtUninstallFn* = proc(
    ctx: BrokerContext, siblingWired, publicWired, siblingProvided: bool
  ) {.nimcall, gcsafe, raises: [].}
    ## Runs on the bridge thread when the providing port withdraws the name.
    ## `publicWired`: this slot was auto-wired; `siblingWired` / `siblingProvided`:
    ## the other signature slot of the same request broker is still auto-wired /
    ## provided, so the public broker / the hidden lane must stay.
  ExtEmitFn* = proc(ctx: BrokerContext, buf: ptr uint8, len: int): Result[void, string] {.
    nimcall, gcsafe, raises: []
  .} ## Runs on the bridge thread: decode an event payload and emit it.

  ExtTunnelCallFn* = proc(
    ctx: BrokerContext, payload: seq[byte]
  ): Future[Result[seq[byte], string]] {.nimcall, async: (raises: []), gcsafe.}
    ## ExtTunnel adapter for one request slot: decode → typed `request` → encode.
  ExtTunnelSignalFn* = proc(
    ctx: BrokerContext, payload: seq[byte]
  ): Result[void, string] {.nimcall, gcsafe, raises: [].}
  ExtTunnelEventCb* = proc(payload: seq[byte]) {.gcsafe, raises: [].}
  ExtTunnelListenFn* = proc(
    ctx: BrokerContext, cb: ExtTunnelEventCb
  ): Result[uint64, string] {.nimcall, gcsafe, raises: [].}
    ## Returns a token for `ExtTunnelUnlistenFn` (valid on the listening thread).
  ExtTunnelUnlistenFn* = proc(ctx: BrokerContext, token: uint64): Future[void] {.
    nimcall, async: (raises: []), gcsafe
  .}

  ExtImportResolveFn* = proc(lib: LibHandle): string {.nimcall, gcsafe, raises: [].}
    ## K1: resolve the broker's C symbols from `lib`; "" or the missing names.

  ExtNameDesc* = object
    name*: cstring
    kind*: ExtNameKind
    dispatch*: ExtDispatch
    install*: ExtInstallFn
    uninstall*: ExtUninstallFn
    emitFn*: ExtEmitFn
    sibling*: int ## nameIdx of the other slot of a dual-slot request, or -1
    autoWire*: bool ## wire the public slot when a port provides this name
    tunnelCall*: ExtTunnelCallFn
    tunnelSignal*: ExtTunnelSignalFn
    tunnelListen*: ExtTunnelListenFn
    tunnelUnlisten*: ExtTunnelUnlistenFn
    importLib*: cstring ## K1: `dynlib` pattern (std/dynlib loadLibPattern)
    importResolve*: ExtImportResolveFn ## K1: resolve this broker's symbols
    peerSig*: cstring ## K2: "args|payload" signature compared with the peer schema

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
    importInvoke*: ExtInvokeFn ## K1: the generated trampoline dispatcher
    loadEager*: bool ## K1: load on `ExtHost.start()` for DefaultBrokerContext
    peerLib*: cstring ## K2: the peer nim-brokers library's name (symbol prefix)
    peerDynlib*: cstring ## K2: `dynlib` pattern of the peer library
    skipSchemaEnv*: cstring ## "<PLUGIN>_SKIP_SCHEMA_CHECK" (static storage)

  ExtImplRef = object
    refs: Atomic[int]
    closed: Atomic[bool]
      ## Set when its port closes: queued worker messages and late one-way
      ## deliveries for it are dropped instead of invoked.
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
    threads: pointer ## ptr UncheckedArray[Thread[ExtWorkerArg]]
    exit: ptr UncheckedArray[Atomic[int32]]
      ## per worker: 0 running, 1 left `workerProc`, 2 joined
    started: int ## threads created (for an orphaned pool's reap)
    leaked: int ## workers still running when this pool was orphaned
    next: ptr ExtWorkerPool ## orphan list link

  ExtWorkerArg = tuple[pool: ptr ExtWorkerPool, idx: int]

  ExtInplaceSlot = object
    ## A synchronous `inplace` call waiting for its reply inside `invoke`.
    ## `ctl` packs `(gen shl 32) or state` so every transition is one
    ## generation-checked CAS (as the MT response slots): a late or duplicate
    ## reply carries an old generation or finds the slot already filled, and
    ## is dropped — it can never land in a later call that reuses the slot.
    ctl: Atomic[uint64]
    port: uint64 ## the source port; a reply from any other port is dropped
    status: int32
    buf: ptr uint8
    len: int

  ExtPluginRt = object
    desc: ptr ExtPluginDesc
    lock: Lock
    loadLock: Lock
      ## Serialises `extImportLoad` / `extPeerLoad`: the "already loaded on
      ## this ctx" check, the one-time peer resolve and the port setup.
    ports: array[ExtMaxPorts, ExtPortSlot]
    pool: ptr ExtWorkerPool
    loadError: cstring ## K1: c_malloc'd, last `extImportLoad` diagnostics
    resolved: uint64 ## K1: names whose symbols resolved (bit per nameIdx)
    peerFns: ptr PeerFns ## K2: resolved peer C ABI (once per process)
    peers: array[ExtMaxPorts, ptr ExtPeerUser] ## K2: one per loaded host ctx

  PeerRespCb = proc(
    user: pointer, reqId: uint64, status: int32, buf: pointer, len: int32
  ) {.cdecl, gcsafe, raises: [].}
  PeerEventCb = proc(
    ctx: uint32, eventName: cstring, buf: pointer, len: int32, user: pointer
  ) {.cdecl, gcsafe, raises: [].}

  PeerFns = object
    ## The fixed 13-function C ABI of a nim-brokers library (the parts used).
    initialize: proc() {.cdecl, gcsafe, raises: [].}
    createContext: proc(errOut: ptr cstring): uint32 {.cdecl, gcsafe, raises: [].}
    shutdown: proc(ctx: uint32): int32 {.cdecl, gcsafe, raises: [].}
    allocBuffer: proc(size: int32): pointer {.cdecl, gcsafe, raises: [].}
    freeBuffer: proc(buf: pointer) {.cdecl, gcsafe, raises: [].}
    call: proc(
      ctx: uint32,
      api: cstring,
      req: pointer,
      reqLen: int32,
      respOut: ptr pointer,
      respLenOut: ptr int32,
    ): int32 {.cdecl, gcsafe, raises: [].}
    callAsync: proc(
      ctx: uint32,
      api: cstring,
      req: pointer,
      reqLen: int32,
      reqId: uint64,
      timeoutMs: uint32,
      cb: PeerRespCb,
      user: pointer,
    ): int32 {.cdecl, gcsafe, raises: [].}
    subscribe: proc(ctx: uint32, ev: cstring, cb: PeerEventCb, user: pointer): uint64 {.
      cdecl, gcsafe, raises: []
    .}
    unsubscribe:
      proc(ctx: uint32, ev: cstring, h: uint64): int32 {.cdecl, gcsafe, raises: [].}
    getSchema:
      proc(outBuf: ptr pointer, outLen: ptr int32): int32 {.cdecl, gcsafe, raises: [].}

  ExtPeerUser = object
    ## `user` of a K2 synthetic port; libc-allocated. Two refs: the port
    ## (dropped by its `release`) and `rt.peers` (dropped by `shutdownPeers`
    ## after the peer context is shut down); the last one frees it.
    refs: Atomic[int]
    port: uint64
    hostCtx: uint32 ## the host context its port serves
    peerCtx: uint32
    fns: ptr PeerFns
    subs: array[ExtMaxNames, uint64] ## event subscriptions by nameIdx

  ExtImportUser = object ## `user` of a K1 synthetic port: lets the trampolines reply.
    port: uint64

  ExtCtlOp = enum
    ecoProvide
    ecoWithdraw
    ecoClose
    ecoCloseCtx ## close every open port on `ctx` (lib `_shutdown`)

  ExtCtlMsg = object
    ## Lives on the waiting caller's stack; the caller blocks on `cond` until
    ## the bridge sets `done`.
    op: ExtCtlOp
    pluginIdx: int
    portSlot: int
    gen: uint32
    nameIdx: int
    ctx: uint32 ## ecoCloseCtx only
    rc: int32
    done: bool
    lock: Lock
    cond: Cond

  ExtReplyMsg = object
    port: uint64 ## the replying port; must be the call's source
    callId: uint64
    status: int32
    buf: ptr uint8 ## c_malloc, consumer frees
    len: int

  ExtEventMsg = object
    port: uint64 ## delivered only while this port is still open
    pluginIdx: int
    nameIdx: int
    ctx: uint32
    buf: ptr uint8 ## c_malloc, consumer frees
    len: int

  ExtHostRt = object
    running: Atomic[bool]
    ctlLock: Lock
      ## Serialises "is the host running" + "push a control message" against
      ## `extHostStop` flipping `running`: nothing is pushed after stop's
      ## final control drain, so no `postCtl` caller can wait forever.
    ready: Atomic[int]
    stopFlag: Atomic[int]
    signal: ptr BrokerSignalShared
    bridgeTid: Atomic[uint64]
    ctlRing: ExtRing[ptr ExtCtlMsg]
    replyRing: ExtRing[ExtReplyMsg]
    eventRing: ExtRing[ExtEventMsg]
    sigRing: ExtRing[ExtCallMsg]
      ## `bridge`-dispatch signals sent from other threads: the bridge invokes
      ## them, so a `bridge` plugin is only ever invoked on one thread.

  PendingCall = object
    fut: Future[ExtRawReply]
    pluginIdx: int
    portSlot: int
    portGen: uint32 ## with pluginIdx / portSlot: the only port whose reply counts
    nameIdx: int
    impl: ptr ExtImplRef
      ## Borrowed: `extCall` holds a ref until its future completes, which is
      ## after the pending entry is gone.
    st: ptr ExtCallState ## borrowed likewise; nil unless `workers` dispatch

  ExtRawReply* = object
    status*: int32
    data*: seq[byte]

  SourceKey = tuple[pluginIdx: int, nameIdx: int, ctx: uint32]

  ExtShared = object
    ## One provided (plugin, name, ctx): which port serves it, and whether the
    ## bridge auto-wired the public slot for it.
    used: bool
    pluginIdx: int
    nameIdx: int
    ctx: uint32
    portSlot: int
    gen: uint32
    wired: bool
    native: bool ## served by a K1 import port

# ---------------------------------------------------------------------------
# Ring
# ---------------------------------------------------------------------------

proc init[T](r: var ExtRing[T], cap: int) =
  # Nim's shared heap, like the structs that hold the ring: under refc that
  # heap is not malloc, so a malloc'd buffer referenced only from it would
  # look unreachable to LeakSanitizer.
  r.buf = cast[ptr UncheckedArray[T]](allocShared0(cap * sizeof(T)))
  r.cap = cap
  r.head = 0
  r.count = 0
  initLock(r.lock)

proc deinit[T](r: var ExtRing[T]) =
  ## Free the ring's storage; the ring must be empty and unused.
  if not r.buf.isNil:
    deallocShared(r.buf)
    r.buf = nil
  r.cap = 0
  deinitLock(r.lock)

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
proc tryPush[T](r: var ExtRing[T], v: T): bool =
  withLock(r.lock):
    if r.count >= r.cap:
      return false
    r.buf[(r.head + r.count) mod r.cap] = v
    inc r.count
  true

{.pop.}

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
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
{.pop.}

var gExtPlugins: array[ExtMaxPlugins, ptr ExtPluginRt]
var gExtPluginCount: Atomic[int]
var gExtRegLock: Lock
var gExtRegLockInit: Atomic[int]
var gExtHost: ptr ExtHostRt
var gExtHostTable: ExtHostTable
var gExtCallSeq: Atomic[uint64]
var gExtBridgeThread: Thread[ptr ExtHostRt]

const
  hsStopped = 0
  hsStarting = 1
  hsRunning = 2
  hsStopping = 3

var gExtHostState: Atomic[int]
  ## Host lifecycle: start / stop CAS into it, so concurrent `start` calls run
  ## one bridge and a stop never overlaps a start.
var gExtIsWorker {.threadvar.}: bool
var gExtLibOwnsHost: Atomic[bool]
  ## Lib mode: `<lib>_extHost()` started the host, so the library stops it
  ## when its last context shuts down (`extLibIdle`).
var gExtLibJoinTimeoutMs: Atomic[int]
  ## Lib mode: the worker join bound `extLibIdle` stops the host with
  ## (`exportExtHost(…, workerJoinTimeoutMs)`); 0 = wait forever.
var gExtOrphanPools: ptr ExtWorkerPool
  ## Pools whose stop timed out on a worker stuck in a foreign `invoke`: kept
  ## alive (the worker still uses the lock, queue and its `Thread`) and
  ## reaped by a later start / stop once every worker has left. Touched only
  ## by the start / stop owner (serialised by `gExtHostState`).
var gExtLeakedWorkers: Atomic[int] ## workers of orphaned pools still running

const ExtDefaultJoinTimeout* = chronos.seconds(5)
  ## Default bound for joining a plugin's worker threads at host stop.

when defined(extTestHooks):
  var extTestBridgeStarts*: Atomic[int] ## bridge threads started
  var extTestBridgeExits*: Atomic[int] ## bridge threads finished
  var extTestWorkerStarts*: Atomic[int] ## worker threads started
  var extTestWorkerExits*: Atomic[int] ## worker threads finished
  var extTestFailWorkerAt*: Atomic[int]
    ## > 0: the n-th worker thread of the next start fails to start.
  proc extTestBridgeThread*(): uint64 =
    ## OS id of the running bridge thread (0 when stopped) — the same value
    ## a C plugin gets from `pthread_self()` / `GetCurrentThreadId()`.
    if gExtHost.isNil:
      0'u64
    else:
      gExtHost.bridgeTid.load(moAcquire)

  var extTestPauseEvents*: Atomic[bool]
    ## true: the bridge leaves queued events in the ring (delivery-order tests).
const ExtMaxInplace = 256
var gExtInplace: array[ExtMaxInplace, ExtInplaceSlot]

const ExtMaxShared = 1024
var gExtShared: array[ExtMaxShared, ExtShared]
var gExtSharedLock: Lock

# Bridge-thread-local state.
var gExtPending {.threadvar.}: Table[uint64, PendingCall]

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

proc fromBytes(b: seq[byte]): string =
  result = newString(b.len)
  if b.len > 0:
    copyMem(addr result[0], unsafeAddr b[0], b.len)

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
proc osThreadId(): uint64 =
  when defined(windows):
    uint64(extGetCurrentThreadId())
  else:
    cast[uint64](pthread_self())

{.pop.}

proc ensureRegLock() =
  var expected = 0
  if gExtRegLockInit.compareExchange(expected, 1):
    initLock(gExtRegLock)
    initLock(gExtSharedLock)
    gExtRegLockInit.store(2, moRelease)
  else:
    while gExtRegLockInit.load(moAcquire) != 2:
      discard

proc extRegisterPlugin*(desc: ptr ExtPluginDesc): int =
  ## Called once per `registerExtPlugin` at module init. Returns the plugin
  ## index used by the generated stubs.
  ensureRegLock()
  withLock(gExtRegLock):
    # Idempotent: a second registration of the same descriptor (or name) must
    # not create a second, unreachable plugin. Module init itself runs once
    # (doc/FFI_API.md § "Module initialisation"); `<lib>_initialize` used to
    # re-run it on POSIX, which is what first hit this path.
    for i in 0 ..< gExtPluginCount.load(moAcquire):
      if gExtPlugins[i].desc == desc or
          c_strcmp(gExtPlugins[i].desc.name, desc.name) == 0:
        gExtPlugins[i].desc = desc
        return i
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
    initLock(rt.loadLock)
    gExtPlugins[idx] = rt
    gExtPluginCount.store(idx + 1, moRelease)
    return idx

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
proc findPlugin(name: cstring): int =
  if name.isNil:
    return -1
  let n = gExtPluginCount.load(moAcquire)
  for i in 0 ..< n:
    let rt = gExtPlugins[i]
    if not rt.isNil and c_strcmp(rt.desc.name, name) == 0:
      return i
  -1

{.pop.}

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
proc findName(desc: ptr ExtPluginDesc, name: cstring): int =
  if name.isNil:
    return -1
  for i in 0 ..< desc.nameCount:
    if c_strcmp(desc.names[i].name, name) == 0:
      return i
  -1

{.pop.}

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
proc makePort(pluginIdx, slot: int, gen: uint32): uint64 =
  (uint64(pluginIdx) shl 48) or (uint64(slot) shl 32) or uint64(gen)

{.pop.}

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
proc splitPort(port: uint64): tuple[pluginIdx, slot: int, gen: uint32] =
  (
    int(port shr 48),
    int((port shr 32) and 0xFFFF'u64),
    uint32(port and 0xFFFF_FFFF'u64),
  )

{.pop.}

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
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

{.pop.}

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
proc implAcquire(r: ptr ExtImplRef) =
  discard r.refs.fetchAdd(1, moAcquireRelease)

{.pop.}

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
proc implRelease(r: ptr ExtImplRef) =
  if r.refs.fetchSub(1, moAcquireRelease) == 1:
    if not r.impl.release.isNil:
      r.impl.release(r.impl.user)
    c_free(r)

{.pop.}

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
proc stRelease(st: ptr ExtCallState) =
  if not st.isNil and st.refs.fetchSub(1, moAcquireRelease) == 1:
    c_free(st)

{.pop.}

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

proc workerProc(arg: ExtWorkerArg) {.thread.} =
  ## Plain worker: no chronos loop, never touches broker state. Runs the
  ## foreign `invoke` (which may block this thread only). A worker still in
  ## `invoke` when the host stop's join bound expires is left running: its
  ## pool is orphaned (kept alive) and reaped once it has left.
  let pool = arg.pool
  when defined(extTestHooks):
    discard extTestWorkerStarts.fetchAdd(1)
  gExtIsWorker = true
  while true:
    var m: ExtCallMsg
    var got = false
    var stopping = false
    withLock(pool.lock):
      while true:
        stopping = pool.stop
        if pool.q.tryPop(m):
          got = true
          break
        if pool.stop:
          break
        wait(pool.cond, pool.lock)
    if not got:
      break
    # Never invoke once the host is stopping or the port is closed: the caller
    # already got an error (at-most-once), and the plugin may be gone.
    var expected = 0
    if not stopping and not m.impl.closed.load(moAcquire) and
        (m.st.isNil or m.st.state.compareExchange(expected, 1)):
      m.impl.impl.invoke(
        m.impl.impl.user, m.id, m.nameIdx, m.name, m.buf, csize_t(m.len)
      )
    if not m.buf.isNil:
      c_free(m.buf)
    stRelease(m.st)
    implRelease(m.impl)
  # Last touch of the pool: from here on the stopper may join and free it.
  pool.exit[arg.idx].store(1, moRelease)
  when defined(extTestHooks):
    discard extTestWorkerExits.fetchAdd(1) # after `exit`: tests reap on it

const
  ExtInplaceIdBit = 1'u64 shl 63 ## inplace call ids: bit 63 | slot << 32 | gen
  isFree = 0'u64
  isClaimed = 1'u64
  isFilling = 2'u64
  isFilled = 3'u64

template slotState(c: uint64): uint64 =
  c and 0xFFFF_FFFF'u64

template slotGen(c: uint64): uint64 =
  c shr 32

proc inplaceClaim(port: uint64): tuple[slot: int, id: uint64] =
  ## Claim a free slot; the returned call id names the slot and its new
  ## generation, so `inplaceFill` needs no search. (-1, 0) when all are busy.
  for i in 0 ..< ExtMaxInplace:
    let c = gExtInplace[i].ctl.load(moAcquire)
    if slotState(c) == isFree:
      var g = (slotGen(c) + 1) and 0xFFFF_FFFF'u64
      if g == 0:
        g = 1
      var expected = c
      if gExtInplace[i].ctl.compareExchange(expected, (g shl 32) or isClaimed):
        gExtInplace[i].port = port
        gExtInplace[i].buf = nil
        gExtInplace[i].len = 0
        return (i, ExtInplaceIdBit or (uint64(i) shl 32) or g)
  (-1, 0'u64)

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
proc inplaceFill(port, id: uint64, status: int32, buf: ptr uint8, len: int): bool =
  ## Called from `extReply` (any thread): `true` when `id` is an inplace call
  ## id — the reply is then stored in its slot or, if late / duplicate / from
  ## another port, dropped. `false`: not an inplace id (use the reply ring).
  if (id and ExtInplaceIdBit) == 0:
    return false
  let i = int((id shr 32) and 0x7FFF_FFFF'u64)
  if i >= ExtMaxInplace:
    return true
  let g = id and 0xFFFF_FFFF'u64
  var expected = (g shl 32) or isClaimed
  if not gExtInplace[i].ctl.compareExchange(expected, (g shl 32) or isFilling):
    return true # first reply wins; late / duplicate replies are dropped
  if gExtInplace[i].port != port:
    gExtInplace[i].ctl.store((g shl 32) or isClaimed, moRelease)
    return true # not the call's source port
  gExtInplace[i].status = status
  gExtInplace[i].len = 0
  if len > 0:
    let copy = cast[ptr uint8](c_malloc(csize_t(len)))
    if copy.isNil:
      gExtInplace[i].status = ExtReplyErr # out of memory: answer, empty error
    else:
      copyMem(copy, buf, len)
      gExtInplace[i].buf = copy
      gExtInplace[i].len = len
  gExtInplace[i].ctl.store((g shl 32) or isFilled, moRelease)
  true

{.pop.}

proc sharedFind(
    p, n: int, ctx: uint32
): tuple[found: bool, slot: int, gen: uint32, wired: bool, native: bool] =
  withLock(gExtSharedLock):
    for i in 0 ..< ExtMaxShared:
      let e = gExtShared[i]
      if e.used and e.pluginIdx == p and e.nameIdx == n and e.ctx == ctx:
        return (true, e.portSlot, e.gen, e.wired, e.native)
  (false, 0, 0'u32, false, false)

proc sharedAdd(p, n: int, ctx: uint32, slot: int, gen: uint32, native = false): int32 =
  withLock(gExtSharedLock):
    var free = -1
    for i in 0 ..< ExtMaxShared:
      let e = gExtShared[i]
      if e.used:
        if e.pluginIdx == p and e.nameIdx == n and e.ctx == ctx:
          return ExtAlreadyProvided
      elif free < 0:
        free = i
    if free < 0:
      return ExtAgain
    gExtShared[free] = ExtShared(
      used: true,
      pluginIdx: p,
      nameIdx: n,
      ctx: ctx,
      portSlot: slot,
      gen: gen,
      native: native,
    )
  ExtOk

proc sharedSetWired(p, n: int, ctx: uint32, wired: bool) =
  withLock(gExtSharedLock):
    for i in 0 ..< ExtMaxShared:
      if gExtShared[i].used and gExtShared[i].pluginIdx == p and
          gExtShared[i].nameIdx == n and gExtShared[i].ctx == ctx:
        gExtShared[i].wired = wired

proc sharedDel(p, n: int, ctx: uint32, slot: int): tuple[found, wired: bool] =
  withLock(gExtSharedLock):
    for i in 0 ..< ExtMaxShared:
      if gExtShared[i].used and gExtShared[i].pluginIdx == p and
          gExtShared[i].nameIdx == n and gExtShared[i].ctx == ctx and
          gExtShared[i].portSlot == slot:
        let w = gExtShared[i].wired
        gExtShared[i] = ExtShared()
        return (true, w)
  (false, false)

proc acquireSource(
    p, n: int, ctx: uint32
): tuple[impl: ptr ExtImplRef, rt: ptr ExtPluginRt, slot: int, gen: uint32] =
  ## The serving port's impl with one extra ref, or nil. Any thread.
  let f = sharedFind(p, n, ctx)
  if not f.found:
    return (nil, nil, 0, 0'u32)
  let rt = gExtPlugins[p]
  var impl: ptr ExtImplRef
  withLock(rt.lock):
    let ps = addr rt.ports[f.slot]
    if ps.open.load(moAcquire) and ps.gen.load(moAcquire) == f.gen:
      impl = ps.impl
      if not impl.isNil:
        implAcquire(impl)
  (impl, rt, f.slot, f.gen)

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
proc hostRunning(): bool =
  not gExtHost.isNil and gExtHost.running.load(moAcquire)

{.pop.}

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
proc onBridgeThread(): bool =
  not gExtHost.isNil and gExtHost.bridgeTid.load(moAcquire) == osThreadId()

# ---------------------------------------------------------------------------
# Bridge-side operations (run on the bridge thread only)
# ---------------------------------------------------------------------------
{.pop.}

proc failPending(
    pred: proc(c: PendingCall): bool {.gcsafe, raises: [].}, msg: string, hint: bool
) =
  ## Fail matching pending calls with `msg`. A call still queued for a worker
  ## is marked cancelled first, so its `invoke` never runs (at-most-once: the
  ## caller is about to see an error). `hint`: also send the plugin's cancel
  ## hint for calls already running — used for host-initiated failures only,
  ## never while the plugin itself is withdrawing / closing (re-entrancy).
  var ids: seq[uint64]
  for id, c in gExtPending:
    if pred(c):
      ids.add(id)
  for id in ids:
    var c: PendingCall
    if gExtPending.pop(id, c):
      var running = true
      if not c.st.isNil:
        var expected = 0
        running = not c.st.state.compareExchange(expected, 2)
      if running and hint and not c.impl.isNil and not c.impl.impl.cancel.isNil:
        c.impl.impl.cancel(c.impl.impl.user, id)
      if not c.fut.finished():
        c.fut.complete(ExtRawReply(status: ExtReplyErr, data: toBytes(msg)))

proc bridgeWithdraw(pluginIdx, slot, nameIdx: int, ctx: uint32): int32 =
  let d = sharedDel(pluginIdx, nameIdx, ctx, slot)
  if not d.found:
    return ExtNotProvided
  let rt = gExtPlugins[pluginIdx]
  let nd = rt.desc.names[nameIdx]
  var siblingWired, siblingProvided = false
  if nd.sibling >= 0:
    let sib = sharedFind(pluginIdx, nd.sibling, ctx)
    siblingProvided = sib.found
    siblingWired = sib.found and sib.wired
  if not nd.uninstall.isNil:
    nd.uninstall(BrokerContext(ctx), siblingWired, d.wired, siblingProvided)
  discard rt.ports[slot].provided.fetchAnd(not (1'u64 shl nameIdx), moAcquireRelease)
  failPending(
    proc(c: PendingCall): bool =
      c.pluginIdx == pluginIdx and c.portSlot == slot and c.nameIdx == nameIdx,
    "EXTAPI: provider withdrawn",
    hint = false,
  )
  ExtOk

proc bridgeProvide(pluginIdx, slot, nameIdx: int, ctx: uint32, gen: uint32): int32 =
  var native = false
  let prt = gExtPlugins[pluginIdx]
  withLock(prt.lock):
    let impl = prt.ports[slot].impl
    if not impl.isNil:
      native = (impl.impl.caps and ExtCapNative) != 0
  let rc = sharedAdd(pluginIdx, nameIdx, ctx, slot, gen, native)
  if rc != ExtOk:
    return rc
  let rt = gExtPlugins[pluginIdx]
  discard rt.ports[slot].provided.fetchOr(1'u64 shl nameIdx, moAcquireRelease)
  let nd = rt.desc.names[nameIdx]
  if not nd.install.isNil:
    let r = nd.install(BrokerContext(ctx), nd.autoWire)
    if r.isOk:
      sharedSetWired(pluginIdx, nameIdx, ctx, nd.autoWire)
    else:
      # The public slot is held by someone else (e.g. a Nim provider). The
      # foreign source stays registered; `extProvider` / `extFallback` reach it.
      warn "EXTAPI: provided name not auto-wired",
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
    hint = false,
  )
  var impl: ptr ExtImplRef
  withLock(rt.lock):
    if ps.gen.load(moAcquire) == gen and ps.open.load(moAcquire):
      ps.open.store(false, moRelease)
      impl = ps.impl
      ps.impl = nil
      if not impl.isNil:
        impl.closed.store(true, moRelease)
  if not impl.isNil:
    implRelease(impl)
  ExtOk

proc bridgeCloseCtx(ctx: uint32) =
  ## Close every open port bound to `ctx` (plugin-opened and K1/K2 synthetic):
  ## withdraws its names (uninstalling what was auto-wired), fails its
  ## pending calls. Bridge thread only, like `bridgeClose`.
  for p in 0 ..< gExtPluginCount.load(moAcquire):
    let rt = gExtPlugins[p]
    for s in 0 ..< ExtMaxPorts:
      let ps = addr rt.ports[s]
      if ps.open.load(moAcquire) and ps.ctx == ctx:
        discard bridgeClose(p, s, ps.gen.load(moAcquire))

proc runCtl(m: ptr ExtCtlMsg) =
  if m.op == ecoCloseCtx:
    bridgeCloseCtx(m.ctx)
    m.rc = ExtOk
    return
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
    of ecoCloseCtx:
      ExtOk # handled above

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
      var fromSource = false
      gExtPending.withValue(r.callId, pc):
        let (rp, rs, rg) = splitPort(r.port)
        fromSource = rp == pc.pluginIdx and rs == pc.portSlot and rg == pc.portGen
      if fromSource and gExtPending.pop(r.callId, c):
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

proc sigPoll(): int {.gcsafe, raises: [].} =
  ## Bridge: invoke `bridge`-dispatch signals queued by other threads.
  {.cast(gcsafe).}:
    var did = 0
    var m: ExtCallMsg
    while gExtHost.sigRing.tryPop(m):
      did = 1
      if not m.impl.closed.load(moAcquire):
        m.impl.impl.invoke(
          m.impl.impl.user, 0, m.nameIdx, m.name, m.buf, csize_t(m.len)
        )
      if not m.buf.isNil:
        c_free(m.buf)
      implRelease(m.impl)
    did

proc eventPoll(): int {.gcsafe, raises: [].} =
  when defined(extTestHooks):
    if extTestPauseEvents.load(moAcquire):
      return 0
  {.cast(gcsafe).}:
    var did = 0
    var e: ExtEventMsg
    while gExtHost.eventRing.tryPop(e):
      did = 1
      let nd = gExtPlugins[e.pluginIdx].desc.names[e.nameIdx]
      if not lookupPort(e.port).ok:
        debug "EXTAPI: event of a closed port dropped", name = $nd.name
      elif not nd.emitFn.isNil:
        let r = nd.emitFn(BrokerContext(e.ctx), e.buf, e.len)
        if r.isErr:
          warn "EXTAPI: event payload dropped", name = $nd.name, reason = r.error
      if not e.buf.isNil:
        c_free(e.buf)
    did

# ---------------------------------------------------------------------------
# The call paths used by generated forwarders
# ---------------------------------------------------------------------------

proc invokeInplace(
    impl: ptr ExtImplRef,
    port: uint64,
    nameIdx: int,
    name: cstring,
    buf: ptr uint8,
    len: int,
): Result[seq[byte], string] =
  ## Synchronous contract: the reply must arrive before `invoke` returns.
  let (slot, id) = inplaceClaim(port)
  if slot < 0:
    return err("EXTAPI: too many concurrent inplace calls")
  impl.impl.invoke(impl.impl.user, id, uint32(nameIdx), name, buf, csize_t(len))
  # Retire: a reply racing the return (state Filling) is waited for and
  # counts; the slot keeps its generation when freed, so any later reply for
  # this id fails its CAS.
  var filled = false
  var status = ExtReplyErr
  var data: seq[byte]
  while true:
    let c = gExtInplace[slot].ctl.load(moAcquire)
    case slotState(c)
    of isFilling:
      cpuRelax()
    of isFilled:
      filled = true
      status = gExtInplace[slot].status
      data = newSeq[byte](gExtInplace[slot].len)
      if data.len > 0:
        copyMem(addr data[0], gExtInplace[slot].buf, data.len)
      if not gExtInplace[slot].buf.isNil:
        c_free(gExtInplace[slot].buf)
        gExtInplace[slot].buf = nil
      gExtInplace[slot].ctl.store((slotGen(c) shl 32) or isFree, moRelease)
      break
    else:
      var expected = c
      if gExtInplace[slot].ctl.compareExchange(expected, (slotGen(c) shl 32) or isFree):
        break
  if not filled:
    return err("EXTAPI: inplace impl returned without reply")
  if status == ExtReplyOk:
    return ok(data)
  err(fromBytes(data))

proc extFindName*(plugin, name: string): tuple[pluginIdx, nameIdx: int] =
  ## Resolve a (plugin, wire name) pair; (-1, -1) when unknown.
  let p = findPlugin(cstring(plugin))
  if p < 0:
    return (-1, -1)
  (p, findName(gExtPlugins[p].desc, cstring(name)))

proc extNameDesc*(pluginIdx, nameIdx: int): ptr ExtNameDesc =
  addr gExtPlugins[pluginIdx].desc.names[nameIdx]

proc extOnBridge*(): bool =
  ## True on the EXTAPI bridge thread.
  onBridgeThread()

proc extNameDispatch*(pluginIdx, nameIdx: int): ExtDispatch =
  if pluginIdx < 0 or nameIdx < 0 or pluginIdx >= gExtPluginCount.load(moAcquire):
    return edBridge
  gExtPlugins[pluginIdx].desc.names[nameIdx].dispatch

proc extAvailable*(pluginIdx, nameIdx: int, ctx: BrokerContext): bool =
  ## Some open port provides `(plugin, name)` on `ctx`. Any thread, no Nim heap.
  if pluginIdx < 0 or nameIdx < 0:
    return false
  sharedFind(pluginIdx, nameIdx, uint32(ctx)).found

proc extInplaceActive*(pluginIdx, nameIdx: int, ctx: BrokerContext): bool =
  ## An `inplace` source is provided AND the bridge auto-wired the public slot
  ## for it: the generated `request` may bypass the MT hop entirely.
  if pluginIdx < 0 or nameIdx < 0:
    return false
  let f = sharedFind(pluginIdx, nameIdx, uint32(ctx))
  f.found and f.wired

proc extInplaceRoute*(pluginIdx, nameIdx: int, ctx: BrokerContext): int =
  ## One source-table lookup for the inplace hook: 0 = not auto-wired here
  ## (take the normal broker path), 1 = foreign inplace port, 2 = K1 native.
  if pluginIdx < 0 or nameIdx < 0:
    return 0
  let f = sharedFind(pluginIdx, nameIdx, uint32(ctx))
  if not (f.found and f.wired):
    0
  elif f.native:
    2
  else:
    1

proc extNativeActive*(pluginIdx, nameIdx: int, ctx: BrokerContext): bool =
  ## A K1 import serves `(plugin, name)` on `ctx` and the bridge auto-wired
  ## the public slot: the generated code may call the C function directly.
  if pluginIdx < 0 or nameIdx < 0:
    return false
  let f = sharedFind(pluginIdx, nameIdx, uint32(ctx))
  f.found and f.native and f.wired

proc extNativeProvided*(pluginIdx, nameIdx: int, ctx: BrokerContext): bool =
  ## A K1 import serves `(plugin, name)` on `ctx` (wired or not).
  if pluginIdx < 0 or nameIdx < 0:
    return false
  let f = sharedFind(pluginIdx, nameIdx, uint32(ctx))
  f.found and f.native

proc extCallInplace*(
    pluginIdx, nameIdx: int, ctx: BrokerContext, payload: seq[byte]
): Result[seq[byte], string] =
  ## Run an `inplace` source synchronously on the calling thread (any thread).
  if pluginIdx < 0 or nameIdx < 0:
    return err("EXTAPI: plugin not registered")
  let (impl, rt, srcSlot, srcGen) = acquireSource(pluginIdx, nameIdx, uint32(ctx))
  if impl.isNil:
    return err("EXTAPI: no provider registered (not provided by any plugin port)")
  defer:
    implRelease(impl)
  let bufPtr =
    if payload.len > 0:
      cast[ptr uint8](unsafeAddr payload[0])
    else:
      nil
  invokeInplace(
    impl,
    makePort(pluginIdx, srcSlot, srcGen),
    nameIdx,
    rt.desc.names[nameIdx].name,
    bufPtr,
    payload.len,
  )

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
    # Off-bridge forwarders go through the hidden `<T>ExtLane` instead.
    return err("EXTAPI: extCall must run on the bridge thread")
  let (impl, rt, srcSlot, srcGen) = acquireSource(pluginIdx, nameIdx, uint32(ctx))
  if impl.isNil:
    return err(
      "EXTAPI: no provider registered (" & $gExtPlugins[pluginIdx].desc.name & "." &
        $gExtPlugins[pluginIdx].desc.names[nameIdx].name &
        " not provided by any plugin port on ctx " & $uint32(ctx) & ")"
    )
  defer:
    implRelease(impl)
  let nd = rt.desc.names[nameIdx]
  let id = gExtCallSeq.fetchAdd(1, moAcquireRelease) + 1
  let fut = newFuture[ExtRawReply]("extCall")
  {.cast(gcsafe).}:
    gExtPending[id] = PendingCall(
      fut: fut,
      pluginIdx: pluginIdx,
      portSlot: srcSlot,
      portGen: srcGen,
      nameIdx: nameIdx,
      impl: impl,
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
    {.cast(gcsafe).}:
      gExtPending.del(id)
    return invokeInplace(
      impl, makePort(pluginIdx, srcSlot, srcGen), nameIdx, nd.name, bufPtr, payload.len
    )
  of edWorkers:
    if rt.pool.isNil:
      {.cast(gcsafe).}:
        gExtPending.del(id)
      return err("EXTAPI: worker pool not running")
    st = newCallState()
    if st.isNil:
      {.cast(gcsafe).}:
        gExtPending.del(id)
      return err("EXTAPI: out of memory")
    {.cast(gcsafe).}:
      gExtPending.withValue(id, pc):
        pc.st = st
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
    let oom = payload.len > 0 and m.buf.isNil
    if oom or not poolPush(rt.pool, m):
      if not m.buf.isNil:
        c_free(m.buf)
      stRelease(st) # the worker's ref, never handed over
      implRelease(impl)
      {.cast(gcsafe).}:
        gExtPending.del(id)
      return err(if oom: "EXTAPI: out of memory" else: "EXTAPI: worker queue full")
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
  ## Any thread. `inplace` invokes on the calling thread (by contract),
  ## `workers` enqueue for the pool, `bridge` invokes on the bridge thread —
  ## directly when already there, else through the signal ring (review M3).
  if pluginIdx < 0 or nameIdx < 0:
    return err("EXTAPI: plugin not registered")
  let (impl, rt, _, _) = acquireSource(pluginIdx, nameIdx, uint32(ctx))
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
    let oom = payload.len > 0 and m.buf.isNil
    if oom or not poolPush(rt.pool, m):
      if not m.buf.isNil:
        c_free(m.buf)
      implRelease(impl)
      return err(if oom: "EXTAPI: out of memory" else: "EXTAPI: worker queue full")
    return ok()
  if nd.dispatch == edBridge and not onBridgeThread():
    let m = ExtCallMsg(
      impl: impl, # the bridge releases it
      id: 0,
      nameIdx: uint32(nameIdx),
      name: nd.name,
      buf: copyToC(payload),
      len: payload.len,
      st: nil,
    )
    let oom = payload.len > 0 and m.buf.isNil
    if oom or not gExtHost.sigRing.tryPush(m):
      if not m.buf.isNil:
        c_free(m.buf)
      implRelease(impl)
      return err(if oom: "EXTAPI: out of memory" else: "EXTAPI: signal queue full")
    fireBrokerSignal(gExtHost.signal)
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

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
proc postCtl(
    op: ExtCtlOp, pluginIdx, slot: int, gen: uint32, nameIdx: int, ctx = 0'u32
): int32 =
  if not hostRunning():
    return ExtShutdown
  var m: ExtCtlMsg
  m.op = op
  m.pluginIdx = pluginIdx
  m.portSlot = slot
  m.gen = gen
  m.nameIdx = nameIdx
  m.ctx = ctx
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
  # Check-and-push under `ctlLock`: `extHostStop` clears `running` under the
  # same lock before its final control drain, so a message is either pushed
  # in time to be answered (by the bridge or by that drain) or not at all.
  var rc = ExtOk
  withLock(gExtHost.ctlLock):
    if not gExtHost.running.load(moAcquire):
      rc = ExtShutdown
    elif not gExtHost.ctlRing.tryPush(addr m):
      rc = ExtAgain
  if rc != ExtOk:
    return rc
  fireBrokerSignal(gExtHost.signal)
  withLock(m.lock):
    while not m.done:
      wait(m.cond, m.lock)
  m.rc

{.pop.}

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
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
    # Same escape hatch as `<lib>_verifySchema`: an operator who knows the
    # mismatch is benign can open anyway.
    let skip =
      extEnvFlagSet("BROKERS_FFI_SKIP_SCHEMA_CHECK") or
      (not rt.desc.skipSchemaEnv.isNil and extEnvFlagSet(rt.desc.skipSchemaEnv))
    if not skip:
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
        if r.isNil:
          return ExtAgain # out of memory: the slot stays closed
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

{.pop.}

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
proc extClose(host: pointer, port: uint64): int32 {.cdecl, gcsafe, raises: [].} =
  let lp = lookupPort(port)
  if not lp.ok:
    return ExtStale
  postCtl(ecoClose, splitPort(port).pluginIdx, lp.slot, lp.gen, -1)

{.pop.}

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
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
    var closed = false
    withLock(lp.rt.lock):
      let ps = addr lp.rt.ports[lp.slot]
      let impl = ps.impl
      if impl.isNil or not ps.open.load(moAcquire) or ps.gen.load(moAcquire) != lp.gen:
        closed = true # closed since `lookupPort`: STALE, not a caps mismatch
      else:
        caps = impl.impl.caps
    if closed:
      return ExtStale
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

{.pop.}

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
proc extProvide(
    host: pointer, port: uint64, name: cstring
): int32 {.cdecl, gcsafe, raises: [].} =
  nameOp(port, name, ecoProvide)

{.pop.}

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
proc extWithdraw(
    host: pointer, port: uint64, name: cstring
): int32 {.cdecl, gcsafe, raises: [].} =
  nameOp(port, name, ecoWithdraw)

{.pop.}

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
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
  if len > csize_t(high(int32)):
    return ExtBadArg
  if inplaceFill(port, id, status, buf, int(len)):
    return ExtOk
  var m = ExtReplyMsg(port: port, callId: id, status: status, len: int(len))
  if len > 0:
    m.buf = cast[ptr uint8](c_malloc(len))
    if m.buf.isNil:
      return ExtAgain
    copyMem(m.buf, buf, int(len))
  if not gExtHost.replyRing.tryPush(m):
    if not m.buf.isNil:
      c_free(m.buf)
    return ExtAgain
  fireBrokerSignal(gExtHost.signal)
  ExtOk

{.pop.}

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
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
  if len > csize_t(high(int32)):
    return ExtBadArg
  # Read the port's ctx together with its open / generation state: a close +
  # reopen in between must not deliver this event on the new port's ctx.
  var ctx = 0'u32
  var live = false
  acquire(lp.rt.lock)
  let ps = addr lp.rt.ports[lp.slot]
  if ps.open.load(moAcquire) and ps.gen.load(moAcquire) == lp.gen:
    ctx = ps.ctx
    live = true
  release(lp.rt.lock)
  if not live:
    return ExtStale
  var m = ExtEventMsg(
    port: port,
    pluginIdx: splitPort(port).pluginIdx,
    nameIdx: n,
    ctx: ctx,
    len: int(len),
  )
  if len > 0:
    m.buf = cast[ptr uint8](c_malloc(len))
    if m.buf.isNil:
      return ExtAgain
    copyMem(m.buf, buf, int(len))
  if not gExtHost.eventRing.tryPush(m):
    if not m.buf.isNil:
      c_free(m.buf)
    return ExtAgain
  fireBrokerSignal(gExtHost.signal)
  ExtOk

{.pop.}

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
proc copyOut(src: cstring, n: int, outBuf: ptr ptr uint8, outLen: ptr csize_t): int32 =
  if outBuf.isNil or outLen.isNil:
    return ExtBadArg
  let b = cast[ptr uint8](c_malloc(csize_t(max(n, 1))))
  if b.isNil:
    return ExtAgain
  if n > 0:
    copyMem(b, src, n)
  outBuf[] = b
  outLen[] = csize_t(n)
  ExtOk

{.pop.}

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
proc extListApis(
    host: pointer, plugin: cstring, outBuf: ptr ptr uint8, outLen: ptr csize_t
): int32 {.cdecl, gcsafe, raises: [].} =
  let p = findPlugin(plugin)
  if p < 0:
    return ExtUnknownName
  let d = gExtPlugins[p].desc
  copyOut(d.listApisBuf, d.listApisLen, outBuf, outLen)

{.pop.}

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
proc extGetSchema(
    host: pointer, plugin: cstring, outBuf: ptr ptr uint8, outLen: ptr csize_t
): int32 {.cdecl, gcsafe, raises: [].} =
  let p = findPlugin(plugin)
  if p < 0:
    return ExtUnknownName
  let d = gExtPlugins[p].desc
  copyOut(d.schemaBuf, d.schemaLen, outBuf, outLen)

{.pop.}

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
proc extFreeBuffer(host: pointer, buf: ptr uint8) {.cdecl, gcsafe, raises: [].} =
  if not buf.isNil:
    c_free(buf)

{.pop.}

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
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

{.pop.}

proc extImportReplyOk*(user: pointer, id: uint64, data: seq[byte]) =
  ## K1 trampolines: answer an invoke through the ordinary reply path.
  let u = cast[ptr ExtImportUser](user)
  let p =
    if data.len > 0:
      cast[ptr uint8](unsafeAddr data[0])
    else:
      nil
  discard extReply(nil, u.port, id, ExtReplyOk, p, csize_t(data.len))

proc extImportReplyErr*(user: pointer, id: uint64, msg: string) =
  let u = cast[ptr ExtImportUser](user)
  let p =
    if msg.len > 0:
      cast[ptr uint8](unsafeAddr msg[0])
    else:
      nil
  discard extReply(nil, u.port, id, ExtReplyErr, p, csize_t(msg.len))

proc extPeerLoad(pluginIdx: int, ctx: BrokerContext): Result[void, string]

proc setLoadError(rt: ptr ExtPluginRt, msg: string) =
  withLock(rt.lock):
    if not rt.loadError.isNil:
      c_free(rt.loadError)
      rt.loadError = nil
    if msg.len > 0:
      rt.loadError = cast[cstring](c_malloc(csize_t(msg.len + 1)))
      if not rt.loadError.isNil:
        copyMem(rt.loadError, unsafeAddr msg[0], msg.len)
        cast[ptr UncheckedArray[char]](rt.loadError)[msg.len] = '\0'

proc importLoadedOn(rt: ptr ExtPluginRt, ctx: BrokerContext): bool =
  ## An import (K1) or peer (K2) port of this plugin is already open on `ctx`.
  withLock(rt.lock):
    for s in 0 ..< ExtMaxPorts:
      let ps = addr rt.ports[s]
      if ps.open.load(moAcquire) and ps.ctx == uint32(ctx) and not ps.impl.isNil and
          ((ps.impl.impl.caps and ExtCapNative) != 0 or not rt.peers[s].isNil):
        return true
  false

proc extImportLoad*(pluginIdx: int, ctx: BrokerContext): Result[void, string] =
  ## K1: resolve every import of the plugin and serve the resolved names on
  ## `ctx` through a synthetic port. Names whose library or symbol is missing
  ## stay unprovided (`extFallback` / "no provider") and are listed in
  ## `extImportLoadError`. `err` only when nothing could be loaded. Libraries
  ## are never unloaded: running calls could outlive any unload point.
  if not hostRunning():
    return err("EXTAPI: host not started (call ExtHost.start() first)")
  if pluginIdx < 0 or pluginIdx >= gExtPluginCount.load(moAcquire):
    return err("EXTAPI: unknown plugin")
  let rt = gExtPlugins[pluginIdx]
  let d = rt.desc
  acquire(rt.loadLock)
  defer:
    release(rt.loadLock)
  if importLoadedOn(rt, ctx):
    return ok() # idempotent: eager + explicit load, or a repeated load
  if not d.peerLib.isNil:
    return extPeerLoad(pluginIdx, ctx)
  if d.importInvoke.isNil:
    return err("EXTAPI: plugin " & $d.name & " has no native or peer imports")
  var problems: seq[string]
  var resolved: seq[int]
  for n in 0 ..< d.nameCount:
    let nd = d.names[n]
    if nd.importResolve.isNil:
      continue
    var lib: LibHandle = nil
    try:
      lib = loadLibPattern($nd.importLib)
    except Exception:
      lib = nil
    if lib.isNil:
      problems.add($nd.name & ": cannot load library '" & $nd.importLib & "'")
      continue
    let missing = nd.importResolve(lib)
    if missing.len > 0:
      problems.add($nd.name & ": missing symbol " & missing)
      continue
    resolved.add(n)
  if resolved.len == 0:
    let msg = problems.join("; ")
    setLoadError(rt, msg)
    return err("EXTAPI: nothing could be loaded for " & $d.name & ": " & msg)
  let user = cast[ptr ExtImportUser](c_calloc(1, csize_t(sizeof(ExtImportUser))))
  var impl = ExtImplDesc(
    abiVersion: ExtAbiVersion,
    plugin: d.name,
    schemaHash: nil,
    caps: ExtCapNonBlocking or ExtCapReplyInline or ExtCapNative,
    invoke: d.importInvoke,
    cancel: nil,
    release: proc(u: pointer) {.cdecl, gcsafe, raises: [].} =
      c_free(u),
    user: user,
  )
  var port: uint64
  let rc = extOpen(nil, uint32(ctx), addr impl, addr port)
  if rc != ExtOk:
    c_free(user)
    return err("EXTAPI: cannot open import port (" & $rc & ")")
  user.port = port
  var provided = 0
  for n in resolved:
    let prc = extProvide(nil, port, d.names[n].name)
    if prc == ExtOk:
      inc provided
    else:
      problems.add($d.names[n].name & ": provide failed (" & $prc & ")")
  let msg = problems.join("; ")
  setLoadError(rt, msg) # after the provides, so their failures are reported too
  if provided == 0:
    discard extClose(nil, port)
    return err("EXTAPI: nothing could be served for " & $d.name & ": " & msg)
  ok()

proc extImportLoadError*(pluginIdx: int): string =
  if pluginIdx < 0 or pluginIdx >= gExtPluginCount.load(moAcquire):
    return "unknown plugin"
  let rt = gExtPlugins[pluginIdx]
  withLock(rt.lock):
    if not rt.loadError.isNil:
      return $rt.loadError
  ""

# ---------------------------------------------------------------------------
# K2 — nim-brokers peer library
# ---------------------------------------------------------------------------

const
  peerBadEnvelope: cstring = "EXTAPI: malformed peer response envelope"
  peerTimedOut: cstring = "EXTAPI: peer timed out"
  peerShutDown: cstring = "EXTAPI: peer shut down"
  peerDispatchFailed: cstring = "EXTAPI: peer dispatch failed"
  peerBusy: cstring = "ext: peer busy"
  peerCallFailed: cstring = "EXTAPI: peer callAsync failed"
  peerAllocFailed: cstring = "EXTAPI: peer allocBuffer failed"

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
proc replyText(port: uint64, id: uint64, msg: cstring) =
  discard
    extReply(nil, port, id, ExtReplyErr, cast[ptr uint8](msg), csize_t(c_strlen(msg)))

{.pop.}

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
proc cborHeadAt(
    b: ptr UncheckedArray[uint8], n, at: int
): tuple[major, hdr: int, v: uint64] =
  ## Minimal CBOR head decoder (definite lengths up to 64 bit); hdr 0 = error.
  if at >= n:
    return (0, 0, 0'u64)
  let ib = int(b[at])
  let major = ib shr 5
  let ai = ib and 31
  if ai < 24:
    return (major, 1, uint64(ai))
  let extra =
    case ai
    of 24: 1
    of 25: 2
    of 26: 4
    of 27: 8
    else: -1
  if extra < 0 or at + extra >= n:
    return (major, 0, 0'u64)
  var v = 0'u64
  for i in 1 .. extra:
    v = (v shl 8) or uint64(b[at + i])
  (major, 1 + extra, v)

{.pop.}

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
proc peerRespCb(
    user: pointer, reqId: uint64, status: int32, buf: pointer, len: int32
) {.cdecl, gcsafe, raises: [].} =
  ## Runs on the PEER's delivery thread — foreign to this runtime: pointer
  ## arithmetic, libc and `extReply` (which copies) only. Unwraps the peer's
  ## `{ok: v}` / `{err: "…"}` envelope into a bare value / error text.
  let u = cast[ptr ExtPeerUser](user)
  if status != 0:
    case status
    of -12:
      replyText(u.port, reqId, peerTimedOut)
    of -11:
      replyText(u.port, reqId, peerShutDown)
    of -4:
      if len > 0 and not buf.isNil:
        discard
          extReply(nil, u.port, reqId, ExtReplyErr, cast[ptr uint8](buf), csize_t(len))
      else:
        replyText(u.port, reqId, peerDispatchFailed)
    else:
      replyText(u.port, reqId, peerDispatchFailed)
    return
  if buf.isNil or len <= 0:
    replyText(u.port, reqId, peerBadEnvelope)
    return
  let b = cast[ptr UncheckedArray[uint8]](buf)
  let n = int(len)
  let m = cborHeadAt(b, n, 0)
  if m.hdr == 0 or m.major != 5 or m.v != 1:
    replyText(u.port, reqId, peerBadEnvelope)
    return
  let k = cborHeadAt(b, n, m.hdr)
  if k.hdr == 0 or k.major != 3:
    replyText(u.port, reqId, peerBadEnvelope)
    return
  let keyAt = m.hdr + k.hdr
  # Peer-controlled lengths: compare in uint64 before any int arithmetic.
  if keyAt > n or k.v > uint64(n - keyAt):
    replyText(u.port, reqId, peerBadEnvelope)
    return
  let valAt = keyAt + int(k.v)
  if k.v == 2 and b[keyAt] == uint8('o') and b[keyAt + 1] == uint8('k'):
    let p = (if valAt < n: addr b[valAt] else: nil)
    discard extReply(nil, u.port, reqId, ExtReplyOk, p, csize_t(n - valAt))
  elif k.v == 3 and b[keyAt] == uint8('e') and b[keyAt + 1] == uint8('r') and
      b[keyAt + 2] == uint8('r'):
    let t = cborHeadAt(b, n, valAt)
    if t.hdr == 0 or t.major != 3 or valAt + t.hdr > n or t.v > uint64(
      n - valAt - t.hdr
    ):
      replyText(u.port, reqId, peerBadEnvelope)
      return
    let p = (if t.v > 0: addr b[valAt + t.hdr] else: nil)
    discard extReply(nil, u.port, reqId, ExtReplyErr, p, csize_t(t.v))
  else:
    replyText(u.port, reqId, peerBadEnvelope)

{.pop.}

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
proc peerEventCb(
    ctx: uint32, eventName: cstring, buf: pointer, len: int32, user: pointer
) {.cdecl, gcsafe, raises: [].} =
  ## Peer delivery thread: the event payload is the same CBOR object our
  ## EventBroker decodes — forward it as a foreign `emit`.
  let u = cast[ptr ExtPeerUser](user)
  if len < 0:
    return
  discard extEmit(nil, u.port, eventName, cast[ptr uint8](buf), csize_t(len))

{.pop.}

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
proc peerUserRelease(u: ptr ExtPeerUser) =
  if u.refs.fetchSub(1, moAcquireRelease) == 1:
    c_free(u)

{.pop.}

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
proc peerRelease(user: pointer) {.cdecl, gcsafe, raises: [].} =
  peerUserRelease(cast[ptr ExtPeerUser](user))

{.pop.}

{.push checks: off, stackTrace: off, lineTrace: off.} # foreign-thread path (M2)
proc peerInvoke(
    user: pointer,
    id: uint64,
    nameIdx: uint32,
    name: cstring,
    buf: ptr uint8,
    len: csize_t,
) {.cdecl, gcsafe, raises: [].} =
  ## The synthetic port's invoke: requests → `<peer>_callAsync` (never
  ## blocks; the reply arrives on the peer's delivery thread), signals →
  ## the peer's slot-free one-way `<peer>_call`. The request buffer is the
  ## peer's to free (allocated with `<peer>_allocBuffer`).
  let u = cast[ptr ExtPeerUser](user)
  if len > csize_t(high(int32)):
    if id != 0:
      replyText(u.port, id, peerCallFailed)
    return
  var req: pointer = nil
  if len > 0:
    req = u.fns.allocBuffer(int32(len))
    if req.isNil:
      if id != 0:
        replyText(u.port, id, peerAllocFailed)
      return
    copyMem(req, buf, int(len))
  if id == 0:
    var resp: pointer = nil
    var respLen: int32 = 0
    discard u.fns.call(u.peerCtx, name, req, int32(len), addr resp, addr respLen)
    if not resp.isNil:
      u.fns.freeBuffer(resp)
    return
  let rc = u.fns.callAsync(u.peerCtx, name, req, int32(len), id, 0, peerRespCb, user)
  if rc < 0:
    replyText(u.port, id, (if rc == -6: peerBusy else: peerCallFailed))

{.pop.}

proc resolvePeer(lib: LibHandle, prefix: string): Result[ptr PeerFns, string] =
  let f = cast[ptr PeerFns](c_calloc(1, csize_t(sizeof(PeerFns))))
  var missing: seq[string]
  template res(field, suffix: untyped) =
    let symName = prefix & suffix
    let a = symAddr(lib, cstring(symName))
    if a.isNil:
      missing.add(prefix & suffix)
    else:
      f.field = cast[typeof(f.field)](a)

  res(initialize, "_initialize")
  res(createContext, "_createContext")
  res(shutdown, "_shutdown")
  res(allocBuffer, "_allocBuffer")
  res(freeBuffer, "_freeBuffer")
  res(call, "_call")
  res(callAsync, "_callAsync")
  res(subscribe, "_subscribe")
  res(unsubscribe, "_unsubscribe")
  res(getSchema, "_getSchema")
  if missing.len > 0:
    c_free(f)
    return err("missing peer symbols: " & missing.join(", "))
  ok(f)

proc peerSchemaSigs(f: ptr PeerFns): Result[seq[(string, string)], string] =
  ## (wire name, "args|payload") for every request / event / signal the peer
  ## publishes, in the same canonical form `registerExtPlugin` burns in.
  var outBuf: pointer = nil
  var outLen: int32 = 0
  if f.getSchema(addr outBuf, addr outLen) != 0 or outBuf.isNil:
    return err("peer _getSchema failed")
  # `<lib>_getSchema` returns the JSON form of `LibraryDescriptor`.
  var text = newString(int(outLen))
  if outLen > 0:
    copyMem(addr text[0], outBuf, int(outLen))
  f.freeBuffer(outBuf)
  var sigs: seq[(string, string)]
  try:
    let j = parseJson(text)
    # The peer's own type records, so its types expand to wire shapes exactly
    # like ours (`extTypeShapes`): nested objects and enums are compared, not
    # just type names (EXTAPI review M13).
    var types = initTable[string, PeerType]()
    if j.hasKey("types"):
      for t in j["types"]:
        var rec: PeerType
        case t["kind"].getStr()
        of "object":
          rec.kind = ptkObject
          for f in t["fields"]:
            rec.fields.add((f["name"].getStr(), f["nimType"].getStr()))
        of "enum":
          rec.kind = ptkEnum
          for v in t["enumValues"]:
            rec.enumValues.add((v["ordinal"].getInt(), v["name"].getStr()))
        else:
          rec.kind = ptkAlias
          rec.underlying = t["underlyingType"].getStr()
        types[t["name"].getStr()] = rec
    for r in j["requests"]:
      var args: seq[(string, string)]
      for a in r["argFields"]:
        args.add((a["name"].getStr(), peerShape(a["nimType"].getStr(), types)))
      args.sort(
        proc(x, y: (string, string)): int =
          cmp(x[0], y[0])
      )
      var parts: seq[string]
      for (n, sh) in args:
        parts.add(n & ":" & sh)
      let resp = r["responseType"].getStr()
      sigs.add(
        (
          r["apiName"].getStr(),
          parts.join(",") & "|" & (
            if resp.len == 0: "void" else: peerShape(resp, types)
          ),
        )
      )
    for e in j["events"]:
      sigs.add(
        (e["apiName"].getStr(), "|" & peerShape(e["payloadType"].getStr(), types))
      )
    for e in j["signals"]:
      sigs.add(
        (e["apiName"].getStr(), "|" & peerShape(e["payloadType"].getStr(), types))
      )
  except CatchableError as e:
    return err("peer schema parse failed: " & e.msg)
  ok(sigs)

proc extPeerLoad(pluginIdx: int, ctx: BrokerContext): Result[void, string] =
  ## K2: one peer context per host context (EXTAPI_PLAN §D4-4). Resolves the
  ## peer library once, checks every imported name against the peer schema,
  ## creates `peerCtx`, opens a synthetic port, provides the requests /
  ## signals and subscribes the events.
  let rt = gExtPlugins[pluginIdx]
  let d = rt.desc
  var problems: seq[string]
  if rt.peerFns.isNil:
    var lib: LibHandle = nil
    try:
      lib = loadLibPattern($d.peerDynlib)
    except Exception:
      lib = nil
    if lib.isNil:
      return err("EXTAPI: cannot load peer library '" & $d.peerDynlib & "'")
    let f = resolvePeer(lib, $d.peerLib)
    if f.isErr:
      return err("EXTAPI: " & f.error)
    f.value.initialize()
    rt.peerFns = f.value
  let fns = rt.peerFns
  let sigs = peerSchemaSigs(fns)
  if sigs.isErr:
    return err("EXTAPI: " & sigs.error)
  var accepted: seq[int]
  for n in 0 ..< d.nameCount:
    let want = $d.names[n].peerSig
    var found = false
    var match = false
    for (nm, sg) in sigs.value:
      if nm == $d.names[n].name:
        found = true
        match = sg == want
    if not found:
      problems.add($d.names[n].name & ": not published by the peer")
    elif not match:
      problems.add($d.names[n].name & ": schema differs from the peer's")
    else:
      accepted.add(n)
  if accepted.len == 0:
    let msg = problems.join("; ")
    setLoadError(rt, msg)
    return err("EXTAPI: nothing could be imported from " & $d.peerLib & ": " & msg)
  var errOut: cstring = nil
  let peerCtx = fns.createContext(addr errOut)
  if peerCtx == 0:
    let e = (if errOut.isNil: "unknown" else: $errOut)
    if not errOut.isNil:
      fns.freeBuffer(errOut)
    return err("EXTAPI: peer createContext failed: " & e)
  let user = cast[ptr ExtPeerUser](c_calloc(1, csize_t(sizeof(ExtPeerUser))))
  user.refs.store(2, moRelease) # the port + `rt.peers`
  user.hostCtx = uint32(ctx)
  user.peerCtx = peerCtx
  user.fns = fns
  var impl = ExtImplDesc(
    abiVersion: ExtAbiVersion,
    plugin: d.name,
    schemaHash: nil,
    caps: ExtCapNonBlocking,
    invoke: peerInvoke,
    cancel: nil, # no `_cancelAsync` yet: a cancelled call's late reply is dropped by id
    release: peerRelease, # drops the port's ref; `shutdownPeers` drops the other
    user: user,
  )
  var port: uint64
  let rc = extOpen(nil, uint32(ctx), addr impl, addr port)
  if rc != ExtOk:
    discard fns.shutdown(peerCtx)
    c_free(user)
    return err("EXTAPI: cannot open peer port (" & $rc & ")")
  user.port = port
  withLock(rt.lock):
    rt.peers[splitPort(port).slot] = user
  for n in accepted:
    let nd = d.names[n]
    if nd.kind == enkEvent:
      user.subs[n] = fns.subscribe(peerCtx, nd.name, peerEventCb, user)
    else:
      let prc = extProvide(nil, port, nd.name)
      if prc != ExtOk:
        problems.add($nd.name & ": provide failed (" & $prc & ")")
  setLoadError(rt, problems.join("; "))
  ok()

proc shutdownPeer(rt: ptr ExtPluginRt, u: ptr ExtPeerUser) =
  ## Unsubscribe, shut the peer context down and drop `rt.peers`' ref (an
  ## off-bridge call still holding the port's impl keeps the user alive).
  for n in 0 ..< rt.desc.nameCount:
    if u.subs[n] != 0:
      discard rt.peerFns.unsubscribe(u.peerCtx, rt.desc.names[n].name, u.subs[n])
  discard rt.peerFns.shutdown(u.peerCtx)
  peerUserRelease(u)

proc shutdownPeers() =
  ## Host stop, after the bridge and the worker pools are gone: shut every
  ## peer context down.
  for p in 0 ..< gExtPluginCount.load(moAcquire):
    let rt = gExtPlugins[p]
    if rt.peerFns.isNil:
      continue
    for s in 0 ..< ExtMaxPorts:
      var u: ptr ExtPeerUser
      withLock( # vs. a concurrent `extLibCtxClose`
        rt.lock
      ):
        u = rt.peers[s]
        rt.peers[s] = nil
      if not u.isNil:
        shutdownPeer(rt, u)

proc extJoinMissing*(missing: seq[string]): string =
  missing.join(", ")

proc extPluginIndex*(name: string): int =
  findPlugin(cstring(name))

proc extHostTable*(): ptr ExtHostTable =
  ## The function table handed to foreign plugins (`broker_ext_host`).
  addr gExtHostTable

# ---------------------------------------------------------------------------
# Bridge thread lifecycle (exe mode)
# ---------------------------------------------------------------------------

proc bridgeThreadProc(h: ptr ExtHostRt) {.thread.} =
  when defined(extTestHooks):
    discard extTestBridgeStarts.fetchAdd(1)
  h.signal = getOrInitBrokerSignal()
  h.bridgeTid.store(osThreadId(), moRelease)
  registerBrokerPoller(ctlPoll)
  registerBrokerPoller(replyPoll)
  registerBrokerPoller(eventPoll)
  registerBrokerPoller(sigPoll)
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
      hint = true,
    )
  # Drain any ctl message that raced the stop so its caller does not hang.
  discard ctlPoll()
  teardownBrokerThread()
  closeThreadDispatcherSelector()
  when defined(extTestHooks):
    discard extTestBridgeExits.fetchAdd(1)

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

proc freePool(pool: ptr ExtWorkerPool) =
  pool.q.deinit()
  deallocShared(pool.exit)
  deallocShared(pool.threads)
  deinitCond(pool.cond)
  deinitLock(pool.lock)
  deallocShared(pool)

proc joinExited(pool: ptr ExtWorkerPool): int =
  ## Join the workers that have left `workerProc` and are not joined yet;
  ## the number still running.
  let threads = cast[ptr UncheckedArray[Thread[ExtWorkerArg]]](pool.threads)
  for i in 0 ..< pool.started:
    case pool.exit[i].load(moAcquire)
    of 1:
      joinAndReleaseThread(threads[i])
      pool.exit[i].store(2, moRelease)
    of 2:
      discard
    else:
      inc result

proc stopPool(pool: ptr ExtWorkerPool, started: int, joinTimeout: Duration): int =
  ## Stop the first `started` worker threads of `pool` and free queued messages
  ## without invoking them. Waits up to `joinTimeout` (`ZeroDuration` or
  ## `InfiniteDuration`: forever) for the workers to leave; joins those that
  ## did. With none left running the pool is freed; otherwise it is orphaned
  ## — kept alive for the workers still inside a foreign `invoke` — and the
  ## number of those is returned.
  pool.started = started
  withLock(pool.lock):
    pool.stop = true
    broadcast(pool.cond)
    # Under the lock: a worker still running may pop concurrently.
    var m: ExtCallMsg
    while pool.q.tryPop(m):
      if not m.buf.isNil:
        c_free(m.buf)
      stRelease(m.st)
      implRelease(m.impl)
  if joinTimeout <= ZeroDuration or joinTimeout == InfiniteDuration:
    let threads = cast[ptr UncheckedArray[Thread[ExtWorkerArg]]](pool.threads)
    for i in 0 ..< started:
      joinAndReleaseThread(threads[i])
    freePool(pool)
    return 0
  let deadline = Moment.now() + joinTimeout
  var running = joinExited(pool)
  while running > 0 and Moment.now() < deadline:
    os.sleep(1)
    running = joinExited(pool)
  if running == 0:
    freePool(pool)
    return 0
  pool.leaked = running
  pool.next = gExtOrphanPools
  gExtOrphanPools = pool
  discard gExtLeakedWorkers.fetchAdd(running, moAcquireRelease)
  running

proc reapOrphanPools() =
  ## Join and free orphaned pools whose workers have all left. Start / stop
  ## owner only.
  var link = addr gExtOrphanPools
  while not link[].isNil:
    let pool = link[]
    if joinExited(pool) == 0:
      link[] = pool.next
      discard gExtLeakedWorkers.fetchSub(pool.leaked, moAcquireRelease)
      freePool(pool)
    else:
      link = addr pool.next

proc stopAllPools(joinTimeout: Duration): string =
  ## Stop every plugin's pool; "" when every worker was joined, else what was
  ## left running.
  for p in 0 ..< gExtPluginCount.load(moAcquire):
    let rt = gExtPlugins[p]
    if not rt.pool.isNil:
      let pool = rt.pool
      rt.pool = nil
      let stuck = stopPool(pool, pool.n, joinTimeout)
      if stuck > 0:
        if result.len > 0:
          result.add("; ")
        result.add(
          $stuck & " worker(s) of plugin " & $rt.desc.name & " still in a foreign " &
            "invoke after " & $joinTimeout & ", leaked"
        )

proc extLeakedWorkerCount*(): int =
  ## Worker threads left running by a host stop whose join bound expired (they
  ## are joined and freed by a later start / stop once they leave). Any thread.
  gExtLeakedWorkers.load(moAcquire)

proc stopBridgeThread() =
  gExtHost.stopFlag.store(1, moRelease)
  fireBrokerSignal(gExtHost.signal)
  joinAndReleaseThread(gExtBridgeThread)
  gExtHost.bridgeTid.store(0, moRelease)

proc startHost(): Result[void, string] =
  ## Owner of the `hsStarting` state: bring up the bridge, then the worker
  ## pools. On any failure everything already started is torn down again.
  reapOrphanPools()
  if gExtHost.isNil:
    gExtHost = cast[ptr ExtHostRt](createShared(ExtHostRt, 1))
    gExtHost.ctlRing.init(ExtRingCap)
    gExtHost.replyRing.init(ExtRingCap)
    gExtHost.eventRing.init(ExtRingCap)
    gExtHost.sigRing.init(ExtRingCap)
    initLock(gExtHost.ctlLock)
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
  # Ready before the pools: a rollback can then always signal and join it.
  while gExtHost.ready.load(moAcquire) != 1:
    os.sleep(1)
  # Worker pools: one per plugin that has `workers` names.
  var attempts = 0
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
    let threads = cast[ptr UncheckedArray[Thread[ExtWorkerArg]]](createShared(
      Thread[ExtWorkerArg], n
    ))
    pool.threads = threads
    pool.exit = cast[ptr UncheckedArray[Atomic[int32]]](createShared(Atomic[int32], n))
    for i in 0 ..< n:
      inc attempts
      var failure = ""
      when defined(extTestHooks):
        if extTestFailWorkerAt.load(moAcquire) == attempts:
          failure = "injected failure"
      if failure.len == 0:
        try:
          createThread(threads[i], workerProc, (pool, i))
        except ResourceExhaustedError as e:
          failure = e.msg
      if failure.len > 0:
        # Freshly started workers: nothing was invoked, the join cannot hang.
        discard stopPool(pool, i, InfiniteDuration)
        discard stopAllPools(InfiniteDuration)
        stopBridgeThread()
        return err("EXTAPI: cannot start worker thread: " & failure)
    rt.pool = pool
  ok()

proc extHostStart*(): Result[void, string] =
  ## Start the shared EXTAPI bridge thread and the worker pools. Idempotent and
  ## safe from any thread (`<lib>_extHost()` may race on foreign threads):
  ## exactly one caller starts, the others wait for it.
  while true:
    var expected = hsStopped
    if gExtHostState.compareExchange(expected, hsStarting):
      break
    if expected == hsRunning:
      return ok()
    os.sleep(1) # another start or a stop is in progress
  let r = startHost()
  if r.isErr:
    gExtHostState.store(hsStopped, moRelease)
    return r
  gExtHost.running.store(true, moRelease)
  gExtHostState.store(hsRunning, moRelease)
  for p in 0 ..< gExtPluginCount.load(moAcquire):
    let d = gExtPlugins[p].desc
    if d.loadEager and (not d.importInvoke.isNil or not d.peerLib.isNil):
      let r = extImportLoad(p, DefaultBrokerContext)
      if r.isErr:
        warn "EXTAPI: eager import load failed", plugin = $d.name, reason = r.error
  ok()

proc extHostStop*(joinTimeout = ExtDefaultJoinTimeout): Result[void, string] =
  ## Stop the host: closes every port, fails pending calls (queued worker calls
  ## never run), clears every auto-wired provider, stops the worker pools and
  ## K2 peer contexts. Foreign calls afterwards return SHUTDOWN. Refused on the
  ## bridge or a worker thread (it would join itself): `err`, host left
  ## running. Idempotent.
  ##
  ## Worker threads get `joinTimeout` (`ZeroDuration`: forever) to leave a
  ## foreign `invoke` in progress. A worker still inside it is leaked: the
  ## host is stopped all the same (restartable), and `err` names the plugin
  ## and count. A later start / stop joins and frees it once it has left.
  if onBridgeThread() or gExtIsWorker:
    return err("EXTAPI: ExtHost.stop() cannot run on the bridge or a worker thread")
  while true:
    var expected = hsRunning
    if gExtHostState.compareExchange(expected, hsStopping):
      break
    if expected == hsStopped:
      return ok()
    os.sleep(1) # a start or another stop is in progress
  withLock(gExtHost.ctlLock):
    gExtHost.running.store(false, moRelease)
  stopBridgeThread()
  reapOrphanPools()
  # Pools before peers: queued peer calls are dropped, never invoked against
  # a shut-down peer context.
  let leaked = stopAllPools(joinTimeout)
  shutdownPeers()
  # Payloads that raced the stop: free them.
  var rm: ExtReplyMsg
  while gExtHost.replyRing.tryPop(rm):
    if not rm.buf.isNil:
      c_free(rm.buf)
  var em: ExtEventMsg
  while gExtHost.eventRing.tryPop(em):
    if not em.buf.isNil:
      c_free(em.buf)
  var sm: ExtCallMsg
  while gExtHost.sigRing.tryPop(sm):
    if not sm.buf.isNil:
      c_free(sm.buf)
    implRelease(sm.impl)
  # A control call pushed before `running` flipped and not yet answered by the
  # bridge: answer it so its caller never hangs.
  var m: ptr ExtCtlMsg
  while gExtHost.ctlRing.tryPop(m):
    withLock(m.lock):
      m.rc = ExtShutdown
      m.done = true
      signal(m.cond)
  gExtHostState.store(hsStopped, moRelease)
  if leaked.len > 0:
    return err("EXTAPI: host stopped; " & leaked)
  ok()

# ---------------------------------------------------------------------------
# Lib mode: teardown driven by the library's context lifecycle
# ---------------------------------------------------------------------------

proc extLibHostStart*(workerJoinTimeoutMs: int): Result[void, string] =
  ## `<lib>_extHost()`: start the host (idempotent) and hand its lifetime to
  ## the library — it stops when the library's last context shuts down
  ## (`extLibIdle`), joining worker threads for up to `workerJoinTimeoutMs`
  ## (0 = forever). A later `<lib>_extHost()` starts it again.
  ?extHostStart()
  gExtLibJoinTimeoutMs.store(workerJoinTimeoutMs, moRelease)
  gExtLibOwnsHost.store(true, moRelease)
  ok()

proc extLibCtxClose(ctx: BrokerContext) {.nimcall, gcsafe, raises: [].} =
  ## `<lib>_shutdown(ctx)`, before it joins the context's threads: the bridge
  ## closes every port bound to `ctx` (withdraws its names, uninstalls what it
  ## auto-wired, fails pending calls; queued worker calls never run), then
  ## the K2 peer contexts that served `ctx` are shut down. No-op while the
  ## host is stopped.
  {.cast(gcsafe).}:
    if not hostRunning():
      return
    let rc = postCtl(ecoCloseCtx, 0, 0, 0, -1, uint32(ctx))
    if rc != ExtOk:
      # ExtShutdown: a concurrent host stop closes the ports instead.
      if rc != ExtShutdown:
        warn "EXTAPI: ports of a shut-down context not closed",
          ctx = uint32(ctx), rc = rc
      return
    for p in 0 ..< gExtPluginCount.load(moAcquire):
      let rt = gExtPlugins[p]
      if rt.peerFns.isNil:
        continue
      var mine: array[ExtMaxPorts, ptr ExtPeerUser]
      var k = 0
      withLock(rt.lock):
        for s in 0 ..< ExtMaxPorts:
          let u = rt.peers[s]
          if not u.isNil and u.hostCtx == uint32(ctx):
            rt.peers[s] = nil
            mine[k] = u
            inc k
      for i in 0 ..< k:
        shutdownPeer(rt, mine[i])

proc extLibIdle() {.nimcall, gcsafe, raises: [].} =
  ## The library's last context has shut down: stop the host if
  ## `<lib>_extHost()` started it. Refused (logged, host left running) when
  ## called on the bridge or a worker thread. A worker that outlives the join
  ## bound is logged; the host is stopped all the same.
  var expected = true
  if not gExtLibOwnsHost.compareExchange(expected, false):
    return
  {.cast(gcsafe).}:
    let ms = gExtLibJoinTimeoutMs.load(moAcquire)
    if onBridgeThread() or gExtIsWorker:
      gExtLibOwnsHost.store(true, moRelease)
      warn "EXTAPI: host not stopped after the last library context",
        reason = "the last shutdown ran on the bridge or a worker thread"
      return
    let r = extHostStop(
      if ms > 0:
        chronos.milliseconds(ms)
      else:
        ZeroDuration
    )
    if r.isErr:
      # Stopped, but a worker stuck in a foreign `invoke` was leaked.
      warn "EXTAPI: host stopped after the last library context", reason = r.error

gApiLibCtxCloseHook = extLibCtxClose
gApiLibIdleHook = extLibIdle

{.pop.}
