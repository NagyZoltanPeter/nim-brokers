{.used.}

import testutils/unittests
import chronos
import std/sequtils
import std/strutils

import brokers/multi_request_broker

MultiRequestBroker:
  type NoArgResponse = object
    label*: string

  proc signatureFetch*(): Future[Result[NoArgResponse, string]] {.async.}

MultiRequestBroker:
  type ArgResponse = object
    id*: string

  proc signatureFetch*(
    suffix: string, numsuffix: int
  ): Future[Result[ArgResponse, string]] {.async.}

MultiRequestBroker:
  type DualResponse = ref object
    note*: string
    suffix*: string

  proc signatureBase*(): Future[Result[DualResponse, string]] {.async.}
  proc signatureWithInput*(
    suffix: string
  ): Future[Result[DualResponse, string]] {.async.}

type ExternalBaseType = string

MultiRequestBroker:
  type NativeIntResponse = int

  proc signatureFetch*(): Future[Result[NativeIntResponse, string]] {.async.}

MultiRequestBroker:
  type ExternalAliasResponse = ExternalBaseType

  proc signatureFetch*(): Future[Result[ExternalAliasResponse, string]] {.async.}

MultiRequestBroker:
  type AlreadyDistinctResponse = distinct int

  proc signatureFetch*(): Future[Result[AlreadyDistinctResponse, string]] {.async.}

