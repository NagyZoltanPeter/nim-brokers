## A small nim-brokers FFI library used as a K2 peer by test_ext_imports.nim.
## Built at test time with `--app:lib -d:BrokerFfiApi --nimMainPrefix:peerlib`.

import chronos, results
import
  brokers/[request_broker, event_broker, signal_broker, broker_context, api_library]

RequestBroker(API):
  type InitializeRequest = object
    initialized*: bool

  proc signature*(): Future[Result[InitializeRequest, string]] {.async.}

RequestBroker(API):
  type ShutdownRequest = object
    status*: int32

  proc signature*(): Future[Result[ShutdownRequest, string]] {.async.}

RequestBroker(API):
  type PeerEcho = object
    text*: string

  proc signature*(text: string): Future[Result[PeerEcho, string]] {.async.}

RequestBroker(API):
  type PeerFail = object
    n*: int32

  proc signature*(): Future[Result[PeerFail, string]] {.async.}

EventBroker(API):
  type PeerTick = object
    n*: int32

SignalBroker(API):
  type PeerPoke = object
    n*: int32

proc setupProviders(ctx: BrokerContext): Result[void, string] =
  proc initProv(): Future[Result[InitializeRequest, string]] {.async.} =
    return ok(InitializeRequest(initialized: true))

  ?InitializeRequest.setProvider(ctx, initProv)

  proc shutProv(): Future[Result[ShutdownRequest, string]] {.async.} =
    return ok(ShutdownRequest(status: 0))

  ?ShutdownRequest.setProvider(ctx, shutProv)

  proc echoProv(text: string): Future[Result[PeerEcho, string]] {.async.} =
    PeerTick.emit(ctx, PeerTick(n: int32(text.len)))
    return ok(PeerEcho(text: "peer:" & text))

  ?PeerEcho.setProvider(ctx, echoProv)

  proc failProv(): Future[Result[PeerFail, string]] {.async.} =
    return err("nope")

  ?PeerFail.setProvider(ctx, failProv)

  ?PeerPoke.onSignal(
    ctx,
    proc(p: PeerPoke) {.async: (raises: []).} =
      PeerTick.emit(ctx, PeerTick(n: 100 + p.n)),
  )
  ok()

registerBrokerLibrary:
  name:
    "peerlib"
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest
