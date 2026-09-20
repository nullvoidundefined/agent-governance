#!/usr/bin/env bash
# Covers: hook:task-provenance-gate
#
# Verifies task-provenance-gate.sh (R-213) and the summary that reads what it
# enforces. The rule exists because a long session's task list is a flat pile
# in which work the user asked for is indistinguishable from work the session
# assigned itself, so the user cannot tell whether the original request is
# finished or whether everything since was optional.
#
# Gate invariants (a PreToolUse gate on TaskCreate):
#   1. Each of the three tags passes: [requested], [required], [self].
#   2. An untagged subject is denied.
#   3. The denial names all three tags, so the fix is in the message.
#   4. An unrecognized tag is denied rather than waved through.
#   5. A tag that is not at the start of the subject is denied, since a task
#      list is skimmed by its left edge.
#   6. Tag matching ignores case and tolerates leading whitespace.
#   7. TaskUpdate is never gated: provenance is set once, at creation.
#   8. A missing or empty subject is silent, because the tool rejects it
#      anyway and a second denial would only confuse the message.
#   9. The denial is well-formed PreToolUse JSON carrying decision "deny".
#
# Summary invariants (task-provenance.sh, reading the tracker's event log):
#  10. With every requested task completed, the summary reports DONE.
#  11. With a requested task still open, it reports NOT DONE and the count.
#  12. It counts required and self tasks separately from requested ones.
#  13. A deleted task is dropped, matching fold_task_state_log's own rule.
#  14. An empty or absent log reports that no tasks were recorded.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/task-provenance-gate.sh"
SUMMARY="$CLAUDE_HARNESS_ROOT/skills/task-start/scripts/task-provenance.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
check() { [ "$2" -eq 0 ] || { echo "FAIL: $1"; fail=1; }; }
silent() { [ -z "$1" ] && echo 0 || echo 1; }
denied() { [ "$(decision "$1")" = "deny" ] && echo 0 || echo 1; }

create() { jq -n --arg s "$1" '{hook_event_name:"PreToolUse",tool_name:"TaskCreate",tool_input:{subject:$s}}' | bash "$HOOK"; }
update() { jq -n --arg s "$1" '{hook_event_name:"PreToolUse",tool_name:"TaskUpdate",tool_input:{subject:$s,taskId:"7",status:"completed"}}' | bash "$HOOK"; }
decision() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // ""'; }
reason() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'; }

# 1. The three tags pass.
for tag in requested required self; do
  OUT=$(create "[$tag] Ship the gate")
  check "a [$tag] subject must pass, got: $(decision "$OUT") $(reason "$OUT")" "$(silent "$OUT")"
done

# 2, 3, 9. An untagged subject is denied, and the denial teaches the fix.
OUT=$(create "Ship the gate")
check "an untagged subject must be denied, got: '$(decision "$OUT")'" "$(denied "$OUT")"
check "the denial must cite R-213, got: $(reason "$OUT")" "$(reason "$OUT" | grep -q 'R-213' && echo 0 || echo 1)"
for tag in requested required self; do
  check "the denial must name [$tag], got: $(reason "$OUT")" "$(reason "$OUT" | grep -q "\[$tag\]" && echo 0 || echo 1)"
done
check "the denial must be PreToolUse JSON" "$(printf '%s' "$OUT" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' >/dev/null 2>&1 && echo 0 || echo 1)"

# 4. An unrecognized tag is denied.
OUT=$(create "[nice-to-have] Ship the gate")
check "an unrecognized tag must be denied, got: '$(decision "$OUT")'" "$(denied "$OUT")"

# 5. A tag must lead the subject.
OUT=$(create "Ship the gate [self]")
check "a trailing tag must be denied, got: '$(decision "$OUT")'" "$(denied "$OUT")"

# 6. Case and leading whitespace are tolerated.
OUT=$(create "[Requested] Ship the gate")
check "a capitalised tag must pass, got: $(reason "$OUT")" "$(silent "$OUT")"
OUT=$(create "   [self] Ship the gate")
check "leading whitespace before the tag must pass, got: $(reason "$OUT")" "$(silent "$OUT")"

# 7. TaskUpdate is never gated.
OUT=$(update "Ship the gate")
check "TaskUpdate must never be gated, got: '$(decision "$OUT")'" "$(silent "$OUT")"

# 8. No subject to judge.
OUT=$(jq -n '{hook_event_name:"PreToolUse",tool_name:"TaskCreate",tool_input:{}}' | bash "$HOOK")
check "a missing subject must be silent, got: '$(decision "$OUT")'" "$(silent "$OUT")"

# --- summary ---
LOG="$TMP/task-state.session.jsonl"
event() { # event <task_id> <subject> <status>
  jq -nc --arg t "2026-09-20T00:00:0${RANDOM:0:1}Z" --arg i "$1" --arg s "$2" --arg st "$3" \
    '{ts:$t,task_id:$i,subject:$s,status:$st,cwd:"/repo",branch:"main"}' >> "$LOG"
}

# 10. Every requested task complete.
: > "$LOG"
event 1 "[requested] Build the gate" created
event 1 "" completed
OUT=$(bash "$SUMMARY" summary "$LOG" 2>&1)
check "a completed requested task must report DONE, got: $OUT" "$(grep -q 'Original task: DONE' <<< "$OUT" && echo 0 || echo 1)"

# 11, 12. One requested task open, plus required and self work.
event 2 "[requested] Write the docs" created
event 3 "[required] Regenerate the ports" created
event 4 "[self] Tidy an unrelated hook" created
event 5 "[self] Rename a variable" completed
OUT=$(bash "$SUMMARY" summary "$LOG" 2>&1)
check "an open requested task must report NOT DONE, got: $OUT" "$(grep -q 'Original task: NOT DONE' <<< "$OUT" && echo 0 || echo 1)"
check "the summary must report 1 of 2 requested complete, got: $OUT" "$(grep -qE '1 of 2 requested' <<< "$OUT" && echo 0 || echo 1)"
check "the summary must count 1 required, got: $OUT" "$(grep -qE '1 required' <<< "$OUT" && echo 0 || echo 1)"
check "the summary must count 2 self, got: $OUT" "$(grep -qE '2 self' <<< "$OUT" && echo 0 || echo 1)"

# 13. A deleted task is dropped.
event 4 "" deleted
OUT=$(bash "$SUMMARY" summary "$LOG" 2>&1)
check "a deleted task must not be counted, got: $OUT" "$(grep -qE '1 self' <<< "$OUT" && echo 0 || echo 1)"

# 14. Nothing recorded.
: > "$LOG"
OUT=$(bash "$SUMMARY" summary "$LOG" 2>&1)
check "an empty log must say no tasks were recorded, got: $OUT" "$(grep -qi 'no tasks' <<< "$OUT" && echo 0 || echo 1)"
OUT=$(bash "$SUMMARY" summary "$TMP/absent.jsonl" 2>&1)
check "an absent log must say no tasks were recorded, got: $OUT" "$(grep -qi 'no tasks' <<< "$OUT" && echo 0 || echo 1)"

[ "$fail" -eq 0 ] || exit 1
echo "task-provenance-gate.test.sh PASS"
