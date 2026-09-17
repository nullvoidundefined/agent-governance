#!/usr/bin/env bash
# task-state-tracker.sh: PostToolUse tracker on TaskCreate/TaskUpdate. Mirrors
# task-commit-reminder.sh's stdin parsing conventions and session-end.sh's
# project-key derivation and tmp-file + mv -f atomic-write pattern. On every
# TaskCreate/TaskUpdate event it atomically rewrites
# ~/.claude/projects/<project-key>/task-state.<session-id>.json, a crash-safe
# live snapshot of every task the current session has created or touched, so
# an interrupted session's task list survives and can be offered for resume
# by session-start.sh at the next session's start.
#
# File shape: {"state_version":1,"session_id":"...","cwd":"...",
# "branch":"...","updated_at":"...","tasks":{"<task id>":{"subject":"...",
# "status":"created|in_progress|completed","created_at":"...",
# "updated_at":"..."}}}. A TaskUpdate that sets status "deleted" removes the
# task from the file entirely rather than recording a fourth status value
# the shape does not carry.
#
# Advisory infrastructure: this tracker must never block a tool call. Every
# failure path degrades to a silent, unconditional exit 0; the whole body
# runs inside a `set +e` subshell (session-end.sh's write_session_snapshot
# pattern) so a jq hiccup, an unreadable transcript, or malformed stdin never
# propagates past this script. No output on the happy path: PostToolUse
# context noise has a real cost (R-... advisory hooks convention).
#
# To test manually:
#   jq -n '{tool_name:"TaskCreate",transcript_path:"/path/to/<key>/<sid>.jsonl",cwd:"/repo",tool_input:{subject:"x",description:"y"},tool_response:{task:{id:"1",subject:"x"}}}' \
#     | ~/.claude/hooks/task-state-tracker.sh
# Should write ~/.claude/projects/<key>/task-state.<sid>.json with task "1".

set -uo pipefail

INPUT=$(cat 2>/dev/null || true)

# main: reads the PostToolUse stdin payload, derives the project key and
# session id from transcript_path exactly as session-start.sh and
# session-end.sh do, upserts (or, on a "deleted" status, removes) the one
# task the event describes, and atomically rewrites the session's
# task-state.<session-id>.json file. Runs entirely under `set -euo
# pipefail` so any unexpected failure aborts this subshell cleanly instead
# of half-writing state; the caller below turns that into an unconditional
# exit 0.
main() (
  set -euo pipefail

  local tool transcript_path cwd key session_id
  local task_id subject status branch now existing tmp_file state_dir state_file delete_flag

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

  delete_flag="false"
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
      deleted) delete_flag="true" ;;
    esac
  fi
  [ -n "$task_id" ] || return 0

  state_dir="$HOME/.claude/projects/$key"
  mkdir -p "$state_dir"
  state_file="$state_dir/task-state.$session_id.json"

  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  branch=""
  if [ -n "$cwd" ] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    branch=$(git -C "$cwd" branch --show-current 2>/dev/null || true)
  fi

  # A corrupt or absent existing file degrades to an empty tasks map rather
  # than failing: the file gets replaced sanely with just this event's task.
  existing="{}"
  if [ -f "$state_file" ] && jq -e . "$state_file" >/dev/null 2>&1; then
    existing=$(jq -c '.' "$state_file")
  fi

  tmp_file=$(mktemp "$state_dir/.task-state.XXXXXX")
  jq -n \
    --arg sid "$session_id" --arg cwd "$cwd" --arg branch "$branch" --arg now "$now" \
    --arg tid "$task_id" --arg subject "$subject" --arg status "$status" \
    --argjson existing "$existing" --argjson del "$delete_flag" \
    '
    ($existing.tasks // {}) as $tasks
    | ($tasks[$tid] // {}) as $prior
    | {
        state_version: 1,
        session_id: $sid,
        cwd: $cwd,
        branch: $branch,
        updated_at: $now,
        tasks: (
          if $del then
            ($tasks | del(.[$tid]))
          else
            $tasks + {
              ($tid): {
                subject: (if $subject != "" then $subject else ($prior.subject // "") end),
                status: $status,
                created_at: ($prior.created_at // $now),
                updated_at: $now
              }
            }
          end
        )
      }
    ' > "$tmp_file"

  mv -f "$tmp_file" "$state_file"
  return 0
)

main || true
exit 0
