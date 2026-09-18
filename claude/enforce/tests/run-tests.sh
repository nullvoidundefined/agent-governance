#!/usr/bin/env bash
# Runs the enforcement fixture tests through enforce/run-fixture-shards.sh and
# fails if any does not report PASS. `--affected` runs only the fixtures the
# changed files need (the R-509 Stop gate); no argument runs all of them.
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

# Sixteen fixtures in this directory drive the ESLint rule bundle, which lives
# in enforce/node_modules. That directory is gitignored, so a fresh checkout or
# a new worktree has none, and every one of those fixtures fails at once in a
# way that reads like sixteen unrelated rules regressing rather than one
# missing install. Since PR #20 bound fixtures to the checkout they live in
# rather than to $HOME/.claude, they can no longer borrow the installed tree's
# modules either, so this became the normal first experience of a new
# worktree. A line in enforce/README.md does not help: nothing sends you there,
# because the symptom does not look like a setup problem. Reported cold by the
# session that hit it, 2026-09-18.
ENFORCE_DIR="$(cd "$DIR/.." && pwd)"
if [ -f "$ENFORCE_DIR/package.json" ] && [ ! -d "$ENFORCE_DIR/node_modules" ]; then
  echo "enforcement fixtures need this checkout's own ESLint bundle, which is not installed." >&2
  echo "run: npm ci --prefix $ENFORCE_DIR" >&2
  echo "(node_modules is gitignored, so every fresh checkout and every new worktree needs it once.)" >&2
  exit 1
fi
# The runner applies the verdict the old loop did (exit 0, a PASS line, no
# FAIL line; the 2026-09-16 audit, Testing item 4, found a fixture printing
# "FAIL: ..." lines while exiting 0 reported ok), runs the fixtures in
# parallel, and with --affected runs only what the changed files need. No
# argument means every fixture: pre-push, CI, and doctor.sh call it that way.
MODE="${1:---all}"
if bash "$DIR/../run-fixture-shards.sh" "$DIR" "$MODE"; then
  echo "ALL ENFORCEMENT TESTS PASS"
else
  echo "ENFORCEMENT TESTS FAILED"; exit 1
fi
