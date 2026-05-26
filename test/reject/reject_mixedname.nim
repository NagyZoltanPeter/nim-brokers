# All signatures in one block must share the proc name.
import chronos
import brokers/request_broker
RequestBroker:
  proc alpha(): Future[Result[int, string]] {.async.}
  proc beta(x: int): Future[Result[int, string]] {.async.}
