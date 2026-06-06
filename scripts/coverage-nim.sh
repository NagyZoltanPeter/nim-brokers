#!/usr/bin/env bash
# Mode B — .nim line-attribution coverage of the broker macro-generated code.
#
# Compiles the full test suite with -d:brokerCoverage (so BrokerInterface /
# BrokerImplement stamp their generated procs with the line info of the source
# decl) and --lineDir:on (so gcov maps the generated C back onto .nim). gcovr
# then reports against the .nim sources; the stamped broker dispatch lands
# (coarsely) on the BrokerInterface / BrokerImplement decl sites.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
# shellcheck source=scripts/coverage-common.sh
source "$ROOT/scripts/coverage-common.sh"

cov_require_gcovr   # sets $GCOVR
GCOV="$(cov_gcov_tool)"

CACHE=".cov-cache/nim"
rm -rf "$CACHE"
mkdir -p "$CACHE"

cov_build_and_run "$CACHE" "-d:brokerCoverage --lineDir:on --debugger:native"

echo ""
echo "=== gcovr (Mode B: .nim line attribution) ==="
# $CACHE passed as a positional SEARCH PATH so gcovr runs gcov from --root,
# where Nim's #line-mapped .nim source paths resolve (see coverage-c.sh).
$GCOVR "$CACHE" \
  --root . \
  --gcov-executable "$GCOV" \
  --filter '.*\.nim$' \
  --merge-mode-functions=merge-use-line-0 \
  --gcov-ignore-errors=source_not_found \
  --gcov-ignore-errors=no_working_dir_found \
  --html-details "$CACHE/report.html" \
  --txt

echo ""
echo "Mode B HTML report: $CACHE/report.html"
