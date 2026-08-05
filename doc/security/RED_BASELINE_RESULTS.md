# Red baseline — empirical confirmation of the 2026-07 audit findings

**Test-first run, before any fix is applied.** Every test below asserts the
*fixed* behaviour, so a FAILURE here is the proof that the finding is real and
reachable on the current tree.

- **Tree:** `2b0732e` (master content) + `doc/security/` and `test/security/` only
- **Date:** 2026-07-30
- **Platform:** Linux amd64, Nim 2.2.4, default memory manager, **no sanitizer**
- **Deps:** pinned per nim-ffi's `nimble.lock` (see "Reproducing" below)

> **Update 2026-07-30 (post-fix):** PR 1 (H1, H2) and the M6 guard have landed.
> Current status of the same suite:
>
> | Finding | Status | Evidence |
> |---|---|---|
> | **H1** | ✅ **FIXED** | `shutdown returned 0`; parked caller wakes with `-11` (`ApiStatusShutdown`) |
> | **H2** | ✅ **FIXED** | wedged provider now returns `-12` (`ApiStatusTimeout`) |
> | **M6** | ✅ **FIXED** | `_subscribe` → `0`, `_unsubscribe` → `-1`; no segfault |
> | **M3** | ⬜ open | fix is PR 4 |
> | **M4** | 🟨 partial | request ceiling is now configurable (`-d:brokerFfiMaxRequestBytes`); per-API `maxPayloadBytes` binding still **not** implemented, so the test stays red by design |
> | **M5** | ✅ **FIXED** | lying `reqLen` rejected with `-3`; validated against the registry's recorded size |
> | **M7a** | ✅ **FIXED** | freeing the static `_version()` pointer is refused; process survives |
> | **M7b** | ✅ **FIXED** | double free refused; ASan-clean |
>
> Regression check after the fixes: 119 existing tests green
> (`api_courier_growth`, `api_library_init` — fd-leak delta 0 —, `api_callAsync`,
> `api_signal_broker`, `api_discovery`, `api_codec`, `event_broker`,
> `request_broker`, `multi_thread_request_broker`).
>
> **M5 + M7 — design note (inline header rejected).** These share a root cause:
> `_freeBuffer` could not tell what it was freeing, and `_call` could not tell
> how big a buffer really was. Both are answered by tracking live library
> allocations in `brokers/internal/api_buf.nim`.
>
> The obvious implementation — a `[magic][size]` header before each payload —
> was written first and **rejected after measurement**. Validating a pointer
> then means reading the bytes *before* it, which is undefined behaviour in
> exactly the cases being defended against. Under ASan:
>
> * freeing the static `_version()` string → `global-buffer-overflow` **inside
>   the validator itself**;
> * double free → `heap-use-after-free`, because the second call reads a header
>   already returned to the allocator — so "poison the magic on free" is not
>   even reliable.
>
> Both behave correctly without a sanitizer, but a security fix must not
> introduce UB, and this repo runs ASan in CI (`memcheck_ci.yml`). The shipped
> design is a **side registry** keyed by the pointer's numeric value: it never
> dereferences an untrusted pointer, so it is ASan-clean and correct by
> construction. It also has a benign failure mode — a missed `apiFreeTagged`
> leaves a stale table entry (small leak), never heap corruption, because
> allocations keep their plain `allocShared0` layout.
>
> The classification of free sites mattered: `eventCourierPoll` and
> `respCourierPoll` contain near-identical `deallocShared(m.buf)` calls, but the
> first frees an **event** payload (`cborEncodeShared`, untracked) and the
> second an **async response** (`encodeApiResp`, tracked). Conflating them
> would have been a heap bug.

## Summary (original pre-fix baseline)

