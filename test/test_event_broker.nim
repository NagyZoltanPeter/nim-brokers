import chronos
import std/sequtils
import testutils/unittests

import event_broker

type ExternalDefinedEventType = object
  label*: string

EventBroker:
  type IntEvent = int

EventBroker:
  type ExternalAliasEvent = distinct ExternalDefinedEventType

EventBroker:
  type SampleEvent = object
    value*: int
    label*: string

EventBroker:
  type BinaryEvent = object
    flag*: bool

EventBroker:
  type RefEvent = ref object
    payload*: seq[int]

template waitForListeners() =
  await sleepAsync(1.milliseconds)

suite "EventBroker":
  asyncTest "delivers events to all listeners":
    var seen: seq[(int, string)] = @[]

    discard SampleEvent.listen(
      proc(evt: SampleEvent): Future[void] {.async: (raises: []).} =
        seen.add((evt.value, evt.label))
    )

    discard SampleEvent.listen(
      proc(evt: SampleEvent): Future[void] {.async: (raises: []).} =
        seen.add((evt.value * 2, evt.label & "!"))
    )

    let evt = SampleEvent(value: 5, label: "hi")
    SampleEvent.emit(evt)
    waitForListeners()

    check seen.len == 2
    check seen.anyIt(it == (5, "hi"))
    check seen.anyIt(it == (10, "hi!"))

    await SampleEvent.dropAllListeners()

  asyncTest "forget removes a single listener":
    var counter = 0

    let handleA = SampleEvent.listen(
      proc(evt: SampleEvent): Future[void] {.async: (raises: []).} =
        inc counter
    )

    let handleB = SampleEvent.listen(
      proc(evt: SampleEvent): Future[void] {.async: (raises: []).} =
        inc(counter, 2)
    )

    await SampleEvent.dropListener(handleA.get())
    let eventVal = SampleEvent(value: 1, label: "one")
    SampleEvent.emit(eventVal)
    waitForListeners()
    check counter == 2

    await SampleEvent.dropAllListeners()

  asyncTest "forgetAll clears every listener":
    var triggered = false

    let handle1 = SampleEvent.listen(
      proc(evt: SampleEvent): Future[void] {.async: (raises: []).} =
        triggered = true
    )
    let handle2 = SampleEvent.listen(
      proc(evt: SampleEvent): Future[void] {.async: (raises: []).} =
        discard
    )

    await SampleEvent.dropAllListeners()
    SampleEvent.emit(42, "noop")
    SampleEvent.emit(label = "noop", value = 42)
    waitForListeners()
    check not triggered

    let freshHandle = SampleEvent.listen(
      proc(evt: SampleEvent): Future[void] {.async: (raises: []).} =
        discard
    )
    check freshHandle.get().id > 0'u64
    await SampleEvent.dropListener(freshHandle.get())

  asyncTest "broker helpers operate via typedesc":
    var toggles: seq[bool] = @[]

    let handle = BinaryEvent.listen(
      proc(evt: BinaryEvent): Future[void] {.async: (raises: []).} =
        toggles.add(evt.flag)
    )

    BinaryEvent(flag: true).emit()
    waitForListeners()
    let binaryEvent = BinaryEvent(flag: false)
    BinaryEvent.emit(binaryEvent)
    waitForListeners()

    check toggles == @[true, false]
    await BinaryEvent.dropAllListeners()

  asyncTest "ref typed event":
    var counter: int = 0

    let handle = RefEvent.listen(
      proc(evt: RefEvent): Future[void] {.async: (raises: []).} =
        for n in evt.payload:
          counter += n
    )

    RefEvent(payload: @[1, 2, 3]).emit()
    waitForListeners()
    RefEvent.emit(payload = @[4, 5, 6])
    waitForListeners()

    check counter == 21 # 1+2+3 + 4+5+6
    await RefEvent.dropAllListeners()

  asyncTest "supports BrokerContext-scoped listeners":
    await SampleEvent.dropAllListeners()

    let ctxA = NewBrokerContext()
    let ctxB = NewBrokerContext()

    var seenA: seq[int] = @[]
    var seenB: seq[int] = @[]

    discard SampleEvent.listen(
      ctxA,
      proc(evt: SampleEvent): Future[void] {.async: (raises: []).} =
        seenA.add(evt.value),
    )

    discard SampleEvent.listen(
      ctxB,
      proc(evt: SampleEvent): Future[void] {.async: (raises: []).} =
        seenB.add(evt.value),
    )

    SampleEvent.emit(ctxA, SampleEvent(value: 1, label: "a"))
    SampleEvent.emit(ctxB, SampleEvent(value: 2, label: "b"))
    waitForListeners()

    check seenA == @[1]
    check seenB == @[2]

    await SampleEvent.dropAllListeners(ctxA)
    SampleEvent.emit(ctxA, SampleEvent(value: 3, label: "a2"))
    SampleEvent.emit(ctxB, SampleEvent(value: 4, label: "b2"))
    waitForListeners()

    check seenA == @[1]
    check seenB == @[2, 4]

    await SampleEvent.dropAllListeners(ctxB)

  asyncTest "supports non-object event types (auto-distinct)":
    var seen: seq[int] = @[]

    discard IntEvent.listen(
      proc(evt: IntEvent): Future[void] {.async: (raises: []).} =
        seen.add(int(evt))
    )

    IntEvent.emit(IntEvent(42))
    waitForListeners()

    check seen == @[42]
    await IntEvent.dropAllListeners()

  asyncTest "supports externally-defined type aliases (auto-distinct)":
    var seen: seq[string] = @[]

    discard ExternalAliasEvent.listen(
      proc(evt: ExternalAliasEvent): Future[void] {.async: (raises: []).} =
        let base = ExternalDefinedEventType(evt)
        seen.add(base.label)
    )

    ExternalAliasEvent.emit(ExternalAliasEvent(ExternalDefinedEventType(label: "x")))
    waitForListeners()

    check seen == @["x"]
    await ExternalAliasEvent.dropAllListeners()

  asyncTest "dropAllListeners cancels in-flight listeners":
    var completed = false

    discard SampleEvent.listen(
      proc(evt: SampleEvent): Future[void] {.async: (raises: []).} =
        try:
          await sleepAsync(10.seconds)
          completed = true
        except CancelledError:
          discard
    )

    SampleEvent.emit(SampleEvent(value: 1, label: "cancel-test"))
    waitForListeners()

    await SampleEvent.dropAllListeners()
    check completed == false

  asyncTest "dropListener cancels in-flight and allows safe teardown":
    var completed = false

    let handle = SampleEvent
      .listen(
        proc(evt: SampleEvent): Future[void] {.async: (raises: []).} =
          try:
            await sleepAsync(10.seconds)
            completed = true
          except CancelledError:
            discard
      )
      .get()

    SampleEvent.emit(SampleEvent(value: 1, label: "drop-test"))
    waitForListeners()

    await SampleEvent.dropListener(handle)
    # After await returns, all in-flight work is cancelled — safe to release resources
    check completed == false
