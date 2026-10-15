## Test library for `test_api_module_init_once`: counts how often this
## module's top-level code runs. Built with `--app:lib`, so its module
## initialiser is driven by the platform loader hook (`NimMainInit`
## constructor on POSIX, `DllMain` on Windows) and must run exactly once,
## however often the consumer calls `initoncelib_initialize`.

import std/atomics
import results
import brokers/[request_broker, broker_context, api_library]

# Zero-initialised storage (no runtime initialiser): a second module-init run
# cannot reset it, so the count records every run.
var gModuleInitRuns {.noinit.}: Atomic[int]

discard gModuleInitRuns.fetchAdd(1, moRelaxed)

proc initoncelib_moduleInitRuns(): cint {.exportc, cdecl, dynlib.} =
  cint(gModuleInitRuns.load(moRelaxed))

RequestBroker(API):
  type InitializeRequest = object
    initialized*: bool

  proc signature*(): Future[Result[InitializeRequest, string]] {.async.}

RequestBroker(API):
  type ShutdownRequest = object
    status*: int32

  proc signature*(): Future[Result[ShutdownRequest, string]] {.async.}

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
    "initoncelib"
  version:
    "0.1.0"
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest
