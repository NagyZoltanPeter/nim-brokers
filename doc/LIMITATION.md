# Platform & Nim Version Limitations

This document collects all known platform / Nim-version / memory-manager /
build-mode constraints for nim-brokers, with the reasoning for each. The
project's main `README.md` references this file; everything user-facing about
"can I use refc on Windows?" or "what's safe under Nim 2.2.4 on macOS?" lives
here.

The single-thread brokers (`EventBroker`, `RequestBroker`,
`MultiRequestBroker`) are **fully supported** on every supported platform
under both `--mm:orc` and `--mm:refc`. Every limitation in this document
applies to the multi-thread (`(mt)`) brokers and the Broker FFI API only —
the layers that share state across threads through chronos'
`ThreadSignalPtr`.

The cross-thread transport is a hand-rolled Vyukov MPSC ring + per-bucket
payload slab + response slot pool, all in `brokers/internal/mt_queue.nim`.
We **no longer use stdlib `Channel[T]`** for broker transport — the
"channel-dispatch" refactor on branch `refactor-channel-dispatch` (commits
`dd1b86c` through `c821bb4`) replaced it end-to-end. Several historical
limitations around `Channel[T]` are now closed; this document keeps them
for two reasons: (a) downstream searches for the old crash signatures
should land on a clear explanation, and (b) the support matrix needs to
stay accurate per Nim version.

---

## 1. Support matrix

Legend: ✅ fully supported · ⚠️ supported with carve-outs (this document
explains which) · ❌ unsupported · — never tested in CI.

### 1.1 Single-thread brokers

| Broker | Linux | macOS | Windows |
|---|:---:|:---:|:---:|
| `EventBroker` | ✅ orc & refc | ✅ orc & refc | ✅ orc & refc |
| `RequestBroker` (sync & async) | ✅ orc & refc | ✅ orc & refc | ✅ orc & refc |
| `MultiRequestBroker` | ✅ orc & refc | ✅ orc & refc | ✅ orc & refc |

Single-thread brokers are pure threadvar code. No shared heap, no
`Channel[T]`, no chronos thread-pool callbacks — none of this document's
issues touch them.

### 1.2 Multi-thread brokers and Broker FFI API

| OS / arch | Nim 2.2.4 + orc | Nim 2.2.4 + refc | Nim 2.2.10 + orc | Nim 2.2.10 + refc | Nim devel + orc | Nim devel + refc |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| **Linux amd64** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **macOS arm64** | ✅ | ✅ native ⚠️ — see §2.7; CBOR ✅ | ✅ | ✅ native ⚠️ — see §2.7; CBOR ✅ | ✅ (untested) | ✅ native ⚠️ likely same; CBOR ✅ |
| **macOS amd64** | ✅ likely same as arm64 | ✅ native ⚠️ likely same as arm64 — see §2.7 | ✅ likely same as arm64 | ✅ native ⚠️ likely same as arm64 — see §2.7 | ✅ likely same as arm64 | ✅ native ⚠️ likely same as arm64 — see §2.7 |
| **Windows amd64** | ✅ | ❌ — see §2.1 | ✅ | ❌ — see §2.1 | ✅ | ❌ — see §2.1 (devel install also unsupported by setup-nim-action) |

Nim versions older than 2.2.0 are **not supported** (see §2.4).

### 1.3 Recommendation

Build any nim-brokers code that uses `(mt)` brokers or the Broker FFI API
with **`--mm:orc`** for the smoothest experience. ORC has **no known
limitations** on any supported platform after the channel-dispatch
refactor.

If you need `--mm:refc`:
- **Linux + refc**: fully supported, no constraints.
- **Windows + refc**: unsupported (see §2.1). No workaround; use ORC.
- **macOS + refc + CBOR-mode FFI**: fully supported.
- **macOS + refc + native-mode FFI**: ⚠️ a chronos+refc Future-allocator
  race under sustained high-frequency complex-response RPC workloads
  remains as a residual fragility (§2.7). Light to moderate workloads
  are fine. If you need sustained ~100 RPC/sec native+refc on macOS,
  switch to CBOR-mode FFI or ORC.

