## PersistenceImpl — the IPersistence facade implementation.
##
## Keeps a reference to every backend it creates (the `seq[BackendEntry]`),
## creating either a File or Memory backend per `makeBackend(kind)`, and offers
## `listBackends` (state) + `terminateBackend` (targeted Nim-side teardown).

import results, chronos
import brokers/broker_context, brokers/broker_interface, brokers/broker_implement
import ./PersistenceAPI, ./MemoryBackend, ./FileBackend, ./PersistenceFacade

IPersistence.provideFactory(
  proc(): Result[IPersistence, string] {.gcsafe.} =
    ok(IPersistence(PersistenceImpl.createUnderContext(NewBrokerContext())))
)
