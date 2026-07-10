{.used.}

## Tests for the handler-registration body sugar:
## - `listenIt` (EventBroker) / `onSignalIt` (SignalBroker): block = listener
##   body, event/signal value injected as `it`.
## - `provideIt` / `reprovideIt` (RequestBroker): block = provider body with
##   the declared signature arg names injected; `providerBody` guarantees the
##   body cannot silently fall through to err("").
## Compile-fail cases live in test/reject/reject_provideit_*.nim (see the
## `testSugarRejects` nimble task).

import testutils/unittests
import chronos

import brokers/event_broker
import brokers/signal_broker
import brokers/request_broker

EventBroker:
  type SugarLogin = object
    userId*: int
    name*: string

SignalBroker:
  type SugarSample = object
    deviceId*: string
    value*: float64

SignalBroker:
  type SugarPulse = void

RequestBroker(sync):
  proc sugarTransform(input: string, len: int): Result[seq[byte], string]

RequestBroker:
  proc sugarGetFromDb(
    id: string, maxItem: int
  ): Future[Result[seq[string], string]] {.async.}

RequestBroker:
  type SugarDual = object
    note*: string
    count*: int

  proc signature*(): Future[Result[SugarDual, string]] {.async.}
  proc signature*(suffix: string): Future[Result[SugarDual, string]] {.async.}

proc drain() =
  waitFor sleepAsync(chronos.milliseconds(20))

suite "listenIt (EventBroker single-thread)":
  test "block body with injected `it`, handle drops the listener":
    var seen: seq[string] = @[]
    let h = SugarLogin.listenIt:
      seen.add(it.name & "/" & $it.userId)

    check h.isOk()
    SugarLogin.emit(userId = 7, name = "alice")
    drain()
    check seen == @["alice/7"]

    waitFor SugarLogin.dropListener(h.value)
    SugarLogin.emit(userId = 8, name = "bob")
    drain()
    check seen == @["alice/7"]

  test "explicit broker context form":
    let ctx = NewBrokerContext()
    var hits = 0
    let h = SugarLogin.listenIt(ctx):
      discard it
      inc hits

    check h.isOk()
    SugarLogin.emit(ctx, SugarLogin(userId: 1, name: "ctx"))
    SugarLogin.emit(userId = 2, name = "default-ctx")
    drain()
    check hits == 1
    waitFor SugarLogin.dropAllListeners(ctx)

  test "body may await":
    var woke = false
    let h = SugarLogin.listenIt:
      discard it
      try:
        await sleepAsync(chronos.milliseconds(1))
      except CancelledError:
        discard
      woke = true

    check h.isOk()
    SugarLogin.emit(userId = 3, name = "sleepy")
    drain()
    check woke
    waitFor SugarLogin.dropAllListeners()

suite "onSignalIt (SignalBroker single-thread)":
  teardown:
    waitFor SugarSample.dropSignalHandler()
    waitFor SugarPulse.dropSignalHandler()

  test "block body with injected `it`":
    var lastDevice = ""
    var lastValue = 0.0
    let h = SugarSample.onSignalIt:
      lastDevice = it.deviceId
      lastValue = it.value

    check h.isOk()
    check SugarSample.signal(deviceId = "d1", value = 0.5).isOk()
    drain()
    check lastDevice == "d1"
    check lastValue == 0.5

  test "duplicate handler guard is preserved":
    let first = SugarSample.onSignalIt:
      discard it

    check first.isOk()
    let second = SugarSample.onSignalIt:
      discard it

    check second.isErr()

  test "void signal type injects nothing":
    var pulses = 0
    let h = SugarPulse.onSignalIt:
      inc pulses

    check h.isOk()
    check SugarPulse.signal().isOk()
    drain()
    check pulses == 1

