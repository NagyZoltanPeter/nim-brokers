## PersistenceImpl — the IPersistence facade implementation.
##
## Keeps a reference to every backend it creates (the `seq[BackendEntry]`),
## creating either a File or Memory backend per `makeBackend(kind)`, and offers
## `listBackends` (state) + `terminateBackend` (targeted Nim-side teardown).

import results, chronos
import brokers/broker_interface, brokers/broker_implement
import ./PersistenceAPI, ./MemoryBackend, ./FileBackend

type
  BackendEntry = object
    backend: IBackend ## keeps the instance reachable (IPersistence owns it)
    kind: int32
    handle: uint32 ## the backend's routing ctx
    alive: bool
    terminate: proc() {.gcsafe, raises: [].} ## closure → the concrete impl's close()

  PersistenceImpl* = ref object of IPersistence
    backends: seq[BackendEntry]

BrokerImplement PersistenceImpl of IPersistence:
  proc init() =
    self.backends = @[]

  method makeBackend(
      self: PersistenceImpl, kind: int32
  ): Future[Result[IBackend, string]] {.async.} =
    # Sub-instance SHARES the library classCtx (so its requests/events route to
    # this same processing thread) with a fresh instanceCtx. The factory picks
    # the concrete impl by input; both kinds coexist under one library.
    let subCtx = newInstanceCtx(self.brokerCtx)
    var be: IBackend
    var term: proc() {.gcsafe, raises: [].}
    if kind == int32(bkFile):
      let f = FileBackendImpl.bindToContext(subCtx)
      be = f
      term = proc() {.gcsafe, raises: [].} =
        {.cast(gcsafe).}:
          f.close()
    else:
      let m = MemoryBackendImpl.bindToContext(subCtx)
      be = m
      term = proc() {.gcsafe, raises: [].} =
        {.cast(gcsafe).}:
          m.close()
    self.backends.add(
      BackendEntry(
        backend: be, kind: kind, handle: uint32(subCtx), alive: true, terminate: term
      )
    )
    await self.emit(BackendCreated, BackendCreated(handle: uint32(subCtx), kind: kind))
    ok(be)

  method listBackends(
      self: PersistenceImpl
  ): Future[Result[ListBackends, string]] {.async.} =
    var st = ListBackends()
    for e in self.backends:
      st.backends.add(BackendInfo(handle: e.handle, kind: e.kind, alive: e.alive))
    ok(st)

  method terminateBackend(
      self: PersistenceImpl, handle: uint32
  ): Future[Result[bool, string]] {.async.} =
    for i in 0 ..< self.backends.len:
      if self.backends[i].handle == handle and self.backends[i].alive:
        # Tear down THIS backend (clears its providers + drops its listeners on
        # the processing thread); siblings are untouched.
        self.backends[i].terminate()
        self.backends[i].alive = false
        return ok(true)
    err("backend not found or already terminated")

  method initializeRequest(
      self: PersistenceImpl, configPath: string
  ): Future[Result[InitializeRequest, string]] {.async.} =
    ok(InitializeRequest(ok: true))

  method shutdownRequest(
      self: PersistenceImpl
  ): Future[Result[ShutdownRequest, string]] {.async.} =
    ok(ShutdownRequest(status: 0))
