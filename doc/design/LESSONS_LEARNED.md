# Lessons Learned — Closed Issues with Reusable Insights

This document is the long-form record of bugs, hazards, and design
mistakes the nim-brokers codebase has hit and closed. Each chapter is
self-contained: original symptom, root cause, fix, and the lesson
worth remembering when the next similar issue surfaces.

These are **not active limitations** — every chapter here has been
resolved. The companion [`../LIMITATION.md`](../LIMITATION.md) is the
short, current list of constraints that still apply.

If you landed here from a stack-trace search (`storeAux →
newObjNoInit → SIGSEGV`, `Channel.send → rawSend →
addToSharedFreeList`, `chronos newFutureImpl → rawAlloc:942`,
`ensureBrokerDispatchStarted` ZCT leak, …), the matching chapter
explains what happened, what changed, and how to recognise an
authentic regression vs. a similar-looking-but-different bug
elsewhere.

---

## 1. Stdlib `Channel[T]` allocator races

**Status: closed by the channel-dispatch refactor** (branch
`refactor-channel-dispatch`, commits `dd1b86c` → `c821bb4`). Broker
code no longer uses `Channel[T]` at all; the transport is a
hand-rolled Vyukov MPSC ring + per-bucket payload slab + response
slot pool in `brokers/internal/mt_queue.nim`.

Three closely-related bugs sat behind this category. They are
preserved in detail because the *pattern* — stdlib Channel deep-copies
payloads through the shared allocator, and any sustained cross-thread
allocator pressure widens the race window for latent refc allocator
bugs — is durable: it can resurface in any code path that has cross-
thread Nim allocations on the hot path.

### 1.1 macOS + Nim 2.2.4 + `--mm:refc` + debug: `storeAux` freelist race

**Original symptom.**

```
channels_builtin.nim:storeAux (recursive, ~7 frames)
gc.nim:newObjNoInit
gc_common.nim:prepareDealloc
SIGSEGV  Illegal storage access. (Attempt to read from nil?)
```

**Root cause.** Nim 2.2.4's stdlib
`system/channels_builtin.nim:storeAux` deep-copies a `Channel[T]`
payload by recursively traversing the Nim type tree and allocating
new cells in the cross-thread shared heap. Under refc those went
through the small-cell freelist in `system/alloc.nim`. With sustained
producer/consumer concurrency on the same chunk's freelist, refc's
bookkeeping hit a sequence-of-operations race:

1. Sender reads `c.freeList` (line 939 in `alloc.nim`) — head non-nil.
2. Receiver frees a previously-consumed message: pushes a different
   cell back onto the head.
3. Sender evaluates `c.freeList = c.freeList.next` (line 942) —
   re-reads the head, gets a partially-updated state, and the `.next`
   dereference reads garbage.
4. SIGSEGV.

**Fix.** Replaced `Channel[T]` with `VyukovMpscRing` + `PayloadSlab` +
`ResponseSlotPool`. Broker code no longer calls into
`system/channels_builtin.nim`. Slab cells are pre-allocated by the
bucket-owning thread and used cross-thread only via atomic
claim/release — sender threads never touch the Nim allocator on the
hot path.

**Verified post-refactor** on Nim 2.2.4 + refc + debug + macOS arm64
with the original mitigation flag (`brokerTestsSkipFragileRefcBursts`,
since retired) disabled:

- `test_multi_thread_event_broker.nim` → 13/13 OK
- `test_multi_thread_request_broker.nim` → 23/23 OK
- C++ `test_typemappingtestlib` → 130/130 OK

### 1.2 macOS + `--mm:orc`: slot-payload UAF after sender thread exit

**Original ASAN signature.**

```
# Path A — next emit on a reused channel
Channel.send → rawSend → deallocShared → addToSharedFreeList   (UAF)

# Path B — explicit broker teardown that closes the channel
Channel.close → deinitRawChannel → rawDealloc                   (UAF)
```

**Root cause.** On macOS, dyld backs each module's TLVs with a
per-thread `calloc`'d block, and pthread's TSD cleanup `free()`s that
block at thread exit. Nim's allocator stored `MemRegion` (the
per-thread chunk arena) as a `{.threadvar.}` inside that block.
`Channel[T].send` deep-copied its payload through `allocShared` paths
whose chunk metadata ended up referenced by the channel's slot ring.
Once the sender exited and dyld freed its TLV block, the slot-ring's
free-list links into that block dangled. Whichever code path next
iterated the ring tripped the fault.

**Fix.** Same as §1.1 — eliminating `Channel[T]` removed the slot
ring entirely.

**Verified post-refactor** on macOS arm64 + Nim 2.2.10 + ORC + ASAN
using `test/probe_mt_uaf.nim`, all seven probe modes:

- `baseline` ✅
- `relisten` ✅ *(previously failed — channel reuse + transient threads)*
- `gcCollect`, `gcCollectAll` ✅
- `relistenKeepAlive`, `keepAlive` ✅
- `shutdownEach` ✅

### 1.3 Nim devel + `--mm:refc` + release: shared-heap allocator regression

**Original symptom.** After roughly four `createContext` / `shutdown`
lifecycle iterations the next allocation crashed inside the refc
small-object allocator at `system/alloc.nim:942` (`c.freeList =
c.freeList.next` reading address `0x8`). Same code passed on Nim
2.0.16, 2.2.10, and on devel under refc *debug*; only refc + release
+ devel crashed.

**Closed by the same refactor** — the trigger was the same cross-
thread `Channel[T]` allocator path as §1.1, just on a different Nim
version. Post-refactor CI on Nim devel + refc is green on all
platforms in the matrix.

### Lessons (across §1)

- **stdlib `Channel[T]` deep-copies payloads through the shared
  allocator.** Cross-thread allocator pressure under refc is a
  freelist-race waiting to happen. If your design has a hot-path
  cross-thread message that goes through `Channel.send`, you're
  exposed.
- **The fix template:** replace cross-thread allocator hops with
  pre-allocated cell pools + atomic claim/release. The bucket-owning
  thread allocates once; senders only touch atomics + memcpy. No Nim
  allocator on the hot path means no allocator races.
- **If you still see `storeAux → newObjNoInit → SIGSEGV` or
  `addToSharedFreeList` UAF on a post-refactor build, you are NOT
  hitting §1.1/§1.2** — broker code doesn't go through those paths
  anymore. Most likely culprit: application code is calling
  `Channel[T].send` directly somewhere else.

---

## 2. Foreign-thread allocator under chronos

**Status: closed by PR #13** (`blockingRequest` switch) **and made
moot by the Round-2 native ABI retirement**.

### 2.1 macOS + native FFI + `--mm:refc`: chronos Future allocator under high-frequency RPC

**Original crash signature.**

```
sendAndAwait<RequestName>            (broker request issuer)
  → chronos asyncfutures.nim:80 newFutureImpl
  → system/gc.nim:496        newObj
  → system/alloc.nim:942     rawAlloc      ← c.freeList = c.freeList.next
  → SIGSEGV (read from nil)
```

The `alloc.nim:942` line is the same hot spot as §1.1 and §1.3, but
the allocator caller is **chronos's `newFutureImpl`**, not
`Channel.storeAux` or our marshaled-bytes paths. Each cross-thread
broker request allocated a fresh `Future[Result[T, string]]` on the
foreign caller thread to await the response. Sustained churn on this
foreign thread's heap allocator under refc's per-thread local-heap
hit the same stale-freelist-link race.

**Why the channel-dispatch refactor (§1) did not close this.** The
refactor moved every *broker-owned* allocation off the hot path
(pre-allocated slab cells, atomic claim/release). But the `await
responseFut` pattern was still chronos-owned: every request created
and awaited a fresh `Future`. Eliminating that allocation needed a
different fix.

**Root cause (PR #13 analysis).** `ensureBrokerDispatchStarted()`
lazily spawns a per-thread `brokerDispatchLoop` coroutine on first
use. That design is correct for threads that own a chronos event loop
for their entire lifetime (processing/delivery threads spawned by
`createContext`, torn down via `joinThread`). It is **wrong** for an
FFI caller's thread which:

- re-enters Nim per FFI call
- lives for the entire host process
- has no joiner that can tear down its chronos state

The persistent loop's suspended `await signal.wait()` Future, the
threadvar pollers seq, and chronos's pending callback list accumulated
across calls. Under refc this dragged the thread's ZCT and freelist
state through a slow corruption until a `collectZCT` walk hit a cell
with `typ == nil` and SEGV'd (typically around context #51 in the
parity test).

**Fix (PR #13).** Two FFI entry points (`<lib>_shutdown`,
`<lib>_<request>` zero-arg) replaced `waitFor request(...)` with
`blockingRequest(...)`. `blockingRequest` is the busy-poll variant:
claim a `ResponseSlot`, byte-marshal the request into a `PayloadSlab`
cell, fire the provider's signal, busy-poll `ResponseSlot.readyState`
via `Moment.now()` / `sleep(1)`, then unmarshal the response bytes
back on the caller's thread. Zero chronos Future allocations on the
caller's thread; zero persistent state in chronos pending lists.

**Hot-path perf consequences.**

| | Before (`waitFor request()`) | After (`blockingRequest`) |
|---|---|---|
| Per-call Nim allocations on caller thread | 1 Future + 1 closure for poller + ZCT churn | **None** — slab cell + response slot pre-allocated |
| Wait mechanism | Parked on eventfd/kqueue (0 CPU) | Busy-poll: check slot, `sleep(1ms)`, repeat |
| Wake latency | ~50–200 µs (signal + scheduler) | 0 if Ready on first check, else ≤1 ms |
| Memory churn | refc allocations → GC pressure | Zero |

For typical FFI workloads where requests complete in well under 1 ms,
the busy-poll never enters `sleep(1)` — it sees `Ready` on the first
or second check. Expected per-call latency is slightly faster (no
chronos future-allocation overhead, no `signal.wait` setup).

**Made moot by Round-2.** The native FFI codegen path that contained
these entry points was retired. CBOR-mode FFI is the only path now,
and its `<lib>_call` already used a pure-cond response wait by
construction.

### Lessons (across §2)

- **FFI caller threads don't own a chronos event loop.** Never run
  `waitFor` from them. Use a raw cond-wait (`blockingRequest`,
  `std::condition_variable`, etc.) or a direct busy-poll.
- **chronos Future allocation on a per-call basis is per-thread refc
  pressure.** It drags ZCT / freelist state through slow corruption.
- **Lazy thread-init patterns** (e.g.
  `ensureBrokerDispatchStarted()` on first call) are correct for
  threads with a joiner, **wrong** for re-entered threads with no
  teardown. A persistent coroutine on such a thread accumulates
  state across calls forever.

---

## 3. Provider-thread teardown ordering

**Status: closed by PR #13.** Internal correctness fix; not
user-visible at the API surface.

### 3.1 Async-spawned deferred ring/slab/pool free

**Original symptom.** The ring/slab/pool free path used
`asyncSpawn deferredFreeReqRing(ring, slab, pool)` from inside a
broker poll fn when it observed `ring.isClosed()`. The async proc
did `await sleepAsync(50ms)` (a grace window for cross-thread senders
that captured pointers before the bucket was removed under lock) and
then freed the three buffers. Two problems exposed by Linux refc +
ASAN:

1. The `sleepAsync(50ms)` Future was allocated **inside teardown** —
   during `cleanupAllRequestsIdent(ctx)` followed by `drainAsyncOps`,
   the processing thread's gch was already churning through 17
   brokers' worth of `clearProvider` cleanup. One of the resulting
   Future allocations would SEGV in `rawAlloc` (offset 0x4 / 0x8 /
   0x28 in the allocator's bookkeeping).
2. `drainAsyncOps` only polls chronos for 1 ms; the 50 ms `sleepAsync`
   never fired before the thread exited. The async free was either
   orphaned (silent shared-memory leak) or racing thread teardown.

**Fix.** Replaced with a synchronous deferred-free registry in
`brokers/internal/mt_broker_common.nim`:

- `enqueuePendingRingFree(ring, slab, pool)` (thread-local seq).
- `drainPendingRingFrees()` — single `sleep(50)` grace window per
  thread, then direct calls to the existing
  `freeVyukovMpscRing` / `deinitPayloadSlab` + `deallocShared` /
  `deinitResponseSlotPool` + `deallocShared` helpers.

Called from both provider thread procs in `api_library.nim` after
`drainAsyncOps` (processing thread) and after
`shutdownAllProcessLoopsIdent(ctx)` (delivery thread).

### 3.2 `dropAllListeners` before draining in-flight invocations

**Original symptom.** Hard SEGV with `pc == bad address` inside
chronos's `internalContinue`.

**Root cause.** The old teardown order ran `cleanupAllIdent(ctx)`
(which calls `dropAllListeners`, decrementing listener-closure
refcounts to zero) **before** `waitFor shutdownAllProcessLoops(ctx)`
(which awaits the in-flight listener-invocation futures stored in
`tvListenerFuts`). Under refc, this created a window where chronos
resumed a future whose continuation pointed at freed listener-closure
code.

**Fix.** Run `clearProvider → drain processLoops + listener futures →
drop listeners` in that order, so no in-flight invocation references
can outlive the listener table they call into.

### Lessons (across §3)

- **Don't `asyncSpawn` inside a teardown path.** `drainAsyncOps` only
  polls for 1 ms; spawned futures whose body sleeps longer than that
  may never fire. Use synchronous deferred-free queues instead.
- **The correct teardown order is "providers stop → in-flight drains
  → listeners drop"** (not "listeners drop → drain", which leaves
  dangling continuations).

