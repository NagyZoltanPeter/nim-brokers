{.used.}

## MT-lane coverage for the handler body sugar (`listenIt` / `onSignalIt` /
## `provideIt` / `reprovideIt`). The sugar synthesises the exact closure a
## hand-written registration would pass, so the cross-thread dispatch
## machinery itself is covered by the dedicated MT test files — here we verify
## the sugar surface resolves and dispatches on the MT broker variants.

import testutils/unittests
import chronos

import brokers/event_broker
import brokers/signal_broker
import brokers/request_broker

EventBroker(mt):
  type SugarMtEvent = object
    value*: int
    label*: string

SignalBroker(mt):
  type SugarMtSignal = object
    value*: int

RequestBroker(mt):
  type SugarMtReply = object
    text*: string

  proc signature*(
    prefix: string, n: int
  ): Future[Result[SugarMtReply, string]] {.async.}

proc drain() =
  waitFor sleepAsync(chronos.milliseconds(20))

suite "handler sugar on multi-thread brokers (same-thread lane)":
  test "listenIt on EventBroker(mt)":
    var seen: seq[int] = @[]
    let h = SugarMtEvent.listenIt:
      seen.add(it.value)

    check h.isOk()
    SugarMtEvent.emit(value = 41, label = "mt")
    SugarMtEvent.emit(value = 42, label = "mt")
    drain()
    check seen == @[41, 42]
    waitFor SugarMtEvent.dropListener(h.value)

  test "onSignalIt on SignalBroker(mt)":
    var total = 0
    let h = SugarMtSignal.onSignalIt:
      total += it.value

    check h.isOk()
    check SugarMtSignal.signal(value = 5).isOk()
    check SugarMtSignal.signal(value = 7).isOk()
    drain()
    check total == 12
    waitFor SugarMtSignal.dropSignalHandler()

  test "provideIt / reprovideIt on RequestBroker(mt)":
    let p = SugarMtReply.provideIt:
      if n < 0:
        return err("negative n")
      return ok(SugarMtReply(text: prefix & "-" & $n))

    check p.isOk()
    check (waitFor SugarMtReply.request("job", 3)).value.text == "job-3"
    check (waitFor SugarMtReply.request("job", -1)).isErr()

    let r = SugarMtReply.reprovideIt:
      ok(SugarMtReply(text: prefix & "+" & $n))

    check r.isOk()
    check (waitFor SugarMtReply.request("job", 3)).value.text == "job+3"
    SugarMtReply.clearProvider()
