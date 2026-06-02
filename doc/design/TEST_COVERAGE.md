# Test Coverage for nim-brokers

Status: **working, exploratory** — a `nimble coverage` task exists and produces a
verified per-module line-coverage table for the hand-written runtime. Several
known restrictions remain (see below). This document captures the original plan,
the implementation as built, the restrictions, and a reference snapshot of the
numbers so the work can be picked up later.

Branch: `coverage-task` (forked from `flexible-mt-dispatch`).
Touched files: `brokers.nimble` only (new `coverage` task + extra imports
`tables, sets, algorithm`).

---

## 1. Original plan

The ask: *"Can we measure the test coverage of nim-brokers?"* — wire a
`nimble coverage` task that runs the existing test suite under coverage
instrumentation and reports per-`brokers/*.nim` numbers, debug/orc only, gated
so it does not touch the existing 4-way (orc/refc × debug/release) test matrix.

Initial intended approach (later abandoned — see §3): **LLVM source-based
coverage** (`-fprofile-instr-generate -fcoverage-mapping` → `llvm-profdata` →
`llvm-cov`). The premise was that Nim emits `#line` directives back to the
`.nim` sources in debug (`--lineDir:on`), so clang's coverage mapping would
attribute hits onto the original Nim files, and `llvm-cov report`/`show` could
filter to `brokers/*.nim`.

That premise turned out to be **false** — see Restrictions.

---

## 2. Implementation as built

Final approach: **gcov line coverage** (GNU-style), because gcov *does* honor
Nim's `#line` directives whereas clang's source-based coverage does not.

The `coverage` task (in `brokers.nimble`) does, debug + `--mm:orc` only:

1. Compiles each of the 17 core / MT / FFI test files once with
   `--cc:clang --lineDir:on --debugger:native --passC:--coverage --passL:--coverage`,
   into a per-test nimcache under `build/cov/cache/<test>/`. Flag groups mirror
   the existing `test` / `testApi` tasks exactly (no `--threads:on` for the
   single-thread core tests; `--threads:on` for MT; `-d:BrokerFfiApi --threads:on`
   + per-test `--nimMainPrefix` for the FFI tests).
2. Runs each test binary (populates `.gcda`).
3. For each `.gcda` whose mangled name carries the `brokers@s` path segment
   (i.e. the hand-written brokers package modules — see §3 on why only these),
   runs `gcov` **from the project root** with a `./`-prefixed path.
4. Parses the emitted `.gcov` files and **union-merges** line data across all
   tests in NimScript: a line is *executable* if it carries a count, *hit* if
   the count is non-zero in **any** test. Keyed by project-relative
   `brokers/...nim` path.
5. Prints a per-file + TOTAL table.

gcov tool resolution (`gcovInvocation`): macOS uses `xcrun llvm-cov gcov`
(Apple's system `gcov` can't read clang `.gcno`); Linux uses `gcov`; otherwise
falls back to `llvm-cov gcov`.

Run it:

```
nimble coverage
```

Artifacts land under `build/cov/` (gitignored).

### Four bugs found and fixed during bring-up

These are the non-obvious traps; re-tripping them is easy when extending this.

| Symptom | Root cause | Fix |
|---|---|---|
| `llvm-cov` source-based coverage reported 0 on every `.nim` | clang's coverage **mapping ignores `#line`** — it keys regions to the generated `.c` (`@mtest_*.nim.c`), not the `.nim` | abandon LLVM source-based; use **gcov** (honors `#line`) |
| First gcov run → `0/0 TOTAL` | nim-2.2.10 emits **relative** `Source:` paths (`brokers/...nim`); the filter compared against an **absolute** root (nim-2.2.4 had emitted absolute paths) | normalize to project-relative (`brokersRelPath`) |
| Batch gcov → `ENAMETOOLONG` / no output | `@`-mangled Nim filenames are read as `@response-file` args; `llvm-cov gcov` also mishandles multiple files in one call | **one `.gcda` per gcov call**, each `./`-prefixed |
| `.gcov` files had only header lines, no counts | gcov ran with cwd = cacheDir; the relative `brokers/...nim` source paths didn't resolve, and gcov **must read the source to emit per-line counts** | run gcov **from the project root** |

---

## 3. Restrictions / known limitations

