## IPersistenceLib — the FFI library entry point for the persistence example.
##
## Wires the IPersistence facade impl into the C-ABI surface. The interfaces
## live in PersistenceAPI; the behaviour in the three impl modules; this file
## only binds the main impl to the FFI context and registers the library.
##
## Build & run via nimble:
##   nimble runPersistenceExampleCpp   # lib + C++ wrapper + cpp_example (orc+refc)

import results, chronos
import brokers/broker_interface, brokers/broker_implement, brokers/api_library
import ./PersistenceAPI
import ./PersistenceFacade

proc setupProviders(ctx: BrokerContext): Result[void, string] =
  ## Called by registerBrokerLibrary on the processing thread: construct the
  ## main facade impl adopting the FFI context, wiring its providers under `ctx`.
  discard PersistenceImpl.createUnderContext(ctx)
  ok()

registerBrokerLibrary:
  name:
    "persistence"
  version:
    "0.1.0"
  mainClass:
    IPersistence
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest
