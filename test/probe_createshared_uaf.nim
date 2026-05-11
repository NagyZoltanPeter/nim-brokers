## Phase 0 probe (gates the §2.6 redesign plan).
##
## Question: is `createShared` of a multi-KiB region §2.6-safe?
##
## The §2.6 UAF was traced to Nim's small-cell `allocShared` path retaining
## chunk metadata in the sender thread's per-thread arena (anchored in dyld
## TLV on macOS). If `createShared` of the sizes the redesign needs (ring
## headers, slab storage — typically ≥ 4 KiB, usually multi-KiB) routes
## through the big-chunk / mmap path instead, it is §2.6-immune and we can
## back the new MPSC ring + slab with `createShared` directly. If it ALSO
## trips UAF, the plan must fall back to `c_malloc`/`c_free` for queue
## backing memory.
##
## What we exercise:
##   1. Thread T1 createShared's regions of several sizes.
##   2. T1 writes payload bytes into each region.
##   3. T1 hands pointers to the main thread and exits (joinThread).
##   4. Thread T2 reads and writes each region.
##   5. Thread T3 deallocShareds each region (cross-thread free).
##   6. Thread T4 createShareds fresh regions to exercise the free list
##      that T3 just added to.
##
## All three of (4), (5), (6) are the operations whose code paths trip
## §2.6 in the broker case. If this probe runs clean under ASAN+ORC+macOS
## arm64, the redesign foundation is sound.
##
## Build:
##   nim c -r --cc:clang --debugger:native --threads:on --mm:orc \
##     --passC:"-fsanitize=address -fno-omit-frame-pointer -O1 -g \
##              -fno-optimize-sibling-calls" \
##     --passL:"-fsanitize=address" --path:. \
##     --outdir:build test/probe_createshared_uaf.nim

import std/[atomics, os]

const sizes = [256, 1024, 4096, 16 * 1024, 64 * 1024, 256 * 1024]
const nRegions = sizes.len

var regions: array[nRegions, pointer]
var regionSizes: array[nRegions, int]

var t1Done: Atomic[bool]
var t2Done: Atomic[bool]
var t3Done: Atomic[bool]

proc allocator() {.thread.} =
  ## T1: allocate each size, write a recognizable byte pattern, expose pointers.
  for i in 0 ..< nRegions:
    let p = createShared(byte, sizes[i])
    doAssert not p.isNil
    let bytes = cast[ptr UncheckedArray[byte]](p)
    for j in 0 ..< sizes[i]:
      bytes[j] = byte((i * 31 + j) and 0xff)
    regions[i] = p
    regionSizes[i] = sizes[i]
  t1Done.store(true)

proc reader() {.thread.} =
  ## T2: cross-thread read+write. Reads must observe T1's pattern;
  ## writes overwrite with a different pattern that T3 will not check
  ## (we're only interested in whether the access faults).
  while not t1Done.load():
    sleep(1)
  for i in 0 ..< nRegions:
    let bytes = cast[ptr UncheckedArray[byte]](regions[i])
    for j in 0 ..< regionSizes[i]:
      doAssert bytes[j] == byte((i * 31 + j) and 0xff),
        "region " & $i & " offset " & $j & " value mismatch"
    for j in 0 ..< regionSizes[i]:
      bytes[j] = byte((i * 17 + j + 1) and 0xff)
  t2Done.store(true)

proc deallocator() {.thread.} =
  ## T3: cross-thread free. This is the path that mirrors the §2.6
  ## broker UAF: `deallocShared` from a thread that didn't allocate.
  ## Under §2.6 the alloc was on T1's per-thread arena; if T1's TLV had
  ## been freed (which it has by now — see `joinThread` in main), the
  ## allocator's chunk-metadata walk would fault here.
  while not t2Done.load():
    sleep(1)
  for i in 0 ..< nRegions:
    deallocShared(regions[i])
    regions[i] = nil
  t3Done.store(true)

proc reuser() {.thread.} =
  ## T4: alloc fresh regions of the same sizes — exercises the free
  ## list T3 just contributed to. If §2.6-class corruption exists in
  ## the free list, this is the most likely place to trip it.
  while not t3Done.load():
    sleep(1)
  for round in 0 ..< 4:
    var newPtrs: array[nRegions, pointer]
    for i in 0 ..< nRegions:
      newPtrs[i] = createShared(byte, sizes[i])
      doAssert not newPtrs[i].isNil
      let bytes = cast[ptr UncheckedArray[byte]](newPtrs[i])
      for j in 0 ..< sizes[i]:
        bytes[j] = byte((round * 13 + i * 7 + j) and 0xff)
    for i in 0 ..< nRegions:
      deallocShared(newPtrs[i])

proc run() =
  t1Done.store(false)
  t2Done.store(false)
  t3Done.store(false)

  var t1, t2, t3, t4: Thread[void]

  # T1 allocates and exits.  This is the key step that distinguishes
  # this probe from a plain shared-allocation smoke test:  T1 exits
  # BEFORE the other threads touch its allocations.  On macOS that
  # frees T1's dyld TLV block (the §2.6 mechanism).
  t1.createThread(allocator)
  t1.joinThread()
  # T1's TLV block is now free()'d by _pthread_tsd_cleanup on macOS.

  # Light sleep so any latent memory-system reuse hits before T2 reads.
  sleep(50)

  t2.createThread(reader)
  t3.createThread(deallocator)
  t4.createThread(reuser)

  t2.joinThread()
  t3.joinThread()
  t4.joinThread()

  echo "PROBE OK — createShared multi-KiB regions are §2.6-safe across thread exits"
  echo "sizes tested: ", sizes

run()
