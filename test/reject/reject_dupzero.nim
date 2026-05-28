# Only one zero-argument signature is allowed.
import chronos
import brokers/request_broker
RequestBroker:
  proc dup(): Future[Result[int, string]] {.async.}
  proc dup(): Future[Result[int, string]] {.async.}
