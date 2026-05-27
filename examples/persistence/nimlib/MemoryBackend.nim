## MemoryBackendImpl — an in-memory IBackend implementation.
## Demonstrates an impl module separated from the interface contract.

import std/[tables, random]
import results, chronos
import brokers/broker_interface, brokers/broker_implement
import ./PersistenceAPI

type MemoryBackendImpl* = ref object of IBackend
  data: Table[string, string]
  rng: Rand ## per-instance RNG (no global state → gcsafe; runs single-threaded)

BrokerImplement MemoryBackendImpl of IBackend:
  proc init() =
    self.data = initTable[string, string]()
    # Seed deterministically from the instance ctx so runs are reproducible.
    self.rng = initRand(int64(uint32(self.brokerCtx)) * 2 + 1)

  method store(
      self: MemoryBackendImpl, key: string, value: string
  ): Future[Result[bool, string]] {.async.} =
    # Realistic jitter: a small write latency before acknowledging. `noCancel`
    # keeps the delay within the method's `raises: []` contract.
    await noCancel(sleepAsync(self.rng.rand(1 .. 8).milliseconds))
    self.data[key] = value
    ok(true)

  method read(
      self: MemoryBackendImpl, key: string
  ): Future[Result[bool, string]] {.async.} =
    let found = self.data.hasKey(key)
    let value = self.data.getOrDefault(key, "")
    # Realistic jitter: the value is produced after a variable delay, then
    # delivered asynchronously through the instance-scoped event facade
    # (injects this backend's own ctx → routes to this backend's subs).
    await noCancel(sleepAsync(self.rng.rand(5 .. 40).milliseconds))
    await self.emit(ReadCompleted, ReadCompleted(key: key, value: value, found: found))
    ok(true)
