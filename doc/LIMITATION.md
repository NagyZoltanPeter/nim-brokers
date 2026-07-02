# Platform & Nim Version Limitations

This document collects the **current** platform / Nim-version / memory-
manager / build-mode constraints for nim-brokers. After the Round-2
CBOR retirement + channel-dispatch + courier refactor, the surface
shrank dramatically — most historical limitations are now closed and
documented in [`design/LESSONS_LEARNED.md`](design/LESSONS_LEARNED.md).

If you landed here looking for a historical crash signature (`storeAux
→ newObjNoInit → SIGSEGV`, `Channel.send → rawSend → addToSharedFreeList`,
`chronos newFutureImpl → rawAlloc:942`, `ensureBrokerDispatchStarted` ZCT
leak, etc.), check `LESSONS_LEARNED.md` — those are all closed and
preserved there with their root-cause analysis intact.

---

## 1. Support matrix

Legend: ✅ fully supported · ❌ unsupported · — never tested in CI.

### 1.1 Single-thread brokers

| Broker | Linux | macOS | Windows |
|---|:---:|:---:|:---:|
| `EventBroker` | ✅ orc & refc | ✅ orc & refc | ✅ orc & refc |
| `RequestBroker` (sync & async) | ✅ orc & refc | ✅ orc & refc | ✅ orc & refc |
| `MultiRequestBroker` | ✅ orc & refc | ✅ orc & refc | ✅ orc & refc |

Single-thread brokers are pure threadvar code. No shared heap, no
cross-thread transport, no FFI runtime — none of this document touches
them.

### 1.2 Multi-thread brokers and Broker FFI API

| OS / arch | Nim 2.2.4 (orc / refc) | Nim 2.2.10 (orc / refc) | Nim devel (orc / refc) |
|---|:---:|:---:|:---:|
| **Linux amd64**   | ✅ / ✅ | ✅ / ✅ | ✅ / ✅ |
| **macOS arm64**   | ✅ / ✅ | ✅ / ✅ | ✅ / ✅ |
| **macOS amd64**   | ✅ / ✅ | ✅ / ✅ | ✅ / ✅ |
| **Windows amd64** | ✅ / ✅ ¹ | ✅ / ✅ ¹ | — / — ² |

¹ Windows + refc passes the full CI matrix (`nimble test`, `testApi`,
`runTypeMapTestLib{Cpp,Py,Rust,Go}`, `runFfiExample{Cpp,Py,Rust,Go}`)
on Nim 2.2.4 and 2.2.10. **A latent platform hazard does still exist**
— see §2.2 — but broker / FFI code paths don't trip it.

² Nim devel on Windows is unsupported by `setup-nim-action`; the
runner can't install it. Not a nim-brokers limitation. If devel
becomes installable, expect it to behave like 2.2.10.

The full matrix is exercised on every PR. The `MM=…` env var on the
parity / FFI-example task families honours single-MM overrides for
local re-runs.

---

## 2. Active constraints

### 2.1 Nim ≥ 2.2.0 required

`requires "nim >= 2.2.0"` is the build floor declared in
`brokers.nimble`. Nim 2.0.x's refc foreign-thread allocator path
deterministically SIGSEGVs in `genericSeqAssign` / `rawAlloc` for
`seq[object]` and `array[N, T]` payloads crossing the FFI boundary.
Nim 2.2 fixed that path upstream. We do not test 2.0.x and don't
intend to.

**Recommendation.** Pin `requires "nim >= 2.2.0"` in downstream
projects. CI exercises 2.2.4, 2.2.10, and devel.

---

### 2.2 Windows + refc: latent TLS-uninit hazard (broker code safe; don't bypass it)

**Status: hazard reproduces in the minimal probe; broker / FFI code
paths do NOT trip it in the full CI matrix.**

On Windows the chronos `ThreadSignalPtr.wait()` implementation
registers a completion callback through Win32
[`RegisterWaitForSingleObject`][rwfso]. Per Microsoft's documentation,
when the waited-on event is signaled the callback is invoked on a
**wait thread owned by the legacy NT thread pool**
(`ntdll!TppWorkerThread`). That thread is created by the OS, not by
Nim's `system/threads.nim`, and the application has no hook to
initialize its TLS before the callback runs.

[rwfso]: https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-registerwaitforsingleobject

Under `--mm:refc` that wait-thread has **uninitialized GC TLS** —
any Nim allocation, `GC_ref`, string/seq grow, or exception-frame
push from inside the callback touches null / garbage TLS. ORC
sidesteps this; refc does not.

**The minimal repro `test/probe_win_tls_uninit.nim` still crashes**
under refc on Windows across every Nim version we test (2.2.4,
2.2.10) — confirmed empirically via `nimble probeWinTlsUninitRefc`.
The hazard is real, structural, and unfixable from our side without
an upstream chronos rewrite of the Windows wait primitive.

**Broker / FFI code DID trip a related teardown variant of this
hazard until the `teardownBrokerThread` fix.** A 2026-07 CI
investigation (repeated-run harness, ~30 % crash rate per execution on
GitHub win runners, `0xC0000005`) showed the historical
"win + Nim 2.2.4 first-run CI flake" was in fact this mechanism firing
at **worker-thread exit**, on *every* Nim 2.2.x, hidden on other
versions only by single-shot CI sampling:

- A worker thread that used the MT brokers leaves `brokerDispatchLoop`
  suspended in `await signal.wait()`; on Windows that wait is a live
  `RegisterWaitForSingleObject` registration holding a **GC-heap
  `ref PostCallbackData`**.
- refc frees the whole thread heap at thread exit
  (`deallocOsPages()`); a later `setEvent` / handle reuse makes the OS
  wait-thread callback dereference unmapped pages. ORC survives
  because it skips `deallocOsPages` (the state leaks in still-mapped
  memory).
- A second, **general** (all-platform) variant existed: raw
  `ThreadSignalPtr` pointers in shared buckets / request messages
  could be fired by other threads after the owner closed and freed the
  signal — on POSIX a silent stray `write()` to a possibly-reused fd.

**The fix (teardown-sequence, 2026-07):**

- `BrokerSignalShared` — a type-stable, close-guarded shared wrapper
  (closed-bit + in-flight-firer refcount, recycled on a process
  freelist) replaces every raw `ThreadSignalPtr` handed across
  threads. Firing after close is a no-op; wrapper memory is never
  unmapped. Identical semantics under refc and orc, all platforms.
- `teardownBrokerThread()` (in `brokers/internal/mt_broker_common.nim`)
  runs stop-dispatch-loop → close signal wrapper →
  `drainPendingRingFrees` → close chronos dispatcher handle, **before**
  the thread's refc heap dies. It is registered automatically via
  `onThreadDestruction` for Nim-created threads; **foreign/FFI threads
  and the main thread must call it explicitly** (Nim's destruction
  handlers never run for them).
- Regression gate: `nimble testAllocRace` (40 repeated trials per
  single-ingredient reproducer variant, refc + release) and the
  dispatch-only `teardown_verify.yml` workflow.

**Recommendation.** Use the brokers and the FFI API on Windows under
either `--mm:orc` or `--mm:refc`. But:

- **Do not call `Nim` allocators from your own
  `RegisterWaitForSingleObject` callbacks under refc.** This is the
  hazard the probe demonstrates; broker code no longer does it, but
  unrelated app code that does will crash the same way.
- **Threads not created by Nim (FFI callers) that used broker APIs
  must call `teardownBrokerThread()` before their final return.**
- **Prefer `--mm:orc`** if you want full peace of mind.
- The `skipRefcOnWindows` predicate in `brokers.nimble` remains
  *disabled*; the teardown-sequence fix addresses the broker-path
  crash it used to paper over.

Run `nimble probeWinTlsUninitRefc` on a Windows host to reproduce the
raw hazard, or `nimble probeWinTlsUninitOrc` to verify ORC is clean.
The `memcheck_ci.yml` workflow exposes both as `workflow_dispatch`
options; `teardown_verify.yml` exercises the broker teardown gate.

---

## 3. Build notes (Windows toolchain)

These aren't bugs — they're correct platform-specific behaviour that
trips users coming from POSIX expectations.

### 3.1 `--nimMainPrefix` is not used on Windows

Every nimble task that compiles a shared library passes
`--nimMainPrefix:<libname>` on Linux / macOS and omits it on Windows.

**Why.** `--nimMainPrefix` exists to avoid `NimMain` symbol collisions
when multiple Nim `.so` files are loaded into the same POSIX process —
`dlopen(... RTLD_GLOBAL)` merges all exports into a single namespace,
so two libraries both defining `NimMain` clash. The prefix renames
them (e.g. `fooNimMain`, `barNimMain`).

On Windows the PE loader resolves every import as `DLL!Symbol`, so
`foo.dll!NimMain` and `bar.dll!NimMain` are entirely separate entries
that never interfere. Any number of Nim DLLs can be loaded into the
same process without a prefix.

Attempting to use `--nimMainPrefix` on Windows also triggers a Nim
codegen bug: the C generator forward-declares the prefixed `NimMain`
without `__declspec(dllexport)` and then defines it with
`N_LIB_EXPORT`, which both clang and gcc reject as a hard error
(`err_attribute_dll_redeclaration`).

### 3.2 LLVM clang + Ninja on PATH

The Broker FFI API requires **LLVM clang and Ninja** on `PATH` for FFI
builds on Windows. The bundled MinGW `gcc` mismatches the cmake-side
MSVC CRT and produces cross-heap crashes. When running the
AddressSanitizer tasks, `clang_rt.asan_dynamic-x86_64.dll` from
`C:\Program Files\LLVM\lib\clang\<ver>\lib\windows\` must also be on
`PATH`; the `memcheck_ci.yml` workflow handles this for CI.

---

## 4. Reliability profile (quick reference)

After the Round-2 closure:

| Pattern | Reliability |
|---|---|
| Single-thread brokers, any payload | **Guaranteed** |
| `(mt)` brokers, any payload, ORC, any platform | **Guaranteed** |
| `(mt)` brokers, any payload, refc, Linux / macOS | **Guaranteed** |
| `(mt)` brokers, any payload, refc, Windows | **Guaranteed** ¹ |
| FFI API (foreign caller threads), any wrapper, ORC | **Guaranteed** |
| FFI API (foreign caller threads), any wrapper, refc, Linux / macOS | **Guaranteed** |
| FFI API (foreign caller threads), any wrapper, refc, Windows | **Guaranteed** ¹ |

¹ With the caveat in §2.2 — don't call Nim allocators from your own
`RegisterWaitForSingleObject` callbacks under refc.

No payload-dependent fragility remains: the marshaler in
`brokers/internal/mt_codec.nim` handles scalars, strings, `seq[U]`,
fixed `array[N, U]`, enums, distinct types of POD, and recursive
object types via `fieldPairs`. `ref T` payloads are rejected at macro
time. Complex payloads (`seq[Object<seq>]`, `Option[seq[byte]]`,
inline-nested Objects, named tuples) are fully supported — see
[`TYPESUPPORT.md`](TYPESUPPORT.md) for the per-cell parity matrix.
