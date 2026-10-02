#!/usr/bin/env bash
# Shard: fast
# ci-fixture-scope-wiring.test.sh: pins how .github/workflows/enforce.yml wires
# the fixture-scope job (enforce/ci-fixture-scope.sh) into the two fixture
# jobs, so that the suites run unless the scope job answers false (IAN-552).
#
# The fixture reads the workflow as text, because no YAML parser can be
# assumed on either runner. Each job block runs from its `  <job>:` line at
# two-space indent to the next two-space-indent key; comment lines are
# dropped before any assertion, so prose cannot satisfy or break one.
#
# Behaviours asserted:
# - `fixtures:` and `fixtures-macos:` each declare `needs: fixture-scope`.
# - Each of those jobs has exactly one `if:` line, and it contains
#   `!cancelled()`, `needs.fixture-scope.result != 'success'`, and
#   `needs.fixture-scope.outputs.should_run != 'false'`, and never compares
#   should_run with `==`, so an empty or garbled output runs the suites
#   instead of skipping them.
# - The fixture-scope job's `decide` step invokes
#   claude/enforce/ci-fixture-scope.sh on a line that redirects with
#   `>> "$GITHUB_OUTPUT"` and carries no `|`: the default Actions shell is
#   `bash -e` without pipefail, so a pipe would hide the script's failure.
# - The script path named in that step exists in the checkout.
# - The `pull_request` trigger lists `ready_for_review` among its types.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"

# CI symlinks $HOME/.claude to the checkout's claude/ dir, so the harness root
# is resolved physically before stepping to its parent (the repository root).
REPO_ROOT="$(cd -P "$CLAUDE_HARNESS_ROOT" && cd -P .. && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/enforce.yml"

failures=0

# fail_with <message>: prints one FAIL line and counts it.
fail_with() {
  echo "FAIL: $1"
  failures=$((failures + 1))
}

# extract_job_block <job>: prints the non-comment lines of one job, from its
# two-space-indent key to the next two-space-indent key.
extract_job_block() {
  awk -v key="  $1:" '
    $0 == key { inside = 1; print; next }
    inside && /^  [A-Za-z0-9_-]+:/ { exit }
    inside && /^[^ #]/ { exit }
    inside { print }
  ' "$WORKFLOW" | grep -vE '^[[:space:]]*#'
}

# extract_decide_step: prints the fixture-scope job's `decide` step, from its
# `- id: decide` line to the next step at the same indent.
extract_decide_step() {
  extract_job_block fixture-scope | awk '
    /^      - id: decide[[:space:]]*$/ { inside = 1; print; next }
    inside && /^      - / { exit }
    inside { print }
  '
}

# extract_pull_request_trigger: prints the non-comment lines of the
# `pull_request:` entry under the top-level `on:` key.
extract_pull_request_trigger() {
  awk '
    /^on:/ { on_block = 1; next }
    on_block && /^[^ #]/ { exit }
    on_block && /^  pull_request:/ { inside = 1; print; next }
    inside && /^  [A-Za-z0-9_-]+:/ { exit }
    inside { print }
  ' "$WORKFLOW" | grep -vE '^[[:space:]]*#'
}

# assert_fixture_job_wiring <job>: asserts the needs and if wiring of one
# fixture job.
assert_fixture_job_wiring() {
  local job="$1" block if_lines if_count if_line
  block="$(extract_job_block "$job")"
  if [ -z "$block" ]; then
    fail_with "$job: no '  $job:' job block found in $WORKFLOW"
    return
  fi
  if ! printf '%s\n' "$block" | grep -qE '^    needs:[[:space:]]*fixture-scope[[:space:]]*$'; then
    fail_with "$job: does not declare 'needs: fixture-scope'"
  fi
  if_lines="$(printf '%s\n' "$block" | grep -E '^    if:' || true)"
  if_count="$(printf '%s\n' "$if_lines" | grep -c . || true)"
  if [ "$if_count" != "1" ]; then
    fail_with "$job: expected exactly one job-level 'if:' line, found $if_count"
    return
  fi
  if_line="$if_lines"
  printf '%s' "$if_line" | grep -qF '!cancelled()' \
    || fail_with "$job: 'if:' lacks !cancelled(): $if_line"
  printf '%s' "$if_line" | grep -qF "needs.fixture-scope.result != 'success'" \
    || fail_with "$job: 'if:' lacks needs.fixture-scope.result != 'success': $if_line"
  printf '%s' "$if_line" | grep -qF "needs.fixture-scope.outputs.should_run != 'false'" \
    || fail_with "$job: 'if:' lacks needs.fixture-scope.outputs.should_run != 'false': $if_line"
  if printf '%s' "$if_line" | grep -qE "should_run[[:space:]]*=="; then
    fail_with "$job: 'if:' compares should_run with '==', so an empty or garbled output skips the suites: $if_line"
  fi
  if printf '%s' "$if_line" | grep -qF "== 'true'"; then
    fail_with "$job: 'if:' uses == 'true': $if_line"
  fi
}

# assert_decide_step_wiring: asserts the scope script's invocation and that
# the script it names exists.
assert_decide_step_wiring() {
  local step invoke_lines invoke_line script_path
  step="$(extract_decide_step)"
  if [ -z "$step" ]; then
    fail_with "fixture-scope: no '- id: decide' step found"
    return
  fi
  invoke_lines="$(printf '%s\n' "$step" | grep -F 'claude/enforce/ci-fixture-scope.sh' || true)"
  if [ -z "$invoke_lines" ]; then
    fail_with "fixture-scope decide: run block does not invoke claude/enforce/ci-fixture-scope.sh"
    return
  fi
  while IFS= read -r invoke_line; do
    [ -n "$invoke_line" ] || continue
    printf '%s' "$invoke_line" | grep -qF '>> "$GITHUB_OUTPUT"' \
      || fail_with "fixture-scope decide: invocation lacks a plain >> \"\$GITHUB_OUTPUT\" redirect: $invoke_line"
    if printf '%s' "$invoke_line" | grep -qF '|'; then
      fail_with "fixture-scope decide: invocation pipes the script's output, which bash -e without pipefail hides: $invoke_line"
    fi
    script_path="$(printf '%s' "$invoke_line" | grep -oE 'claude/enforce/[A-Za-z0-9._-]+\.sh' | head -n 1)"
    if [ ! -f "$REPO_ROOT/$script_path" ]; then
      fail_with "fixture-scope decide: script $script_path does not exist under $REPO_ROOT"
    fi
  done <<EOF
$invoke_lines
EOF
}

# assert_ready_for_review_trigger: asserts the pull_request trigger lists
# ready_for_review.
assert_ready_for_review_trigger() {
  local trigger
  trigger="$(extract_pull_request_trigger)"
  if [ -z "$trigger" ]; then
    fail_with "on: no pull_request trigger found"
    return
  fi
  printf '%s\n' "$trigger" | grep -qE '(^|[^A-Za-z_])ready_for_review([^A-Za-z_]|$)' \
    || fail_with "on.pull_request: types do not list ready_for_review"
}

if [ ! -f "$WORKFLOW" ]; then
  echo "FAIL: workflow not found at $WORKFLOW"
  exit 1
fi

assert_fixture_job_wiring fixtures
assert_fixture_job_wiring fixtures-macos
assert_decide_step_wiring
assert_ready_for_review_trigger

if [ "$failures" -ne 0 ]; then
  echo "ci-fixture-scope-wiring.test.sh FAIL ($failures)"
  exit 1
fi
echo "ci-fixture-scope-wiring.test.sh PASS"
