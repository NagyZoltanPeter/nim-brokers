## Lib-mode EXTAPI teardown: `<lib>_shutdown(ctx)` closes the plugin ports
## opened on `ctx`, and the shutdown of the library's last context stops the
## EXTAPI host that `<lib>_extHost()` started (bridge + worker pools joined).
## See doc/FFI_API.md § "EXTAPI" ("Lib-mode teardown").
##
## The library under test (`test/extteardownlib/extteardownlib.nim`, built
## with `-d:extTestHooks`) is built by the `testApi` task and its path passed
## in via `-d:extTeardownLib=<path>`. The test is a plain foreign host: it
## mirrors the `broker_ext_host` ABI below and opens ports like a C plugin.

import std/[atomics, dynlib, os, times]
import testutils/unittests

const extTeardownLib {.strdefine.} = ""

const
  ExtAbiVersion = 1'u32
  ExtCapNonBlocking = 1'u32 # required for the `bridge`-dispatch `td_bridge`
  ExtOk = 0'i32
  ExtShutdown = -11'i32
  ExtStale = -15'i32

type
  ExtInvokeFn = proc(
    user: pointer,
    id: uint64,
    nameIdx: uint32,
    name: cstring,
    buf: ptr uint8,
    len: csize_t,
  ) {.cdecl, gcsafe, raises: [].}
  ExtCancelFn = proc(user: pointer, id: uint64) {.cdecl, gcsafe, raises: [].}
  ExtReleaseFn = proc(user: pointer) {.cdecl, gcsafe, raises: [].}

  ExtImplDesc {.bycopy.} = object ## `broker_ext_impl`
    abiVersion: uint32
    plugin: cstring
    schemaHash: cstring
    caps: uint32
    invoke: ExtInvokeFn
    cancel: ExtCancelFn
    release: ExtReleaseFn
    user: pointer

  ExtHostTable {.bycopy.} = object ## `broker_ext_host`, prefix used here
    abiVersion: uint32
    host: pointer
    open: proc(
      host: pointer, ctx: uint32, impl: ptr ExtImplDesc, outPort: ptr uint64
    ): int32 {.cdecl, gcsafe, raises: [].}
    close: proc(host: pointer, port: uint64): int32 {.cdecl, gcsafe, raises: [].}
    provide: proc(host: pointer, port: uint64, name: cstring): int32 {.
      cdecl, gcsafe, raises: []
    .}

  VoidFn = proc() {.cdecl, gcsafe, raises: [].}
  CountFn = proc(): cint {.cdecl, gcsafe, raises: [].}
  CreateCtxFn = proc(): uint32 {.cdecl, gcsafe, raises: [].}
  ShutdownFn = proc(ctx: uint32): int32 {.cdecl, gcsafe, raises: [].}
  ExtHostFn = proc(): ptr ExtHostTable {.cdecl, gcsafe, raises: [].}
  KickFn = proc(ctx: uint32) {.cdecl, gcsafe, raises: [].}

var gReleases: Atomic[int]
var gGate: Atomic[int] # 0: `td_work` invokes park until it is opened
var gParked: Atomic[int] # `td_work` invokes that parked

# Called on the library's bridge thread (foreign to this program's runtime).
{.push checks: off, stackTrace: off, lineTrace: off.}
proc tdInvoke(
    user: pointer,
    id: uint64,
    nameIdx: uint32,
    name: cstring,
    buf: ptr uint8,
    len: csize_t,
) {.cdecl, gcsafe, raises: [].} =
  # Only `td_work` (a worker name) is ever called: it parks while the gate
  # is closed, standing in for a plugin stuck in blocking code. No reply:
  # by the time it returns, its call has been failed by the teardown.
  if gGate.load() == 0:
    discard gParked.fetchAdd(1)
    while gGate.load() == 0:
      sleep(1)

proc tdRelease(user: pointer) {.cdecl, gcsafe, raises: [].} =
  discard gReleases.fetchAdd(1)

{.pop.}

proc openTd(t: ptr ExtHostTable, ctx: uint32, port: var uint64): int32 =
  var impl = ExtImplDesc(
    abiVersion: ExtAbiVersion,
    plugin: "td",
    caps: ExtCapNonBlocking,
    invoke: tdInvoke,
    release: tdRelease,
  )
  t.open(t.host, ctx, addr impl, addr port)

proc eventually(f: CountFn, want: cint): cint =
  ## Worker threads count their start asynchronously (the host does not wait
  ## for them); exits are ordered by the join, so they are checked directly.
  for _ in 0 ..< 2000:
    if f() == want:
      break
    sleep(1)
  f()

gGate.store(1)

