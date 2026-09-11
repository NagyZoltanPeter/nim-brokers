# `<lib>_shutdown` auto-invokes the teardown provider through its ZERO-ARGUMENT
# signature (issue #49) — it has no payload to supply. A shutdownRequest declared
# with only an arg-based signature must be a hard error, not a silent skip.
# Opting out with `invokeShutdownRequest: false` is the escape hatch.
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

  # Arg-based only — no zero-arg slot for `_shutdown` to call.
  proc signature*(reason: string): Future[Result[ShutdownRequest, string]] {.async.}

proc setupProviders(ctx: BrokerContext): Result[void, string] =
  return Result[void, string].ok()

registerBrokerLibrary:
  name:
    "sdrej"
  version:
    "0.1.0"
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest
