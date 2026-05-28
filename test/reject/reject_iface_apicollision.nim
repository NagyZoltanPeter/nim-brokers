# reduced-A (A1): apiNames are globally unique across ALL BrokerInterface(API)
# interfaces in a library, not per interface. Two interfaces each declaring a
# request whose verb produces the same wire apiName ("get_value") must be a hard
# compile error. Compile with -d:BrokerFfiApi --threads:on (API mode).
import results, chronos
import brokers/broker_interface
import brokers/broker_implement

BrokerInterface(API, IAlpha):
  RequestBroker:
    proc getValue(): Future[Result[int32, string]] {.async.}

BrokerInterface(API, IBeta):
  RequestBroker:
    proc getValue(): Future[Result[int32, string]] {.async.}