suite "EXTAPI lib-mode teardown":
  test "_shutdown closes a context's ports; the last one stops the host":
    doAssert extTeardownLib.len > 0, "build with -d:extTeardownLib=<path>"
    let lib = loadLib(extTeardownLib)
    doAssert lib != nil, "cannot load " & extTeardownLib

    let initialize = cast[VoidFn](lib.checkedSymAddr("extteardownlib_initialize"))
    let createContext =
      cast[CreateCtxFn](lib.checkedSymAddr("extteardownlib_createContext"))
    let shutdown = cast[ShutdownFn](lib.checkedSymAddr("extteardownlib_shutdown"))
    let extHost = cast[ExtHostFn](lib.checkedSymAddr("extteardownlib_extHost"))
    let bridgeStarts = cast[CountFn](lib.checkedSymAddr("extteardownlib_bridgeStarts"))
    let bridgeExits = cast[CountFn](lib.checkedSymAddr("extteardownlib_bridgeExits"))
    let workerStarts = cast[CountFn](lib.checkedSymAddr("extteardownlib_workerStarts"))
    let workerExits = cast[CountFn](lib.checkedSymAddr("extteardownlib_workerExits"))

    initialize()
    let ctx1 = createContext()
    let ctx2 = createContext()
    check ctx1 != 0'u32
    check ctx2 != 0'u32

    let t = extHost()
    check t != nil
    check bridgeStarts() == 1
    check bridgeExits() == 0
    check eventually(workerStarts, 2) == 2 # `workers(2)`

    var p1, p2: uint64
    check openTd(t, ctx1, p1) == ExtOk
    check t.provide(t.host, p1, "td_work") == ExtOk
    check t.provide(t.host, p1, "td_bridge") == ExtOk
    check openTd(t, ctx2, p2) == ExtOk
    check t.provide(t.host, p2, "td_work") == ExtOk

    # ctx1 down: its port is closed and released, ctx2's is untouched and the
    # host keeps running for it.
    check shutdown(ctx1) == 0
    check gReleases.load() == 1
    check t.provide(t.host, p1, "td_work") == ExtStale
    check t.provide(t.host, p2, "td_bridge") == ExtOk
    check bridgeExits() == 0
    check workerExits() == 0

    # Last context down: the host stops, bridge and both workers joined.
    check shutdown(ctx2) == 0
    check gReleases.load() == 2
    check bridgeExits() == 1
    check workerExits() == 2
    var p: uint64
    check openTd(t, ctx2, p) == ExtShutdown

    # A new context + `_extHost()` starts the host again.
    let ctx3 = createContext()
    check ctx3 != 0'u32
    check extHost() == t
    check bridgeStarts() == 2
    check eventually(workerStarts, 4) == 4
    var p3: uint64
    check openTd(t, ctx3, p3) == ExtOk
    check t.provide(t.host, p3, "td_work") == ExtOk
    check shutdown(ctx3) == 0
    check gReleases.load() == 3
    check bridgeExits() == 2
    check workerExits() == 4
    # No unloadLib: a Nim runtime is not designed to be unloaded.

  test "the last _shutdown leaks a stuck worker after the join bound":
    # Same process and library as above: the host was stopped twice so far
    # (two bridge starts, four worker starts / exits).
    let lib = loadLib(extTeardownLib)
    doAssert lib != nil
    let createContext =
      cast[CreateCtxFn](lib.checkedSymAddr("extteardownlib_createContext"))
    let shutdown = cast[ShutdownFn](lib.checkedSymAddr("extteardownlib_shutdown"))
    let extHost = cast[ExtHostFn](lib.checkedSymAddr("extteardownlib_extHost"))
    let workerStarts = cast[CountFn](lib.checkedSymAddr("extteardownlib_workerStarts"))
    let workerExits = cast[CountFn](lib.checkedSymAddr("extteardownlib_workerExits"))
    let bridgeExits = cast[CountFn](lib.checkedSymAddr("extteardownlib_bridgeExits"))
    let leaked = cast[CountFn](lib.checkedSymAddr("extteardownlib_leakedWorkers"))
    let kickWork = cast[KickFn](lib.checkedSymAddr("extteardownlib_kickWork"))
    let joinKick = cast[CountFn](lib.checkedSymAddr("extteardownlib_joinKick"))

    let ctx = createContext()
    let t = extHost()
    check t != nil
    check eventually(workerStarts, 6) == 6
    var p: uint64
    check openTd(t, ctx, p) == ExtOk
    check t.provide(t.host, p, "td_work") == ExtOk

    gGate.store(0)
    kickWork(ctx)
    for _ in 0 ..< 2000:
      if gParked.load() == 1:
        break
      sleep(1)
    check gParked.load() == 1

    # The worker stays inside `invoke`: `_shutdown` gives up after the 200 ms
    # bound (`exportExtHost(…, workerJoinTimeoutMs = 200)`) instead of
    # hanging, still returns 0 and still stops the host.
    let t0 = epochTime()
    check shutdown(ctx) == 0
    check epochTime() - t0 < 2.0
    check joinKick() == 1 # the parked request failed when its port closed
    check bridgeExits() == 3
    check workerExits() == 5 # the idle worker was joined
    check leaked() == 1
    check openTd(t, ctx, p) == ExtShutdown

    # Released, the stuck worker leaves; the next start joins and frees it.
    gGate.store(1)
    check eventually(workerExits, 6) == 6
    let ctx2 = createContext()
    check extHost() == t
    check leaked() == 0
    check shutdown(ctx2) == 0
    check bridgeExits() == 4
