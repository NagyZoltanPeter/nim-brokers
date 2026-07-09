# A signal handler binds to a SignalBroker by name (`<Signal>` / `on<Signal>`),
# but its payload parameter must still be of the signal's type. A handler that
# names the signal yet takes the wrong payload type is a compile error.
import chronos
import brokers/broker_interface
import brokers/broker_implement

BrokerInterface(IRejBadShape):
  SignalBroker:
    type Ping = object
      n: int

type RejBadShapeImpl = ref object of IRejBadShape

BrokerImplement RejBadShapeImpl of IRejBadShape:
  proc new(T: typedesc[RejBadShapeImpl]): RejBadShapeImpl =
    RejBadShapeImpl()

  # Names `Ping` via the `on<Signal>` form, but the payload is `int`, not `Ping`.
  method onPing(
      self: RejBadShapeImpl, s: int
  ): Future[void] {.async: (raises: []), gcsafe.} =
    discard
