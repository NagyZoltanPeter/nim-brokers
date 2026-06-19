{.used.}

## Regression: `create` / `createUnderContext` mirror the user `new` ctor's
## result shape across all four forms:
##   proc new(...): T
##   proc new(...): Future[T] {.async.}
##   proc new(...): Result[T, string]
##   proc new(...): Future[Result[T, string]] {.async.}
## The async forms are generated via `parseStmt`; because they carry a
## `typedesc` parameter they are implicitly generic, and synthetic line info
## crashes the chronos async transform (compiler OSError) — the generator
## re-stamps a real source location to avoid it (see copyLineInfoRec).

import testutils/unittests
import chronos

import brokers/broker_interface
import brokers/broker_implement
import brokers/broker_context

BrokerInterface(ICtorShape):
  RequestBroker:
    proc greet(name: string): Future[Result[string, string]] {.async.}

# Form 1 — sync bare:           create(): T
type GSyncBare = ref object of ICtorShape
  prefix: string

BrokerImplement GSyncBare of ICtorShape:
  proc new(T: typedesc[GSyncBare], prefix: string): GSyncBare =
    GSyncBare(prefix: prefix)

  method greet(
      self: GSyncBare, name: string
  ): Future[Result[string, string]] {.async.} =
    ok(self.prefix & name)

# Form 2 — async bare:          create(): Future[T] {.async.}
type GAsyncBare = ref object of ICtorShape
  prefix: string

BrokerImplement GAsyncBare of ICtorShape:
  proc new(T: typedesc[GAsyncBare], prefix: string): Future[GAsyncBare] {.async.} =
    return GAsyncBare(prefix: prefix)

  method greet(
      self: GAsyncBare, name: string
  ): Future[Result[string, string]] {.async.} =
    ok(self.prefix & name)

# Form 3 — sync Result:         create(): Result[T, string]
type GSyncResult = ref object of ICtorShape
  prefix: string

BrokerImplement GSyncResult of ICtorShape:
  proc new(T: typedesc[GSyncResult], prefix: string): Result[GSyncResult, string] =
    if prefix.len == 0:
      return err("empty prefix")
    ok(GSyncResult(prefix: prefix))

  method greet(
      self: GSyncResult, name: string
  ): Future[Result[string, string]] {.async.} =
    ok(self.prefix & name)

# Form 4 — async Result:        create(): Future[Result[T, string]] {.async.}
type GAsyncResult = ref object of ICtorShape
  prefix: string

BrokerImplement GAsyncResult of ICtorShape:
  proc new(
      T: typedesc[GAsyncResult], prefix: string
  ): Future[Result[GAsyncResult, string]] {.async.} =
    if prefix.len == 0:
      return err("empty prefix")
    return ok(GAsyncResult(prefix: prefix))

  method greet(
      self: GAsyncResult, name: string
  ): Future[Result[string, string]] {.async.} =
    ok(self.prefix & name)

suite "BrokerImplement: ctor result-shape mirroring":
  test "form 1 — sync bare: create returns T, providers wired":
    let g = GSyncBare.create(prefix = "1:")
    check (waitFor Greet.request(g.brokerCtx, "x")).value == "1:x"

  test "form 2 — async bare: create returns Future[T]":
    let g = waitFor GAsyncBare.create(prefix = "2:")
    check (waitFor Greet.request(g.brokerCtx, "x")).value == "2:x"

  test "form 3 — sync Result: create returns Result[T, string] (ok + err)":
    let g = GSyncResult.create(prefix = "3:").get()
    check (waitFor Greet.request(g.brokerCtx, "x")).value == "3:x"
    check GSyncResult.create(prefix = "").isErr()

  test "form 4 — async Result: create returns Future[Result[T, string]] (ok + err)":
    let g = (waitFor GAsyncResult.create(prefix = "4:")).get()
    check (waitFor Greet.request(g.brokerCtx, "x")).value == "4:x"
    check (waitFor GAsyncResult.create(prefix = "")).isErr()

  test "createUnderContext adopts an external ctx (async Result form)":
    let ctx = NewBrokerContext()
    let g = (waitFor GAsyncResult.createUnderContext(ctx, prefix = "u:")).get()
    check g.brokerCtx == ctx
    check (waitFor Greet.request(ctx, "x")).value == "u:x"

  test "create adopts the ambient global classCtx; instances stay distinct":
    # Outside any lock the ambient global is the default scope.
    let d = GSyncBare.create(prefix = "d:")
    check d.brokerCtx.classCtx == DefaultBrokerContext.classCtx
    check d.brokerCtx.instanceCtx != 0'u16 # got a fresh per-instance high16

    proc underLock() {.async.} =
      lockNewGlobalBrokerContext:
        let g = globalBrokerContext()
        let a = (await GAsyncResult.create(prefix = "a:")).get()
        let b = (await GAsyncResult.create(prefix = "b:")).get()
        # Both adopt the locked scope's classCtx (the shared "global" half) ...
        check a.brokerCtx.classCtx == g.classCtx
        check b.brokerCtx.classCtx == g.classCtx
        # ... yet stay isolated via distinct process-global instanceCtx.
        check a.brokerCtx != b.brokerCtx
        check a.brokerCtx.instanceCtx != b.brokerCtx.instanceCtx

    waitFor underLock()
