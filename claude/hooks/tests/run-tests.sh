#!/usr/bin/env bash
# Runs every hook fixture test in this directory and fails if any does not
# report PASS. Mirrors enforce/tests/run-tests.sh.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
fail=0
for t in "$DIR"/*.test.sh; do
  name=$(basename "$t")
  if out=$(bash "$t" 2>&1) && printf '%s' "$out" | grep -q "PASS"; then
    echo "ok   $name"
  else
    echo "FAIL $name"; printf '%s\n' "$out" | tail -3; fail=1
  fi
done
if [ "$fail" -eq 0 ]; then
  echo "ALL HOOK TESTS PASS"
else
  echo "HOOK TESTS FAILED"; exit 1
fi
