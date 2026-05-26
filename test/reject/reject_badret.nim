# Signature must return Future[Result[T, string]] (async).
import chronos
import brokers/request_broker
RequestBroker:
  proc bad(): int