### 1.4 Historical context: limitations closed by the channel-dispatch refactor

These sections are preserved (§2.2 and §2.6) for users searching for
the old crash signatures. They were real bugs on the previous
`Channel[T]`-based transport; the refactor removed `Channel[T]` from
broker code entirely and both classes of failure are gone:

- **§2.2** — `Channel[T].send` storeAux freelist race on macOS+2.2.4+refc+debug
- **§2.6** — channel slot-payload UAF on macOS+ORC after sender thread exit

If you hit either crash signature on a `refactor-channel-dispatch`
build (or anything that descends from it), it is **not** §2.2 or §2.6;
gather a fresh trace and file a new issue.

---

## 2. Per-platform issue analysis

### 2.1 Windows: refc is unsupported for `(mt)` brokers and the Broker FFI API

**Status: ACTIVE.** Unchanged by the channel-dispatch refactor — the
root cause is chronos's Windows wait primitive, not channel transport.

**Scope.** `nimble test` (multi-thread subset), `nimble perftest`,
`nimble testApi`, `nimble testFfiApi`, `nimble testFfiApiCpp`,
`testFfiApiCppAsanRefc`, `testMtEventBrokerAsanRefc`, and
`testMtRequestBrokerAsanRefc` automatically skip every `--mm:refc` variant
on Windows (with a clear log line). ORC is fully supported.

**Root cause.** Both the `(mt)` brokers and the Broker FFI API runtime use
chronos' `ThreadSignalPtr.wait()` to receive cross-thread wakeups. On
Windows the chronos implementation registers a completion callback through
the Win32 [`RegisterWaitForSingleObject`][rwfso] API. Per Microsoft's
documentation, when the waited-on event is signaled the callback is
invoked on a **wait thread owned by the legacy NT thread pool**
(`ntdll!TppWorkerThread`). That thread is created by the OS, not by Nim's
`system/threads.nim`, and the application has no hook to initialize it
before the callback runs.

[rwfso]: https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-registerwaitforsingleobject

Nim's refc runtime is **per-thread local-heap**, not a global
stop-the-world collector — there is no SuspendThread sweep across sibling
threads. The hazard on Windows is therefore not "the GC freed memory the
callback was reading"; it is **uninitialized thread-local runtime state on
the OS-owned wait thread**:

1. Refc relies on TLS for the GC frame stack (`framePtr`, `gch`), the
   thread's local heap pointer, and exception state. These slots are
   populated by `nimGC_setStackBottom` / the per-thread initializer in
   `lib/system/threadlocalstorage.nim`, which only runs on threads
   created via `system/threads.nim` or explicitly attached.
2. A thread-pool wait callback fires on a thread that has never executed
   that init. Any allocation, `GC_ref`, string/seq grow, or even an
   exception-frame push from that callback touches null/garbage TLS.
3. The exact failure mode on the broker transport changed with the
   channel-dispatch refactor, but the hazard class is identical:
   any allocator interaction from the wait-thread callback under refc
   tries to read TLS that was never set up.

ORC sidesteps this because its allocation paths on shared, atomically
ref-counted cells (`nimRawNewObj` / `nimNewObj` in the ORC runtime) do
not depend on per-thread GC-frame TLS for correctness.

**Why the FFI API cannot work around it.** The FFI API runtime spawns
dedicated processing and delivery threads that block on
`ThreadSignalPtr.wait()` by design, and foreign threads (C / C++ /
Python) drive that wait through requests, event registrations and
lifecycle operations. The thread-pool callback path is therefore part of
the steady state, not a corner case. A workaround would require either an
upstream chronos rewrite of the Windows wait primitive, or replacing
`ThreadSignalPtr` in `mt_broker_common.nim` with a Nim-thread-only
blocking-receive design — both substantial efforts that would still leave
foreign-thread attach/detach hazards for refc unresolved. Given that ORC
is Nim's default since 2.0 and refc is legacy, neither workaround is
worthwhile.

**Recommendation.** Build any nim-brokers code that uses `(mt)` brokers or
the Broker FFI API on Windows with `--mm:orc`. Single-thread brokers
remain fully refc-compatible on Windows.

**Minimal repro.** [`test/probe_win_tls_uninit.nim`](../test/probe_win_tls_uninit.nim)
isolates the hazard from chronos: it calls `RegisterWaitForSingleObject`
directly and has the resulting wait-thread callback allocate Nim memory in
a tight loop. Driven via the nimble tasks `probeWinTlsUninitOrc` and
`probeWinTlsUninitRefc` (also exposed through the `memcheck_ci.yml`
workflow_dispatch matrix), the probe is expected to exit 0 under
`--mm:orc` and to crash under `--mm:refc` on Windows; non-Windows hosts
skip with exit 77.

---

### 2.2 macOS + Nim 2.2.4 + `--mm:refc` + debug: stdlib `Channel[T].send` regression

**Status: CLOSED by the channel-dispatch refactor.** The bug was real;
the broker transport no longer uses `Channel[T]` so the trigger no
longer exists. Kept for historical reference and for downstream users
searching for the old crash signature.

**Original root cause.** Nim 2.2.4's stdlib `system/channels_builtin.nim:storeAux`
deep-copies a `Channel[T]` payload by recursively traversing the Nim type
tree and allocating new cells in the cross-thread shared heap. Under
refc, those allocations went through the small-cell freelist in
`system/alloc.nim`. With sustained producer/consumer concurrency on the
same chunk's freelist, refc's bookkeeping in 2.2.4 hit a sequence-of-
operations race:

1. Sender thread reads `c.freeList` (line 939 in `alloc.nim`) — head non-nil.
2. Receiver thread frees a previously-consumed message: pushes a different cell back onto the head.
3. Sender thread evaluates `c.freeList = c.freeList.next` (line 942) — re-reads the head, gets a stale or partially-updated state, and the `.next` dereference reads garbage.
4. SIGSEGV.

The historical crash backtrace was:

```
channels_builtin.nim:storeAux (recursive, ~7 frames)
gc.nim:newObjNoInit
gc_common.nim:prepareDealloc
SIGSEGV  Illegal storage access. (Attempt to read from nil?)
```

**How it was closed.** The `refactor-channel-dispatch` branch (Phase 1-4b,
commits `dd1b86c`..`c821bb4`) replaced `Channel[T]` with `VyukovMpscRing`
+ `PayloadSlab` + `ResponseSlotPool`. Broker code no longer calls into
`system/channels_builtin.nim` at all. Verified post-refactor on Nim
**2.2.4** + refc + debug + macOS arm64 with the gate flag (the historic
mitigation, see §3) **disabled**, so every previously-gated test runs:

- `test_multi_thread_event_broker.nim` → 13/13 OK (incl. `concurrent emitters from multiple threads`)
- `test_multi_thread_request_broker.nim` → 23/23 OK (incl. `concurrent requests from multiple threads`)
- `test_typemappingtestlib.cpp` → 102/102 OK (incl. all `test_foreign_thread_*` and `test_seq_object_event_rapid_fire_no_leak`)

**If you still see the `storeAux → newObjNoInit → SIGSEGV` signature on a
post-refactor build**, you are NOT hitting §2.2 — broker code does not
call `storeAux`. Most likely culprit: application code is calling
`Channel[T].send` directly somewhere else.

---

### 2.3 Nim devel (2.3.x) + `--mm:refc` + release: shared-heap allocator regression

**Status: ASSUMED CLOSED, NEEDS VERIFICATION.** The historical trigger
was the same cross-thread `Channel[T]` allocator path as §2.2 (different
Nim version). The channel-dispatch refactor removed that path, so the
regression is expected to be closed as well — but we have not yet
re-tested on Nim devel since the refactor.

