## pytestlib — Minimal API test library for Python binding validation
## ==================================================================
## Small library exercising context separation, requests, events, and
## lifecycle through the generated Python wrapper.
##
## Build (from repo root):
##   nimble buildPyTestLib

{.push raises: [].}

import brokers/[event_broker, request_broker, broker_context]

when defined(BrokerFfiApi):
  import brokers/api_library

# ---------------------------------------------------------------------------
# Request Brokers
# ---------------------------------------------------------------------------

RequestBroker(API):
  type InitializeRequest = object
    label*: string

  proc signature*(label: string): Future[Result[InitializeRequest, string]] {.async.}

RequestBroker(API):
  type ShutdownRequest = object
    status*: int32

  proc signature*(): Future[Result[ShutdownRequest, string]] {.async.}

RequestBroker(API):
  type EchoRequest = object
    reply*: string

  proc signature*(message: string): Future[Result[EchoRequest, string]] {.async.}

RequestBroker(API):
  type CounterRequest = object
    value*: int32

  proc signature*(): Future[Result[CounterRequest, string]] {.async.}

# ---------------------------------------------------------------------------
# Event Brokers
# ---------------------------------------------------------------------------

EventBroker(API):
  type CounterChanged = object
    value*: int32

# ---------------------------------------------------------------------------
# Provider state (per processing thread = per context)
# ---------------------------------------------------------------------------

var gLabel {.threadvar.}: string
var gCounter {.threadvar.}: int32
var gProviderCtx {.threadvar.}: BrokerContext

proc setupProviders(ctx: BrokerContext) =
  gProviderCtx = ctx
  gCounter = 0
  gLabel = ""

  discard InitializeRequest.setProvider(
    ctx,
    proc(label: string): Future[Result[InitializeRequest, string]] {.closure, async.} =
      gLabel = label
      return ok(InitializeRequest(label: label)),
  )

  discard ShutdownRequest.setProvider(
    ctx,
    proc(): Future[Result[ShutdownRequest, string]] {.closure, async.} =
      return ok(ShutdownRequest(status: 0)),
  )

  discard EchoRequest.setProvider(
    ctx,
    proc(message: string): Future[Result[EchoRequest, string]] {.closure, async.} =
      return ok(EchoRequest(reply: gLabel & ":" & message)),
  )

  discard CounterRequest.setProvider(
    ctx,
    proc(): Future[Result[CounterRequest, string]] {.closure, async.} =
      inc gCounter
      await CounterChanged.emit(gProviderCtx, CounterChanged(value: gCounter))
      return ok(CounterRequest(value: gCounter)),
  )

# ---------------------------------------------------------------------------
# Library registration
# ---------------------------------------------------------------------------

when defined(BrokerFfiApi):
  registerBrokerLibrary:
    name:
      "pytestlib"
    initializeRequest:
      InitializeRequest
    shutdownRequest:
      ShutdownRequest
