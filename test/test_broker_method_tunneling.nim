{.used.}

## Tunneling proof: a direct `instance.method(...)` call (and a base-typed
## `IFace(instance).method(...)` call) must route through the broker dispatch
## path — i.e. honor a provider swap (mock) — rather than running the impl body
## inline via a vtable call.
##
## Before the tunneling refactor, `g.greet("bob")` returned `real:bob` even
## after mocking `Greet`'s provider (the mock only intercepted
## `Greet.request(ctx, …)`). After the refactor both paths return `MOCK<bob>`.

import testutils/unittests
import chronos
import results

import brokers/broker_interface
import brokers/broker_implement

BrokerInterface(IGreeter):
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
    ok("real:" & self.prefix & name)

  method version(self: GreeterImpl): Future[Result[string, string]] {.async.} =
    ok("real:v")

proc installMock(ctx: BrokerContext) =
  ## Replace the with-arg `Greet` provider and the zero-arg `Version` provider
  ## for `ctx` with mocks. clear-then-set because setProvider rejects a
  ## double-install (a first-class withMockProvider lands in a later phase).
  Greet.clearProvider(ctx)
  Version.clearProvider(ctx)
  discard Greet.setProvider(
    ctx,
    proc(name: string): Future[Result[string, string]] {.async.} =
      ok("MOCK<" & name & ">"),
  )
  discard Version.setProvider(
    ctx,
    proc(): Future[Result[string, string]] {.async.} =
      ok("MOCK<v>"),
  )

suite "BrokerInterface: method calls tunnel through the broker":
  test "sanity: real provider answers the direct call":
    let g = GreeterImpl.create(prefix = "p:")
    check (waitFor g.greet("bob")).value == "real:p:bob"
    check (waitFor g.version()).value == "real:v"

  test "criterion 1: mock honored on a direct instance.method() call":
    let g = GreeterImpl.create(prefix = "p:")
    installMock(g.brokerCtx)
    # With-arg slot: direct call must hit the mocked provider, not the impl body.
    check (waitFor g.greet("bob")).value == "MOCK<bob>"
    # Zero-arg slot too.
    check (waitFor g.version()).value == "MOCK<v>"

  test "criterion 2: mock honored on a base-typed IFace(instance).method() call":
    let g = GreeterImpl.create(prefix = "p:")
    installMock(g.brokerCtx)
    let base: IGreeter = g
    check (waitFor base.greet("sue")).value == "MOCK<sue>"
    check (waitFor base.version()).value == "MOCK<v>"

  test "mock is per-ctx: a second instance keeps the real provider":
    let a = GreeterImpl.create(prefix = "a:")
    let b = GreeterImpl.create(prefix = "b:")
    installMock(a.brokerCtx)
    check (waitFor a.greet("x")).value == "MOCK<x>"
    check (waitFor b.greet("x")).value == "real:b:x"