suite "MultiRequestBroker":
  test "aggregates zero-argument providers":
    discard NoArgResponse.setProvider(
      proc(): Future[Result[NoArgResponse, string]] {.async.} =
        ok(NoArgResponse(label: "one"))
    )

    discard NoArgResponse.setProvider(
      proc(): Future[Result[NoArgResponse, string]] {.async.} =
        discard catch:
          await sleepAsync(1.milliseconds)
        ok(NoArgResponse(label: "two"))
    )

    let responses = waitFor NoArgResponse.request()
    check responses.get().len == 2
    check responses.get().anyIt(it.label == "one")
    check responses.get().anyIt(it.label == "two")

    NoArgResponse.clearProviders()

  test "aggregates argument providers":
    discard ArgResponse.setProvider(
      proc(suffix: string, num: int): Future[Result[ArgResponse, string]] {.async.} =
        ok(ArgResponse(id: suffix & "-a-" & $num))
    )

    discard ArgResponse.setProvider(
      proc(suffix: string, num: int): Future[Result[ArgResponse, string]] {.async.} =
        ok(ArgResponse(id: suffix & "-b-" & $num))
    )

    let keyed = waitFor ArgResponse.request("topic", 1)
    check keyed.get().len == 2
    check keyed.get().anyIt(it.id == "topic-a-1")
    check keyed.get().anyIt(it.id == "topic-b-1")

    ArgResponse.clearProviders()

  test "clearProviders resets both provider lists":
    discard DualResponse.setProvider(
      proc(): Future[Result[DualResponse, string]] {.async.} =
        ok(DualResponse(note: "base", suffix: ""))
    )

    discard DualResponse.setProvider(
      proc(suffix: string): Future[Result[DualResponse, string]] {.async.} =
        ok(DualResponse(note: "base" & suffix, suffix: suffix))
    )

    let noArgs = waitFor DualResponse.request()
    check noArgs.get().len == 1

    let param = waitFor DualResponse.request("-extra")
    check param.get().len == 1
    check param.get()[0].suffix == "-extra"

    DualResponse.clearProviders()

    let emptyNoArgs = waitFor DualResponse.request()
    check emptyNoArgs.get().len == 0

    let emptyWithArgs = waitFor DualResponse.request("-extra")
    check emptyWithArgs.get().len == 0

  test "request returns empty seq when no providers registered":
    let empty = waitFor NoArgResponse.request()
    check empty.get().len == 0

  test "failed providers will fail the request":
    NoArgResponse.clearProviders()
    discard NoArgResponse.setProvider(
      proc(): Future[Result[NoArgResponse, string]] {.async.} =
        err("boom")
    )

    discard NoArgResponse.setProvider(
      proc(): Future[Result[NoArgResponse, string]] {.async.} =
        ok(NoArgResponse(label: "survivor"))
    )

    let filtered = waitFor NoArgResponse.request()
    check filtered.isErr()

    NoArgResponse.clearProviders()

  test "deduplicates identical zero-argument providers":
    NoArgResponse.clearProviders()
    var invocations = 0
    let sharedHandler = proc(): Future[Result[NoArgResponse, string]] {.async.} =
      inc invocations
      ok(NoArgResponse(label: "dup"))

    let first = NoArgResponse.setProvider(sharedHandler)
    let second = NoArgResponse.setProvider(sharedHandler)

    check first.get().id == second.get().id
    check first.get().kind == second.get().kind

    let dupResponses = waitFor NoArgResponse.request()
    check dupResponses.get().len == 1
    check invocations == 1

    NoArgResponse.clearProviders()

  test "removeProvider deletes registered handlers":
    var removedCalled = false
    var keptCalled = false

    let removable = NoArgResponse.setProvider(
      proc(): Future[Result[NoArgResponse, string]] {.async.} =
        removedCalled = true
        ok(NoArgResponse(label: "removed"))
    )

    discard NoArgResponse.setProvider(
      proc(): Future[Result[NoArgResponse, string]] {.async.} =
        keptCalled = true
        ok(NoArgResponse(label: "kept"))
    )

    NoArgResponse.removeProvider(removable.get())

    let afterRemoval = (waitFor NoArgResponse.request()).valueOr:
      assert false, "request failed"
      @[]
    check afterRemoval.len == 1
    check afterRemoval[0].label == "kept"
    check not removedCalled
    check keptCalled

    NoArgResponse.clearProviders()

  test "removeProvider works for argument signatures":
    var invoked: seq[string] = @[]

    discard ArgResponse.setProvider(
      proc(suffix: string, num: int): Future[Result[ArgResponse, string]] {.async.} =
        invoked.add("first" & suffix)
        ok(ArgResponse(id: suffix & "-one-" & $num))
    )

    let handle = ArgResponse.setProvider(
      proc(suffix: string, num: int): Future[Result[ArgResponse, string]] {.async.} =
        invoked.add("second" & suffix)
        ok(ArgResponse(id: suffix & "-two-" & $num))
    )

    ArgResponse.removeProvider(handle.get())

    let single = (waitFor ArgResponse.request("topic", 1)).valueOr:
      assert false, "request failed"
      @[]
    check single.len == 1
    check single[0].id == "topic-one-1"
    check invoked == @["firsttopic"]

    ArgResponse.clearProviders()

  test "catches exception from providers and report error":
    let firstHandler = NoArgResponse.setProvider(
      proc(): Future[Result[NoArgResponse, string]] {.async.} =
        raise newException(ValueError, "first handler raised")
    )

    discard NoArgResponse.setProvider(
      proc(): Future[Result[NoArgResponse, string]] {.async.} =
        ok(NoArgResponse(label: "just ok"))
    )

    let afterException = waitFor NoArgResponse.request()
    check afterException.isErr()
    check afterException.error().contains("first handler raised")

    NoArgResponse.clearProviders()

  test "ref providers returning nil fail request":
    DualResponse.clearProviders()

  test "supports native request types":
    NativeIntResponse.clearProviders()

    discard NativeIntResponse.setProvider(
      proc(): Future[Result[NativeIntResponse, string]] {.async.} =
        ok(NativeIntResponse(1))
    )

    discard NativeIntResponse.setProvider(
      proc(): Future[Result[NativeIntResponse, string]] {.async.} =
        ok(NativeIntResponse(2))
    )

    let res = waitFor NativeIntResponse.request()
    check res.isOk()
    check res.get().len == 2
    check res.get().anyIt(int(it) == 1)
    check res.get().anyIt(int(it) == 2)

    NativeIntResponse.clearProviders()

  test "supports external request types":
    ExternalAliasResponse.clearProviders()

    discard ExternalAliasResponse.setProvider(
      proc(): Future[Result[ExternalAliasResponse, string]] {.async.} =
        ok(ExternalAliasResponse("hello"))
    )

    let res = waitFor ExternalAliasResponse.request()
    check res.isOk()
    check res.get().len == 1
    check ExternalBaseType(res.get()[0]) == "hello"

    ExternalAliasResponse.clearProviders()

  test "supports already-distinct request types":
    AlreadyDistinctResponse.clearProviders()

    discard AlreadyDistinctResponse.setProvider(
      proc(): Future[Result[AlreadyDistinctResponse, string]] {.async.} =
        ok(AlreadyDistinctResponse(7))
    )

    let res = waitFor AlreadyDistinctResponse.request()
    check res.isOk()
    check res.get().len == 1
    check int(res.get()[0]) == 7

    AlreadyDistinctResponse.clearProviders()

  test "context-aware providers are isolated":
    NoArgResponse.clearProviders()
    let ctxA = NewBrokerContext()
    let ctxB = NewBrokerContext()

    discard NoArgResponse.setProvider(
      ctxA,
      proc(): Future[Result[NoArgResponse, string]] {.async.} =
        ok(NoArgResponse(label: "a")),
    )
    discard NoArgResponse.setProvider(
      ctxB,
      proc(): Future[Result[NoArgResponse, string]] {.async.} =
        ok(NoArgResponse(label: "b")),
    )

    let resA = waitFor NoArgResponse.request(ctxA)
    check resA.isOk()
    check resA.get().len == 1
    check resA.get()[0].label == "a"

    let resB = waitFor NoArgResponse.request(ctxB)
    check resB.isOk()
    check resB.get().len == 1
    check resB.get()[0].label == "b"

    let resDefault = waitFor NoArgResponse.request()
    check resDefault.isOk()
    check resDefault.get().len == 0

    NoArgResponse.clearProviders(ctxA)
    let clearedA = waitFor NoArgResponse.request(ctxA)
    check clearedA.isOk()
    check clearedA.get().len == 0

    let stillB = waitFor NoArgResponse.request(ctxB)
    check stillB.isOk()
    check stillB.get().len == 1
    check stillB.get()[0].label == "b"

    NoArgResponse.clearProviders(ctxB)

    discard DualResponse.setProvider(
      proc(): Future[Result[DualResponse, string]] {.async.} =
        let nilResponse: DualResponse = nil
        ok(nilResponse)
    )

    let zeroArg = waitFor DualResponse.request()
    check zeroArg.isErr()

    DualResponse.clearProviders()

    discard DualResponse.setProvider(
      proc(suffix: string): Future[Result[DualResponse, string]] {.async.} =
        let nilResponse: DualResponse = nil
        ok(nilResponse)
    )

    let withInput = waitFor DualResponse.request("-extra")
    check withInput.isErr()

    DualResponse.clearProviders()

