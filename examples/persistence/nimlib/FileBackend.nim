## FileBackendImpl — a file-backed IBackend implementation (one dir per
## instance). Demonstrates a second, behaviourally-distinct impl of the same
## sub-interface that coexists with MemoryBackendImpl under the same library.

import std/os
import results, chronos
import brokers/broker_interface, brokers/broker_implement
import ./PersistenceAPI

type FileBackendImpl* = ref object of IBackend
  dir: string

BrokerImplement FileBackendImpl of IBackend:
  proc init() =
    # `brokerCtx` is already assigned by the time the init body runs, so it
    # yields a per-instance directory name. No filesystem IO here (kept simple
    # and gcsafe — the new()/bindToContext path is gcsafe); the dir is created
    # lazily on first store.
    self.dir = "build" / "persist_be_" & $uint32(self.brokerCtx)

  method store(
      self: FileBackendImpl, key: string, value: string
  ): Future[Result[bool, string]] {.async.} =
    try:
      {.cast(gcsafe).}:
        discard existsOrCreateDir("build")
        discard existsOrCreateDir(self.dir)
        writeFile(self.dir / key, value)
    except CatchableError as e:
      return err("file store failed: " & e.msg)
    ok(true)

  method read(
      self: FileBackendImpl, key: string
  ): Future[Result[bool, string]] {.async.} =
    var found = false
    var value = ""
    try:
      {.cast(gcsafe).}:
        let path = self.dir / key
        found = fileExists(path)
        if found:
          value = readFile(path)
    except CatchableError as e:
      return err("file read failed: " & e.msg)
    await self.emit(ReadCompleted, ReadCompleted(key: key, value: value, found: found))
    ok(true)
