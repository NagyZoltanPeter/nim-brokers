## Test library for `test_api_ext_lib_teardown`: a lib-mode EXTAPI library
## (storagelib-style) whose host application provides the `td` plugin through
## `extteardownlib_extHost()`. Built with `-d:extTestHooks`; exports the
## bridge / worker thread counters so the test can check that `_shutdown`
## joins them.

import std/atomics
import results
import brokers/[request_broker, broker_context, api_library, ext_plugin]

RequestBroker(API):
  type InitializeRequest = object
    initialized*: bool

  proc signature*(): Future[Result[InitializeRequest, string]] {.async.}

RequestBroker(API):
  type ShutdownRequest = object
    status*: int32

  proc signature*(): Future[Result[ShutdownRequest, string]] {.async.}

# Consumed: implemented by the host application. `workers(2)` gives the
# plugin a worker pool next to the shared bridge thread.
RequestBroker(EXTAPI[td], dispatch = workers(2)):
  type TdWork = object
    n*: int32

  proc signature*(): Future[Result[TdWork, string]] {.async.}

RequestBroker(EXTAPI[td]):
  type TdBridge = object
    n*: int32

  proc signature*(): Future[Result[TdBridge, string]] {.async.}

registerExtPlugin(td, version = "1.0.0")
# A short join bound: the stuck-worker test must not wait the 5 s default.
exportExtHost("extteardownlib", workerJoinTimeoutMs = 200)

proc extteardownlib_bridgeStarts(): cint {.exportc, cdecl, dynlib.} =
  cint(extTestBridgeStarts.load())

proc extteardownlib_bridgeExits(): cint {.exportc, cdecl, dynlib.} =
  cint(extTestBridgeExits.load())

proc extteardownlib_workerStarts(): cint {.exportc, cdecl, dynlib.} =
  cint(extTestWorkerStarts.load())

proc extteardownlib_workerExits(): cint {.exportc, cdecl, dynlib.} =
  cint(extTestWorkerExits.load())

proc extteardownlib_leakedWorkers(): cint {.exportc, cdecl, dynlib.} =
  cint(ExtHost.leakedWorkers())

# A `td_work` request from a thread of the library, so the test can park the
# host application's `invoke` on a worker without a chronos loop of its own.
var gKick: Thread[uint32]
var gKickDone: Atomic[bool]

proc kickProc(ctx: uint32) {.thread.} =
  discard TdWork.blockingRequest(BrokerContext(ctx))
  gKickDone.store(true)

proc extteardownlib_kickWork(ctx: uint32) {.exportc, cdecl, dynlib.} =
  gKickDone.store(false)
  createThread(gKick, kickProc, ctx)

proc extteardownlib_joinKick(): cint {.exportc, cdecl, dynlib.} =
  ## 1 when the kicked request returned (it fails once its port is closed).
  joinThread(gKick)
  cint(gKickDone.load())

proc setupProviders(ctx: BrokerContext): Result[void, string] =
  proc initProv(): Future[Result[InitializeRequest, string]] {.async.} =
    return ok(InitializeRequest(initialized: true))

  proc shutProv(): Future[Result[ShutdownRequest, string]] {.async.} =
    return ok(ShutdownRequest(status: 0))

  ?InitializeRequest.setProvider(ctx, initProv)
  ?ShutdownRequest.setProvider(ctx, shutProv)
  ok()

registerBrokerLibrary:
  name:
    "extteardownlib"
  version:
    "1.0.0"
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest
