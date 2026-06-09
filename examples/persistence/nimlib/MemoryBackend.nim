## MemoryBackendImpl — an in-memory IBackend implementation.
## Demonstrates an impl module separated from the interface contract.

import std/[tables, random]
import results, chronos
import brokers/broker_interface, brokers/broker_implement
import ./PersistenceAPI

type MemoryBackendImpl* = ref object of IBackend
  data: Table[string, string]
  rng: Rand ## per-instance RNG (no global state → gcsafe; runs single-threaded)

proc emitReadResult(
    self: MemoryBackendImpl, key, value: string, found: bool
) {.async: (raises: []), gcsafe.} =
  ## Out-of-band read result: `read` acks immediately; this fires later, after a
  ## variable delay, on the processing thread (where it was spawned).
  await noCancel(sleepAsync(self.rng.rand(5 .. 40).milliseconds))
  await self.emit(ReadCompleted, ReadCompleted(key: key, value: value, found: found))

BrokerImplement MemoryBackendImpl of IBackend:
  proc init(self: MemoryBackendImpl) =
    # Post-context hook: runs after `brokerCtx` is bound (and before providers).
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
    # Snapshot the value now, then ACK IMMEDIATELY. The result is delivered
    # purely out-of-band: a spawned task waits a variable delay and emits
    # ReadCompleted on this backend's own ctx (→ routes to this backend's subs).
    let found = self.data.hasKey(key)
    let value = self.data.getOrDefault(key, "")
    asyncSpawn self.emitReadResult(key, value, found)
    ok(true)
