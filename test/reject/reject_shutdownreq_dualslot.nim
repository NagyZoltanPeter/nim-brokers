# The teardown hook is author-only: `<lib>_shutdown` invokes its zero-argument
# signature and it is not published as a request (issue #49). An argument-based
# second slot could therefore never run — and it would additionally rename the
# zero-arg slot's wire name (`shutdown_request` -> `shutdown_request_zero`).
# Declaring one must be a hard error, not a silently dead entry point.
import results, chronos
import brokers/[request_broker, broker_context, api_library]

RequestBroker(API):
  type InitializeRequest = object
    initialized*: bool

  proc signature*(
    configPath: string
  ): Future[Result[InitializeRequest, string]] {.async.}

RequestBroker(API):
  type ShutdownRequest = object
    status*: int32

  proc signature*(): Future[Result[ShutdownRequest, string]] {.async.}
  proc signature2*(reason: string): Future[Result[ShutdownRequest, string]] {.async.}

proc setupProviders(ctx: BrokerContext): Result[void, string] =
  return Result[void, string].ok()

registerBrokerLibrary:
  name:
    "sdrej2"
  version:
    "0.1.0"
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest
