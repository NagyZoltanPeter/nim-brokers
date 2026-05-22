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

**But broker / FFI code under refc on Windows is green.** The
channel-dispatch refactor + the courier rework moved every Nim
allocator interaction off the wait-thread callback path. The
callback now does pure atomic state-machine work; allocations happen
on broker-owned threads (processing / delivery) that go through
proper Nim thread init. The full CI matrix (`nimble test`,
`testApi`, all four `runTypeMapTestLib*`, all four `runFfiExample*`)
is green under Windows + refc + Nim 2.2.4 + Nim 2.2.10.

**Recommendation.** Use the brokers and the FFI API freely on Windows
under either `--mm:orc` or `--mm:refc` — both are CI-green. But:

- **Do not call `Nim` allocators from your own
  `RegisterWaitForSingleObject` callbacks under refc.** This is the
  hazard the probe demonstrates; broker code happens to not do it,
  but unrelated app code that does will crash the same way.
- **Prefer `--mm:orc`** if you want full peace of mind.
- The `skipRefcOnWindows` predicate in `brokers.nimble` is currently
  *disabled* (commit `a10ccff` on PR #17 — commented-out but kept).
  If a future regression somehow re-exposes the hazard via broker
  code, restoring the skip is a one-line revert.

Run `nimble probeWinTlsUninitRefc` on a Windows host to reproduce the
raw hazard, or `nimble probeWinTlsUninitOrc` to verify ORC is clean.
The `memcheck_ci.yml` workflow exposes both as `workflow_dispatch`
options.

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
