#!/usr/bin/env bash
# Runs every hook and enforce fixture (claude/enforce/tests and
# claude/hooks/tests) and fails if any exits nonzero.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0
for test in "$ROOT"/enforce/tests/*.test.sh "$ROOT"/hooks/tests/*.test.sh; do
  if out=$(bash "$test" 2>&1); then
    echo "ok   $(basename "$test")"
  else
    echo "FAIL $(basename "$test")"
    printf '%s\n' "$out" | grep -E 'FAIL' | head -5
    fail=1
  fi
done
exit "$fail"
