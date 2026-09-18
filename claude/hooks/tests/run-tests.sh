#!/usr/bin/env bash
# Runs every hook fixture test in this directory and fails if any does not
# report PASS. Mirrors enforce/tests/run-tests.sh.
set -uo pipefail
# Fixture fires are not telemetry: silence the rule-fire log for the run.
export CLAUDE_FIRE_LOG=/dev/null
# When this suite runs as a pre-push hook fired from a linked worktree, git
# sets GIT_DIR (and friends) in the hook's environment pointing at the real
# repo. Every fixture below builds its own throwaway repo with `git -C
# "$sandbox" init`/`config`, but `-C` loses to an inherited GIT_DIR: git
# targets GIT_DIR instead of the `-C` path, silently reconfiguring the real
# repo a fixture only meant to touch its own sandbox (2026-09-16, confirmed
# by direct reproduction after a real push from a worktree left this repo's
# own .git/config with core.bare=true and a fixture's dummy git identity).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
DIR="$(cd "$(dirname "$0")" && pwd)"
fail=0
for t in "$DIR"/*.test.sh; do
  name=$(basename "$t")
  # Require PASS and reject any FAIL line: a fixture printing per-case
  # "FAIL: ..." lines while exiting 0 was reported ok by the old grep
  # (2026-09-16 audit, Testing item 4).
  if out=$(bash "$t" 2>&1) && grep -q "PASS" <<< "$out" && ! grep -q "FAIL" <<< "$out"; then
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
