# SignalBroker only accepts `mt` / `API` modes — `sync` must be rejected.
import chronos
import brokers/signal_broker

SignalBroker(sync):
  type Bad = object
    n*: int
