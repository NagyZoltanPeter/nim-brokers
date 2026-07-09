# A signal must have exactly one handler. Two methods binding to the SAME
# signal — here `Shutdown` (exact name) and `onShutdown` (the `on<Signal>` form)
# both resolve to the `Shutdown` signal — is a compile error.
import chronos
import brokers/broker_interface
import brokers/broker_implement

BrokerInterface(IRejDup):
  SignalBroker:
    type Shutdown = object
      reason: string

type RejDupImpl = ref object of IRejDup

BrokerImplement RejDupImpl of IRejDup:
  proc new(T: typedesc[RejDupImpl]): RejDupImpl =
    RejDupImpl()

  # First handler — binds to `Shutdown` by exact name.
  method Shutdown(
      self: RejDupImpl, s: Shutdown
  ): Future[void] {.async: (raises: []), gcsafe.} =
    discard

  # Second handler — also binds to `Shutdown` via the `on<Signal>` form. Two
  # handlers for one signal must be rejected.
  method onShutdown(
      self: RejDupImpl, s: Shutdown
  ): Future[void] {.async: (raises: []), gcsafe.} =
    discard
