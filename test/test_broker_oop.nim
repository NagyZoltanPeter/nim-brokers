{.used.}

## Tests for the hierarchical / OOP broker layer: BrokerInterface (abstract
## facade + event facade + factory/DI) and BrokerImplement (derived impl with
## per-instance providers + close). Plain (non-API) interface — single thread.

import testutils/unittests
import chronos

import brokers/broker_interface
import brokers/broker_implement

BrokerInterface(IGreeter):
  EventBroker:
    type Greeted = object
      who: string

  RequestBroker:
    proc greet(name: string): Future[Result[string, string]] {.async.}

  RequestBroker:
    proc version(): Future[Result[string, string]] {.async.}

type GreeterImpl = ref object of IGreeter
  prefix: string

BrokerImplement GreeterImpl of IGreeter:
  proc init(prefix: string) =
    self.prefix = prefix

  method greet(
      self: GreeterImpl, name: string
  ): Future[Result[string, string]] {.async.} =
    ok(self.prefix & name)

  method version(self: GreeterImpl): Future[Result[string, string]] {.async.} =
    ok("v2")

suite "BrokerImplement: instance lifecycle + dispatch":
  test "new() runs init and wires providers; request dispatches to the override":
    let g = GreeterImpl.new(prefix = "hello ")
    check (waitFor Greet.request(g.brokerCtx, "bob")).value == "hello bob"
    check (waitFor Version.request(g.brokerCtx)).value == "v2"

  test "virtual dispatch through a base-typed ref resolves to the override":
    let g = GreeterImpl.new(prefix = "hi ")
    let base: IGreeter = g
    check (waitFor base.greet("sue")).value == "hi sue"

  test "instances get independent contexts and providers":
    let a = GreeterImpl.new(prefix = "a:")
    let b = GreeterImpl.new(prefix = "b:")
    check a.brokerCtx != b.brokerCtx
    check (waitFor Greet.request(a.brokerCtx, "x")).value == "a:x"
    check (waitFor Greet.request(b.brokerCtx, "x")).value == "b:x"

  test "close() clears this instance's providers, leaving others intact":
    let a = GreeterImpl.new(prefix = "a:")
    let b = GreeterImpl.new(prefix = "b:")
    let actx = a.brokerCtx
    a.close()
    check (waitFor Greet.request(actx, "x")).isErr() # a cleared
    check (waitFor Greet.request(b.brokerCtx, "x")).value == "b:x" # b intact
    b.close()

  test "close() is idempotent":
    let g = GreeterImpl.new(prefix = "g:")
    g.close()
    g.close() # must not raise

suite "BrokerInterface: event facade":
  test "self.listen + self.emit inject the instance context":
    let g = GreeterImpl.new(prefix = "x")
    let fut = newFuture[string]("oop-event")
    discard g.listen(
      Greeted,
      proc(ev: Greeted): Future[void] {.async: (raises: []), gcsafe.} =
        if not fut.finished:
          fut.complete(ev.who),
    )
    g.emit(Greeted, Greeted(who: "bob"))
    check (waitFor fut) == "bob"

suite "BrokerInterface: factory / dependency-injection":
  test "create() errors with no factory":
    check IGreeter.create().isErr()

  test "zero-arg factory; create returns the impl behind the interface":
    IGreeter.provideFactory(
      proc(): Result[IGreeter, string] =
        ok(GreeterImpl.new(prefix = "zero:"))
    )
    let d = IGreeter.create()
    check d.isOk()
    check (waitFor d.value.greet("a")).value == "zero:a" # virtual dispatch

  test "typed-config factory (last wins) + config-type guard":
    IGreeter.provideFactory(
      proc(cfg: string): Result[IGreeter, string] =
        ok(GreeterImpl.new(prefix = cfg))
    )
    let d = IGreeter.create("cfg:")
    check d.isOk()
    check (waitFor d.value.greet("a")).value == "cfg:a"
    check IGreeter.create(123).isErr() # wrong config type
