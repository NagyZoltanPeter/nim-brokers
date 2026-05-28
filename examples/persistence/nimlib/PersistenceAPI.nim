## PersistenceAPI — the interface contract for the persistence example.
##
## Two layers of BrokerInterface(API):
##   * IBackend     — a storage backend (sub-interface): store/read requests +
##                    a ReadCompleted event (the read result arrives async).
##   * IPersistence — the library facade (main interface): a create-instance
##                    request `makeBackend(kind)` returning an IBackend (File or
##                    Memory), plus listBackends / terminateBackend for state +
##                    targeted teardown, and a BackendCreated event.
##
## This module declares ONLY the contract — the brokers, abstract methods, event
## facade and factory are generated here; the concrete behaviour lives in the
## separate impl modules (MemoryBackendImpl / FileBackendImpl / PersistenceImpl).

import results, chronos
import brokers/broker_interface

type BackendKind* = enum
  bkMemory = 0
  bkFile = 1

# --- Sub-interface: a storage backend -------------------------------------
BrokerInterface(API, IBackend):
  EventBroker:
    type ReadCompleted = object ## async result of a `read` request
      key*: string
      value*: string
      found*: bool

  RequestBroker:
    proc store(key: string, value: string): Future[Result[bool, string]] {.async.}

  RequestBroker:
    # Acks acceptance synchronously; the value is delivered via ReadCompleted.
    proc read(key: string): Future[Result[bool, string]] {.async.}

# --- State projection returned by IPersistence.listBackends ---------------
type BackendInfo* = object
  handle*: uint32 ## the backend's routing ctx (shared classCtx, own instanceCtx)
  kind*: int32
  alive*: bool

# --- Main interface: the persistence facade -------------------------------
BrokerInterface(API, IPersistence):
  EventBroker:
    type BackendCreated = object
      handle*: uint32
      kind*: int32

  RequestBroker:
    # Create-instance request: returns a backend of the requested kind.
    proc makeBackend(kind: int32): Future[Result[IBackend, string]] {.async.}

  RequestBroker:
    # Object form (type declared in-block, exported for the impl module): a POD
    # form with an external object payload would name the response after the
    # verb and leave the object unregistered.
    type ListBackends* = object
      backends*: seq[BackendInfo]

    proc listBackends(): Future[Result[ListBackends, string]] {.async.}

  RequestBroker:
    proc terminateBackend(handle: uint32): Future[Result[bool, string]] {.async.}

  RequestBroker:
    type InitializeRequest = object
      ok*: bool

    proc initializeRequest(
      configPath: string
    ): Future[Result[InitializeRequest, string]] {.async.}

  RequestBroker:
    type ShutdownRequest = object
      status*: int32

    proc shutdownRequest(): Future[Result[ShutdownRequest, string]] {.async.}
