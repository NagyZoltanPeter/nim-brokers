#!/usr/bin/env bash
# Mode A — C-level coverage of the broker macro-generated dispatch.
#
# Compiles the full test suite with gcov instrumentation and --lineDir:off, so
# gcov attributes hits onto the generated translation units (@mtest_*.nim.c)
# rather than the .nim sources. The macros expand at the call site, so the
# generated dispatch C lives in those per-test TUs. We gcovr-filter to ONLY
# those broker test TUs.
#
# No source changes required (this mode does not need -d:brokerCoverage).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
# shellcheck source=scripts/coverage-common.sh
source "$ROOT/scripts/coverage-common.sh"

cov_require_gcovr   # sets $GCOVR
GCOV="$(cov_gcov_tool)"

CACHE=".cov-cache/c"
rm -rf "$CACHE"
mkdir -p "$CACHE"

cov_build_and_run "$CACHE" "--lineDir:off"

# Derive + print the broker-generated translation units we will isolate. Nim
# mangles the test path into the .nim.c name (@mtest_<name>.nim.c). Print them
# so the filter is auditable rather than guessed.
echo ""
echo "=== Broker-generated translation units (Mode A filter targets) ==="
find "$CACHE" -name '@mtest_*.nim.c' | sort | sed "s#^$CACHE/##"
FILTER='.*@mtest_.*\.nim\.c$'

echo ""
echo "=== gcovr (Mode A: generated C TUs) ==="
# $CACHE is passed as a positional SEARCH PATH (the object directory). gcovr
# then runs gcov from --root (project root), where Nim's root-relative source
# paths resolve. The bare --gcov-object-directory form runs gcov in the .gcda
# dir instead, where those paths don't resolve → 0 lines.
$GCOVR "$CACHE" \
  --root . \
  --gcov-executable "$GCOV" \
  --filter "$FILTER" \
  --gcov-ignore-errors=source_not_found \
  --gcov-ignore-errors=no_working_dir_found \
  --html-details "$CACHE/report.html" \
  --txt

echo ""
echo "Mode A HTML report: $CACHE/report.html"
