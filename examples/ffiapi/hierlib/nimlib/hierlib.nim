## hierlib — Broker FFI API example built with the OOP interface model.
##
## A single main `BrokerInterface(API)` defines the whole library surface; a
## `BrokerImplement` provides the request methods; `createUnderContext` adopts the
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

# --- Sub-interface (reduced-A): created at runtime by the main interface via a
# create-instance request. It has its own typed wrapper class; calls route to
# the same library processing thread (shared classCtx, distinct instanceCtx).
BrokerInterface(API, IWidget):
  RequestBroker:
    proc area(): Future[Result[int32, string]] {.async.}

  RequestBroker:
    proc scale(factor: int32): Future[Result[int32, string]] {.async.}

  # Sub-interface one-way signal: nudges this widget's size. Over FFI it routes
  # to THIS widget instance by its BrokerContext (the wrapper emits it on the
  # Widget sub-class, not the main Hier class). Observable via area().
  SignalBroker:
    type ResizeSignal = object
      delta: int32

BrokerInterface(API, IHier):
  EventBroker:
    type Tick = object
      n: int32

  RequestBroker:
    proc getValue(): Future[Result[int32, string]] {.async.}

  # Create-instance request: returns a sub-interface ref. Over FFI the wire
  # carries the sub-instance's BrokerContext (uint32); the wrapper turns it into
  # a typed Widget object.
  RequestBroker:
    proc makeWidget(size: int32): Future[Result[IWidget, string]] {.async.}

  RequestBroker:
    proc echoLen(s: string): Future[Result[int32, string]] {.async.}

  RequestBroker:
    proc fireTick(n: int32): Future[Result[int32, string]] {.async.}

  # One-way signal (fire-and-forget, slot-free `_call`): a foreign caller nudges
  # the value; the effect is observable through `getValue`. Demonstrates a
  # SignalBroker over FFI declared inside a BrokerInterface(API).
  SignalBroker:
    type NudgeSignal = object
      by: int32

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

type WidgetImpl = ref object of IWidget
  size: int32

BrokerImplement WidgetImpl of IWidget:
  proc new(T: typedesc[WidgetImpl], size: int32): WidgetImpl =
    WidgetImpl(size: size)

  method area(self: WidgetImpl): Future[Result[int32, string]] {.async.} =
    ok(self.size * self.size)

  method scale(
      self: WidgetImpl, factor: int32
  ): Future[Result[int32, string]] {.async.} =
    self.size = self.size * factor
    ok(self.size)

  # Signal handler — bound to `ResizeSignal` by the `on<Signal>` name. One-way:
  # mutates this instance's size, observable via area().
  method onResizeSignal(
      self: WidgetImpl, s: ResizeSignal
  ): Future[void] {.async: (raises: []), gcsafe.} =
    self.size += s.delta

type HierImpl = ref object of IHier
  value: int32

BrokerImplement HierImpl of IHier:
  proc new(T: typedesc[HierImpl]): HierImpl =
    HierImpl(value: 7)

  method getValue(self: HierImpl): Future[Result[int32, string]] {.async.} =
    ok(self.value)

  method makeWidget(
      self: HierImpl, size: int32
  ): Future[Result[IWidget, string]] {.async.} =
    # Build a sub-instance that SHARES this library's classCtx (so its calls
    # route to the same processing thread) but gets a fresh instanceCtx. Use
    # createUnderContext, NOT create() (create() would allocate its own classCtx
    # and break the classCtx-mask routing). gcsafe: create/createUnderContext
    # are gcsafe (A0).
    let w = WidgetImpl.createUnderContext(newInstanceCtx(self.brokerCtx), size)
    ok(IWidget(w))

  method echoLen(self: HierImpl, s: string): Future[Result[int32, string]] {.async.} =
    ok(int32(s.len))

  method fireTick(self: HierImpl, n: int32): Future[Result[int32, string]] {.async.} =
    # Emit an event through the instance-scoped facade (injects self.brokerCtx).
    self.emit(Tick, Tick(n: n))
    ok(n)

  # Signal handler — bound to `NudgeSignal` by the `on<Signal>` name. One-way:
  # no response; the mutation is observable via getValue.
  method onNudgeSignal(
      self: HierImpl, s: NudgeSignal
  ): Future[void] {.async: (raises: []), gcsafe.} =
    self.value += s.by

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
  discard HierImpl.createUnderContext(ctx)
  ok()

registerBrokerLibrary:
  name:
    "hierlib"
  version:
    "0.1.0"
  mainClass:
    IHier
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest
