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
`ThreadSignalPtr` and Nim's stdlib `Channel[T]`.

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
| **macOS arm64** | ⚠️ transient-thread carve-out — see §2.6 | ⚠️ debug only — see §2.2 | ⚠️ transient-thread carve-out — see §2.6 | ✅ | ⚠️ likely same as 2.2.10 — see §2.6 | ⚠️ release only — see §2.3 |
| **macOS amd64** | ⚠️ likely same as arm64 — see §2.6 | ⚠️ likely same as arm64 — see §2.2 | ⚠️ likely same as arm64 — see §2.6 | ✅ | ⚠️ likely same as arm64 — see §2.6 | likely ⚠️ same as arm64 — see §2.3 |
| **Windows amd64** | ✅ | ❌ — see §2.1 | ✅ | ❌ — see §2.1 | ✅ | ❌ — see §2.1 (devel install also unsupported by setup-nim-action) |

Nim versions older than 2.2.0 are **not supported** (see §2.4).

### 1.3 Recommendation

Build any nim-brokers code that uses `(mt)` brokers or the Broker FFI API
with **`--mm:orc`** and **Nim ≥ 2.2.10** for the smoothest experience.
The refc carve-outs are real but narrow. ORC has one carve-out that
applies on **macOS** (any arch, any Nim version we tested): threads that
send to or receive from a broker channel must not exit before broker
teardown — see §2.6. On Linux and Windows, ORC has no known limitations.

If your application uses persistent worker threads (thread pools, an
event-loop thread, FFI callers that stay alive across the library's
lifetime), the §2.6 carve-out does not apply to you. It only matters for
code that creates short-lived threads which `joinThread` while the broker
they emitted on is still in use.

---

## 2. Per-platform issue analysis

### 2.1 Windows: refc is unsupported for `(mt)` brokers and the Broker FFI API

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
3. Even when the callback only signals a `Channel[T]`, `Channel.send`
   under refc dispatches through `system/channels_builtin.nim`'s
   `storeAux` → `rawNewObj` on the *shared* heap, whose chunk-cache and
   freelist bookkeeping in `system/alloc.nim` still consult per-thread
   TLS for the owning allocator. The result is heap corruption with the
   same `c.freeList = c.freeList.next` crash signature documented in
   §2.2 — but reached through TLS-not-initialized rather than through a
   freelist race.

ORC sidesteps this because its allocation path on shared, atomically
ref-counted cells (`nimRawNewObj` / `nimNewObj` in the ORC runtime) does
not depend on the same per-thread GC-frame TLS for correctness:
ref-count adjustment is `atomicInc`/`atomicDec` on the cell header, and
the cycle collector is in-thread on Nim-owned threads only. A foreign
wait-thread callback that allocates a shared cell under ORC therefore
reaches a self-contained code path; the same callback under refc reaches
TLS-dependent allocator state that was never set up.

**Why `(mt)` brokers are also affected on Windows.** Earlier project notes
said `(mt)` refc tests pass on Windows because their workloads tend to
keep the broker signal pre-fired by the time the dispatcher polls,
sometimes short-circuiting the `RegisterWaitForSingleObject` slow path.
That is true for the existing test suite under light load, but it is a
property of the test patterns — not a guarantee. Sustained idle periods,
foreign-thread attaches, and stress workloads such as ASAN's
`test_foreign_thread_concurrent_lifecycle` all reach the slow path,
hand control to a non-Nim wait thread, and expose the same TLS-uninit
hazard deterministically.

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

---

### 2.2 macOS + Nim 2.2.4 + `--mm:refc` + debug: stdlib `Channel[T].send` regression

**Scope.** Tracked, narrow scope. CI's nimble tasks (`test`, `perftest`,
`testApi`, `testFfiApi`, `testFfiApiCpp`) keep running on this combo, but
the suspect *individual tests* are compile-time excluded via the
mechanism described in §3 below. Linux + 2.2.4 + refc debug is unaffected,
and refc release on macOS + 2.2.4 is unaffected — only this exact
four-way intersection trips.

**Root cause.** Nim 2.2.4's stdlib `system/channels_builtin.nim:storeAux`
deep-copies a `Channel[T]` payload by recursively traversing the Nim type
tree and allocating new cells in the cross-thread shared heap. Under
refc, those allocations go through the small-cell freelist in
`system/alloc.nim`. With sustained producer/consumer concurrency on the
same chunk's freelist, refc's bookkeeping in 2.2.4 hits a sequence-of-
operations race:

1. Sender thread reads `c.freeList` (line 939 in `alloc.nim`) — the head pointer is non-nil.
2. Receiver thread frees a previously-consumed message: pushes a different cell back onto the head.
3. Sender thread evaluates `c.freeList = c.freeList.next` (line 942) — re-reads the head, gets a stale or partially-updated state, and the `.next` dereference reads garbage.
4. SIGSEGV.

The crash backtrace is unmistakable:

```
channels_builtin.nim:storeAux (recursive, ~7 frames)
gc.nim:newObjNoInit
gc_common.nim:prepareDealloc
SIGSEGV  Illegal storage access. (Attempt to read from nil?)
```

**Why complex payloads matter.** Allocations per `Channel[T].send` scale
with payload shape: a POD scalar = 0; a `seq[int32]` = 1; a `seq[Tag]`
where each `Tag` has 2 strings = `1 + 2·N`. The CI test
`test_seq_object_event_rapid_fire_no_leak` fires 100 emits × 10 tags =
~2100 allocations through the shared heap in a tight loop, which is
exactly the load profile that exposes the bookkeeping race. Lighter
workloads — small payloads, normal pacing — never reach the bad
freelist state.

**Why debug-only.** Release-mode optimizations eliminate intermediate
temporaries inside `storeAux`'s recursion and shift the
allocation-and-free ordering. The race window stops aligning, so the
same workload no longer trips it. The bug isn't fixed in release — it's
just dodged.

**Why macOS-specific (and not Linux even with the same Nim 2.2.4).** Three
suspected contributors, in decreasing confidence:

1. **Compiler differences.** `gcc -O0` on Linux loads `c.freeList` once
   into a register and reuses it; Apple Clang `-O0` reloads from memory
   between consecutive statements (more "literal" debug semantics). The
   reload exposes the race window we identified above.
2. **macOS pthread / scheduler behavior.** `pthread_mutex_t` on macOS is
   non-fair and uses a different fast-path than Linux's futex-based
   mutex; XNU's scheduler also interleaves equal-priority threads more
   aggressively on M-series CPUs to keep cores warm. Both factors widen
   the race window in practice.
3. **arm64 weak memory ordering** vs x86 TSO. Likely a partial
   contributor to the arm64-specific symptom, but not the dominant one
   (we expect macOS amd64 to fail the same way pending CI confirmation).

**Mitigation.** Fixed in Nim 2.2.10. Use orc, or upgrade to 2.2.10, to
remove the limitation entirely. If you must stay on Nim 2.2.4 + refc:
- Build in release mode (the bug is debug-only).
- Avoid sustained sub-second bursts of complex-payload cross-thread
  emits (≳ 50 emits with ≥ 10 cell allocations per emit). Normal
  pacing is fine.

**Compile-time test exclusion.** See §3.

---

### 2.3 Nim devel (2.3.x) + `--mm:refc` + release: shared-heap allocator regression

**Scope.** Tracked, not blocking PRs. Devel coverage is opt-in via the
manual `memcheck_ci.yml` workflow_dispatch (`nim-version: devel`); CI
does not gate on it. Locally reproducible on macOS arm64 with
`--mm:refc -d:release` and Nim 2.3.1.