**Historical scope.** After roughly four `createContext` / `shutdown` lifecycle
iterations the next allocation crashed inside the refc small-object
allocator at `system/alloc.nim:942` (`c.freeList = c.freeList.next`
reading address `0x8`). The same code passed on Nim 2.0.16, 2.2.10 and
on devel under refc *debug*; only refc + release + devel crashed.

**Action to confirm closure.** Run the Memcheck CI manual dispatch with
`nim-version: devel` on macOS+arm64 after the channel-dispatch refactor
merges. If the previously-failing scenarios pass, this section can be
deleted. If they still fail, the trigger is something other than
`Channel[T]` and we need a fresh diagnosis.

---

### 2.4 Nim 2.0.x is unsupported

**Status: ACTIVE.** Unchanged by the channel-dispatch refactor — the
2.0.x failure was upstream in refc's foreign-thread allocator path, not
in our channel transport.

**Scope.** Dropped from the CI matrix on 2026-05-04. Refc + foreign-thread
allocator on macOS deterministically SIGSEGVs in `genericSeqAssign` /
`rawAlloc` for `seq[object]` and `array[N,T]` payloads crossing the FFI
boundary. 2.2 fixes that path.

**Recommendation.** Pin `requires "nim >= 2.2.0"` (or stricter) in
downstream projects.

---

### 2.5 `--nimMainPrefix` is not used on Windows

**Status: ACTIVE.** Build-system constraint unrelated to channel transport.

**Scope.** All `nimble` tasks omit `--nimMainPrefix:<libname>` on Windows.
This is correct behavior, not a workaround.

**Root cause.** `--nimMainPrefix` exists to avoid `NimMain` symbol
collisions when multiple Nim `.so` files are loaded in the same POSIX
process. On Linux/macOS, `dlopen` with `RTLD_GLOBAL` merges all
shared-object exports into a single flat namespace, so two Nim libraries
that both define `NimMain` clash. The prefix renames them
(e.g. `fooNimMain`, `barNimMain`) to prevent that.

On Windows the PE loader works differently: every import is resolved as
`DLL!Symbol`, so `foo.dll!NimMain` and `bar.dll!NimMain` are entirely
separate entries that never interfere with each other. Any number of Nim
DLLs can be loaded into the same process without a prefix.

Attempting to use `--nimMainPrefix` on Windows also triggers a Nim
codegen bug: the C generator forward-declares the prefixed `NimMain`
without `__declspec(dllexport)` and then defines it with `N_LIB_EXPORT`,
which both clang and GCC reject as a hard error
(`err_attribute_dll_redeclaration`).

---

### 2.6 macOS + `--mm:orc`: `Channel[T]` slot-payload UAF after sender thread exit

**Status: CLOSED by the channel-dispatch refactor.** Kept for historical
reference and for downstream users searching for the old crash signature.

**Original root cause.** On macOS, dyld backs each module's TLVs with a
per-thread `calloc`'d block, and pthread's TSD cleanup `free()`s that
block in one shot at thread exit. Nim's allocator stored `MemRegion`
(the per-thread chunk arena) as a `{.threadvar.}` inside that block.
`Channel[T].send` deep-copied its payload through `allocShared` paths
whose chunk metadata ended up referenced by the channel's slot ring.
Once the sender exited and dyld freed its TLV block, the slot-ring's
free-list links into that block dangled. Whichever code path next
iterated the ring tripped the fault.

The historical ASAN signature was:

```
# Path A — next emit on a reused channel.
Channel.send → rawSend → deallocShared → addToSharedFreeList   (UAF)

# Path B — explicit broker teardown that closes the channel.
Channel.close → deinitRawChannel → rawDealloc                   (UAF)
```

**How it was closed.** Replacing `Channel[T]` with `VyukovMpscRing` +
`PayloadSlab` removed the slot-ring entirely. Slab cells are
pre-allocated by the bucket-owning thread (a persistent thread per
Invariant I2) and used cross-thread only via atomic claim/release —
sender threads never call the Nim allocator on the hot path.

**Verified post-refactor** on macOS arm64 + Nim 2.2.10 + ORC + ASAN
using `test/probe_mt_uaf.nim`, all seven probe modes including the
ones that previously failed:

