{.used.}

## Tests for SignalBroker support inside the hierarchical / OOP broker layer:
## a `SignalBroker:` block declared in a `BrokerInterface`, fulfilled by handler
## `method` overrides in a `BrokerImplement` derived type. Covers both a PAYLOAD
## signal (matched to its handler by parameter type) and a VOID (pulse) signal
## (matched by the `on<Signal>` method-name convention), alongside a coexisting
## RequestBroker and EventBroker. Plain (non-API) interface — single thread.

import testutils/unittests
import chronos

import brokers/broker_interface
import brokers/broker_implement

BrokerInterface(IWorker):
  RequestBroker:
    proc ping(): Future[Result[string, string]] {.async.}

  EventBroker:
    type Announced = object
      what: string

  SignalBroker:
    type Shutdown = object
      reason: string

  SignalBroker:
    type Restart = object
      mode: string

  SignalBroker:
    type Heartbeat = void

type WorkerImpl = ref object of IWorker
  lastReason: string
  lastMode: string
  beats: int

BrokerImplement WorkerImpl of IWorker:
  proc new(T: typedesc[WorkerImpl]): WorkerImpl =
    WorkerImpl()

  method ping(self: WorkerImpl): Future[Result[string, string]] {.async.} =
    ok("pong")

  # Payload signal handler — bound to `Shutdown` by the `on<Signal>` name.
  method onShutdown(
      self: WorkerImpl, s: Shutdown
  ): Future[void] {.async: (raises: []), gcsafe.} =
    self.lastReason = s.reason

  # Payload signal handler — bound to `Restart` by the EXACT signal name.
  method Restart(
      self: WorkerImpl, s: Restart
  ): Future[void] {.async: (raises: []), gcsafe.} =
    self.lastMode = s.mode

  # Void (pulse) signal handler — bound to `Heartbeat` by the `on<Signal>` name.
  method onHeartbeat(self: WorkerImpl): Future[void] {.async: (raises: []), gcsafe.} =
    inc self.beats

proc drain() =
  ## Signals are fire-and-forget (sync call site + asyncSpawn); drain the loop so
  ## spawned handler tasks complete before asserting.
  waitFor sleepAsync(chronos.milliseconds(20))

suite "BrokerInterface + SignalBroker: coexistence with request/event":
  test "request still dispatches through the broker":
    let w = WorkerImpl.create()
    check (waitFor Ping.request(w.brokerCtx)).value == "pong"
    w.close()

  test "event facade still works alongside signals":
    let w = WorkerImpl.create()
    let fut = newFuture[string]("iface-signal-event")
    discard w.listen(
      Announced,
      proc(ev: Announced): Future[void] {.async: (raises: []), gcsafe.} =
        if not fut.finished:
          fut.complete(ev.what),
    )
    w.emit(Announced, Announced(what: "hi"))
    check (waitFor fut) == "hi"
    w.close()

suite "BrokerInterface + SignalBroker: payload signal":
  test "signal via the value facade dispatches to the handler":
    let w = WorkerImpl.create()
    check w.signal(Shutdown, Shutdown(reason: "bye")).isOk()
    drain()
    check w.lastReason == "bye"
    w.close()

  test "signal via the inline-field facade overload":
    let w = WorkerImpl.create()
    check w.signal(Shutdown, reason = "again").isOk()
    drain()
    check w.lastReason == "again"
    w.close()

  test "signal via the bare broker surface on the instance ctx":
    let w = WorkerImpl.create()
    check Shutdown.signal(w.brokerCtx, Shutdown(reason: "direct")).isOk()
    drain()
    check w.lastReason == "direct"
    w.close()

  test "payload signal handler bound by EXACT signal name":
    let w = WorkerImpl.create()
    check w.signal(Restart, mode = "hard").isOk()
    drain()
    check w.lastMode == "hard"
    w.close()

suite "BrokerInterface + SignalBroker: void (pulse) signal":
  test "void signal via the facade increments the counter":
    let w = WorkerImpl.create()
    check w.signal(Heartbeat).isOk()
    drain()
    check w.beats == 1
    w.close()

  test "void signal via the bare broker surface":
    let w = WorkerImpl.create()
    check Heartbeat.signal(w.brokerCtx).isOk()
    drain()
    check w.beats == 1
    w.close()

suite "BrokerInterface + SignalBroker: instance isolation + teardown":
  test "distinct instances route signals to their own handler":
    let a = WorkerImpl.create()
    let b = WorkerImpl.create()
    check a.brokerCtx != b.brokerCtx
    check a.signal(Shutdown, reason = "a").isOk()
    drain()
    check a.lastReason == "a"
    check b.lastReason == "" # b untouched
    a.close()
    b.close()

  test "close() drops both the payload and the void signal handlers":
    let w = WorkerImpl.create()
    let ctx = w.brokerCtx
    w.close()
    check Shutdown.signal(ctx, Shutdown(reason: "x")).isErr()
    check Heartbeat.signal(ctx).isErr()

  test "close() is idempotent with signal handlers present":
    let w = WorkerImpl.create()
    w.close()
    w.close()
