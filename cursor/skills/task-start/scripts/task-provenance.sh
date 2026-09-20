#!/usr/bin/env bash
# task-provenance.sh: the R-213 read side (IAN-199). task-provenance-gate.sh
# makes every task declare who asked for it, task-state-tracker.sh records
# that tag on each event, and this folds the resulting log into the two lines
# the user actually reads:
#
#   Original task: NOT DONE (1 of 2 requested complete)
#   Since then: 1 required, 2 self
#
# The point is the first line. A session that has been running for hours can
# otherwise only be audited by reading the whole transcript, and the question
# the user wants answered ("is the thing I asked for finished, and was the
# rest of this necessary") is exactly the one a flat task list cannot answer.
#
# Usage:
#   task-provenance.sh summary [<log-file>]
#     folds one task-state log. With no path, the most recently modified
#     task-state.*.jsonl under ~/.claude/projects/ is used, which is this
#     session's in the ordinary case.
#
# Folding follows session-start.sh's fold_task_state_log exactly, because
# disagreeing with it would report a different task list than the resume and
# handoff paths do: the LAST status recorded for a task id wins, the FIRST
# line for that id supplies the subject (a later status-only TaskUpdate never
# blanks it), a task whose last status is "deleted" is dropped entirely, and
# malformed lines are skipped rather than failing the fold.
#
# A task carrying no recognised tag counts as untagged and is reported only
# when there is at least one, so logs written before R-213 existed degrade to
# an honest count rather than being silently folded into "self".
set -uo pipefail

die() { printf 'task-provenance: %s\n' "$*" >&2; exit 1; }

# newest_task_state_log: prints the most recently modified task-state log, or
# nothing when none exists. `ls -t` rather than `find -printf`, which BSD
# find on macOS does not support.
newest_task_state_log() {
  local projects="$HOME/.claude/projects"
  [ -d "$projects" ] || return 0
  ls -t "$projects"/*/task-state.*.jsonl 2>/dev/null | head -1
}

# fold_counts <log-file>: prints four space-separated integers, the number of
# requested tasks, how many of those are completed, the number of required
# tasks, and the number of self-assigned tasks, then a fifth for untagged.
fold_counts() {
  jq -R 'try fromjson catch empty' "$1" 2>/dev/null | jq -s -r '
    def provenance:
      (. // "") | ascii_downcase | sub("^[[:space:]]+"; "")
      | if startswith("[requested]") then "requested"
        elif startswith("[required]") then "required"
        elif startswith("[self]") then "self"
        else "untagged" end;
    reduce .[] as $event ({};
      ($event.task_id // "") as $id
      | if $id == "" then .
        else
          (has($id)) as $seen
          | (.[$id] // {}) as $prior
          | . + { ($id): {
              subject: (if $seen then $prior.subject else ($event.subject // "") end),
              status: (if ($event.status // "") != "" then $event.status
                       elif $seen then $prior.status else "created" end)
            } }
        end)
    | [ to_entries[] | .value | select(.status != "deleted") ]
    | map(. + {prov: (.subject | provenance)})
    | [ (map(select(.prov == "requested")) | length),
        (map(select(.prov == "requested" and .status == "completed")) | length),
        (map(select(.prov == "required")) | length),
        (map(select(.prov == "self")) | length),
        (map(select(.prov == "untagged")) | length) ]
    | @tsv
  ' 2>/dev/null
}

cmd_summary() {
  local log="${1:-}" counts requested done required self untagged
  [ -n "$log" ] || log=$(newest_task_state_log)
  if [ -z "$log" ] || [ ! -s "$log" ]; then
    printf 'task-provenance: no tasks recorded for this session\n'
    return 0
  fi
  counts=$(fold_counts "$log")
  [ -n "$counts" ] || die "could not read the task-state log at $log"
  IFS=$'\t' read -r requested done required self untagged <<< "$counts"
  if [ "$((requested + required + self + untagged))" -eq 0 ]; then
    printf 'task-provenance: no tasks recorded for this session\n'
    return 0
  fi
  if [ "$requested" -eq 0 ]; then
    printf 'Original task: NOT TRACKED (no [requested] task was ever opened)\n'
  elif [ "$done" -eq "$requested" ]; then
    printf 'Original task: DONE (%d of %d requested complete)\n' "$done" "$requested"
  else
    printf 'Original task: NOT DONE (%d of %d requested complete)\n' "$done" "$requested"
  fi
  printf 'Since then: %d required, %d self' "$required" "$self"
  [ "$untagged" -gt 0 ] && printf ', %d untagged' "$untagged"
  printf '\n'
}

case "${1:-}" in
  summary) shift; cmd_summary "${1:-}" ;;
  *) die "usage: task-provenance.sh summary [<log-file>]" ;;
esac