**Root cause.** After roughly four `createContext` / `shutdown` lifecycle
iterations the next allocation crashes inside the refc small-object
allocator at `system/alloc.nim:942` (`c.freeList = c.freeList.next`
reading address `0x8`). The same code passes on Nim 2.0.16, 2.2.10 and
on devel under refc *debug*; only refc + release + devel crashes.

The crash signature is heap corruption — `c.freeList` is non-nil at
line 939 but stale by line 942 — consistent with a release-mode
codegen / GC regression on the cross-thread allocator path that ships
in 2.3.x. Workarounds inside nim-brokers would be brittle; the right
fix is upstream. We refresh devel coverage on every CI run so once the
regression clears, the informational job will go green again.

**Mitigation.** Use Nim 2.2.x stable. If you must use devel, switch to
`--mm:orc` or use debug builds.

---

### 2.4 Nim 2.0.x is unsupported

**Scope.** Dropped from the CI matrix on 2026-05-04. Refc + foreign-thread
allocator on macOS deterministically SIGSEGVs in `genericSeqAssign` /
`rawAlloc` for `seq[object]` and `array[N,T]` payloads crossing the FFI
boundary. 2.2 fixes that path.

**Recommendation.** Pin `requires "nim >= 2.2.0"` (or stricter) in
downstream projects.

---

### 2.5 `--nimMainPrefix` is not used on Windows

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

**Scope.** Affects `(mt)` brokers and the Broker FFI API on **macOS**
(arm64 confirmed locally and in Memcheck CI; amd64 untested but expected
to behave the same — same dyld TLV mechanism). Both **Nim 2.2.4** and
**Nim 2.2.10** are affected; the bug is *not* fixed by upgrading Nim.
The Memcheck CI run that originally appeared to "pass" on 2.2.10 was
hiding the same crash behind a nimble 0.22 exit-code regression — the
workflow now greps the log for ASAN markers as a backstop, so future
runs report failure honestly.

The crash only manifests when **both** of the following hold:

1. A thread that emitted (or sent a request) on the broker's channel
   has exited (`pthread_exit`, including via `joinThread`).
2. The broker's bucket / channel for that context is **walked again
   afterwards** — by another emit, by `Channel.close()` during a
   shutdown path, or by recv on the listener side.

If either condition is removed (transient threads but no channel
reuse, OR channel reuse but persistent threads), no crash. Linux,
Windows, and macOS + refc are all unaffected.

**Symptom.** ASAN heap-use-after-free in
`system::addToSharedFreeList` (`alloc.nim:796` on 2.2.10, `alloc.nim:1052`
on 2.2.4) reached through `rawDealloc`. Two top-of-stack shapes are
observed depending on which code path next walks the channel:

```
# Path A — next emit on a reused channel.
Channel.send → rawSend → deallocShared → addToSharedFreeList   (UAF)

# Path B — explicit broker teardown that closes the channel.
Channel.close → deinitRawChannel → rawDealloc                   (UAF)
```

The freed memory is a ~13 KiB region originally `calloc`'d by
`dyld::ThreadLocalVariables::instantiateVariable` for the exited thread's
threadvars (Nim's `nimErrorFlag`, `MemRegion`, etc.) and then `free()`'d
by macOS' `_pthread_tsd_cleanup` on `pthread_exit`.

**Root cause.** On macOS, dyld backs each module's TLVs with a per-thread
`calloc`'d block, and pthread's TSD cleanup `free()`s that block in one
shot at thread exit. Nim's allocator stores `MemRegion` (the per-thread
chunk arena) as a `{.threadvar.}` inside that block. `Channel[T].send`
deep-copies its payload through `allocShared` paths whose chunk metadata
ends up referenced by the channel's slot ring. Once the sender exits and
dyld frees its TLV block, the slot-ring's free-list links into that
block dangle. Whichever code path next iterates the ring trips the fault.

Linux's glibc TLS lives in static thread-stack slots that
`pthread_exit` does not free, so the analogous chunk references stay
valid through the channel's lifetime. Windows uses PE TLS / `TlsAlloc`,
which similarly does not free Nim's `MemRegion` as a single block. macOS
+ refc uses different chunk metadata layout that does not retain
TLV-anchored references in the ring under the workloads we tested.