---

## 4. Windows + chronos thread-pool + refc — a feared hazard, not an actual one

**Status: hypothesis no longer reproduces in broker code; raw hazard
still exists** in `test/probe_win_tls_uninit.nim` as a structural
witness.

**The historical concern.** Both the `(mt)` brokers and the Broker
FFI API runtime use chronos's `ThreadSignalPtr.wait()` to receive
cross-thread wakeups. On Windows the chronos implementation registers
a completion callback through Win32
[`RegisterWaitForSingleObject`][rwfso]. Per Microsoft's
documentation, when the waited-on event is signaled the callback is
invoked on a **wait thread owned by the legacy NT thread pool**
(`ntdll!TppWorkerThread`). That thread is created by the OS, not by
Nim's `system/threads.nim`, and the application has no hook to
initialize it before the callback runs.

[rwfso]: https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-registerwaitforsingleobject

**The hazard.** Refc relies on TLS for the GC frame stack
(`framePtr`, `gch`), the thread's local heap pointer, and exception
state. These slots are populated by `nimGC_setStackBottom` / the
per-thread initializer in `lib/system/threadlocalstorage.nim`, which
only runs on threads created via `system/threads.nim` or explicitly
attached. A thread-pool wait callback fires on a thread that has
never executed that init. Any allocation, `GC_ref`, string/seq grow,
or even an exception-frame push from that callback touches null /
garbage TLS.

ORC sidesteps this because its allocation paths on shared, atomically
ref-counted cells (`nimRawNewObj` / `nimNewObj` in the ORC runtime)
do not depend on per-thread GC-frame TLS for correctness.

**What the empirical record says.**

The raw hazard **does** still reproduce in
`test/probe_win_tls_uninit.nim` (run via `nimble
probeWinTlsUninitRefc` on Windows — see verdict below). The probe
calls `RegisterWaitForSingleObject` directly and has the wait-thread
callback allocate Nim memory in a tight loop. Under refc on Windows
that's an immediate crash; under ORC it's clean.

**But the broker code paths don't trip it.** With the Windows-refc
skip mechanism (`skipRefcOnWindows` + `memoryManagerMatrix`)
disabled, the full CI matrix is green on Windows + refc across Nim
2.2.4 / 2.2.10 / devel. The chronos `ThreadSignalPtr` callback in the
broker code path apparently doesn't allocate Nim heap memory from the
wait-thread callback — or whatever allocation does happen lands on a
path that's safe under refc's per-thread TLS model.

The exact mechanism is unverified, but the empirical evidence is
unambiguous: production usage with `(mt)` brokers + FFI API + refc +
Windows works.

**Empirical verdict (PR #17, branch `retire-native-cbor-optimize`).**

Workflow_dispatch runs of `nimble probeWinTlsUninit{Orc,Refc}` on
`windows-latest` × Nim `{2.2.4, 2.2.10}` confirmed:

| Build | Probe result | Interpretation |
|---|---|---|
| Windows + Nim 2.2.4 + ORC | probe exits 0 | ORC is clean (expected) |
| Windows + Nim 2.2.10 + ORC | probe exits 0 | ORC is clean (expected) |
| Windows + Nim 2.2.4 + refc | probe crashes | `probeWinTlsUninit/refc: hypothesis reproduced (probe crashed as expected)` |
| Windows + Nim 2.2.10 + refc | probe crashes | same — `hypothesis reproduced` |

In parallel, the same PR's full CI matrix (run `26235856782` on
commit `a10ccff` — the experiment that *disabled* `skipRefcOnWindows`)
is green on Windows + refc + Nim 2.2.4 + Nim 2.2.10 across `nimble
test`, `testApi`, all four `runTypeMapTestLib*`, and all four
`runFfiExample*` tasks.

The probe data + the broker-code green CI is the joint evidence
behind the §4 conclusion: **the raw hazard is real, broker code
doesn't trip it**.

### Lessons

