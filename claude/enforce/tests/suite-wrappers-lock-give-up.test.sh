#!/usr/bin/env bash
# Verifies that both fixture-suite wrappers, enforce/tests/run-tests.sh and
# hooks/tests/run-tests.sh, pass the runner's exit 75 through (IAN-351). The
# runner exits 75 when its wait for the machine-wide run lock reaches the cap;
# the R-509 Stop gate calls the wrappers, not the runner, and skips its retry
# only on a 75, so a wrapper that flattened 75 to 1 would send the gate into a
# second full wait past the Stop hook's 660-second budget. A plain fixture
# failure must still exit 1.
#
# Each real wrapper is copied into a sandbox tree beside a stub runner, so the
# wrapper runs unchanged against a runner whose exit status the case chooses.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../harness-root.sh"

fail=0
check() {
  local name="$1"; shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/suite-wrappers-lock-give-up.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT
WRAPPER_TREE="$SANDBOX/claude"
mkdir -p "$WRAPPER_TREE/enforce/tests" "$WRAPPER_TREE/hooks/tests"
cp "$CLAUDE_HARNESS_ROOT/enforce/tests/run-tests.sh" "$WRAPPER_TREE/enforce/tests/run-tests.sh"
cp "$CLAUDE_HARNESS_ROOT/hooks/tests/run-tests.sh" "$WRAPPER_TREE/hooks/tests/run-tests.sh"

# wrapper_status <suite> <runner exit status>: runs that suite's wrapper
# against a stub runner exiting with the status, and prints the wrapper's own.
wrapper_status() {
  printf 'exit %s\n' "$2" > "$WRAPPER_TREE/enforce/run-fixture-shards.sh"
  bash "$WRAPPER_TREE/$1/tests/run-tests.sh" --affected > /dev/null 2>&1
  echo "$?"
}

check "the enforce suite wrapper passes the runner's 75 through" test "$(wrapper_status enforce 75)" -eq 75
check "the hook suite wrapper passes the runner's 75 through" test "$(wrapper_status hooks 75)" -eq 75
check "the enforce suite wrapper still exits 1 on a fixture failure" test "$(wrapper_status enforce 1)" -eq 1
check "the hook suite wrapper still exits 1 on a fixture failure" test "$(wrapper_status hooks 1)" -eq 1
check "the enforce suite wrapper still exits 0 on a pass" test "$(wrapper_status enforce 0)" -eq 0
check "the hook suite wrapper still exits 0 on a pass" test "$(wrapper_status hooks 0)" -eq 0

if [ "$fail" -eq 0 ]; then echo "suite-wrappers-lock-give-up: PASS"; else echo "suite-wrappers-lock-give-up: FAIL"; exit 1; fi
