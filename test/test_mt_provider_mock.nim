{.used.}

## getCurrentProvider / replaceProvider / withMockProvider for the multi-thread
## RequestBroker, exercised same-thread (the introspection API is owning-thread
## only). Covers criterion 3 (capture/replace/restore) and 5 (scoped mock) for
## both the with-arg and zero-arg slots on the MT lane.

import testutils/unittests
import chronos
import results

import brokers/request_broker

RequestBroker(mt):
  proc echoUp(s: string): Future[Result[string, string]] {.async.}

RequestBroker(mt):
  proc ping(): Future[Result[string, string]] {.async.}

suite "MT RequestBroker: provider introspection + mock (same thread)":
  setup:
    let ctx = NewBrokerContext()
    discard EchoUp.setProvider(
      ctx,
      proc(s: string): Future[Result[string, string]] {.async.} =
        ok("real:" & s),
    )
    discard Ping.setProvider(
      ctx,
      proc(): Future[Result[string, string]] {.async.} =
        ok("real:pong"),
    )

  test "with-arg: capture -> replace -> restore":
    let orig = EchoUp.getCurrentProvider(ctx)
    check orig.isSome
    check (waitFor EchoUp.request(ctx, "x")).value == "real:x"
    discard EchoUp.replaceProvider(
      ctx,
      proc(s: string): Future[Result[string, string]] {.async.} =
        ok("MOCK<" & s & ">"),
    )
    check (waitFor EchoUp.request(ctx, "x")).value == "MOCK<x>"
    discard EchoUp.replaceProvider(ctx, orig.get)
    check (waitFor EchoUp.request(ctx, "x")).value == "real:x"

  test "zero-arg: capture -> replace -> restore":
    let orig = Ping.getCurrentProviderNoArgs(ctx)
    check orig.isSome
    discard Ping.replaceProvider(
      ctx,
      proc(): Future[Result[string, string]] {.async.} =
        ok("MOCK<pong>"),
    )
    check (waitFor Ping.request(ctx)).value == "MOCK<pong>"
    discard Ping.replaceProvider(ctx, orig.get)
    check (waitFor Ping.request(ctx)).value == "real:pong"

  test "withMockProvider scopes the swap (with-arg)":
    EchoUp.withMockProvider(
      ctx,
      proc(s: string): Future[Result[string, string]] {.async.} =
        ok("MOCK<" & s & ">"),
    ):
      check (waitFor EchoUp.request(ctx, "x")).value == "MOCK<x>"
    check (waitFor EchoUp.request(ctx, "x")).value == "real:x"
