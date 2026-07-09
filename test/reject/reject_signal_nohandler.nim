# A SignalBroker declared in a BrokerInterface must be fulfilled by a handler
# override in the BrokerImplement — omitting it is a compile error.
import chronos
import brokers/broker_interface
import brokers/broker_implement

BrokerInterface(IRejNoHandler):
  SignalBroker:
    type Boom = object
      x: int

type RejNoHandlerImpl = ref object of IRejNoHandler

BrokerImplement RejNoHandlerImpl of IRejNoHandler:
  proc new(T: typedesc[RejNoHandlerImpl]): RejNoHandlerImpl =
    RejNoHandlerImpl()
    # no `method` for Boom -> fulfillment check must fail
