@AGENTS.md

# Coverage

Three gcov-based tasks (POSIX + clang `.gcno`; macOS routes through `xcrun
llvm-cov gcov`; debug/`--mm:orc`):

| Command | Role | Measures | Maps onto |
|---------|------|----------|-----------|
| `nimble coverage` | base | hand-written runtime (`broker_context`, `internal/mt_*`, `internal/api_*`) | `brokers/*.nim` (text table only) |
| `nimble coverage_nim` | **primary** | **Mode B** — the broker-macro-generated dispatch, line-attributed back to `.nim` | the `.nim` decl sites. gcovr HTML + stdout table. |
| `nimble coverage_c` | **audit / fallback** | **Mode A** — the same generated code, at C level | the generated translation units `@mtest_*.nim.c`. gcovr HTML + stdout table. |

**Use Mode B (`coverage_nim`) for the day-to-day "what broker code isn't tested"
workflow** — it's the only one whose red lines are actionable (they point at a
broker decl in `brokers/*.nim`). Open `.cov-cache/nim/report.html`, find red lines
in the broker file you care about, write a test that hits that path, rerun.

Mode B requires `-d:brokerCoverage`, which makes **every broker-generating macro**
— `EventBroker`/`RequestBroker`/`MultiRequestBroker` (single + `mt` + `API`
lanes), `BrokerInterface`/`BrokerImplement`, and `registerBrokerLibrary` — stamp
their generated procs with the source line info of the broker decl (via
`stampLineInfo` in `internal/helper/broker_utils.nim`). It is strictly gated:
normal builds (and macro expansion) are byte-for-byte unchanged. It prints
`broker coverage stamping ON` at compile time.

**Mode A is secondary** — keep it as (1) an independent cross-check that Mode B's
stamped numbers are honest (Mode A measures the real compiled C with no stamping,
so it can't be fooled by a stamping bug), and (2) a zero-instrumentation fallback
(works without `-d:brokerCoverage`, e.g. on a branch lacking the macro edits). It
is **not** for finding untested code by hand — its red lines are mangled generated
C mixed with the test body, not traceable to a Nim construct.

`coverage_c` / `coverage_nim` shell out to `scripts/coverage-{c,nim}.sh` and write
HTML to `.cov-cache/{c,nim}/report.html` (gitignored). Both run the full test
suite (mirrors `coverage`).

Caveats:
- **Mode B maps coarsely to `.nim` decls**: stamping attributes a whole generated
  proc to one source node, so a red line means "this generated proc/branch wasn't
  invoked", not a literal statement-level miss. API brokers ride the MT lane, so
  their core dispatch shows up on `internal/mt_*_broker.nim`; the `(API)` adapter
  and `registerBrokerLibrary` output land on their decl sites in the test.
- **Mode A maps to generated C**, not `.nim`: the macros expand at the call site,
  so there is no `broker_interface.nim.c` TU — the dispatch lives inside the
  per-test `@mtest_*.nim.c` (mixed with the test body; TU-granular).

Needs `gcovr` (`pip install --user gcovr`). See `doc/design/TEST_COVERAGE.md`.

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **nim-brokers** (6509 symbols, 11449 relationships, 229 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/nim-brokers/context` | Codebase overview, check index freshness |
| `gitnexus://repo/nim-brokers/clusters` | All functional areas |
| `gitnexus://repo/nim-brokers/processes` | All execution flows |
| `gitnexus://repo/nim-brokers/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
