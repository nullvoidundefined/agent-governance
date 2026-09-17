#!/usr/bin/env bash
# Verifies task-state-tracker.sh: TaskCreate/TaskUpdate events each append
# one line to ~/.claude/projects/<key>/task-state.<session-id>.jsonl
# (crash-safe, append-only live task-state tracking; fix round 1, C1),
# never block the tool call, and never touch a real HOME.
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
LOG_FILE="$KEY_DIR/task-state.$SESSION_ID.jsonl"

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
exit_code_is()  { [ "$1" -eq "$2" ]; }
line_count_is() { [ "$(wc -l < "$1" | tr -d ' ')" -eq "$2" ]; }

# line_n_field: prints field $3 (a jq filter) of line number $2 (1-based) of
# file $1. Used to build direct `[ "$(line_n_field ...)" = "x" ]` assertions
# rather than a pipe inside a check() argument.
line_n_field() {
  sed -n "${2}p" "$1" | jq -r "$3"
}

# stderr_names_tool: true when $1 (captured stderr) contains $2 (a tool
# name), by exact substring. A named wrapper because check() arguments must
# never contain a live pipe.
stderr_names_tool() {
  printf '%s' "$1" | grep -qF -- "$2"
}

# each_line_valid_json: true only if every line of file $1 parses as its
# own standalone JSON value. Used after the concurrency case to prove that
# no two processes' appends interleaved into one malformed line.
each_line_valid_json() {
  local f="$1" n i
  n=$(wc -l < "$f" | tr -d ' ')
  i=1
  while [ "$i" -le "$n" ]; do
    sed -n "${i}p" "$f" | jq -e . >/dev/null 2>&1 || return 1
    i=$((i + 1))
  done
  return 0
}

# --- Case 1: TaskCreate appends one line with the task as created ---
EXIT1=0
run_hook "$(create_payload 1 "Write the fixture" "cover the create path")" || EXIT1=$?
check "TaskCreate exits 0" exit_code_is "$EXIT1" 0
check "log file created" file_exists "$LOG_FILE"
check "exactly one line after one TaskCreate" line_count_is "$LOG_FILE" 1
check "line 1 task_id is 1" [ "$(line_n_field "$LOG_FILE" 1 '.task_id')" = "1" ]
check "line 1 subject recorded" [ "$(line_n_field "$LOG_FILE" 1 '.subject')" = "Write the fixture" ]
check "line 1 status is created" [ "$(line_n_field "$LOG_FILE" 1 '.status')" = "created" ]
check "line 1 cwd recorded" [ "$(line_n_field "$LOG_FILE" 1 '.cwd')" = "$REPO" ]
check "line 1 branch recorded" [ "$(line_n_field "$LOG_FILE" 1 '.branch')" = "feature/tracker" ]
check "line 1 has a ts" [ -n "$(line_n_field "$LOG_FILE" 1 '.ts')" ]

# --- Case 2: TaskUpdate to in_progress then completed each append a line ---
sleep 1
EXIT2=0
run_hook "$(update_payload 1 in_progress)" || EXIT2=$?
check "TaskUpdate(in_progress) exits 0" exit_code_is "$EXIT2" 0
check "two lines after one update" line_count_is "$LOG_FILE" 2
check "line 2 task_id is 1" [ "$(line_n_field "$LOG_FILE" 2 '.task_id')" = "1" ]
check "line 2 status is in_progress" [ "$(line_n_field "$LOG_FILE" 2 '.status')" = "in_progress" ]
LINE1_TS=$(line_n_field "$LOG_FILE" 1 '.ts')
LINE2_TS=$(line_n_field "$LOG_FILE" 2 '.ts')
check "line 2 ts advanced past line 1" [ "$LINE2_TS" != "$LINE1_TS" ]

sleep 1
EXIT3=0
run_hook "$(update_payload 1 completed)" || EXIT3=$?
check "TaskUpdate(completed) exits 0" exit_code_is "$EXIT3" 0
check "three lines after two updates" line_count_is "$LOG_FILE" 3
check "line 3 status is completed" [ "$(line_n_field "$LOG_FILE" 3 '.status')" = "completed" ]

# --- Case 3: a second task appends alongside the first, keyed by id ---
run_hook "$(create_payload 2 "Second task" "another fixture task")"
check "four lines after a second task's create" line_count_is "$LOG_FILE" 4
check "line 4 task_id is 2" [ "$(line_n_field "$LOG_FILE" 4 '.task_id')" = "2" ]

# --- Case 4 (fix round 1, M4): a payload with no resolvable task id exits 0,
# appends nothing, and writes exactly one stderr line naming the event ---
NO_ID_PAYLOAD=$(jq -n --arg t "$TRANSCRIPT" --arg c "$REPO" \
  '{tool_name:"TaskUpdate", transcript_path:$t, cwd:$c, tool_input:{status:"in_progress"}, tool_response:{}}')
EXIT4=0
STDERR4=$(printf '%s' "$NO_ID_PAYLOAD" | HOME="$SANDBOX" bash "$HOOK" 2>&1 1>/dev/null) || EXIT4=$?
check "missing task id exits 0" exit_code_is "$EXIT4" 0
check "missing task id appends no line" line_count_is "$LOG_FILE" 4
check "missing task id writes exactly one stderr line" [ "$(printf '%s\n' "$STDERR4" | wc -l | tr -d ' ')" -eq 1 ]
check "stderr line names the event type" stderr_names_tool "$STDERR4" "TaskUpdate"

# --- Case 5: writes never touch the real HOME ---
REAL_HOME_LOG="$HOME/.claude/projects/$KEY/task-state.$SESSION_ID.jsonl"
check "nothing was written under the real HOME" [ ! -e "$REAL_HOME_LOG" ]

# --- Case 6: the hook exits 0 on malformed stdin ---
EXIT5=0
printf 'not json at all {{{' | HOME="$SANDBOX" bash "$HOOK" || EXIT5=$?
check "hook exits 0 on malformed stdin" exit_code_is "$EXIT5" 0
check "malformed stdin appends no line" line_count_is "$LOG_FILE" 4

# --- Case 7: an unrelated tool_name is silently ignored ---
OTHER_OUT=$(jq -n --arg t "$TRANSCRIPT" --arg c "$REPO" '{tool_name:"Edit", transcript_path:$t, cwd:$c, tool_input:{}}' | HOME="$SANDBOX" bash "$HOOK")
check "no output for an unrelated tool" [ -z "$OTHER_OUT" ]
check "unrelated tool appends no line" line_count_is "$LOG_FILE" 4

# --- Case 8 (fix round 1, C1): six concurrent TaskCreate events against the
# SAME session must all survive. This is the case that lost 5 of 6 tasks
# under the old read-modify-write implementation (RED evidence in the fix
# round 1 report: a probe against the pre-fix hook recorded 1 of 6 tasks);
# an append-only log makes the race structurally impossible instead of
# merely unlikely. ---
CONCURRENT_SESSION_ID="fixture-session-concurrent"
CONCURRENT_TRANSCRIPT="$KEY_DIR/$CONCURRENT_SESSION_ID.jsonl"
printf '{}\n' > "$CONCURRENT_TRANSCRIPT"
CONCURRENT_LOG="$KEY_DIR/task-state.$CONCURRENT_SESSION_ID.jsonl"

concurrent_create_payload() {
  jq -n --arg t "$CONCURRENT_TRANSCRIPT" --arg c "$REPO" --arg id "$1" \
    '{tool_name:"TaskCreate", transcript_path:$t, cwd:$c,
      tool_input:{subject:("Concurrent task " + $id), description:"race fixture"},
      tool_response:{task:{id:$id, subject:("Concurrent task " + $id)}}}'
}

for i in t1 t2 t3 t4 t5 t6; do
  run_hook "$(concurrent_create_payload "$i")" &
done
wait

check "concurrent log has exactly 6 lines (no torn or dropped writes)" line_count_is "$CONCURRENT_LOG" 6
DISTINCT_IDS=$(jq -r '.task_id' "$CONCURRENT_LOG" | sort -u | wc -l | tr -d ' ')
check "all 6 distinct task ids recorded" [ "$DISTINCT_IDS" -eq 6 ]
check "every concurrent line parses as valid JSON (no interleaving)" each_line_valid_json "$CONCURRENT_LOG"

if [ "$fail" -eq 0 ]; then
  echo "task-state-tracker.test.sh PASS"
  exit 0
else
  echo "task-state-tracker.test.sh: FAILURES PRESENT"
  exit 1
fi
