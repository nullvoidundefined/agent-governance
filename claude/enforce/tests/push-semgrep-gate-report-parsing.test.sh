#!/usr/bin/env bash
# Verifies the B-6e fail-closed parsing of push-semgrep-gate.sh (IAN-381). The
# gate reads Semgrep's JSON report with jq in two places: the incomplete-scan
# listing (errors and skipped paths) and the findings report. A jq failure in
# either place must deny the push with an R-109 reason, never read as a clean
# scan. Each case replaces Semgrep with a stub (CLAUDE_SEMGREP_CMD) that prints
# a hand-written JSON report and exits with a chosen status, so only that JSON
# decides the outcome. The pushed file is always a clean app/x.py, so the
# gate's local parse check passes.
#
# Each case builds its own throwaway repository under one mktemp directory,
# and the hook runs with HOME pointed at a scratch directory that holds no
# exempt list, so a developer's real ~/.claude/enforce/exempt-repos.txt cannot
# change the outcome.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/push-semgrep-gate.sh"
unset CLAUDE_ENFORCE_BASE CLAUDE_SEMGREP_CMD

failures=0
report_failure() { echo "FAIL: $1"; failures=$((failures + 1)); }
report_ok() { echo "ok: $1"; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PLAIN_HOME="$WORK/home-plain"
mkdir -p "$PLAIN_HOME"

CLEAN_SOURCE="$WORK/clean.py"
printf 'VALUE = 1\n' > "$CLEAN_SOURCE"

# make_repo <dir> <branch>: a fresh repository on <branch> with one empty
# commit, and origin/main pinned to that commit so the outgoing base resolves.
make_repo() {
  local dir="$1" branch="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" symbolic-ref HEAD "refs/heads/$branch"
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" update-ref refs/remotes/origin/main HEAD
}

# commit_file <repo> <path> <source file>: copies <source file> to <path>
# inside <repo> and commits it.
commit_file() {
  local repo="$1" path="$2" source="$3"
  mkdir -p "$(dirname "$repo/$path")"
  cp "$source" "$repo/$path"
  git -C "$repo" add "$path"
  git -C "$repo" commit -q -m "add $path"
}

push_payload() {
  jq -cn --arg cwd "$1" --arg cmd "git push origin $2" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd}}'
}

# run_hook <repo> <branch> [VAR=value ...]: runs the hook from inside <repo>
# on a push payload, with HOME at the plain scratch home, and prints its stdout.
run_hook() {
  local repo="$1" branch="$2"; shift 2
  (cd "$repo" && push_payload "$repo" "$branch" | env HOME="$PLAIN_HOME" "$@" "$HOOK" 2>/dev/null)
}

decision_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null; }
reason_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null; }

# expect_deny <label> <output>: asserts a deny whose reason contains R-109.
expect_deny() {
  local label="$1" output="$2" reason
  if [ "$(decision_of "$output")" != "deny" ]; then
    report_failure "$label: expected permissionDecision deny; got: ${output:-<no output (allow)>}"
    return
  fi
  reason=$(reason_of "$output")
  if grep -qF -- "R-109" <<< "$reason"; then
    report_ok "$label"
  else
    report_failure "$label: the deny reason must contain R-109; got: $reason"
  fi
}

expect_silent() {
  local label="$1" output="$2"
  if [ -n "$output" ]; then
    report_failure "$label: expected no output (allow); got: $output"
  else
    report_ok "$label"
  fi
}

# make_stub <name> <exit status> <json file>: writes an executable Semgrep
# stub under $WORK that ignores its arguments, prints <json file>, and exits
# with <exit status>. Prints the stub's path.
make_stub() {
  local name="$1" status="$2" json_file="$3" stub_path="$WORK/stub-$1"
  printf '#!/bin/sh\ncat "%s"\nexit %s\n' "$json_file" "$status" > "$stub_path"
  chmod +x "$stub_path"
  printf '%s' "$stub_path"
}

# run_case <name> <exit status> <json>: builds a repository whose push adds
# the clean app/x.py, runs the hook with a stub printing <json>, and prints
# the hook's stdout.
run_case() {
  local name="$1" status="$2" json="$3" repo="$WORK/repo-$1" json_file="$WORK/report-$1.json" stub_path
  printf '%s\n' "$json" > "$json_file"
  stub_path=$(make_stub "$name" "$status" "$json_file")
  make_repo "$repo" main
  commit_file "$repo" app/x.py "$CLEAN_SOURCE"
  run_hook "$repo" main CLAUDE_SEMGREP_CMD="$stub_path"
}

# 1. .errors has the wrong type, so iterating it fails inside jq. The gate
# must deny rather than read the empty listing as a complete scan.
OUT_ERRORS=$(run_case errors-wrong-type 0 \
  '{"results": [], "errors": "not-an-array", "paths": {"scanned": []}}')
expect_deny "1 .errors is not an array" "$OUT_ERRORS"

# 2. .paths.skipped has the wrong type, so iterating it fails inside jq.
OUT_SKIPPED=$(run_case skipped-wrong-type 0 \
  '{"results": [], "errors": [], "paths": {"scanned": [], "skipped": "not-an-array"}}')
expect_deny "2 .paths.skipped is not an array" "$OUT_SKIPPED"

# 3. A result with no .start and no .check_id, reported with Semgrep's
# findings exit status 1. Formatting the finding fails inside jq, and the
# gate must deny rather than allow a push Semgrep said had findings.
OUT_MALFORMED=$(run_case malformed-result 1 \
  '{"results": [{"path": "app/x.py"}], "errors": [], "paths": {"scanned": ["app/x.py"]}}')
expect_deny "3 result missing .start and .check_id, exit 1" "$OUT_MALFORMED"

# 4. Control: a well-formed clean report with exit 0 on the clean file. The
# gate must stay silent, which proves the stub path and the parse check pass.
OUT_CLEAN=$(run_case clean-control 0 \
  '{"results": [], "errors": [], "paths": {"scanned": ["app/x.py"]}}')
expect_silent "4 control: well-formed clean report" "$OUT_CLEAN"

if [ "$failures" -gt 0 ]; then
  echo "push-semgrep-gate-report-parsing.test.sh FAIL ($failures)"
  exit 1
fi
echo "push-semgrep-gate-report-parsing.test.sh PASS"