1. **Macro modules contribute nothing.** The broker macros (`EventBroker`,
   `RequestBroker`, `MultiRequestBroker`, their `mt` variants, and the
   `api_*_broker` generators) expand at the **call site**, so the generated
   dispatch procs get `#line` pointing at the test's `XBroker:` declaration,
   not at the macro source. Concretely: `event_broker.nim`,
   `request_broker.nim`, `mt_event_broker.nim`, etc. have **no own runtime
   `.c`** (no `@pbrokers@s...broker.nim.c.gcda`) and never appear in the table.
   The numbers therefore cover only the **hand-written runtime** (`broker_context`,
   `internal/mt_*`, `internal/api_cbor_*`, `internal/api_common`,
   `api_library`). This is arguably the right thing to measure, but it means
   "X% of brokers/" excludes the macro-generated dispatch entirely.

   *If the macro-generated code's coverage is ever wanted, it would have to be
   read off the per-test module `.gcov` (`@mtest_*.nim.c`) and attributed by
   hand — there is no automatic mapping back to the originating macro.*

2. **Debug + `--mm:orc` only.** Release inlining and dropped line directives
   ruin the `#line`→`.nim` mapping; refc was not exercised. The task hard-codes
   debug/orc and is intentionally **not** part of the test matrix or CI.

3. **No `--threads:on` for the single-thread core tests.** Matches `test`, so
   the single-thread macro path is what's compiled — but since those modules
   are macros, they contribute nothing anyway (see #1).

4. **POSIX + clang `.gcno` only.** Hard-quits on Windows. On macOS the Apple
   system `gcov` is incompatible with clang's `.gcno`; the task routes through
   `xcrun llvm-cov gcov`.

5. **No HTML report from the task itself.** The task prints a text table only.
   For HTML, `lcov` + `genhtml` is the route (not installed on the dev box at
   time of writing). The same gotchas apply — see §4.

6. **Union-merge granularity.** Coverage is unioned at the line level across
   tests; it is not per-test or branch coverage. Branch/condition coverage was
   not attempted.

---

## 4. HTML report via lcov (not yet wired)

`nimble coverage` leaves all `.gcda` under `build/cov/cache/`, so lcov can
capture from them with no recompile. On macOS lcov must be told to use LLVM's
gcov (Apple's can't read the `.gcno`), and `--base-directory` is mandatory so
the relative `Source:` paths resolve (same trap as the task itself).

```sh
nimble coverage                        # generate .gcda (once)

# macOS only: wrapper so lcov calls LLVM's gcov
printf '#!/bin/sh\nexec xcrun llvm-cov gcov "$@"\n' > build/cov/llvm-gcov.sh
chmod +x build/cov/llvm-gcov.sh

lcov --capture --directory build/cov/cache \
     --base-directory "$PWD" \
     --gcov-tool "$PWD/build/cov/llvm-gcov.sh" \
     --output-file build/cov/coverage.info \
     --ignore-errors source,gcov,unsupported,inconsistent

lcov --extract build/cov/coverage.info "$PWD/brokers/*" \
     --output-file build/cov/brokers.info --ignore-errors unused

genhtml build/cov/brokers.info --output-directory build/cov/html \
     --ignore-errors source,inconsistent
open build/cov/html/index.html
```

| | macOS (clang) | Linux (gcc) |
|---|---|---|
| `--gcov-tool` wrapper | needed | omit (system `gcov`) |
| `xcrun` | yes | no |

The `--ignore-errors …` flags matter on **lcov 2.x** (much stricter); harmless
on 1.x.

**Possible future work:** auto-detect `lcov`/`genhtml` in the task, generate the
wrapper, and emit `build/cov/html` as an optional tail step (skip silently when
absent), reusing the already-produced `.gcda`.

---

## 5. Reference snapshot

`nimble coverage`, branch `coverage-task`, nim-2.2.10, debug/`--mm:orc`,
macOS arm64. `lines` = executable Nim lines reached across the whole suite
(union). Macro modules absent by design (see §3.1).

```
========================= COVERAGE (brokers/) =========================
    7/    7   100.0%  brokers/api_library.nim
   38/   38   100.0%  brokers/broker_context.nim
   26/   30    86.7%  brokers/internal/api_cbor_codec.nim
  105/  143    73.4%  brokers/internal/api_cbor_courier.nim
   39/   41    95.1%  brokers/internal/api_cbor_descriptor.nim
   45/   61    73.8%  brokers/internal/api_cbor_event_courier.nim
  135/  184    73.4%  brokers/internal/api_cbor_subs_registry.nim
    0/   13     0.0%  brokers/internal/api_common.nim
   96/  104    92.3%  brokers/internal/mt_broker_common.nim
   46/  107    43.0%  brokers/internal/mt_codec.nim
  196/  216    90.7%  brokers/internal/mt_queue.nim
    2/    2   100.0%  brokers/internal/mt_request_broker.nim
----------------------------------------------------------------------
  735/  946    77.7%  TOTAL
```

Cold spots worth attention later: `api_common.nim` (0/13 — never exercised by
any test) and `mt_codec.nim` (43%).
