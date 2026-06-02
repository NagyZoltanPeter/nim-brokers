{.used.}

## Regression guard for a single-thread *sync* RequestBroker whose forwarder
## calls the keyed `request(typedesc, BrokerContext, ...)` overload.
##
## Sync proc bodies are sem-checked eagerly and Nim has no forward references
## for overloaded routines, so the keyed variant must be emitted *before* the
## non-keyed forwarder. This file deliberately declares a sync, argument-based
## broker as the VERY FIRST broker in the module — no async broker precedes it
## to mask the ordering bug (which is exactly how it slipped past the other
## test files). It covers the legacy, proc-sugar, void, and zero-arg shapes.

import testutils/unittests
import results

import brokers/request_broker

# 1. proc-sugar, argument-based, `void` payload — the user-reported case.
RequestBroker(sync):
  proc MyVoidRequest(t: bool): Result[void, string]

# 2. legacy `signature*`, argument-based, object payload.
RequestBroker(sync):
  type SyncFirstObj = object
    v*: int

  proc signature*(t: bool): Result[SyncFirstObj, string]

# 3. proc-sugar, zero-argument.
RequestBroker(sync):
  proc MyZeroArg(): Result[int, string]

suite "RequestBroker sync — keyed-overload ordering (standalone)":
  test "sugar void arg — ok and err":
    check MyVoidRequest
      .setProvider(
        proc(t: bool): Result[void, string] =
          if t:
            ok()
          else:
            err("was false")
      )
      .isOk()
    check MyVoidRequest.request(true).isOk()
    let r = MyVoidRequest.request(false)
    check r.isErr()
    check r.error == "was false"
    MyVoidRequest.clearProvider()

  test "legacy arg object payload":
    check SyncFirstObj
      .setProvider(
        proc(t: bool): Result[SyncFirstObj, string] =
          ok(SyncFirstObj(v: 9))
      )
      .isOk()
    check SyncFirstObj.request(true).get().v == 9
    SyncFirstObj.clearProvider()

  test "sugar zero-arg":
    check MyZeroArg
      .setProvider(
        proc(): Result[int, string] =
          ok(5)
      )
      .isOk()
    check MyZeroArg.request().get() == 5
    MyZeroArg.clearProvider()
