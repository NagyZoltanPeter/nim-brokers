## Pure-Nim consumer for the persistence interface-model example.
##
## Uses the factory pattern: imports only PersistenceAPI (the interface) and
## PersistenceFacade (for its side-effect factory registration). The consumer
## never sees the concrete impl types.

{.push raises: [].}

import results, chronos
import brokers/broker_interface, brokers/broker_implement
import ../nimlib/PersistenceAPI
import ../nimlib/PersistenceFactory

const
  KindMemory = int32(bkMemory)
  KindFile = int32(bkFile)

proc newPersistence(): IPersistence =
  {.cast(gcsafe).}:
    IPersistence.create().value

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

  let deadline = Moment.now() + seconds(2)
  while not received and Moment.now() < deadline:
    await noCancel(sleepAsync(1.milliseconds))
  doAssert received, "read event timed out"

  await b.dropListener(ReadCompleted, hRes.get())
  doAssert gotFound, "expected key to be found"
  gotValue

# ---------------------------------------------------------------------------
# Scenario A: two IPersistence instances, each with its own backend kind.
# ---------------------------------------------------------------------------

proc scenarioTwoContexts() {.async: (raises: []).} =
  echo "  [A] two IPersistence instances (File + Memory)"

  let pFile = newPersistence()
  discard await pFile.initializeRequest("cfg")
  let bf = (await pFile.makeBackend(KindFile)).value
  doAssert (await roundtrip(bf, "alpha", "file-payload")) == "file-payload"

  let pMem = newPersistence()
  discard await pMem.initializeRequest("cfg")
  let bm = (await pMem.makeBackend(KindMemory)).value
  doAssert (await roundtrip(bm, "alpha", "memory-payload")) == "memory-payload"

  doAssert bf.brokerCtx != bm.brokerCtx

# ---------------------------------------------------------------------------
# Scenario B: one IPersistence with both File + Memory backends coexisting.
# ---------------------------------------------------------------------------

proc scenarioMixedOneContext() {.async: (raises: []).} =
  echo "  [B] one IPersistence, File + Memory backends coexisting"

  let p = newPersistence()
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

  let deadline = Moment.now() + seconds(2)
  while createdCount < 2 and Moment.now() < deadline:
    await noCancel(sleepAsync(1.milliseconds))
  doAssert createdCount == 2, "BackendCreated events"
  await p.dropListener(BackendCreated, chRes.get())

  # Both sub-instances share the parent classCtx but differ in instanceCtx.
  doAssert (uint32(bf.brokerCtx) and 0xFFFF'u32) == (uint32(p.brokerCtx) and 0xFFFF'u32)
  doAssert (uint32(bm.brokerCtx) and 0xFFFF'u32) == (uint32(p.brokerCtx) and 0xFFFF'u32)
  doAssert (uint32(bf.brokerCtx) shr 16) != (uint32(bm.brokerCtx) shr 16)

  doAssert (await roundtrip(bf, "x", "FILE-X")) == "FILE-X"
  doAssert (await roundtrip(bm, "x", "MEM-X")) == "MEM-X"

  block:
    let st = (await p.listBackends()).value
    doAssert st.backends.len == 2
    for it in st.backends:
      doAssert it.alive

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

  doAssert (await roundtrip(bm, "y", "MEM-Y")) == "MEM-Y"

# ---------------------------------------------------------------------------
# Scenario C: two backends under load — parallel chronos tasks.
# ---------------------------------------------------------------------------

proc scenarioConcurrentLoad() {.async: (raises: []).} =
  const N = 30
  echo "  [C] two backends under load, " & $N & " roundtrips each"

  let p = newPersistence()
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

    await be.dropListener(ReadCompleted, hRes.get())
    local

  let fileTask = runBackend(bf, "fileLib", N)
  let memTask = runBackend(bm, "memLib", N)
  let okFile = await fileTask
  let okMem = await memTask

  echo "      File: " & $okFile & "/" & $N & "  Memory: " & $okMem & "/" & $N &
    " roundtrips OK"
  doAssert okFile == N, "all File roundtrips correct under load"
  doAssert okMem == N, "all Memory roundtrips correct under load"

# ---------------------------------------------------------------------------

proc main() {.async: (raises: []).} =
  echo "persistence nim example (pure broker, no FFI)"
  await scenarioTwoContexts()
  await scenarioMixedOneContext()
  await scenarioConcurrentLoad()
  echo "persistence nim example: OK"

waitFor main()
