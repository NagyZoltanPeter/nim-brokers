{.push raises: [].}

## Event / signal declarations for the issue #51 regression test. The point of
## the test is that the module which *instantiates* the generic caller does NOT
## import this module, so these `listen` / `onSignal` overloads are out of
## scope there.

import chronos, results
import brokers/event_broker, brokers/signal_broker

EventBroker:
  type ScopedEvent* = object
    n*: int

SignalBroker:
  type ScopedSignal* = object
    n*: int

when compileOption("threads"):
  EventBroker(mt):
    type ScopedMtEvent* = object
      n*: int

  SignalBroker(mt):
    type ScopedMtSignal* = object
      n*: int
