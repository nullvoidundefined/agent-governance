#!/usr/bin/env bash
# Verifies task-state-tracker.sh: TaskCreate/TaskUpdate events atomically
# rewrite ~/.claude/projects/<key>/task-state.<session-id>.json (crash-safe
# live task-state tracking), never block the tool call, and never touch a
# real HOME.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../task-state-tracker.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

KEY="task-state-fixture-project"
KEY_DIR="$SANDBOX/.claude/projects/$KEY"
mkdir -p "$KEY_DIR"
SESSION_ID="fixture-session-1"
TRANSCRIPT="$KEY_DIR/$SESSION_ID.jsonl"
printf '{}\n' > "$TRANSCRIPT"
STATE_FILE="$KEY_DIR/task-state.$SESSION_ID.json"

REPO="$SANDBOX/work-repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m seed
git -C "$REPO" checkout -q -b feature/tracker

fail=0
check() {
  local name="$1"; shift
  if "$@"; then
    echo "PASS: $name"
  else
    echo "FAIL: $name"
    fail=1
  fi
}

run_hook() {
  # $1 = JSON payload on stdin
  printf '%s' "$1" | HOME="$SANDBOX" bash "$HOOK"
}

create_payload() {
  # $1 = taskId returned by TaskCreate, $2 = subject, $3 = description
  jq -n --arg t "$TRANSCRIPT" --arg c "$REPO" --arg id "$1" --arg subj "$2" --arg desc "$3" \
    '{tool_name:"TaskCreate", transcript_path:$t, cwd:$c,
      tool_input:{subject:$subj, description:$desc, activeForm:"Working"},
      tool_response:{task:{id:$id, subject:$subj}}}'
}

update_payload() {
  # $1 = taskId, $2 = new status
  jq -n --arg t "$TRANSCRIPT" --arg c "$REPO" --arg id "$1" --arg s "$2" \
    '{tool_name:"TaskUpdate", transcript_path:$t, cwd:$c,
      tool_input:{taskId:$id, status:$s},
      tool_response:{taskId:$id, statusChange:{to:$s}, success:true, updatedFields:["status"]}}'
}

file_exists()   { [ -f "$1" ]; }
jq_true()       { jq -e "$2" "$1" >/dev/null 2>&1; }
exit_code_is()  { [ "$1" -eq "$2" ]; }

# --- Case 1: TaskCreate writes a file with the task as created ---
EXIT1=0
run_hook "$(create_payload 1 "Write the fixture" "cover the create path")" || EXIT1=$?
check "TaskCreate exits 0" exit_code_is "$EXIT1" 0
check "state file created" file_exists "$STATE_FILE"
check "state_version is 1" jq_true "$STATE_FILE" '.state_version == 1'
check "session_id recorded" jq_true "$STATE_FILE" ".session_id == \"$SESSION_ID\""
check "cwd recorded" jq_true "$STATE_FILE" ".cwd == \"$REPO\""
check "branch recorded" jq_true "$STATE_FILE" '.branch == "feature/tracker"'
check "task 1 subject recorded" jq_true "$STATE_FILE" '.tasks["1"].subject == "Write the fixture"'
check "task 1 status is created" jq_true "$STATE_FILE" '.tasks["1"].status == "created"'
check "task 1 has created_at" jq_true "$STATE_FILE" '.tasks["1"].created_at | length > 0'
check "task 1 has updated_at" jq_true "$STATE_FILE" '.tasks["1"].updated_at | length > 0'

# --- Case 2: TaskUpdate to in_progress then completed updates status/timestamps ---
CREATED_AT=$(jq -r '.tasks["1"].created_at' "$STATE_FILE")
sleep 1

EXIT2=0
run_hook "$(update_payload 1 in_progress)" || EXIT2=$?
check "TaskUpdate(in_progress) exits 0" exit_code_is "$EXIT2" 0
check "task 1 status is in_progress" jq_true "$STATE_FILE" '.tasks["1"].status == "in_progress"'
check "task 1 subject preserved across update" jq_true "$STATE_FILE" '.tasks["1"].subject == "Write the fixture"'
check "task 1 created_at unchanged" jq_true "$STATE_FILE" ".tasks[\"1\"].created_at == \"$CREATED_AT\""
IN_PROGRESS_UPDATED_AT=$(jq -r '.tasks["1"].updated_at' "$STATE_FILE")
check "task 1 updated_at advanced past created_at" [ "$IN_PROGRESS_UPDATED_AT" != "$CREATED_AT" ]

sleep 1
EXIT3=0
run_hook "$(update_payload 1 completed)" || EXIT3=$?
check "TaskUpdate(completed) exits 0" exit_code_is "$EXIT3" 0
check "task 1 status is completed" jq_true "$STATE_FILE" '.tasks["1"].status == "completed"'
check "task 1 created_at still unchanged" jq_true "$STATE_FILE" ".tasks[\"1\"].created_at == \"$CREATED_AT\""

# --- Case 3: a second task upserts alongside the first, keyed by id ---
run_hook "$(create_payload 2 "Second task" "another fixture task")"
check "task 2 present" jq_true "$STATE_FILE" '.tasks["2"].subject == "Second task"'
check "task 1 still present after task 2 create" jq_true "$STATE_FILE" '.tasks["1"].status == "completed"'

# --- Case 4: a corrupt existing state file does not crash the hook and gets
# replaced sanely (exit 0, valid JSON afterward, the new event recorded) ---
printf '{ this is not valid json' > "$STATE_FILE"
EXIT4=0
run_hook "$(update_payload 1 in_progress)" || EXIT4=$?
check "hook exits 0 against a corrupt state file" exit_code_is "$EXIT4" 0
check "state file is valid JSON after recovering from corruption" jq_true "$STATE_FILE" '.state_version == 1'
check "recovered file records the triggering event" jq_true "$STATE_FILE" '.tasks["1"].status == "in_progress"'

# --- Case 5: writes never touch the real HOME ---
REAL_HOME_STATE="$HOME/.claude/projects/$KEY/task-state.$SESSION_ID.json"
check "nothing was written under the real HOME" [ ! -e "$REAL_HOME_STATE" ]

# --- Case 6: the hook exits 0 on malformed stdin ---
EXIT5=0
printf 'not json at all {{{' | HOME="$SANDBOX" bash "$HOOK" || EXIT5=$?
check "hook exits 0 on malformed stdin" exit_code_is "$EXIT5" 0

# --- Case 7: an unrelated tool_name is silently ignored ---
OTHER_OUT=$(jq -n --arg t "$TRANSCRIPT" --arg c "$REPO" '{tool_name:"Edit", transcript_path:$t, cwd:$c, tool_input:{}}' | HOME="$SANDBOX" bash "$HOOK")
check "no output for an unrelated tool" [ -z "$OTHER_OUT" ]

if [ "$fail" -eq 0 ]; then
  echo "task-state-tracker.test.sh PASS"
  exit 0
else
  echo "task-state-tracker.test.sh: FAILURES PRESENT"
  exit 1
fi
