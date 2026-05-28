## Pure-Nim consumer for the persistence interface-model example.
##
## Replicates the three scenarios from cpp_example/main.cpp using the broker
## interfaces directly — same compilation unit, single thread, chronos async.

{.push raises: [].}

import results, chronos
import brokers/broker_context, brokers/broker_interface, brokers/broker_implement
import ../nimlib/PersistenceAPI
import ../nimlib/PersistenceFacade

const
  KindMemory = int32(bkMemory)
  KindFile = int32(bkFile)

proc roundtrip(b: IBackend, key, val: string): Future[string] {.async: (raises: []).} =
  var gotValue: string
  var gotFound: bool
  var received = false

  let hRes = b.listen(
    ReadCompleted,
    proc(evt: ReadCompleted): Future[void] {.async: (raises: []).} =
      gotValue = evt.value
      gotFound = evt.found
      received = true,
  )
  doAssert hRes.isOk, "listen failed"

  let storeRes = await b.store(key, val)
  doAssert storeRes.isOk, "store failed: " & storeRes.error

  let readRes = await b.read(key)
  doAssert readRes.isOk, "read failed: " & readRes.error

  # Single-thread: just yield until the async emit fires.
  let deadline = Moment.now() + seconds(2)
  while not received and Moment.now() < deadline:
    await noCancel(sleepAsync(1.milliseconds))
  doAssert received, "read event timed out"

  b.dropListener(ReadCompleted, hRes.get())
  doAssert gotFound, "expected key to be found"
  gotValue

# ---------------------------------------------------------------------------
# Scenario A: two PersistenceImpl instances, each with its own backend kind.
# ---------------------------------------------------------------------------

proc scenarioTwoContexts() {.async: (raises: []).} =
  echo "  [A] two PersistenceImpl instances (File + Memory)"

  let pFile = PersistenceImpl.bindToContext(NewBrokerContext())
  discard await pFile.initializeRequest("cfg")
  let bf = (await pFile.makeBackend(KindFile)).value
  doAssert (await roundtrip(bf, "alpha", "file-payload")) == "file-payload"

  let pMem = PersistenceImpl.bindToContext(NewBrokerContext())
  discard await pMem.initializeRequest("cfg")
  let bm = (await pMem.makeBackend(KindMemory)).value
  doAssert (await roundtrip(bm, "alpha", "memory-payload")) == "memory-payload"

  # Distinct contexts.
  doAssert bf.brokerCtx != bm.brokerCtx

  pFile.close()
  pMem.close()

# ---------------------------------------------------------------------------
# Scenario B: one PersistenceImpl with both File + Memory backends coexisting.
# ---------------------------------------------------------------------------

proc scenarioMixedOneContext() {.async: (raises: []).} =
  echo "  [B] one PersistenceImpl, File + Memory backends coexisting"

  let ctx = NewBrokerContext()
  let p = PersistenceImpl.bindToContext(ctx)
  discard await p.initializeRequest("cfg")

  var createdCount = 0
  let chRes = p.listen(
    BackendCreated,
    proc(evt: BackendCreated): Future[void] {.async: (raises: []).} =
      inc createdCount
    ,
  )
  doAssert chRes.isOk

  let bf = (await p.makeBackend(KindFile)).value
  let bm = (await p.makeBackend(KindMemory)).value

  # Yield to let the BackendCreated events fire.
  let deadline = Moment.now() + seconds(2)
  while createdCount < 2 and Moment.now() < deadline:
    await noCancel(sleepAsync(1.milliseconds))
  doAssert createdCount == 2, "BackendCreated events"
  p.dropListener(BackendCreated, chRes.get())

  # Both sub-instances share the parent classCtx but differ in instanceCtx.
  doAssert (uint32(bf.brokerCtx) and 0xFFFF'u32) == (uint32(p.brokerCtx) and 0xFFFF'u32)
  doAssert (uint32(bm.brokerCtx) and 0xFFFF'u32) == (uint32(p.brokerCtx) and 0xFFFF'u32)
  doAssert (uint32(bf.brokerCtx) shr 16) != (uint32(bm.brokerCtx) shr 16)

  # Per-instance routing: each backend's read lands on its own subscriber.
  doAssert (await roundtrip(bf, "x", "FILE-X")) == "FILE-X"
  doAssert (await roundtrip(bm, "x", "MEM-X")) == "MEM-X"

  # State check.
  block:
    let st = (await p.listBackends()).value
    doAssert st.backends.len == 2
    for it in st.backends:
      doAssert it.alive

  # Targeted teardown — save ctx before close() resets it.
  let bfCtx = uint32(bf.brokerCtx)
  let bmCtx = uint32(bm.brokerCtx)
  doAssert (await p.terminateBackend(bfCtx)).isOk

  block:
    let st = (await p.listBackends()).value
    var fileDead = false
    var memAlive = false
    for it in st.backends:
      if it.handle == bfCtx:
        fileDead = not it.alive
      if it.handle == bmCtx:
        memAlive = it.alive
    doAssert fileDead, "File backend should be terminated"
    doAssert memAlive, "Memory backend should still be alive"

  # Sibling keeps working.
  doAssert (await roundtrip(bm, "y", "MEM-Y")) == "MEM-Y"

  p.close()

# ---------------------------------------------------------------------------
# Scenario C: two backends under load — parallel chronos tasks.
# ---------------------------------------------------------------------------

proc scenarioConcurrentLoad() {.async: (raises: []).} =
  const N = 30
  echo "  [C] two backends under load, " & $N & " roundtrips each"

  let p = PersistenceImpl.bindToContext(NewBrokerContext())
  discard await p.initializeRequest("cfg")
  let bf = (await p.makeBackend(KindFile)).value
  let bm = (await p.makeBackend(KindMemory)).value

  proc runBackend(
      be: IBackend, tag: string, n: int
  ): Future[int] {.async: (raises: []).} =
    var results: seq[(string, string)]
    let hRes = be.listen(
      ReadCompleted,
      proc(evt: ReadCompleted): Future[void] {.async: (raises: []).} =
        results.add((evt.key, evt.value)),
    )
    doAssert hRes.isOk

    var local = 0
    for i in 0 ..< n:
      let key = tag & "_" & $i
      let val = tag & "_val_" & $i
      if (await be.store(key, val)).isErr:
        continue
      let before = results.len
      if (await be.read(key)).isErr:
        continue
      let deadline = Moment.now() + seconds(3)
      while results.len <= before and Moment.now() < deadline:
        await noCancel(sleepAsync(1.milliseconds))
      if results.len > before and results[^1][0] == key and results[^1][1] == val:
        inc local

    be.dropListener(ReadCompleted, hRes.get())
    local

  let fileTask = runBackend(bf, "fileLib", N)
  let memTask = runBackend(bm, "memLib", N)
  let okFile = await fileTask
  let okMem = await memTask

  echo "      File: " & $okFile & "/" & $N & "  Memory: " & $okMem & "/" & $N &
    " roundtrips OK"
  doAssert okFile == N, "all File roundtrips correct under load"
  doAssert okMem == N, "all Memory roundtrips correct under load"

  p.close()

# ---------------------------------------------------------------------------

proc main() {.async: (raises: []).} =
  echo "persistence nim example (pure broker, no FFI)"
  await scenarioTwoContexts()
  await scenarioMixedOneContext()
  await scenarioConcurrentLoad()
  echo "persistence nim example: OK"

waitFor main()