**Why we can't fix this in the broker layer.** Three candidate
mitigations were probed against an isolated repro
(`test/probe_mt_uaf.nim`), all on macOS arm64 + Nim 2.2.10 + ORC + ASAN:

| Probe mode | What it does | Result |
|---|---|---|
| `gcCollect`, `gcCollectAll` | `GC_fullCollect()` from the leaving thread before `pthread_exit`, plus extra collects between rounds | UAF — does not return the thread's arena chunks to a "shared safe" pool |
| `shutdownEach` | Adds a public `shutdown()` that fully tears down the bucket and `Channel.close()`s it between rounds | UAF — `Channel.close()` itself walks the corrupted ring and trips ASAN |
| `keepAlive`, `relistenKeepAlive` | Threads that emitted stay alive until program teardown | **OK** — the only mitigation that works |

The corruption is inside `Channel[T]`'s slot ring, written by
`Channel.send` from a thread whose TLV-anchored allocator state then
disappears. The Nim stdlib offers no API to scrub the ring; iterating
it is exactly what triggers the fault. We therefore cannot offer a
broker-level workaround.

**The mitigation that works.** Threads that send to or receive from an
`(mt)` broker channel **must not exit before broker teardown**:

- For application code: use a thread pool with persistent workers, or
  pin emitter threads to the lifetime of the chronos event loop they
  feed. Avoid `createThread` / `joinThread` patterns where the thread's
  whole purpose is to send a few events and exit.
- For tests: prefer one long-lived sender thread (or pool) per scenario
  set over creating a fresh thread per scenario.

**Test gating.** The `concurrent emitters from multiple threads`
(`test/test_multi_thread_event_broker.nim`) and `concurrent requests
from multiple threads` (`test/test_multi_thread_request_broker.nim`)
scenarios that trip this UAF are already gated by the
`brokerTestsSkipFragileRefcBursts` predicate — but only when the
predicate matches macOS + 2.2.4 + refc + debug (see §3). The same gating
needs to extend to macOS + ORC at any Nim version. Pending that
extension, those scenarios will fail Memcheck CI on the macOS-ORC matrix
cell. Until the predicate is widened, the only honest options are:
gate the tests, replace the transient-thread pattern with a persistent
emitter thread, or accept the failure.

