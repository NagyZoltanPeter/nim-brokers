## api_buf — tracked FFI buffer allocator (audit findings M5 + M7)
## ===============================================================
##
## Buffers that cross to the foreign side and may come back through
## `<lib>_freeBuffer` are recorded in a process-global registry of live
## allocations (pointer → payload size). That registry is what lets the FFI
## boundary answer two questions it previously could not:
##
## * **M7** — is this pointer something this library actually allocated, and
##   is it still live? `_freeBuffer` had only a nil check and would happily
##   `deallocShared` the static `_version()` string (reproduced: SIGSEGV in
##   `addToSharedFreeListBigChunks`) or double-free a buffer (reproduced under
##   ASan as `attempting double-free`).
##
## * **M5** — how big is this request buffer really? `_call` trusted the
##   caller's `reqLen` and it became a `copyMem` length on the processing
##   thread (reproduced: SIGSEGV in `handleCourierMsg`).
##
## ### Why a side registry and not an inline header
##
## The obvious implementation — a `[magic][size]` header before the payload —
## was implemented first and rejected. Validating a pointer then means reading
## the bytes *before* it, which is undefined behaviour precisely in the cases
## being defended against. Measured under AddressSanitizer:
##
##   * freeing the static `_version()` string → `global-buffer-overflow`
##     inside the validator itself;
##   * double free → `heap-use-after-free`, because the second call reads the
##     header of a block that has already been returned to the allocator (so
##     the "poison the magic" trick is not reliable either).
##
## Both "work" without a sanitizer, but a security fix must not introduce UB,
## and this repo runs ASan in CI (`memcheck_ci.yml`). The registry never
## dereferences an untrusted pointer — it only hashes its numeric value — so
## it is clean under ASan and correct by construction.
##
## Cost: one lock acquisition per alloc/free/size-query. These paths already
## involve a condvar handoff or a full CBOR encode, so the lock is not
## material. A missed `apiFreeTagged` (i.e. a buffer freed by a raw
## `deallocShared` somewhere) leaves a stale entry — a small leak in the
## table, never memory corruption. That benign failure mode is deliberate.
##
## This module depends on nothing but `system` and `std/locks`, so both the
## codegen layer (`api_common`) and the runtime courier (`api_cbor_courier`)
## can use it without an import cycle.

{.push raises: [].}

import std/[atomics, locks]

const
  EmptySlot = 0'u # never a valid heap pointer
  TombstoneSlot = 1'u # deleted; probing must continue past it
  InitialCap = 1024 # power of two
  MaxLoadNum = 7 # grow when count/cap > 7/10
  MaxLoadDen = 10

type BufRegistry = object
  keys: ptr UncheckedArray[uint]
  sizes: ptr UncheckedArray[int]
  cap: int
  count: int ## live entries
  used: int ## live + tombstones (probe-sequence occupancy)

var gBufRegLock: Lock
var gBufReg: BufRegistry
var gBufRegInit: Atomic[int]

proc bufRegEnsureInit() {.gcsafe.} =
  ## One-time init, CAS-guarded: 0 = untouched, 1 = initialising, 2 = ready.
  if gBufRegInit.load(moAcquire) == 2:
    return
  var expected = 0
  if gBufRegInit.compareExchange(expected, 1, moAcquire, moRelaxed):
    initLock(gBufRegLock)
    gBufReg.keys =
      cast[ptr UncheckedArray[uint]](allocShared0(InitialCap * sizeof(uint)))
    gBufReg.sizes = cast[ptr UncheckedArray[int]](allocShared0(InitialCap * sizeof(int)))
    gBufReg.cap = InitialCap
    gBufReg.count = 0
    gBufReg.used = 0
    gBufRegInit.store(2, moRelease)
  else:
    while gBufRegInit.load(moAcquire) != 2:
      cpuRelax()

func hashPtr(p: uint, cap: int): int {.inline.} =
  ## Allocations are at least 8/16-byte aligned, so the low bits carry no
  ## entropy — shift them out, then mix (Fibonacci hashing).
  let h = (p shr 4) * 0x9E3779B97F4A7C15'u
  int((h shr 32) and uint(cap - 1))

