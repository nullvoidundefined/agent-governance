#!/usr/bin/env bash
# harness-root.sh: gives every fixture in enforce/tests/ and hooks/tests/ one
# explicit, shared answer to the question "which copy of the harness am I
# actually testing?".
#
# Until 2026-09-18 the great majority of fixtures opened their subject as
# "$HOME/.claude/hooks/<name>.sh", which is the INSTALLED copy that the last
# ./sync.sh happened to write, not the checkout that the fixture file itself
# was read from. Neither fixture runner bound that location to the checkout,
# so a local pre-push run verified whichever branch was synced most recently
# while git went on to push something else entirely, and the same fixture
# passed or failed depending on that unrelated history. Continuous integration
# symlinks the checkout into the home directory, which made the drift
# invisible there and left it to bite only on a developer's machine.
#
# Sourcing this file sets CLAUDE_HARNESS_ROOT to the harness tree under test,
# resolved in this order and never from a bare $HOME:
#
#   1. an explicit CLAUDE_HARNESS_ROOT already present in the environment, so
#      that a caller can deliberately point one run at an installed tree, at a
#      sandbox copy, or at a second checkout;
#   2. otherwise the harness tree that this helper file itself lives in,
#      derived from BASH_SOURCE. Because a fixture reaches this helper through
#      a path relative to its own BASH_SOURCE, that tree is by construction
#      the checkout the fixture was read from.
#
# The single deliberate exception in the suite is enforce/tests/hook-latency.test.sh,
# which measures the installed hooks on purpose and records why in its own
# header. Every other fixture resolves through this helper.
#
# Usage, from a fixture in either enforce/tests/ or hooks/tests/ (both sit two
# directories below the harness root, so one spelling serves both):
#
#   . "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
#   HOOK="$CLAUDE_HARNESS_ROOT/hooks/secret-scan.sh"
#
# CLAUDE_HARNESS_ROOT is set but deliberately not exported: a fixture that
# spawns another fixture (the implementation-root prover does exactly that)
# must be able to let the child resolve its own root rather than inherit one.

# Resolves the harness tree a fixture should test against and prints it as an
# absolute path. Honors an explicit CLAUDE_HARNESS_ROOT override first; falls
# back to the directory above the one holding this helper, which is the
# checkout's claude/ root. Runs the directory change inside a subshell so the
# caller's working directory is never disturbed.
resolve_harness_root() {
  if [ -n "${CLAUDE_HARNESS_ROOT:-}" ]; then
    printf '%s' "$CLAUDE_HARNESS_ROOT"
    return 0
  fi
  (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
}

CLAUDE_HARNESS_ROOT="$(resolve_harness_root)"