**Comment fix-up.** The pre-`when` comment in
`test/test_multi_thread_event_broker.nim` ("the exact pattern the Nim
2.2.4 macOS refc debug stdlib regression trips on") describes only one
of the two distinct issues this scenario exposes. The second is the
present one (any macOS + ORC build). When the predicate is widened, that
comment should be updated to reference §2.2 *and* §2.6.

**Upstream report.** Pending. The minimal repro at
`test/probe_mt_uaf.nim` is suitable to file as a Nim issue: ~70 lines,
no chronos-internal magic beyond what `(mt)` brokers already use, and
selects six distinct probe modes via `-d:probeMode=...` that demonstrate
the necessary-and-sufficient conditions.

---

## 3. Compile-time test exclusion mechanism (§2.2 carve-out)

The macOS + Nim 2.2.4 + refc + debug carve-out is implemented as a
**compile-time skip of specific stress tests**, not as a wholesale skip
of the affected build mode. The build configuration is exercised in CI;
only the tests known to trip the upstream regression are excluded.

### 3.1 How it works

`brokers.nimble` detects the affected combo at nimble-script compile
time:

```nim
proc isNim224MacosRefcDebug(mm: string, release: bool): bool =
  when defined(macosx) and (NimMajor, NimMinor, NimPatch) == (2, 2, 4):
    return mm == "refc" and not release
  false
```

When the predicate matches, the iteration loop:

- adds `-d:brokerTestsSkipFragileRefcBursts` to the Nim build command
  (so Nim sources can `when not defined(brokerTestsSkipFragileRefcBursts):`
  around suspect blocks), and
- passes `-DBROKER_TESTS_SKIP_FRAGILE_REFC_BURSTS=ON` to cmake (so
  C++ tests can `#ifndef BROKER_TESTS_SKIP_FRAGILE_REFC_BURSTS` around
  suspect `RUN(...)` calls).

The cmake side translates the variable into a target compile definition
(`test/typemappingtestlib/CMakeLists.txt`).

Linux, Windows, all other Nim versions and all other (mm × build mode)
combinations on macOS run the full test list. Only this one combination
is reduced.

### 3.2 What gets skipped

**C++ (`test/typemappingtestlib/test_typemappingtestlib.cpp`):**

- `test_concurrent_event_types`
- `test_foreign_thread_concurrent_requests`
- `test_foreign_thread_concurrent_seq_string_requests`
- `test_foreign_thread_concurrent_seq_prim_requests`
- `test_foreign_thread_concurrent_seq_object_requests`
- `test_foreign_thread_concurrent_seq_object_param_requests`
- `test_foreign_thread_concurrent_lifecycle`
- `test_foreign_thread_mixed_request_types`
- `test_foreign_thread_stress_all_types`
- `test_seq_object_event_rapid_fire_no_leak`
- `test_seq_object_event_concurrent_listeners_and_requesters`

**Nim multi-thread broker tests:**

- `test_multi_thread_event_broker.nim` → `"concurrent emitters from multiple threads"`
- `test_multi_thread_request_broker.nim` → `"concurrent requests from multiple threads"`

> Note: these two scenarios *also* trip §2.6 on macOS + ORC at any Nim
> version we tested. The current predicate
> (`isNim224MacosRefcDebug`) does not gate them on that combo, so
> Memcheck CI on the macOS-ORC cell will currently fail at these
> scenarios. The predicate needs widening (or a sibling predicate added)
> to cover macOS + ORC; until then, these tests should be considered
> known-failing on macOS + ORC.

**Nimble tasks gated at task level (no per-test selection):**

- `nimble perftest` — perf tests are stress-by-design; the entire task
  is skipped on this combo with a clear log line.

### 3.3 What stays running

Everything else. On macOS + Nim 2.2.4 + refc + debug we still build the
shared library, build the C++ test executable, and run the full
non-stress test suite (basic round-trips, all type-mapping coverage,
single-listener tests, lifecycle, etc.). This keeps the configuration
honestly tested.

---

## 4. Quick reference: reliability profile (cross-thread / FFI paths)

The table below applies to **refc** in particular; the **macOS + ORC**
transient-thread carve-out from §2.6 cuts orthogonally across all rows
that involve cross-thread channel sends — its mitigation (persistent
sender threads) is independent of payload shape or pacing.

| Pattern | Reliability on supported cells |
|---|---|
| Single-thread brokers, any payload | **Guaranteed** |
| MT brokers, POD-only payloads (`int`, `bool`, `enum`, fixed `array[N, scalar]`) | **Guaranteed** (zero shared-heap allocations per send) |
| MT brokers, ≤ ~3 cells per payload (one `seq[int]`, one `string`, etc.), normal pacing | **Reliable** |
| MT brokers, complex payloads (`seq[Obj{string, …}]`, deeply nested) at normal pacing (≤ 10 emits/sec) | **Reliable** (with the macOS+2.2.4+debug carve-out) |
| MT brokers, complex payloads in tight bursts (≥ 50 emits in sub-second windows) | **Best-effort** — works on 2.2.10+ everywhere; trips bugs on the carve-out cell |
| FFI API (foreign caller threads + `Channel[T]` + complex payloads) | Same as MT brokers above |
| `seq[ref Obj]` payloads | **Same** profile as `seq[Obj]` (slightly *worse* — `Channel[T].send` deep-copies the pointee, adding one allocation per element). `ref` does not bypass `storeAux`. |