proc regFindSlotLocked(key: uint): int =
  ## Index of `key`, or -1. Caller holds `gBufRegLock`.
  var idx = hashPtr(key, gBufReg.cap)
  for _ in 0 ..< gBufReg.cap:
    let k = gBufReg.keys[idx]
    if k == EmptySlot:
      return -1
    if k == key:
      return idx
    idx = (idx + 1) and (gBufReg.cap - 1)
  -1

proc regInsertLocked(key: uint, size: int) =
  ## Insert, reusing the first tombstone in the probe sequence. Caller holds
  ## the lock and has already ensured capacity.
  var idx = hashPtr(key, gBufReg.cap)
  var firstTomb = -1
  for _ in 0 ..< gBufReg.cap:
    let k = gBufReg.keys[idx]
    if k == EmptySlot:
      let target = if firstTomb >= 0: firstTomb else: idx
      if firstTomb < 0:
        gBufReg.used.inc()
      gBufReg.keys[target] = key
      gBufReg.sizes[target] = size
      gBufReg.count.inc()
      return
    if k == TombstoneSlot and firstTomb < 0:
      firstTomb = idx
    elif k == key:
      # Re-registration of a live address: overwrite. Cannot happen while the
      # allocator is behaving, but keep the table consistent if it does.
      gBufReg.sizes[idx] = size
      return
    idx = (idx + 1) and (gBufReg.cap - 1)
  # Table full despite the load-factor guard: drop the record rather than spin.
  # The buffer stays valid; `_freeBuffer` will refuse it and it leaks.

proc regGrowLocked() =
  ## Double the table (or just clear tombstones when they dominate).
  let oldKeys = gBufReg.keys
  let oldSizes = gBufReg.sizes
  let oldCap = gBufReg.cap
  var newCap = oldCap
  if gBufReg.count * MaxLoadDen >= oldCap * MaxLoadNum:
    newCap = oldCap * 2
  let nk = cast[ptr UncheckedArray[uint]](allocShared0(newCap * sizeof(uint)))
  if nk.isNil:
    return
  let ns = cast[ptr UncheckedArray[int]](allocShared0(newCap * sizeof(int)))
  if ns.isNil:
    deallocShared(nk)
    return
  gBufReg.keys = nk
  gBufReg.sizes = ns
  gBufReg.cap = newCap
  gBufReg.count = 0
  gBufReg.used = 0
  for i in 0 ..< oldCap:
    let k = oldKeys[i]
    if k != EmptySlot and k != TombstoneSlot:
      regInsertLocked(k, oldSizes[i])
  deallocShared(oldKeys)
  deallocShared(oldSizes)

proc apiAllocTagged*(size: int): pointer {.gcsafe.} =
  ## Allocate a tracked FFI buffer of `size` bytes. Free only via
  ## `apiFreeTagged`. Layout is a plain `allocShared0` block — no header — so
  ## a raw `deallocShared` on the result is still memory-safe (it merely
  ## strands a registry entry).
  if size <= 0:
    return nil
  bufRegEnsureInit()
  let p = allocShared0(size)
  if p.isNil:
    return nil
  withLock gBufRegLock:
    if (gBufReg.used + 1) * MaxLoadDen >= gBufReg.cap * MaxLoadNum:
      regGrowLocked()
    regInsertLocked(cast[uint](p), size)
  p

proc apiTaggedSize*(p: pointer): int {.gcsafe.} =
  ## Payload size of a live tracked buffer, or `-1` when `p` is nil or is not
  ## one. Never dereferences `p`.
  if p.isNil:
    return -1
  bufRegEnsureInit()
  withLock gBufRegLock:
    let idx = regFindSlotLocked(cast[uint](p))
    result = if idx < 0: -1 else: gBufReg.sizes[idx]

proc apiFreeTagged*(p: pointer): bool {.discardable, gcsafe.} =
  ## Free a tracked buffer. Returns `false` — having freed NOTHING — when `p`
  ## is not a live tracked buffer: a foreign pointer, static storage such as
  ## the `_version()` string, or a buffer that was already freed. Never
  ## dereferences `p` before deciding.
  if p.isNil:
    return true
  bufRegEnsureInit()
  var owned = false
  withLock gBufRegLock:
    let idx = regFindSlotLocked(cast[uint](p))
    if idx >= 0:
      gBufReg.keys[idx] = TombstoneSlot
      gBufReg.sizes[idx] = 0
      gBufReg.count.dec()
      owned = true
  if owned:
    deallocShared(p)
  owned

{.pop.}
