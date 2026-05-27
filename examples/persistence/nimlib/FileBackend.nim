## FileBackendImpl — a file-backed IBackend implementation (one dir per
## instance). Demonstrates a second, behaviourally-distinct impl of the same
## sub-interface that coexists with MemoryBackendImpl under the same library.

import std/[os, random]
import results, chronos
import brokers/broker_interface, brokers/broker_implement
import ./PersistenceAPI

type FileBackendImpl* = ref object of IBackend
  dir: string
  rng: Rand ## per-instance RNG (no global state → gcsafe; runs single-threaded)

BrokerImplement FileBackendImpl of IBackend:
  proc init() =
    # `brokerCtx` is already assigned by the time the init body runs, so it
    # yields a per-instance directory name. No filesystem IO here (kept simple
    # and gcsafe — the new()/bindToContext path is gcsafe); the dir is created
    # lazily on first store.
    self.dir = "build" / "persist_be_" & $uint32(self.brokerCtx)
    self.rng = initRand(int64(uint32(self.brokerCtx)) * 2)

  method store(
      self: FileBackendImpl, key: string, value: string
  ): Future[Result[bool, string]] {.async.} =
    # File writes are realistically a touch slower than memory. `noCancel`
    # keeps the delay within the method's `raises: []` contract.
    await noCancel(sleepAsync(self.rng.rand(3 .. 15).milliseconds))
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
    # Variable I/O latency before the async result is delivered.
    await noCancel(sleepAsync(self.rng.rand(8 .. 50).milliseconds))
    await self.emit(ReadCompleted, ReadCompleted(key: key, value: value, found: found))
    ok(true)
