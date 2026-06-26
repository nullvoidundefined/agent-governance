#!/usr/bin/env bash
# Runs every enforcement fixture test and fails if any does not report PASS.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
fail=0
for t in "$DIR"/*.test.sh; do
  name=$(basename "$t")
  [ "$name" = "run-tests.sh" ] && continue
  if out=$(bash "$t" 2>&1) && printf '%s' "$out" | grep -q "PASS"; then
    echo "ok   $name"
  else
    echo "FAIL $name"; printf '%s\n' "$out" | tail -3; fail=1
  fi
done
if [ "$fail" -eq 0 ]; then
  echo "ALL ENFORCEMENT TESTS PASS"
else
  echo "ENFORCEMENT TESTS FAILED"; exit 1
fi
