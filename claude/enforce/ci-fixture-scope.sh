#!/usr/bin/env bash
# ci-fixture-scope.sh: decides whether the CI fixture suites in
# .github/workflows/enforce.yml run for one event (IAN-552).
#
# Reads EVENT_NAME, IS_DRAFT, BASE_SHA and HEAD_SHA from the environment and
# runs inside the git checkout. Prints exactly one stdout line, `should_run=true`
# or `should_run=false`, and always exits 0. The answer is false only for a
# draft pull_request, or for a non-draft pull_request whose three-dot diff is
# readable, non-empty, and entirely under docs/. Every other case answers true,
# and any error answers true, so a failure runs the suites rather than skipping
# them.
set -uo pipefail

# isDocsOnlyChange: succeeds only when BASE_SHA and HEAD_SHA are non-empty, the
# diff between them succeeds and is non-empty, and every path starts with docs/.
isDocsOnlyChange() {
  [ -n "${BASE_SHA:-}" ] && [ -n "${HEAD_SHA:-}" ] || return 1
  local changedFiles
  changedFiles=$(git diff --name-only --no-renames "$BASE_SHA...$HEAD_SHA" 2>/dev/null) || return 1
  [ -n "$changedFiles" ] || return 1
  if printf '%s\n' "$changedFiles" | grep -qv '^docs/'; then
    return 1
  fi
  return 0
}

# decideShouldRun: prints the one-line decision for the current event.
decideShouldRun() {
  if [ "${EVENT_NAME:-}" != "pull_request" ]; then
    echo "should_run=true"
  elif [ "${IS_DRAFT:-}" = "true" ]; then
    echo "should_run=false"
  elif isDocsOnlyChange; then
    echo "should_run=false"
  else
    echo "should_run=true"
  fi
}

decideShouldRun
exit 0
