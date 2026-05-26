## MemoryBackendImpl — an in-memory IBackend implementation.
## Demonstrates an impl module separated from the interface contract.

import std/tables
import results, chronos
import brokers/broker_interface, brokers/broker_implement
import ./PersistenceAPI

type MemoryBackendImpl* = ref object of IBackend
  data: Table[string, string]

BrokerImplement MemoryBackendImpl of IBackend:
  proc init() =
    self.data = initTable[string, string]()

  method store(
      self: MemoryBackendImpl, key: string, value: string
  ): Future[Result[bool, string]] {.async.} =
    self.data[key] = value
    ok(true)

  method read(
      self: MemoryBackendImpl, key: string
  ): Future[Result[bool, string]] {.async.} =
    let found = self.data.hasKey(key)
    let value = self.data.getOrDefault(key, "")
    # The value is delivered asynchronously through the instance-scoped event
    # facade (injects this backend's own ctx → routes to this backend's subs).
    await self.emit(ReadCompleted, ReadCompleted(key: key, value: value, found: found))
    ok(true)
