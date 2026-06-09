{.used.}

## D3 — cross-thread dispatch for a BrokerInterface(API). The `(API)` marker
## lowers the interface's RequestBroker onto the multi-thread lane, so an impl
## wired via createUnderContext on one thread (running its chronos loop) services
## requests issued from a *different* thread. (Plain BrokerInterface uses
## single-thread, thread-local brokers and is same-thread only — see
## test_broker_oop.nim / test_broker_interface_api.nim.)
##
## Compiled with -d:BrokerFfiApi --threads:on (via the testApi task). Structure
## mirrors the cross-thread case of test_multi_thread_request_broker.nim: an
## async main body keeps its event loop alive while a requester thread runs.

import testutils/unittests
import chronos
import std/atomics

import brokers/broker_interface
import brokers/broker_implement

BrokerInterface(API, IMtSvc):
  RequestBroker:
    proc echoLen(s: string): Future[Result[int32, string]] {.async.}

type MtSvcImpl = ref object of IMtSvc

BrokerImplement MtSvcImpl of IMtSvc:
  method echoLen(self: MtSvcImpl, s: string): Future[Result[int32, string]] {.async.} =
    ok(int32(s.len))

var gCtx: BrokerContext
var gResultReady: Atomic[bool]
var gResult: Atomic[int]

proc requesterThread() {.thread.} =
  let r = waitFor EchoLen.request(gCtx, "abcd")
  if r.isOk:
    gResult.store(int(r.value))
  else:
    gResult.store(-1)
  gResultReady.store(true)

suite "BrokerInterface(API) cross-thread dispatch (MT lane)":
  test "request from another thread dispatches to the impl override":
    proc body() {.async.} =
      gCtx = NewBrokerContext()
      gResultReady.store(false)
      gResult.store(-99)

      # Main thread is the provider: wire the impl under gCtx here, on the loop.
      discard MtSvcImpl.createUnderContext(gCtx)

      var req: Thread[void]
      req.createThread(requesterThread)
      while not gResultReady.load():
        await sleepAsync(5.milliseconds)
      req.joinThread()

    waitFor body()
    check gResult.load() == 4

  test "second independent context, cross-thread":
    proc body2() {.async.} =
      gCtx = NewBrokerContext()
      gResultReady.store(false)
      gResult.store(-99)
      discard MtSvcImpl.createUnderContext(gCtx)
      var req: Thread[void]
      req.createThread(requesterThread)
      while not gResultReady.load():
        await sleepAsync(5.milliseconds)
      req.joinThread()

    waitFor body2()
    check gResult.load() == 4