- `baseline` ✅
- `relisten` ✅ (previously failed — channel reuse + transient threads)
- `gcCollect`, `gcCollectAll` ✅
- `relistenKeepAlive`, `keepAlive` ✅
- `shutdownEach` ✅ (uses the new `shutdown()` API)

**If you still see `addToSharedFreeList` UAF on a post-refactor build**,
you are NOT hitting §2.6 — broker code no longer uses
`system/channels_builtin.nim` or `system/alloc.nim`'s shared free-list
under the channel hot path. Most likely culprit: application code is
using `Channel[T]` directly.

---

### 2.7 macOS + native-mode FFI + `--mm:refc`: chronos Future allocator under high-frequency RPC

**Status: ACTIVE.** Identified after the channel-dispatch refactor.
Different trigger and different location than §2.2 or §2.6. Lives in
chronos's `Future` allocator, outside our code surface.

**Scope.** Affects only the combination **macOS + native-mode FFI +
`--mm:refc`** under workloads that issue cross-thread requests at high
frequency from a foreign caller thread. CBOR-mode FFI is unaffected on
the same platform / MM combination. ORC is unaffected. Linux+refc is
unaffected. Windows+refc is unsupported for unrelated reasons (§2.1).

**Reproducer.** [`examples/torpedo/cpp_example`](../examples/torpedo/cpp_example).
Build with `nim c -d:BrokerFfiApiNative --threads:on --app:lib --mm:refc`
plus the CMake project under `examples/torpedo`, run with `--fast`.
Crashes within a few seconds (debug) or after the duel completes (release).
The CBOR-mode build of the **same C++ source** against the same broker
types works cleanly under refc.

**Crash signature.**

```
sendAndAwait<RequestName>            (broker request issuer)
  → chronos asyncfutures.nim:80 newFutureImpl
  → system/gc.nim:496        newObj
  → system/alloc.nim:942     rawAlloc      ← c.freeList = c.freeList.next
  → SIGSEGV (read from nil)
```

The `alloc.nim:942` line is the same hot spot as §2.2 and §2.3, but the
allocator caller is **chronos's `newFutureImpl`**, not `Channel.storeAux`
or our marshaled-bytes paths. Each cross-thread broker request allocates
a fresh `Future[Result[T, string]]` on the foreign caller thread to await
the response. Under refc's per-thread local-heap, sustained churn on this
foreign thread's heap allocator hits the same stale-freelist-link race
that historically affected `Channel[T].send`.

**Why the channel-dispatch refactor did not close this.** The refactor
moved every broker-owned allocation off the hot path (pre-allocated slab
cells, atomic claim/release). But the `await responseFut` pattern is
still chronos-owned: every request creates and awaits a fresh `Future`.
Eliminating that allocation would require either (a) bypassing chronos's
async machinery on the request side, (b) pooling Future objects across
requests (chronos doesn't expose this), or (c) an upstream chronos fix to
its allocator interactions under refc.

**Why it doesn't bite CBOR-mode.** CBOR-mode requests go through
`<lib>_call(...)` which still creates a Future internally via
`waitFor dispatch(...)`, so the structural pattern is similar. The
observed difference is empirical — CBOR runs the same torpedo workload
cleanly on refc. We suspect chronos's CBOR-dispatch code path has a
slightly different allocator footprint (one fewer Future per call, or a
different allocation-size distribution) that doesn't widen the refc race
window. This is a hypothesis we have not fully verified.

**Why the failure differs between debug and release.** Same reasoning as
§2.2 historically had: release-mode optimizations shift the timing of
allocations and the race window shifts. Under torpedo specifically, debug
crashes during the game loop; release runs the duel to completion and
then crashes during the C++ wrapper's shutdown sequence (which itself
issues a request).

**Workloads that are safe under macOS+native+refc.**
- Light cross-thread RPC load (a handful per second).
- Long-pause workloads with seconds between requests.
- Anything that uses **CBOR-mode FFI** instead of native.

