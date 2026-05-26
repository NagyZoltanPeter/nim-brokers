## hierlib — Broker FFI API example built with the OOP interface model.
##
## A single main `BrokerInterface(API)` defines the whole library surface; a
## `BrokerImplement` provides the request methods; `bindToContext` adopts the
## FFI context allocated by `<lib>_createContext` and wires the providers; and
## `registerBrokerLibrary` emits the C ABI + wrappers — exactly the same ABI a
## flat (mylib-style) library produces, but authored as an interface + impl.
##
## Build & run via nimble:
##   nimble buildHierExample        # lib -> nimlib/build/
##   nimble runHierExamplePy        # + Python wrapper + python_example/main.py

import results, chronos
import brokers/broker_interface
import brokers/broker_implement
import brokers/api_library

BrokerInterface(API, IHier):
  EventBroker:
    type Tick = object
      n: int32

  RequestBroker:
    proc getValue(): Future[Result[int32, string]] {.async.}

  RequestBroker:
    proc echoLen(s: string): Future[Result[int32, string]] {.async.}

  RequestBroker:
    proc fireTick(n: int32): Future[Result[int32, string]] {.async.}

  RequestBroker:
    type InitializeRequest = object
      ok*: bool

    proc initializeRequest(
      configPath: string
    ): Future[Result[InitializeRequest, string]] {.async.}

  RequestBroker:
    type ShutdownRequest = object
      status*: int32

    proc shutdownRequest(): Future[Result[ShutdownRequest, string]] {.async.}

type HierImpl = ref object of IHier
  value: int32

BrokerImplement HierImpl of IHier:
  proc init() =
    self.value = 7

  method getValue(self: HierImpl): Future[Result[int32, string]] {.async.} =
    ok(self.value)

  method echoLen(self: HierImpl, s: string): Future[Result[int32, string]] {.async.} =
    ok(int32(s.len))

  method fireTick(self: HierImpl, n: int32): Future[Result[int32, string]] {.async.} =
    # Emit an event through the instance-scoped facade (injects self.brokerCtx).
    await self.emit(Tick, Tick(n: n))
    ok(n)

  method initializeRequest(
      self: HierImpl, configPath: string
  ): Future[Result[InitializeRequest, string]] {.async.} =
    ok(InitializeRequest(ok: true))

  method shutdownRequest(
      self: HierImpl
  ): Future[Result[ShutdownRequest, string]] {.async.} =
    ok(ShutdownRequest(status: 0))

proc setupProviders(ctx: BrokerContext): Result[void, string] =
  ## Called by registerBrokerLibrary on the processing thread: construct the
  ## main impl adopting the FFI context, wiring its providers under `ctx`.
  discard HierImpl.bindToContext(ctx)
  ok()

registerBrokerLibrary:
  name:
    "hierlib"
  version:
    "0.1.0"
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest
