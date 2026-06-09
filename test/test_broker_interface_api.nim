{.used.}

## In-process coverage for BrokerInterface(API) + BrokerImplement: the `(API)`
## marker lowers the sub-brokers onto the multi-thread lane, and
## `createUnderContext` wires an instance's providers under an externally-supplied
## context (the path registerBrokerLibrary drives over FFI). Exercised here on
## one thread via the MT broker's same-thread fast path — no library runtime /
## foreign wrappers needed. The full FFI round-trip is covered by the hierlib
## example + wrapper smoke.

import testutils/unittests
import chronos

import brokers/broker_interface
import brokers/broker_implement

BrokerInterface(API, IDeviceApi):
  RequestBroker:
    proc getCode(): Future[Result[int32, string]] {.async.}

  RequestBroker:
    proc echoLen(s: string): Future[Result[int32, string]] {.async.}

type DeviceApiImpl = ref object of IDeviceApi
  code: int32

BrokerImplement DeviceApiImpl of IDeviceApi:
  proc new(T: typedesc[DeviceApiImpl], code: int32): DeviceApiImpl =
    DeviceApiImpl(code: code)

  method getCode(self: DeviceApiImpl): Future[Result[int32, string]] {.async.} =
    ok(self.code)

  method echoLen(
      self: DeviceApiImpl, s: string
  ): Future[Result[int32, string]] {.async.} =
    ok(int32(s.len))

suite "BrokerInterface(API) + BrokerImplement (in-process MT lane)":
  test "createUnderContext wires providers under the given ctx; request dispatches":
    let ctx = NewBrokerContext()
    discard DeviceApiImpl.createUnderContext(ctx, 42'i32)
    check (waitFor GetCode.request(ctx)).value == 42
    check (waitFor EchoLen.request(ctx, "abcd")).value == 4

  test "a second context is independent":
    let ctx2 = NewBrokerContext()
    discard DeviceApiImpl.createUnderContext(ctx2, 99'i32)
    check (waitFor GetCode.request(ctx2)).value == 99
