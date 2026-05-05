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
| **macOS arm64** | ✅ | ⚠️ debug only — see §2.2 | ✅ | ✅ | ✅ | ⚠️ release only — see §2.3 |
| **macOS amd64** | ✅ | ⚠️ likely same as arm64 — see §2.2 | ✅ | ✅ | ✅ | likely ⚠️ same as arm64 — see §2.3 |
| **Windows amd64** | ✅ | ❌ — see §2.1 | ✅ | ❌ — see §2.1 | ✅ | ❌ — see §2.1 (devel install also unsupported by setup-nim-action) |

Nim versions older than 2.2.0 are **not supported** (see §2.4).

### 1.3 Recommendation

Build any nim-brokers code that uses `(mt)` brokers or the Broker FFI API
with **`--mm:orc`** and **Nim ≥ 2.2.10** for the smoothest experience. The
refc carve-outs are real but narrow; orc has no known limitations on any
supported platform.

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
the Win32 `RegisterWaitForSingleObject` API, and the OS fires that callback
on a **Windows thread-pool thread** — a thread that is not a Nim thread and
is therefore invisible to refc's stop-the-world garbage collector.

Refc's GC is stop-the-world: it pauses every *known* Nim thread before
scanning the heap. Because the thread-pool thread is unknown, refc can free
futures and wait-handles that the callback is still referencing, producing
access violations and use-after-free bugs. ORC has no stop-the-world
phase — its reference counting is fully atomic and its cycle collector
runs in-thread — so the same thread-pool callback is safe.

**Why `(mt)` brokers are also affected on Windows.** Earlier project notes
said `(mt)` refc tests pass on Windows because their workloads tend to
keep the broker signal pre-fired by the time the dispatcher polls,
sometimes short-circuiting the `RegisterWaitForSingleObject` slow path.
That is true for the existing test suite under light load, but it is a
property of the test patterns — not a guarantee. Sustained idle periods,
foreign-thread attaches, and stress workloads such as ASAN's
`test_foreign_thread_concurrent_lifecycle` all reach the slow path and
expose the same use-after-free deterministically.

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

## 4. Quick reference: refc reliability profile (cross-thread / FFI paths)

| Pattern | Reliability on supported cells |
|---|---|
| Single-thread brokers, any payload | **Guaranteed** |
| MT brokers, POD-only payloads (`int`, `bool`, `enum`, fixed `array[N, scalar]`) | **Guaranteed** (zero shared-heap allocations per send) |
| MT brokers, ≤ ~3 cells per payload (one `seq[int]`, one `string`, etc.), normal pacing | **Reliable** |
| MT brokers, complex payloads (`seq[Obj{string, …}]`, deeply nested) at normal pacing (≤ 10 emits/sec) | **Reliable** (with the macOS+2.2.4+debug carve-out) |
| MT brokers, complex payloads in tight bursts (≥ 50 emits in sub-second windows) | **Best-effort** — works on 2.2.10+ everywhere; trips bugs on the carve-out cell |
| FFI API (foreign caller threads + `Channel[T]` + complex payloads) | Same as MT brokers above |
| `seq[ref Obj]` payloads | **Same** profile as `seq[Obj]` (slightly *worse* — `Channel[T].send` deep-copies the pointee, adding one allocation per element). `ref` does not bypass `storeAux`. |