suite "provideIt / reprovideIt (RequestBroker)":
  test "sync provider: guard-clause returns, injected args":
    let p = SugarTransform.provideIt:
      if len <= 0:
        return err("len must be positive, got " & $len)
      if len > input.len:
        return err("len exceeds input length")
      var acc: seq[byte]
      for i in 0 ..< len:
        acc.add(byte(input[i]))
      return ok(acc)

    check p.isOk()
    let r = SugarTransform.request("hello", 3)
    check r.isOk()
    check r.value == @[byte('h'), byte('e'), byte('l')]
    check SugarTransform.request("hi", -1).error == "len must be positive, got -1"
    SugarTransform.clearProvider()

  test "sync provider: result= style and trailing-expression style":
    let p1 = SugarTransform.provideIt:
      result = ok(newSeq[byte](len))
      for i in 0 ..< len:
        result.value[i] = byte(input[i])

    check p1.isOk()
    check SugarTransform.request("hey", 2).value == @[byte('h'), byte('e')]

    let p2 = SugarTransform.reprovideIt:
      var acc: seq[byte]
      for i in 0 ..< min(len, input.len):
        acc.add(byte(input[i]))
      ok(acc)

    check p2.isOk()
    check SugarTransform.request("hi", 99).value == @[byte('h'), byte('i')]
    SugarTransform.clearProvider()

  test "sync provider: final if/else as expression branches":
    let p = SugarTransform.provideIt:
      if len > 0:
        ok(newSeq[byte](len))
      else:
        err("nope")

    check p.isOk()
    check SugarTransform.request("x", 2).isOk()
    check SugarTransform.request("x", -3).error == "nope"
    SugarTransform.clearProvider()

  test "async provider: await + returns, provideIt guard, reprovideIt swap":
    let p = SugarGetFromDb.provideIt:
      if maxItem <= 0:
        return err("maxItem must be positive")
      await sleepAsync(chronos.milliseconds(1))
      var rows: seq[string]
      for i in 1 .. maxItem:
        rows.add(id & "-row" & $i)
      return ok(rows)

    check p.isOk()
    let r = waitFor SugarGetFromDb.request("users", 2)
    check r.isOk()
    check r.value == @["users-row1", "users-row2"]
    check (waitFor SugarGetFromDb.request("users", 0)).isErr()

    # setProvider's "already set" guard is preserved
    let again = SugarGetFromDb.provideIt:
      ok(newSeq[string](0))

    check again.isErr()

    # reprovideIt replaces without the guard
    let swapped = SugarGetFromDb.reprovideIt:
      ok(@[id & "/" & $maxItem])

    check swapped.isOk()
    check (waitFor SugarGetFromDb.request("a", 5)).value == @["a/5"]
    SugarGetFromDb.clearProvider()

  test "explicit broker context form":
    let ctx = NewBrokerContext()
    let p = SugarGetFromDb.provideIt(ctx):
      ok(@[id, $maxItem])

    check p.isOk()
    check (waitFor SugarGetFromDb.request(ctx, "c", 1)).isOk()
    check (waitFor SugarGetFromDb.request("c", 1)).isErr()
    SugarGetFromDb.clearProvider(ctx)

  test "dual-slot broker: provideIt (args) + provideItNoArgs (zero-arg)":
    let pa = SugarDual.provideIt:
      ok(SugarDual(note: "args-" & suffix, count: 1))

    check pa.isOk()
    let pz = SugarDual.provideItNoArgs:
      ok(SugarDual(note: "zero", count: 0))

    check pz.isOk()
    check (waitFor SugarDual.request("x")).value.note == "args-x"
    check (waitFor SugarDual.request()).value.note == "zero"

    let ra = SugarDual.reprovideIt:
      ok(SugarDual(note: "args2-" & suffix, count: 2))

    check ra.isOk()
    let rz = SugarDual.reprovideItNoArgs:
      ok(SugarDual(note: "zero2", count: 2))

    check rz.isOk()
    check (waitFor SugarDual.request("y")).value.note == "args2-y"
    check (waitFor SugarDual.request()).value.note == "zero2"
    SugarDual.clearProvider()
