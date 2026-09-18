#!/usr/bin/env bash
# Runs the hook fixture tests in this directory through
# enforce/run-fixture-shards.sh and fails if any does not report PASS.
# Mirrors enforce/tests/run-tests.sh, including its `--affected` mode.
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
# The runner applies the verdict the old loop did (exit 0, a PASS line, no
# FAIL line; the 2026-09-16 audit, Testing item 4, found a fixture printing
# "FAIL: ..." lines while exiting 0 reported ok), runs the fixtures in
# parallel, and with --affected runs only what the changed files need. No
# argument means every fixture: CI and doctor.sh call it that way.
MODE="${1:---all}"
if bash "$DIR/../../enforce/run-fixture-shards.sh" "$DIR" "$MODE"; then
  echo "ALL HOOK TESTS PASS"
else
  echo "HOOK TESTS FAILED"; exit 1
fi
