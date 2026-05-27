# Object-form payload type must equal the broker name (no third coupling).
import chronos
import brokers/request_broker
type SomethingElse = object
  w: int

RequestBroker:
  type GoodName = object
    v: int

  proc goodName(): Future[Result[SomethingElse, string]] {.async.}
