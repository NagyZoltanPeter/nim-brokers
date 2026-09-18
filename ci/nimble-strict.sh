#!/usr/bin/env bash
#
# Run a nimble task and fail the step when the task fails — including when
# nimble itself does not say so.
#
# Some nimble releases exit 0 even though the task raised. nimble v0.22.2, the
# one shipped with Nim 2.2.10, does exactly that: a failing `nimble testApi`
# prints the assertion, prints `Error: Exception raised during nimble script
# execution`, and then exits 0. Every CI step invoking it reported success, and
# two real defects sat green in this repo's history because of it — a broken
# Rust example and a per-cycle Windows HANDLE leak. v0.18.2 (Nim 2.2.4) and
# v0.24.1 (Nim 2.2.12) both propagate correctly, so this is a nimble 0.22.x
# regression rather than anything about Nim itself.
#
# The exit code stays the primary signal. The log scan is a backstop for the
# case where it lies, and is deliberately anchored on nimble's own wording: if
# that wording ever changes this stops helping, which is why it is not the
# only check.
#
# Usage:  ci/nimble-strict.sh <task> [args...]

set -uo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <nimble-task> [args...]" >&2
  exit 2
fi

log="$(mktemp -t nimble-strict.XXXXXX)"
trap 'rm -f "$log"' EXIT

nimble "$@" 2>&1 | tee "$log"
rc="${PIPESTATUS[0]}"

if [ "$rc" -ne 0 ]; then
  exit "$rc"
fi

# Exit code said success. Confirm the log agrees.
if grep -qE "Exception raised during nimble script execution" "$log"; then
  echo "::error::nimble exited 0 but the task raised (see log above). This is" \
    "the nimble 0.22.x swallowed-failure bug; treating the step as failed."
  exit 1
fi

exit 0
