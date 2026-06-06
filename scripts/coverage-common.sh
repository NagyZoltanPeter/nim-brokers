# Shared helpers for the macro-generated-code coverage modes (sourced, not run).
#
# Both modes compile + run the SAME test suite that `nimble coverage` exercises
# (full suite, debug/orc); they differ only in how gcov attributes the hits:
#   Mode A (coverage-c.sh):   --lineDir:off  -> gcov maps to the generated .nim.c
#   Mode B (coverage-nim.sh): --lineDir:on + -d:brokerCoverage -> gcov maps to .nim
#
# The broker macros (EventBroker / RequestBroker / BrokerInterface /
# BrokerImplement) expand AT THE CALL SITE, so their generated dispatch C lands
# in the per-test translation units (@mtest_*.nim.c), never in a brokers/*.nim.c.

# Test matrix — must mirror the `coverage` task in brokers.nimble.
# Each entry: "<relpath-without-.nim>|<compile env flags>|<nimMainPrefix or empty>"
COV_TESTS=(
  # single-thread core brokers (no --threads:on, matches `test`)
  "test_event_broker|--mm:orc|"
  "test_request_broker|--mm:orc|"
  "test_request_broker_sugar|--mm:orc|"
  "test_request_broker_sync_void|--mm:orc|"
  "test_multi_request_broker|--mm:orc|"
  "test_broker_oop|--mm:orc|"
  "test_broker_lifecycle|--mm:orc|"
  # multi-thread brokers
  "test_multi_thread_request_broker|--mm:orc --threads:on|"
  "test_multi_thread_event_broker|--mm:orc --threads:on|"
  "test_multi_thread_broker_configs|--mm:orc --threads:on|"
  "test_mt_large_payload|--mm:orc --threads:on|"
  # codec + FFI library / runtime (FFI ones carry a distinct NimMain prefix)
  "test_api_codec|--mm:orc|"
  "test_api_library_init|-d:BrokerFfiApi --mm:orc --threads:on|apitest"
  "test_api_event_teardown_isolation|-d:BrokerFfiApi --mm:orc --threads:on|cbevt"
  "test_api_discovery|-d:BrokerFfiApi --mm:orc --threads:on|apidisc"
  "test_broker_interface_api|-d:BrokerFfiApi --mm:orc --threads:on|brokerifaceapi"
  "test_broker_interface_mt|-d:BrokerFfiApi --mm:orc --threads:on|brokerifacemt"
  "typemappingtestlib/test_typemappingtestlib|-d:BrokerFfiApi --mm:orc --threads:on|typemappingtestlib"
)

# Resolve a gcov-compatible tool. Apple's system gcov can't read clang's .gcno,
# so on macOS route through `xcrun llvm-cov gcov`.
cov_gcov_tool() {
  if [[ "$(uname)" == "Darwin" ]] && command -v xcrun >/dev/null 2>&1; then
    echo "xcrun llvm-cov gcov"
  elif command -v gcov >/dev/null 2>&1; then
    echo "gcov"
  elif command -v llvm-cov >/dev/null 2>&1; then
    echo "llvm-cov gcov"
  else
    echo "ERROR: no gcov tool found (need gcov, or llvm-cov via xcrun on macOS)" >&2
    exit 1
  fi
}

# Resolve a gcovr command into the global GCOVR. Prefers a `gcovr` on PATH;
# falls back to `python3 -m gcovr` (pip --user installs land off PATH on macOS).
cov_require_gcovr() {
  if command -v gcovr >/dev/null 2>&1; then
    GCOVR="gcovr"
  elif python3 -m gcovr --version >/dev/null 2>&1; then
    GCOVR="python3 -m gcovr"
  else
    echo "ERROR: gcovr not found. Install with: pip install --user gcovr" >&2
    exit 1
  fi
}

# Compile + run every test in COV_TESTS into per-test nimcaches under $1.
#   $1 = cache root (e.g. .cov-cache/c)
#   $2 = extra compile flags shared by every test (e.g. "--lineDir:off")
cov_build_and_run() {
  local cache="$1" extra="$2"
  for entry in "${COV_TESTS[@]}"; do
    local relpath="${entry%%|*}"
    local rest="${entry#*|}"
    local env="${rest%%|*}"
    local prefix="${rest#*|}"
    local name; name="$(basename "$relpath")"
    # Per-test nimcache under the cache root. The embedded source path is
    # root-relative; gcovr resolves it by running gcov from --root (we pass the
    # cache as a positional search path, not --gcov-object-directory — see the
    # gcovr call in coverage-c.sh / coverage-nim.sh).
    local nc="$cache/$name"
    local bin="$cache/$name.bin"
    local prefixflag=""
    [[ -n "$prefix" ]] && prefixflag="--nimMainPrefix:$prefix"
    echo "=== COVER compile $relpath ==="
    # NB: no --debugger:native here — it forces line directives on even under
    # --lineDir:off, which would steal Mode A's C-level attribution. Each mode
    # supplies its own --lineDir (and --debugger:native for Mode B) via $extra.
    # shellcheck disable=SC2086
    nim c $env $extra --cc:clang \
      --passC:"--coverage -O0 -g" --passL:--coverage --path:. \
      $prefixflag --nimcache:"$nc" --out:"$bin" "test/$relpath.nim"
    echo "=== COVER run $name ==="
    "./$bin"
  done
}