- **Theoretical hazards earn their place in `LIMITATION.md` only
  after they reproduce in CI.** The original §2.1 was a worst-case
  reading of Microsoft documentation that turned out to be wider than
  what the code actually exercised.
- **Keep the minimal repro test even when the high-level fear doesn't
  materialise.** `probe_win_tls_uninit` proves the underlying
  mechanism exists; the gap between "mechanism exists" and "broker
  code triggers it" is informative.
- **Empirical CI evidence beats hypothetical analysis.** This
  document used to spend ~70 lines explaining why Windows refc was
  unsupported. The actual support contract turned out to be one
  green CI matrix on every PR.

---

## 5. Windows + Nim 2.2.4 + `--mm:orc` + debug: `testApi` Python harness mid-suite crash

**Status: closed empirically.** Last observed pre-Round-2; not
reproduced on `a10ccff` or later commits.

**Original symptom.** Only Windows amd64 + Nim 2.2.4 + `--mm:orc` +
debug, only the `nimble testFfiApi` task (Python ctypes parity test
discovered via `unittest`). Surfaced as the test process exiting
mid-suite around `test_const_array` with no Python-side stack trace,
only nimble's "unhandled exception: FAILED" wrapper around the
Python harness exit.

```
test_const_array (test_typemappingtestlib.TestArrays.test_const_array) ...
Error: unhandled exception:
  FAILED: "...\python3.exe" -m unittest discover -s test/typemappingtestlib
                            -p "test_*.py" -v [OSError]
```

Same DLL ran cleanly under the same Python on Nim 2.2.10 and devel.
Other Windows variants (C++ wrapper, etc.) on the same Nim 2.2.4
ALSO passed — only the Python harness was affected. Most-likely
root cause was a Windows-specific quirk in Nim 2.2.4's TLS / DLL
teardown ordering that interacted with Python's ctypes-driven DLL
unload.

**How it closed.** Either the Round-2 work (CBOR-only retirement, the
courier rework, the channel-dispatch refactor) shifted the teardown
sequence enough to sidestep the trigger, or `setup-nim-action`
silently updated 2.2.4 to a patched build. Empirically: the same
test name on the same OS + Nim version is green in this PR's CI.

### Lessons

- **Windows + Nim 2.2.4 + ORC + debug + Python ctypes** was a
  sensitive combination. If a similar mid-test process-exit shows up
  in the future on this exact axis, look at DLL teardown ordering
  first.
- **"Worked one day, not the next"** without a clear-cut code change
  often means the toolchain shifted — pin the Nim version when
  diagnosing.

---

## 6. Test-gating mechanism — `brokerTestsSkipFragileRefcBursts`

**Status: retired.**

The `brokerTestsSkipFragileRefcBursts` predicate in `brokers.nimble`
(plus the matching `-d:brokerTestsSkipFragileRefcBursts` Nim flag, the
`BROKER_TESTS_SKIP_FRAGILE_REFC_BURSTS` CMake / environment variable,
and the Python `@unittest.skipIf` decorators) was introduced as the
§1.1 carve-out: when running on macOS + Nim 2.2.4 + refc + debug, it
disabled the specific stress tests that exercised `Channel[T].send`
under sustained load.

Once §1.1 closed via the channel-dispatch refactor, the gate had no
failures to protect against and was removed in Phase 5 of that
refactor:

- `isNim224MacosRefcDebug` predicate in `brokers.nimble` → removed
- `-d:brokerTestsSkipFragileRefcBursts` flag → no longer emitted
- `BROKER_TESTS_SKIP_FRAGILE_REFC_BURSTS` CMake option → removed
- C++ `#ifndef` gates → removed
- Python `@unittest.skipIf` decorators → removed
- Rust env-var check → removed
- `when not defined(brokerTestsSkipFragileRefcBursts):` gates in the
  multi-thread broker tests → removed

A similar `skipRefcOnWindows` predicate also existed for §4 (Windows
+ refc). That was deferred to a separate experiment (commit
`a10ccff` on this PR) which proved Windows + refc was actually green
across the matrix; the skip body is now commented-out, ready to
restore if a regression appears.

### Lessons

- **Test gates carry technical debt.** When the underlying issue
  closes, retire the gate explicitly — don't let it linger
  indefinitely "just in case".
- **The retirement was easy because the gate was centralised.** A
  single predicate function in `brokers.nimble` controlled six
  surfaces (Nim, CMake, Python, Rust, C++, env var). Future gates
  should follow this same pattern: one predicate, many call sites,
  one removal commit.