## ---------------------------------------------------------------------------
## bind provider sugar (issue #42) — additive, no rebind
## ---------------------------------------------------------------------------

MultiRequestBroker:
  type BindScore = object
    s*: int

  proc signature*(): Future[Result[BindScore, string]] {.async.}

type MultiBindService = ref object
  base: int

proc scoreA(self: MultiBindService): Future[Result[BindScore, string]] {.async.} =
  ok(BindScore(s: self.base + 1))

proc scoreB(self: MultiBindService): Future[Result[BindScore, string]] {.async.} =
  ok(BindScore(s: self.base + 2))

suite "MultiRequestBroker bindProvider sugar (issue #42)":
  test "bindProvider registers class-method providers additively":
    let a = MultiBindService(base: 10)
    let b = MultiBindService(base: 20)
    check BindScore.bindProvider(a.scoreA).isOk()
    check BindScore.bindProvider(b.scoreB).isOk()

    let res = waitFor BindScore.request()
    check res.isOk()
    check res.value.len == 2
    check BindScore(s: 11) in res.value
    check BindScore(s: 22) in res.value

    BindScore.clearProviders()

MultiRequestBroker:
  type SugarScore = object
    s*: int

  proc signatureBase*(): Future[Result[SugarScore, string]] {.async.}
  proc signatureWith*(bonus: int): Future[Result[SugarScore, string]] {.async.}

suite "MultiRequestBroker provideIt sugar":
  teardown:
    SugarScore.clearProviders()

  test "provideIt adds providers additively; injected args; returns a handle":
    # args slot: `bonus` is injected; the body is the real provider proc body
    let h1 = SugarScore.provideIt:
      if bonus < 0:
        return err("negative bonus")
      return ok(SugarScore(s: 100 + bonus))

    check h1.isOk()

    # a second provideIt ADDS another provider (fresh closure, no dedup)
    let h2 = SugarScore.provideIt:
      ok(SugarScore(s: 200 + bonus))

    check h2.isOk()

    let res = waitFor SugarScore.request(5)
    check res.isOk()
    check res.value.len == 2
    check SugarScore(s: 105) in res.value
    check SugarScore(s: 205) in res.value

    # the returned handle removes exactly one provider
    SugarScore.removeProvider(h1.get())
    let res2 = waitFor SugarScore.request(5)
    check res2.isOk()
    check res2.value == @[SugarScore(s: 205)]

  test "provideItNoArgs targets the zero-arg slot on a dual-slot broker":
    let hz = SugarScore.provideItNoArgs:
      ok(SugarScore(s: 1))

    check hz.isOk()
    let ha = SugarScore.provideIt:
      ok(SugarScore(s: 2 + bonus))

    check ha.isOk()

    let zero = waitFor SugarScore.request()
    check zero.value == @[SugarScore(s: 1)]
    let withArg = waitFor SugarScore.request(8)
    check withArg.value == @[SugarScore(s: 10)]