**Workloads that trip §2.7.**
- Sustained > ~50 RPC/sec on a single foreign thread.
- Tight interactive game-loop style RPC pacing (torpedo's `--fast`).
- Multiple foreign caller threads simultaneously issuing RPCs.

**Recommendation.**
1. If you can use **`--mm:orc`**, do — there is no §2.7 on ORC.
2. If you must use `--mm:refc` on macOS, choose **CBOR-mode FFI**
   (`-d:BrokerFfiApiCBOR`) — there is no §2.7 in CBOR-mode.
3. If you must use native-mode FFI + refc on macOS, throttle your
   cross-thread RPC frequency to well below the race window. Empirically,
   workloads at < ~20 RPC/sec are fine; > 100 RPC/sec on a single foreign
   thread reliably triggers §2.7.

**Upstream issue.** Filing a Nim/chronos issue with the torpedo
reproducer is on the follow-up list. The fix is at one of two layers:
chronos's Future allocator path, or Nim's refc cross-thread allocator
race that's been latent since at least 2.2.4.

---

## 3. Test gating (historical — being retired)

The `brokerTestsSkipFragileRefcBursts` predicate in `brokers.nimble`
(plus the matching `-d:brokerTestsSkipFragileRefcBursts` Nim flag, the
`BROKER_TESTS_SKIP_FRAGILE_REFC_BURSTS` CMake / environment variable,
and the Python `@unittest.skipIf` decorators) was introduced as the
§2.2 carve-out: when running on macOS + Nim 2.2.4 + refc + debug, it
disabled the specific stress tests that exercised `Channel[T].send`
under sustained load.

**Status: scheduled for removal.** Since §2.2 is closed by the
channel-dispatch refactor, the gate has no failures to protect against.
The mechanism is being retired in Phase 5 cleanup of the refactor
branch:

- `isNim224MacosRefcDebug` predicate in `brokers.nimble` → removed.
- `-d:brokerTestsSkipFragileRefcBursts` flag → no longer emitted.
- `BROKER_TESTS_SKIP_FRAGILE_REFC_BURSTS` CMake option → removed.
- C++ `#ifndef` gates in `test/typemappingtestlib/test_typemappingtestlib.cpp` → removed.
- Python `@unittest.skipIf` decorators in `test/typemappingtestlib/test_typemappingtestlib.py` → removed.
- Rust env-var check in `test/typemappingtestlib/rust_test/src/main.rs` → removed.
- `when not defined(brokerTestsSkipFragileRefcBursts):` gates in
  `test/test_multi_thread_event_broker.nim` and
  `test/test_multi_thread_request_broker.nim` → removed.

**What is NOT removed.** The `skipRefcOnWindows` predicate stays — it
protects §2.1 which is unchanged by the refactor.

---

## 4. Quick reference: reliability profile

After the channel-dispatch refactor:

| Pattern | Reliability |
|---|---|
| Single-thread brokers, any payload | **Guaranteed** |
| `(mt)` brokers, any payload, ORC, any platform | **Guaranteed** |
| `(mt)` brokers, any payload, refc, Linux | **Guaranteed** |
| `(mt)` brokers, any payload, refc, macOS, CBOR-mode FFI | **Guaranteed** |
| `(mt)` brokers, any payload, refc, macOS, native-mode FFI, light load | **Reliable** |
| `(mt)` brokers, any payload, refc, macOS, native-mode FFI, > 50 RPC/sec | **Best-effort** — §2.7 may trigger |
| `(mt)` brokers, refc, Windows | **Unsupported** — §2.1 |
| FFI API (foreign caller threads) | Same as `(mt)` brokers above |

For broker payload shape, no payload-dependent fragility remains:
the marshaler in `brokers/internal/mt_codec.nim` handles scalars,
strings, `seq[U]`, fixed `array[N, U]`, enums, distinct types of POD,
and recursive object types via `fieldPairs`. `ref T` payloads are
rejected at macro time. Complex payloads (`seq[Obj{string, …}]`) are
fully supported.
