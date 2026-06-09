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
  proc new(T: typedesc[GreeterImpl], prefix: string): GreeterImpl =
    GreeterImpl(prefix: prefix)

  method greet(
      self: GreeterImpl, name: string
  ): Future[Result[string, string]] {.async.} =
    ok(self.prefix & name)

  method version(self: GreeterImpl): Future[Result[string, string]] {.async.} =
    ok("v2")

suite "BrokerImplement: instance lifecycle + dispatch":
  test "new() runs init and wires providers; request dispatches to the override":
    let g = GreeterImpl.create(prefix = "hello ")
    check (waitFor Greet.request(g.brokerCtx, "bob")).value == "hello bob"
    check (waitFor Version.request(g.brokerCtx)).value == "v2"

  test "virtual dispatch through a base-typed ref resolves to the override":
    let g = GreeterImpl.create(prefix = "hi ")
    let base: IGreeter = g
    check (waitFor base.greet("sue")).value == "hi sue"

  test "instances get independent contexts and providers":
    let a = GreeterImpl.create(prefix = "a:")
    let b = GreeterImpl.create(prefix = "b:")
    check a.brokerCtx != b.brokerCtx
    check (waitFor Greet.request(a.brokerCtx, "x")).value == "a:x"
    check (waitFor Greet.request(b.brokerCtx, "x")).value == "b:x"

  test "close() clears this instance's providers, leaving others intact":
    let a = GreeterImpl.create(prefix = "a:")
    let b = GreeterImpl.create(prefix = "b:")
    let actx = a.brokerCtx
    a.close()
    check (waitFor Greet.request(actx, "x")).isErr() # a cleared
    check (waitFor Greet.request(b.brokerCtx, "x")).value == "b:x" # b intact
    b.close()

  test "close() is idempotent":
    let g = GreeterImpl.create(prefix = "g:")
    g.close()
    g.close() # must not raise

suite "BrokerInterface: event facade":
  test "self.listen + self.emit inject the instance context":
    let g = GreeterImpl.create(prefix = "x")
    let fut = newFuture[string]("oop-event")
    discard g.listen(
      Greeted,
      proc(ev: Greeted): Future[void] {.async: (raises: []), gcsafe.} =
        if not fut.finished:
          fut.complete(ev.who)
      ,
    )
    g.emit(Greeted, Greeted(who: "bob"))
    check (waitFor fut) == "bob"

  test "close() drops the instance's event listeners (B2)":
    let g = GreeterImpl.create(prefix = "x")
    let ctx = g.brokerCtx
    var fired = 0
    discard g.listen(
      Greeted,
      proc(ev: Greeted): Future[void] {.async: (raises: []), gcsafe.} =
        inc(fired),
    )
    g.close()
    # Emit on the (now-cleared) context directly; the listener was dropped.
    Greeted.emit(ctx, Greeted(who: "z"))
    waitFor sleepAsync(20.milliseconds)
    check fired == 0

suite "BrokerInterface: factory / dependency-injection":
  test "create() errors with no factory":
    check IGreeter.create().isErr()

  test "zero-arg factory; create returns the impl behind the interface":
    IGreeter.provideFactory(
      proc(): Result[IGreeter, string] =
        ok(GreeterImpl.create(prefix = "zero:"))
    )
    let d = IGreeter.create()
    check d.isOk()
    check (waitFor d.value.greet("a")).value == "zero:a" # virtual dispatch

  test "typed-config factory (last wins) + config-type guard":
    IGreeter.provideFactory(
      proc(cfg: string): Result[IGreeter, string] =
        ok(GreeterImpl.create(prefix = cfg))
    )
    let d = IGreeter.create("cfg:")
    check d.isOk()
    check (waitFor d.value.greet("a")).value == "cfg:a"
    check IGreeter.create(123).isErr() # wrong config type

# ---------------------------------------------------------------------------
# reduced-A: in-process multi-interface (create-instance). A main interface
# returns a sub-interface instance; the sub shares the main's classCtx (so over
# FFI `_call` routes by classCtx mask) but gets a distinct instanceCtx.
# ---------------------------------------------------------------------------

BrokerInterface(IWidget):
  RequestBroker:
    proc area(): Future[Result[int32, string]] {.async.}

  RequestBroker:
    proc scale(factor: int32): Future[Result[int32, string]] {.async.}

BrokerInterface(IFactory):
  RequestBroker:
    proc makeWidget(size: int32): Future[Result[IWidget, string]] {.async.}

type WidgetImpl2 = ref object of IWidget
  size: int32

BrokerImplement WidgetImpl2 of IWidget:
  proc new(T: typedesc[WidgetImpl2], size: int32): WidgetImpl2 =
    WidgetImpl2(size: size)

  method area(self: WidgetImpl2): Future[Result[int32, string]] {.async.} =
    ok(self.size * self.size)

  method scale(
      self: WidgetImpl2, factor: int32
  ): Future[Result[int32, string]] {.async.} =
    self.size = self.size * factor
    ok(self.size)

type FactoryImpl = ref object of IFactory

BrokerImplement FactoryImpl of IFactory:
  method makeWidget(
      self: FactoryImpl, size: int32
  ): Future[Result[IWidget, string]] {.async.} =
    # Sub-instance SHARES the factory's classCtx (routing) + a fresh instanceCtx.
    ok(IWidget(WidgetImpl2.createUnderContext(newInstanceCtx(self.brokerCtx), size)))

suite "reduced-A: in-process create-instance + sub routing invariants":
  test "makeWidget returns a working sub-instance; methods dispatch":
    let f = FactoryImpl.createUnderContext(NewBrokerContext())
    let w = (waitFor f.makeWidget(5)).value
    check (waitFor w.area()).value == 25
    check (waitFor w.scale(3)).value == 15
    check (waitFor w.area()).value == 225

  test "sub shares the factory classCtx, distinct nonzero instanceCtx":
    let f = FactoryImpl.createUnderContext(NewBrokerContext())
    let w = (waitFor f.makeWidget(2)).value
    check classCtx(w.brokerCtx) == classCtx(f.brokerCtx) # routes to same lib ctx
    check instanceCtx(w.brokerCtx) != 0'u16
    check instanceCtx(w.brokerCtx) != instanceCtx(f.brokerCtx)

  test "independent sub-instances get distinct ctxs":
    let f = FactoryImpl.createUnderContext(NewBrokerContext())
    let a = (waitFor f.makeWidget(2)).value
    let b = (waitFor f.makeWidget(3)).value
    check a.brokerCtx != b.brokerCtx
    check (waitFor a.area()).value == 4
    check (waitFor b.area()).value == 9

  test "classCtx mask recovers the parent (FFI _call routing invariant)":
    let f = FactoryImpl.createUnderContext(NewBrokerContext())
    let w = (waitFor f.makeWidget(2)).value
    # `_call` masks instanceCtx off (low16) to find the owning library context.
    check (uint32(w.brokerCtx) and 0x0000FFFF'u32) == uint32(f.brokerCtx)

  test "closing a sub clears its providers (others intact)":
    let f = FactoryImpl.createUnderContext(NewBrokerContext())
    let a = (waitFor f.makeWidget(2)).value
    let b = (waitFor f.makeWidget(3)).value
    WidgetImpl2(a).close()
    check (waitFor Area.request(a.brokerCtx)).isErr() # provider cleared
    check (waitFor b.area()).value == 9 # b untouched
