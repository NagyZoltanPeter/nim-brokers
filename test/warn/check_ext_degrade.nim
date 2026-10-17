# Without -d:BrokerFfiApi an EXTAPI broker degrades to a plain `(mt)` broker:
# it compiles, takes a Nim provider and answers — registerExtPlugin is a no-op.
import chronos, results
import brokers/[request_broker, ext_plugin]

RequestBroker(EXTAPI[degr], dispatch = workers(2)):
  type Degr = object
    v*: int32

  proc signature*(x: int32): Future[Result[Degr, string]] {.async.}

registerExtPlugin(degr, version = "1.0.0")

proc prov(x: int32): Future[Result[Degr, string]] {.async.} =
  return ok(Degr(v: x + 1))

doAssert Degr.setProvider(DefaultBrokerContext, prov).isOk
doAssert (waitFor Degr.request(DefaultBrokerContext, 1)).value.v == 2
