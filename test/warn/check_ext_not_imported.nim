# Plain multi-thread brokers (no -d:BrokerFfiApi) must not pull the EXTAPI
# runtime in: no process globals, std/dynlib, std/json or CBOR codec through
# request_broker / event_broker / signal_broker. Compiles only when gated.
import brokers/[request_broker, event_broker, signal_broker]

static:
  doAssert not declared(extHostStart), "ext_runtime leaked into a plain MT build"
  doAssert not declared(cborEncode), "the CBOR codec leaked into a plain MT build"

RequestBroker(mt):
  type Plain = object
    v*: int32

  proc signature*(): Future[Result[Plain, string]] {.async.}
