#!/usr/bin/env bash
# task-state-tracker.sh: PostToolUse tracker on TaskCreate/TaskUpdate. Mirrors
# task-commit-reminder.sh's stdin parsing conventions and session-end.sh's
# project-key derivation. On every TaskCreate/TaskUpdate event it appends ONE
# line to ~/.claude/projects/<project-key>/task-state.<session-id>.jsonl, a
# crash-safe, append-only event log of every task the current session has
# created or touched, so an interrupted session's task list survives and can
# be offered for resume by session-start.sh at the next session's start.
#
# Append-only, not read-modify-write (fix round 1, C1): several
# TaskCreate/TaskUpdate calls routinely fire in one tool-use block, each
# spawning its own PostToolUse hook process concurrently. A
# read-modify-write-and-replace design loses every write but the last under
# that access pattern; a probe of 6 concurrent TaskCreate events against the
# old read-modify-write implementation recorded 1 of 6 tasks. A single `>>`
# append is what this format buys instead: each event is one line, appended
# independently via O_APPEND, and a line this small (well under the
# platform's atomic-write threshold) cannot interleave with another
# process's append; the failure mode becomes "lines arrive in some order",
# never "a line is torn or lost". No lock file, no retry loop: macOS ships
# no `flock` binary (it is a `util-linux` tool), and a `mkdir`-based mutex
# with a bounded retry loop is real latency risk inside a PostToolUse hook.
#
# Line shape: {"ts":"<ISO8601 UTC>","task_id":"<id>","subject":"...",
# "status":"created|in_progress|completed|deleted","cwd":"...","branch":"..."}.
# Readers (session-start.sh's check_interrupted_tasks, session-end.sh's
# render_task_state_section, both via their own fold_task_state_log copy)
# fold the log into a snapshot: the LAST status recorded for a task id
# wins, the FIRST line recorded for a task id supplies its subject (so a
# later status-only TaskUpdate line never blanks out or overrides an
# earlier real subject), and the file-level cwd/branch are read from the
# last line that carries a non-empty value for each. A task whose last
# recorded status is "deleted" is dropped from the folded view entirely,
# since the shape does not otherwise carry that as a resting state.
#
# Advisory infrastructure: this tracker must never block a tool call. Every
# failure path degrades to a silent, unconditional exit 0; the whole body
# runs inside a `set +e` subshell (session-end.sh's write_session_snapshot
# pattern) so a jq hiccup, an unreadable transcript, or malformed stdin never
# propagates past this script. No output on the happy path: PostToolUse
# context noise has a real cost. The one exception is a payload that names a
# tracked tool but carries no resolvable task id (fix round 1, M4): that
# writes one stderr line naming the event, because a silent skip there would
# let a future payload-shape change turn the whole feature off with no
# signal anywhere.
#
# To test manually:
#   jq -nc '{tool_name:"TaskCreate",transcript_path:"/path/to/<key>/<sid>.jsonl",cwd:"/repo",tool_input:{subject:"x",description:"y"},tool_response:{task:{id:"1",subject:"x"}}}' \
#     | ~/.claude/hooks/task-state-tracker.sh
# Should append one line to ~/.claude/projects/<key>/task-state.<sid>.jsonl.

set -uo pipefail

INPUT=$(cat 2>/dev/null || true)

# main: reads the PostToolUse stdin payload, derives the project key and
# session id from transcript_path exactly as session-start.sh and
# session-end.sh do, and appends ONE JSON line describing the event to the
# session's task-state.<session-id>.jsonl log via a single `>>` redirect.
# Runs entirely under `set -euo pipefail` so any unexpected failure aborts
# this subshell cleanly instead of half-writing a line; the caller below
# turns that into an unconditional exit 0.
main() (
  set -euo pipefail

  local tool transcript_path cwd key session_id
  local task_id subject status branch now state_dir log_file line

  tool=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)
  case "$tool" in
    TaskCreate|TaskUpdate) ;;
    *) return 0 ;;
  esac

  transcript_path=$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)
  cwd=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)
  [ -n "$transcript_path" ] || return 0

  key=""
  case "$transcript_path" in
    */*) key="${transcript_path%/*}"; key="${key##*/}" ;;
  esac
  [ -n "$key" ] && [ "$key" != "." ] && [ "$key" != "/" ] || return 0

  session_id="${transcript_path##*/}"
  session_id="${session_id%.jsonl}"
  [ -n "$session_id" ] || return 0

  if [ "$tool" = "TaskCreate" ]; then
    task_id=$(printf '%s' "$INPUT" | jq -r '.tool_response.task.id // empty')
    subject=$(printf '%s' "$INPUT" | jq -r '.tool_input.subject // .tool_response.task.subject // empty')
    status="created"
  else
    task_id=$(printf '%s' "$INPUT" | jq -r '.tool_input.taskId // .tool_response.taskId // empty')
    subject=$(printf '%s' "$INPUT" | jq -r '.tool_input.subject // empty')
    status=$(printf '%s' "$INPUT" | jq -r '.tool_input.status // .tool_response.statusChange.to // empty')
    case "$status" in
      pending) status="created" ;;
    esac
  fi

  if [ -z "$task_id" ]; then
    echo "task-state-tracker: no task id in $tool payload, skipping" >&2
    return 0
  fi

  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  branch=""
  if [ -n "$cwd" ] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    branch=$(git -C "$cwd" branch --show-current 2>/dev/null || true)
  fi

  state_dir="$HOME/.claude/projects/$key"
  mkdir -p "$state_dir"
  log_file="$state_dir/task-state.$session_id.jsonl"

  line=$(jq -nc \
    --arg ts "$now" --arg tid "$task_id" --arg subject "$subject" \
    --arg status "$status" --arg cwd "$cwd" --arg branch "$branch" \
    '{ts:$ts, task_id:$tid, subject:$subject, status:$status, cwd:$cwd, branch:$branch}')

  # The atomic unit is this one `printf` under O_APPEND (fix round 1, C1):
  # the line is well under any platform's atomic-write threshold, so
  # concurrent hook processes appending to the same file interleave whole
  # lines, never partial ones.
  printf '%s\n' "$line" >> "$log_file"
  return 0
)

main || true
exit 0
