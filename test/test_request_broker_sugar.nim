{.used.}

## Tests for the proc-style RequestBroker sugar (option B — payload decoupled
## from the dispatch tag). The legacy `proc signature*` form is covered by
## test_request_broker.nim; this file exercises only the new sugar.

import testutils/unittests
import chronos
import std/strutils

import brokers/request_broker

## ---------------------------------------------------------------------------
## POD payloads (decoupled): the broker name is derived from the proc verb
## (Capitalized); `request` returns the RAW payload, not a distinct wrapper.
## A lowercase verb emits a capitalization warning at compile time; a
## Capitalized proc name (GetName) is accepted and silences it.
## ---------------------------------------------------------------------------

RequestBroker:
  proc getVersion(): Future[Result[string, string]] {.async.}

RequestBroker:
  proc GetName(): Future[Result[string, string]] {.async.} # capital -> no warning

RequestBroker:
  proc greet(name: string): Future[Result[string, string]] {.async.}

RequestBroker(sync):
  proc getId(): Result[int, string]

## Object payload (coupled): explicit `type` paired to the verb by name.
RequestBroker:
  type GetHealth = object
    alive*: bool
    code*: int

  proc getHealth(): Future[Result[GetHealth, string]] {.async.}

## Two signature slots on one broker (zero-arg + arg-based).
RequestBroker:
  proc lookup(): Future[Result[string, string]] {.async.}
  proc lookup(key: int): Future[Result[string, string]] {.async.}

suite "RequestBroker proc-sugar (option B)":
  test "POD zero-arg returns the raw payload":
    GetVersion
      .setProvider(
        proc(): Future[Result[string, string]] {.async.} =
          ok("1.2.3")
      )
      .get()
    let r = waitFor GetVersion.request()
    check r.isOk()
    check r.value == "1.2.3" # raw string, no .distinctBase needed

  test "capital-initial proc name names the broker directly":
    GetName
      .setProvider(
        proc(): Future[Result[string, string]] {.async.} =
          ok("zoli")
      )
      .get()
    check (waitFor GetName.request()).value == "zoli"

  test "arg-based POD":
    Greet
      .setProvider(
        proc(name: string): Future[Result[string, string]] {.async.} =
          ok("hi " & name)
      )
      .get()
    check (waitFor Greet.request("bob")).value == "hi bob"

  test "sync POD":
    GetId
      .setProvider(
        proc(): Result[int, string] =
          ok(42)
      )
      .get()
    check GetId.request().value == 42

  test "object payload":
    GetHealth
      .setProvider(
        proc(): Future[Result[GetHealth, string]] {.async.} =
          ok(GetHealth(alive: true, code: 7))
      )
      .get()
    let r = waitFor GetHealth.request()
    check r.isOk()
    check r.value.alive
    check r.value.code == 7

  test "two slots: zero-arg + arg-based on one broker":
    Lookup
      .setProvider(
        proc(): Future[Result[string, string]] {.async.} =
          ok("zero")
      )
      .get()
    Lookup
      .setProvider(
        proc(key: int): Future[Result[string, string]] {.async.} =
          ok("k" & $key)
      )
      .get()
    check (waitFor Lookup.request()).value == "zero"
    check (waitFor Lookup.request(7)).value == "k7"

  test "unset provider errors":
    # fresh context with no provider
    let ctx = NewBrokerContext()
    let r = waitFor GetVersion.request(ctx)
    check r.isErr()
