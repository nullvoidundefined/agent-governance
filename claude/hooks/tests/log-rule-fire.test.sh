#!/usr/bin/env bash
# Verifies log-rule-fire.sh appends pipe-delimited fire lines, honors the
# /dev/null silencer, skips the default live log for scratch repositories,
# appends the session ID field and appends the session ID field.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HELPER="$CLAUDE_HARNESS_ROOT/hooks/log-rule-fire.sh"

LOG=$(mktemp)
# Direct helper call appends one well-formed line.
( source "$HELPER"; CLAUDE_FIRE_LOG="$LOG" log_rule_fire "R-999" "test-hook" "deny" )
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\|R-999\|test-hook\|deny\|[^|]+\|-$' "$LOG" || { echo "FAIL: malformed fire line: $(cat "$LOG")"; exit 1; }

# /dev/null silencer writes nothing and errors nothing.
( source "$HELPER"; CLAUDE_FIRE_LOG=/dev/null log_rule_fire "R-999" "test-hook" "deny" )

# With CLAUDE_FIRE_LOG unset and HOME set, the fire lands in HOME's default log.
FIRE_HOME=$(mktemp -d)
# The caller runs from the harness checkout, a real repository outside any
# temporary directory.
FIRE_DEFAULT="$FIRE_HOME/.claude/telemetry/rule-fires.log"
( cd "$CLAUDE_HARNESS_ROOT"; unset CLAUDE_FIRE_LOG; HOME="$FIRE_HOME"; source "$HELPER"; log_rule_fire "R-999" "test-hook" "deny" )
grep -q '|R-999|test-hook|deny|' "$FIRE_DEFAULT" \
  || { echo "FAIL: default fire log under HOME was not written"; exit 1; }

# Session ID: CLAUDE_SESSION_ID wins, then the payload's session_id in the
# caller's INPUT, else `-`; it is the sixth field, after the repository.
( cd "$CLAUDE_HARNESS_ROOT"; unset CLAUDE_FIRE_LOG; HOME="$FIRE_HOME"; CLAUDE_SESSION_ID="sess-env"; INPUT='{"session_id":"sess-payload"}'; source "$HELPER"; log_rule_fire "R-998" "test-hook" "deny" )
( cd "$CLAUDE_HARNESS_ROOT"; unset CLAUDE_FIRE_LOG CLAUDE_SESSION_ID; HOME="$FIRE_HOME"; INPUT='{"session_id":"sess-payload"}'; source "$HELPER"; log_rule_fire "R-997" "test-hook" "deny" )
grep -qE '\|R-998\|test-hook\|deny\|[^|]+\|sess-env$' "$FIRE_DEFAULT" \
  || { echo "FAIL: CLAUDE_SESSION_ID was not the session field: $(cat "$FIRE_DEFAULT")"; exit 1; }
grep -qE '\|R-997\|test-hook\|deny\|[^|]+\|sess-payload$' "$FIRE_DEFAULT" \
  || { echo "FAIL: payload session_id was not the session field: $(cat "$FIRE_DEFAULT")"; exit 1; }

# A session ID carrying a field separator or a line break is stripped of them
# in both branches, so it can neither shift the fields nor forge a second line
# (R-109 r1 #6 on PR #182).
for forged_session_id in 'a|b' $'a\nb' $'a\r\nb'; do
  FORGED_LOG=$(mktemp)
  ( CLAUDE_FIRE_LOG="$FORGED_LOG"; CLAUDE_SESSION_ID="$forged_session_id"; source "$HELPER"; log_rule_fire "R-992" "test-hook" "deny" )
  ( CLAUDE_FIRE_LOG="$FORGED_LOG"; unset CLAUDE_SESSION_ID; INPUT=$(jq -nc --arg s "$forged_session_id" '{session_id:$s}'); source "$HELPER"; log_rule_fire "R-991" "test-hook" "deny" )
  [ "$(wc -l < "$FORGED_LOG" | tr -d ' ')" = 2 ] \
    || { echo "FAIL: a forged session ID did not yield exactly one line per fire: $(cat "$FORGED_LOG")"; exit 1; }
  if awk -F'|' 'NF != 6 || $6 != "ab" { bad = 1 } END { exit !bad }' "$FORGED_LOG"; then
    echo "FAIL: a forged session ID did not yield six fields ending in ab: $(cat -v "$FORGED_LOG")"; exit 1
  fi
  rm -f "$FORGED_LOG"
done

# Fixture runs never reach the default live log: a working directory under a
# temporary directory, or a repository that resolves to `unknown`, is skipped.
SCRATCH_REPO=$(mktemp -d)
git -C "$SCRATCH_REPO" init -q
( cd "$SCRATCH_REPO"; unset CLAUDE_FIRE_LOG; HOME="$FIRE_HOME"; source "$HELPER"; log_rule_fire "R-996" "test-hook" "deny" )
( cd /private/tmp 2>/dev/null || cd /tmp; unset CLAUDE_FIRE_LOG; HOME="$FIRE_HOME"; source "$HELPER"; log_rule_fire "R-995" "test-hook" "deny" )
( cd "$CLAUDE_HARNESS_ROOT"; unset CLAUDE_FIRE_LOG; export GIT_DIR=/nonexistent-git-dir; HOME="$FIRE_HOME"; source "$HELPER"; log_rule_fire "R-994" "test-hook" "deny" )
for scratch_rule in R-996 R-995 R-994; do
  if grep -q "|$scratch_rule|" "$FIRE_DEFAULT"; then
    echo "FAIL: scratch fire $scratch_rule reached the default live log"; exit 1
  fi
done

# An explicit CLAUDE_FIRE_LOG still records a fire from a scratch repository,
# so fixtures can assert on their own log.
SCRATCH_LOG="$SCRATCH_REPO/fire.log"
( cd "$SCRATCH_REPO"; CLAUDE_FIRE_LOG="$SCRATCH_LOG"; source "$HELPER"; log_rule_fire "R-993" "test-hook" "deny" )
grep -q '|R-993|test-hook|deny|' "$SCRATCH_LOG" \
  || { echo "FAIL: explicit fire log in a scratch repository was not written"; exit 1; }
rm -rf "$FIRE_HOME" "$SCRATCH_REPO"

# With HOME and CLAUDE_FIRE_LOG both unset there is nowhere to log, so the
# fire is skipped without aborting: under set -u the bare
# $HOME aborted the hook inside the helper, and a PreToolUse hook that prints
# nothing is an allow (IAN-356). The fixture runners export CLAUDE_FIRE_LOG,
# so both are removed explicitly.
( set -u; unset HOME CLAUDE_FIRE_LOG; source "$HELPER"; log_rule_fire "R-999" "test-hook" "deny" ) \
  || { echo "FAIL: log_rule_fire aborted with HOME and CLAUDE_FIRE_LOG unset"; exit 1; }

rm -f "$LOG"
echo "log-rule-fire.test.sh PASS"
