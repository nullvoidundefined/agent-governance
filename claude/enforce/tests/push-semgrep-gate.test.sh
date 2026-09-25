#!/usr/bin/env bash
# Verifies push-semgrep-gate.sh (IAN-381, B-6): on `git push` it runs the
# security rule pack in enforce/semgrep/ over every code file the outgoing
# range changes, scanning each file whole, and denies the push when the pack
# reports a finding, naming the finding's path:line and rule. It must deny
# (never pass) when Semgrep cannot be found or crashes, stay silent on a range
# that changes only non-code files, and stay silent on commands that are not a
# push. Every deny reason starts with R-109.
#
# The allow and deny cases against the real rule pack need Semgrep, resolved
# the way the hook resolves it: `semgrep` on PATH, else `uvx semgrep`.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/push-semgrep-gate.sh"
SAMPLES_DIR="$CLAUDE_HARNESS_ROOT/enforce/tests/testdata/semgrep"
unset CLAUDE_ENFORCE_BASE CLAUDE_SEMGREP_CMD

failures=0
report_failure() { echo "FAIL: $1"; failures=$((failures + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO"
cd "$REPO" || exit 1
git init -q
git switch -q -c main 2>/dev/null || git checkout -q -b main
git config user.email t@t
git config user.name t
git commit -q --allow-empty -m init
# origin/main at the initial commit, so the outgoing base resolves to it.
git update-ref refs/remotes/origin/main HEAD

PUSH_PAYLOAD=$(jq -cn --arg cwd "$REPO" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:"git push origin main"}}')
STATUS_PAYLOAD=$(jq -cn --arg cwd "$REPO" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:"git status"}}')

# Runs the hook from inside the throwaway repo with the given payload and any
# extra environment assignments, and prints its stdout.
run_hook() {
  local payload="$1"; shift
  printf '%s' "$payload" | env "$@" "$HOOK" 2>/dev/null
}

decision_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null; }
reason_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null; }

# Asserts a deny whose reason starts with R-109 and contains every further
# argument as a fixed substring.
expect_deny() {
  local label="$1" output="$2"; shift 2
  local reason
  if [ "$(decision_of "$output")" != "deny" ]; then
    report_failure "$label: expected deny; got: ${output:-<no output>}"
    return
  fi
  reason=$(reason_of "$output")
  case "$reason" in
    R-109*) ;;
    *) report_failure "$label: the deny reason must start with R-109; got: $reason" ;;
  esac
  local needle
  for needle in "$@"; do
    grep -qF -- "$needle" <<< "$reason" \
      || report_failure "$label: the deny reason must contain '$needle'; got: $reason"
  done
}

expect_silent() {
  local label="$1" output="$2"
  [ -z "$output" ] || report_failure "$label: expected no output (allow); got: $output"
}

# A Semgrep stand-in that crashes: exit 2 with unreadable output.
CRASH_STUB="$WORK/crashing-semgrep"
printf '#!/bin/sh\necho "garbage {{{ not json"\necho "Fatal: internal error" >&2\nexit 2\n' > "$CRASH_STUB"
chmod +x "$CRASH_STUB"

# 1. The #27 shape in app/core/settings.py -> deny naming path:line and rule.
mkdir -p app/core
cp "$SAMPLES_DIR/cors-unvalidated-setting_bad.py" app/core/settings.py
git add app/core/settings.py
git commit -q -m "bad cors setting"
OUT_BAD=$(run_hook "$PUSH_PAYLOAD")
expect_deny "#27 shape" "$OUT_BAD" "app/core/settings.py:16" "cors-unvalidated-setting"

# 2. The file replaced by the #45 shape -> allow.
cp "$SAMPLES_DIR/cors-unvalidated-setting_good.py" app/core/settings.py
git add app/core/settings.py
git commit -q -m "validated cors setting"
OUT_GOOD=$(run_hook "$PUSH_PAYLOAD")
expect_silent "#45 shape" "$OUT_GOOD"

# 1b. Whole-file scan: the #27 shape already sits on the base, and the range
# only appends a comment to the file. The finding's line is not an added line,
# and the push must still be denied.
cp "$SAMPLES_DIR/cors-unvalidated-setting_bad.py" app/core/settings.py
git add app/core/settings.py
git commit -q -m "bad cors setting again"
git update-ref refs/remotes/origin/main HEAD
printf '\n# Trailing note appended by the push.\n' >> app/core/settings.py
git add app/core/settings.py
git commit -q -m "touch settings without touching the finding"
OUT_WHOLE=$(run_hook "$PUSH_PAYLOAD")
expect_deny "whole-file scan of a changed file" "$OUT_WHOLE" "app/core/settings.py:16" "cors-unvalidated-setting"

# 3. No Semgrep anywhere -> deny naming how to install it. PATH carries only
# bash, git, and jq plus the system dirs, so neither semgrep nor uvx resolves.
TOOLS_DIR="$WORK/tools"
mkdir -p "$TOOLS_DIR"
ln -s "$(command -v bash)" "$TOOLS_DIR/bash"
ln -s "$(command -v git)" "$TOOLS_DIR/git"
ln -s "$(command -v jq)" "$TOOLS_DIR/jq"
BARE_PATH="$TOOLS_DIR:/usr/bin:/bin"
if PATH="$BARE_PATH" command -v semgrep >/dev/null 2>&1 || PATH="$BARE_PATH" command -v uvx >/dev/null 2>&1; then
  report_failure "precondition: semgrep or uvx still resolves on the stub PATH $BARE_PATH"
fi
OUT_MISSING=$(run_hook "$PUSH_PAYLOAD" PATH="$BARE_PATH" CLAUDE_SEMGREP_CMD="$WORK/no-such-semgrep")
expect_deny "Semgrep missing" "$OUT_MISSING" "install"

# 4. Semgrep crashes with unreadable output -> deny.
OUT_CRASH=$(run_hook "$PUSH_PAYLOAD" CLAUDE_SEMGREP_CMD="$CRASH_STUB")
expect_deny "Semgrep crash" "$OUT_CRASH"

# 5. A range changing only a .md file -> silent, and Semgrep is never run:
# the crashing stand-in is wired in, so a scan would deny.
git update-ref refs/remotes/origin/main HEAD
printf '# Notes\n' > NOTES.md
git add NOTES.md
git commit -q -m "docs only"
OUT_DOCS=$(run_hook "$PUSH_PAYLOAD" CLAUDE_SEMGREP_CMD="$CRASH_STUB")
expect_silent "non-code range" "$OUT_DOCS"

# 6. A command that is not a push -> silent, with the same crashing stand-in.
OUT_STATUS=$(run_hook "$STATUS_PAYLOAD" CLAUDE_SEMGREP_CMD="$CRASH_STUB")
expect_silent "git status" "$OUT_STATUS"

if [ "$failures" -gt 0 ]; then
  echo "push-semgrep-gate.test.sh FAIL ($failures)"
  exit 1
fi
echo "push-semgrep-gate.test.sh PASS"