| Finding | Test | Result | Evidence |
|---|---|---|---|
| **M3** holey enum accepted | `test_m3_holey_enum.nim` | ❌ **FAILS — confirmed** | ordinals 1/3/4 decode `ok` into a non-member; 4 control cases pass |
| **H2** sync `_call` never times out | `test_h1_h2_shutdown_uaf.nim` | ❌ **FAILS — confirmed** | `secffi_call` never returns; killed at 25 s |
| **H1** shutdown vs parked caller | `test_h1_h2_shutdown_uaf.nim` | ❌ **FAILS — confirmed** | `secffi_shutdown` never returns; killed at 45 s |
| **M4** `maxPayloadBytes` not enforced | `test_m4_m7_ffi_input_ownership.nim` | ❌ **FAILS — confirmed** | 4 KiB request accepted (`st == 0`) by a `maxPayloadBytes = 256` broker |
| **M5** `reqLen` OOB copy | `test_m4_m7_ffi_input_ownership.nim` | ❌ **FAILS — confirmed** | SIGSEGV at `api_library.nim(1393) handleCourierMsg` |
| **M6** `_subscribe` pre-init nil deref | `test_m4_m7_ffi_input_ownership.nim` | ❌ **FAILS — confirmed** | SIGSEGV at `api_library.nim(1156)` → `subsRegistryAdd` |
| **M7a** `_freeBuffer` frees static `_version()` | `test_m4_m7_ffi_input_ownership.nim` | ❌ **FAILS — confirmed** | SIGSEGV at `api_library.nim(836)` → `addToSharedFreeListBigChunks` |
| **M7b** `_freeBuffer` double free | `test_m4_m7_ffi_input_ownership.nim` | ⚠️ **PASSES — inconclusive** | allocator tolerated it; needs ASan to demonstrate |

**7 of 8 scenarios reproduce the audited defect.** The eighth (M7b) is a real
defect by inspection but is not observable without a sanitizer — a green M7b
without ASan must be read as "not measured", never as "not a bug".

## Notable detail — H1's mechanism differs from the static prediction

The audit predicted: the 5 s best-effort drain expires, `_shutdown` proceeds to
`freeCborCourier`, and the still-parked caller then touches a freed
`Cond`/`Lock` (use-after-free).

What actually happens on this platform: `_shutdown` **never returns at all**.
The child reaches

```
CHILD-H1: ctx created
CHILD-H1: calling shutdown while a sync _call is parked in waitSlot
```

and then blocks indefinitely — apparently at one of the `joinThread` calls,
**before** reaching the free. So the reachable defect here is an unbounded
**shutdown deadlock**; the predicted UAF stays a code-reading concern for
configurations where the join does complete.

This does not change the fix (bounded wait + genuine quiescence, PR 1), and the
test gates both outcomes: it requires `_shutdown` to return *and* the caller to
come back with a defined status. It does mean the audit's H1 severity rationale
should cite "shutdown deadlock, UAF by inspection" rather than "observed UAF".

## Cross-check: the compiler agrees about M3

Building the M3 test emits, unprompted:

```
brokers/internal/api_cbor_codec.nim(107, 12)
  Warning: conversion to enum with holes is unsafe: T(i) [HoleEnumConv]
```

— Nim flags the exact line the audit identified.

## Reproducing

`nim-brokers` has no lockfile (finding **B1**), so this baseline was built by
resolving dependencies from **nim-ffi's** `nimble.lock` and cloning each at its
pinned version: `results`, `unittest2`, `testutils`, `stew`, `serialization`,
`faststreams`, `cbor_serialization` (vacp2p), `json_serialization`, `bearssl`,
`chronicles`, `chronos`, `httputils`, `taskpools`.

```sh
# M3 — pure codec, no FFI
nim c -r --path:. <dep-paths> --outdir:build test/security/test_m3_holey_enum.nim

# H1/H2 — FFI lifecycle
nim c -r --path:. <dep-paths> --outdir:build -d:BrokerFfiApi --threads:on \
    --nimMainPrefix:secffi test/security/test_h1_h2_shutdown_uaf.nim

# M4–M7 — FFI input validation and buffer ownership
nim c -r --path:. <dep-paths> --outdir:build -d:BrokerFfiApi --threads:on \
    --nimMainPrefix:secown test/security/test_m4_m7_ffi_input_ownership.nim
```

Add `-d:useMalloc --mm:orc --passC:-fsanitize=address --passL:-fsanitize=address`
to make M5/M7 explicit and to give M7b a chance to register.

Each FFI scenario runs in a **child process** (re-exec selected by
`BROKER_SEC_CHILD`) because the pre-fix failures crash or hang — either would
take an in-process runner down with it. Run one directly for diagnostics:

```sh
BROKER_SEC_CHILD=h1  ./build/test_h1_h2_shutdown_uaf
BROKER_SEC_CHILD=m7a ./build/test_m4_m7_ffi_input_ownership
```

## Still to build

Per `SECURITY_TEST_PLAN.md`, not yet implemented: **H3**/**S5** (mt response-slot
generation harness), **M1** (callback fault isolation, 3 languages), **M2**,
**M8** (TSan), **M9** (code-shape assertion), **S2/S3/S8**, and the **B1–B6**
static policy gate.
