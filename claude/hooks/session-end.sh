#!/usr/bin/env bash
# session-end.sh
#
# SessionEnd hook for Claude Code. Scans per-project feedback memory
# files for lines starting with `fired:` or `miss:` (the R-603 prefix
# convention) and routes new entries into ~/.claude/global-memory/
# rule_fires.md or rule_misses.md respectively. Also writes a resume
# snapshot of the session's edited files, their content hashes, and git
# HEAD (spec B-8 write half; see write_session_snapshot below).
#
# Why this exists: R-603 in ~/.claude/CLAUDE.md says every session ends
# by routing what it learned to the surface that will use it next. The
# fire and miss logs are what closes the loop between work performed,
# mistakes made, and successes logged. Without this hook, the routing
# is honor-system and decays the moment attention lapses.
#
# How it works: on SessionEnd, scan every *.md file under
# ~/.claude/projects/*/memory/ for lines starting with `fired:` or
# `miss:`. For each match, construct a dated log entry in the format
# `YYYY-MM-DD R-NNN <context>` and append to the appropriate
# global-memory log file ONLY if the same content (ignoring the date)
# is not already present. Deduplication strips the leading date before
# comparing, so a fired:/miss: line that persists in project memory is
# not re-appended with a fresh date every session.
#
# Entries are intentionally project-agnostic. An earlier format embedded
# the sanitized cwd path (e.g. -Users-name-Desktop-...), which leaked a
# local filesystem path into the public ~/.claude repo and defeated
# date-insensitive dedupe. That field has been removed.
#
# The hook never reads or writes secret material. It reads only the
# memory files and writes only to rule_fires.md and rule_misses.md.
# If ~/.claude/global-memory/ does not exist, it creates it, and it creates
# each log with its header when the log is absent. Both logs are live-only
# and gitignored in the checkout (IAN-114): a tracked copy never matched the
# live one this hook appends to, so harness-sync.sh saw drift at every
# SessionStart and each sync overwrote the live logs.
#
# To test manually (after writing a fired: line into any memory file):
#   ~/.claude/hooks/session-end.sh
# Then cat ~/.claude/global-memory/rule_fires.md to see the appended
# entry.

set -euo pipefail

# Read the SessionEnd JSON payload once up front (B-8 write half: the
# resume snapshot below needs transcript_path and cwd from it). An empty
# or malformed payload degrades to empty fields rather than failing the
# hook: this script's whole point is to run unattended at session end.
INPUT=$(cat 2>/dev/null || true)
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
SESSION_CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)

PROJECTS_DIR="$HOME/.claude/projects"
GLOBAL_MEMORY="$HOME/.claude/global-memory"
FIRES_LOG="$GLOBAL_MEMORY/rule_fires.md"
MISSES_LOG="$GLOBAL_MEMORY/rule_misses.md"
TODAY=$(date +%Y-%m-%d)

mkdir -p "$GLOBAL_MEMORY"
touch "$FIRES_LOG" "$MISSES_LOG"

# Initialize header if the file is empty (first run).
if [ ! -s "$FIRES_LOG" ]; then
  printf '# Rule fires log\n\nAppend-only. Written by ~/.claude/hooks/session-end.sh per R-603.\nFormat: YYYY-MM-DD R-NNN <context>\n\n' > "$FIRES_LOG"
fi
if [ ! -s "$MISSES_LOG" ]; then
  printf '# Rule misses log\n\nAppend-only. Written by ~/.claude/hooks/session-end.sh per R-603.\nFormat: YYYY-MM-DD R-NNN MISS <context>; gap: <what the rule would need to catch this>\n\n' > "$MISSES_LOG"
fi

# Nothing to scan if there are no project memory directories yet.
if [ ! -d "$PROJECTS_DIR" ]; then
  exit 0
fi

# Iterate every memory file under every project.
find "$PROJECTS_DIR" -type d -name memory 2>/dev/null | while IFS= read -r MEM_DIR; do
  # Find memory files and scan them. Use || true after greps so that
  # no-match (exit 1) does not fail under set -euo pipefail.
  find "$MEM_DIR" -maxdepth 2 -type f -name '*.md' 2>/dev/null | while IFS= read -r MEM_FILE; do
    # Process fired: lines.
    (grep -E '^fired: R-[0-9]{3} ' "$MEM_FILE" 2>/dev/null || true) | while IFS= read -r LINE; do
      [ -z "$LINE" ] && continue
      CONTENT="${LINE#fired: }"
      RULE="${CONTENT%% *}"
      CTX="${CONTENT#* }"
      SIG="$RULE $CTX"
      # Dedupe by content, ignoring the leading date, so the same
      # fired: line is not re-appended with a fresh date each session.
      # Process substitution, not a pipe: under pipefail, grep -q exiting at
      # an early match kills sed with SIGPIPE once the log passes 64KB, and
      # the match would read as a miss and re-append the line (IAN-120).
      if ! grep -qFx "$SIG" < <(sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} //' "$FIRES_LOG"); then
        printf '%s %s\n' "$TODAY" "$SIG" >> "$FIRES_LOG"
      fi
    done

    # Process miss: lines.
    (grep -E '^miss: R-[0-9]{3} ' "$MEM_FILE" 2>/dev/null || true) | while IFS= read -r LINE; do
      [ -z "$LINE" ] && continue
      CONTENT="${LINE#miss: }"
      RULE="${CONTENT%% *}"
      CTX="${CONTENT#* }"
      SIG="$RULE MISS $CTX"
      # Dedupe by content, ignoring the leading date (see fires block).
      if ! grep -qFx "$SIG" < <(sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} //' "$MISSES_LOG"); then
        printf '%s %s\n' "$TODAY" "$SIG" >> "$MISSES_LOG"
      fi
    done
  done
done

# Mechanical fire rollup (2026-07-31 criticism audit P0: the fire log only
# ever received hand-typed entries, so it recorded nothing while enforcement
# grew). Hooks append raw fires to telemetry/rule-fires.log via
# log-rule-fire.sh; this block rolls new lines up into rule_fires.md as one
# counted entry per rule+decision and advances a line-count high-water mark.
FIRE_LOG="$HOME/.claude/telemetry/rule-fires.log"
FIRE_OFFSET_FILE="$HOME/.claude/telemetry/rule-fires.rollup-offset"
if [ -f "$FIRE_LOG" ]; then
  TOTAL_LINES=$(wc -l < "$FIRE_LOG" | tr -d ' ')
  LAST_OFFSET=$(cat "$FIRE_OFFSET_FILE" 2>/dev/null || echo 0)
  case "$LAST_OFFSET" in ''|*[!0-9]*) LAST_OFFSET=0 ;; esac
  if [ "$TOTAL_LINES" -gt "$LAST_OFFSET" ]; then
    tail -n "+$((LAST_OFFSET + 1))" "$FIRE_LOG" \
      | awk -F'|' '{ key = $2 " " $4; count[key]++ } END { for (k in count) print k, count[k] }' \
      | while IFS=' ' read -r fired_rule decision fire_count; do
          [ -z "$fired_rule" ] && continue
          printf '%s %s (auto-rollup: %s %s fire(s) this session)\n' "$TODAY" "$fired_rule" "$fire_count" "$decision" >> "$FIRES_LOG"
        done
    printf '%s\n' "$TOTAL_LINES" > "$FIRE_OFFSET_FILE"
  fi
fi

# Velocity metrics (R-602)
# The four numbers are computed by hooks/session-metrics.sh (2026-09-17 skills
# audit, S-12), which the task-cleanup handoff step also calls on demand so the
# handoff carries live numbers rather than the previous session's; this hook
# still writes the block to a temp file for anything that read it before.
METRICS_FILE="${TMPDIR:-/tmp}/claude-session-metrics.md"
METRICS_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/session-metrics.sh"
if [ -f "$METRICS_SCRIPT" ] && command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  bash "$METRICS_SCRIPT" > "$METRICS_FILE" 2>/dev/null || true
fi

# Resume snapshot writer (B-8 write half). Records the edited files, their
# content hashes, and git HEAD at session end, so a future SessionStart can
# warn on resume when the working tree has drifted since (spec B-8). The
# whole function runs in a `set +e` subshell: a snapshot is advisory
# infrastructure, never load-bearing, so any failure inside it (missing
# transcript, unreadable file, jq hiccup) degrades to a stderr note and the
# hook still exits 0. Failures here must never abort session end.
#
# <key> reuses the project directory the transcript already lives under
# (~/.claude/projects/<key>/<session-id>.jsonl): this script has no other
# project-key derivation to reuse, so the transcript path's parent
# directory name IS the fallback per the task brief.
write_session_snapshot() (
  set +e
  local transcript_path="$1" project_dir="$2"
  local key snapshot_dir total_lines valid_lines files git_head files_json fp digest hashval tmp_file

  if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
    echo "session-end: snapshot skipped: no readable transcript_path" >&2
    return 1
  fi

  key=$(basename "$(dirname "$transcript_path")" 2>/dev/null)
  if [ -z "$key" ] || [ "$key" = "." ] || [ "$key" = "/" ]; then
    echo "session-end: snapshot skipped: could not derive a project key" >&2
    return 1
  fi

  # A transcript that fails to parse as JSON on every line is corrupt, not
  # merely quiet; write no snapshot rather than an empty or misleading one.
  # A transcript with valid lines but zero Write/Edit/NotebookEdit entries
  # is a legitimate no-edits session and still gets a snapshot.
  total_lines=$(wc -l < "$transcript_path" 2>/dev/null | tr -d ' ')
  valid_lines=$(jq -R -r 'try (fromjson | "1") catch empty' "$transcript_path" 2>/dev/null | wc -l | tr -d ' ')
  if [ "${total_lines:-0}" -gt 0 ] && [ "${valid_lines:-0}" -eq 0 ]; then
    echo "session-end: snapshot skipped: transcript did not parse as JSONL" >&2
    return 1
  fi

  files=$(jq -R -r '
    try fromjson catch empty
    | select(.message.content? != null)
    | .message.content[]?
    | select(.type=="tool_use" and (.name=="Write" or .name=="Edit" or .name=="NotebookEdit"))
    | .input.file_path // empty
  ' "$transcript_path" 2>/dev/null | sort -u)

  git_head="none"
  if [ -n "$project_dir" ] && git -C "$project_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_head=$(git -C "$project_dir" rev-parse HEAD 2>/dev/null || echo none)
    [ -n "$git_head" ] || git_head="none"
  fi

  files_json="{}"
  while IFS= read -r fp; do
    [ -z "$fp" ] && continue
    hashval="missing"
    if [ -f "$fp" ]; then
      digest=$(shasum -a 256 "$fp" 2>/dev/null | awk '{print $1}')
      [ -n "$digest" ] && hashval="sha256:$digest"
    fi
    files_json=$(printf '%s' "$files_json" | jq -c --arg k "$fp" --arg v "$hashval" '. + {($k): $v}' 2>/dev/null)
    [ -n "$files_json" ] || files_json="{}"
  done <<< "$files"

  snapshot_dir="$PROJECTS_DIR/$key"
  mkdir -p "$snapshot_dir" 2>/dev/null
  if [ ! -d "$snapshot_dir" ]; then
    echo "session-end: snapshot skipped: could not create $snapshot_dir" >&2
    return 1
  fi

  tmp_file=$(mktemp "$snapshot_dir/.session-snapshot.json.XXXXXX" 2>/dev/null)
  if [ -z "$tmp_file" ]; then
    echo "session-end: snapshot skipped: could not create a temp file" >&2
    return 1
  fi

  if jq -n --arg head "$git_head" --argjson files "$files_json" \
      '{snapshot_version: 1, git_head: $head, files: $files}' > "$tmp_file" 2>/dev/null; then
    mv -f "$tmp_file" "$snapshot_dir/session-snapshot.json" 2>/dev/null
    if [ -f "$snapshot_dir/session-snapshot.json" ]; then
      return 0
    fi
    echo "session-end: snapshot skipped: atomic rename into place failed" >&2
    rm -f "$tmp_file" 2>/dev/null
    return 1
  fi
  echo "session-end: snapshot skipped: jq failed to assemble the snapshot" >&2
  rm -f "$tmp_file" 2>/dev/null
  return 1
)

write_session_snapshot "$TRANSCRIPT_PATH" "$SESSION_CWD" || true

# fold_task_state_log mirrors session-start.sh's function of the same
# name (duplicated rather than shared: standalone hook scripts in this
# repo do not source one another). Reads a task-state-tracker.sh
# append-only event log (one JSON object per line: ts, task_id, subject,
# status, cwd, branch) and folds it into a single snapshot object: {cwd,
# branch, updated_at, tasks: {<id>: {subject, status, created_at,
# updated_at}}}. The LAST status recorded for a task id wins, the FIRST
# line recorded for a task id supplies its subject (fix round 1, M2 falls
# back to a placeholder only when even that first line's subject was
# empty), file-level cwd/branch come from the last line that carries a
# non-empty value for each, and a task whose last recorded status is
# "deleted" is dropped from the tasks map entirely. Malformed lines are
# skipped rather than failing the fold; prints nothing on total jq
# failure, which the caller uses as the unreadable-file signal.
#
# As in session-start.sh, this answers "what did the log record" and not
# "could the log be read at all": a wholly malformed file folds to an empty
# tasks map that is indistinguishable from an honestly empty one, so the
# caller must consult task_state_log_is_parseable below first.
fold_task_state_log() {
  local file="$1"
  jq -R 'try fromjson catch empty' "$file" 2>/dev/null | jq -s '
    def foldTasks:
      reduce .[] as $e ({};
        ($e.task_id // "") as $tid
        | if $tid == "" then .
          else
            (has($tid)) as $seen
            | (.[$tid] // {}) as $prior
            | . + { ($tid): {
                subject: (if $seen then $prior.subject else ($e.subject // "") end),
                status: (if ($e.status // "") != "" then $e.status elif $seen then $prior.status else "created" end),
                created_at: (if $seen then $prior.created_at else ($e.ts // "") end),
                updated_at: ($e.ts // (if $seen then $prior.updated_at else "" end))
              } }
          end
      );
    {
      cwd: (reduce .[] as $e (""; if ($e.cwd // "") != "" then $e.cwd else . end)),
      branch: (reduce .[] as $e (""; if ($e.branch // "") != "" then $e.branch else . end)),
      updated_at: (if length > 0 then (.[-1].ts // "") else "" end),
      tasks: (foldTasks | with_entries(select(.value.status != "deleted")))
    }
  ' 2>/dev/null
}

# task_state_log_is_parseable mirrors session-start.sh's function of the
# same name (duplicated for the same reason the fold is: standalone hook
# scripts in this repo do not source one another). It reports whether a
# folded reading of task-state log $1 can be trusted as a complete account
# of what the tracker recorded, which is the question render_task_state_section
# must answer before it is entitled to treat an empty tasks map as "this
# session finished everything" and delete the log. A file holding no
# non-blank line is parseable, since an empty log honestly records zero
# events. A file holding at least one non-blank line from which jq recovers
# no JSON value at all is not, and neither is an unreadable file; both are
# reported false so the caller skips the file and leaves it on disk. The
# log is the session's ONLY durable task state, so deleting it on the
# strength of a reading that failed is the worst available outcome (PR #14
# review).
task_state_log_is_parseable() {
  local file="$1" content_lines parsed_values
  [ -r "$file" ] || return 1
  content_lines=$(grep -c '[^[:space:]]' "$file" 2>/dev/null || true)
  [ -n "$content_lines" ] || content_lines=0
  [ "$content_lines" -gt 0 ] || return 0
  parsed_values=$(jq -R 'try fromjson catch empty' "$file" 2>/dev/null | jq -s 'length' 2>/dev/null)
  [ -n "$parsed_values" ] || return 1
  [ "$parsed_values" -gt 0 ]
}

# render_task_state_section renders the CURRENT session's live task-state
# tracker (task-state-tracker.sh's append-only
# ~/.claude/projects/<key>/task-state.<session-id>.jsonl event log; fix
# round 1, C1), folded via fold_task_state_log above, into a
# marker-delimited "## Task state" section of
# docs/session-handoff/session-handoff.md under the session cwd's repo,
# but only when that handoff file already exists: the handoff is
# repo-owned, and this hook must never create one on a repo that does not
# keep one. The rendered section is wrapped in <!-- task-state:begin -->
# / <!-- task-state:end --> marker lines (fix round 1, I2); any
# pre-existing marked region is replaced by matching those literal marker
# lines only, never a "## " heading, so a handoff that quotes an example
# "## Task state" block inside a fenced code section is left
# byte-identical. Every task is rendered, not only the incomplete ones,
# each with its task id (fix round 1, M1): this section is a session-end
# summary of everything the tracker recorded, unlike session-start.sh's
# interrupted-task offering, which surfaces only non-completed work from a
# DIFFERENT session. Once every task in the log is completed, the log
# itself is deleted (independent of whether a handoff file existed to
# render into); otherwise it is left for the next session-start to offer
# as interrupted work. Runs in a `set +e` subshell (same posture as
# write_session_snapshot): an unreadable log, or any write failure, is
# skipped with a stderr note and never fails session end.
render_task_state_section() (
  set +e
  local transcript_path="$1" session_cwd="$2"
  local key session_id log_file handoff_file handoff_dir tmp_file body section all_completed folded

  if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
    return 0
  fi

  key=$(basename "$(dirname "$transcript_path")" 2>/dev/null)
  session_id=$(basename "$transcript_path" 2>/dev/null)
  session_id="${session_id%.jsonl}"
  if [ -z "$key" ] || [ "$key" = "." ] || [ "$key" = "/" ] || [ -z "$session_id" ]; then
    return 0
  fi

  log_file="$PROJECTS_DIR/$key/task-state.$session_id.jsonl"
  [ -f "$log_file" ] || return 0

  # A non-empty log nothing can be parsed out of is corrupt, not finished:
  # nothing is rendered and, crucially, nothing is deleted (PR #14 review).
  if ! task_state_log_is_parseable "$log_file"; then
    echo "session-end: task-state render skipped: unparseable state file $log_file" >&2
    return 0
  fi

  folded=$(fold_task_state_log "$log_file")
  if [ -z "$folded" ]; then
    echo "session-end: task-state render skipped: unreadable state file $log_file" >&2
    return 0
  fi

  all_completed=$(printf '%s' "$folded" | jq -r '[.tasks // {} | to_entries[] | select(.value.status != "completed")] | length == 0' 2>/dev/null)

  # render_succeeded tracks whether the completed state actually reached a
  # durable artifact. Pruning the log is only safe once it has: a failed
  # mktemp or a failed mv leaves the handoff untouched, and deleting the log
  # anyway would destroy the session's only record of the work (PR #14
  # review). A repo with no handoff file has no artifact to reach and never
  # will, so that case prunes as before rather than accumulating logs forever.
  render_succeeded="true"

  if [ -n "$session_cwd" ]; then
    handoff_file="$session_cwd/docs/session-handoff/session-handoff.md"
    if [ -f "$handoff_file" ]; then
      render_succeeded="false"
      body=$(printf '%s' "$folded" | jq -r '
        .tasks // {}
        | to_entries
        | sort_by(.value.created_at // "")
        | .[]
        | "- [" + .value.status + "] " + (if (.value.subject // "") == "" then "(unknown subject: " + .key + ")" else .value.subject end) + " (task " + .key + ") (updated " + .value.updated_at + ")"
      ' 2>/dev/null)

      section=$'<!-- task-state:begin -->\n## Task state\n\n'
      if [ -n "$body" ]; then
        section+="$body"$'\n'
      else
        section+="(no tasks recorded)"$'\n'
      fi
      section+=$'<!-- task-state:end -->\n'

      handoff_dir=$(dirname "$handoff_file")
      tmp_file=$(mktemp "$handoff_dir/.session-handoff.md.XXXXXX" 2>/dev/null)
      if [ -n "$tmp_file" ]; then
        # Marker-delimited replace (fix round 1, I2): matches only the
        # literal <!-- task-state:begin/end --> lines, so a fenced code
        # block quoting an example "## Task state" heading is never
        # touched. No markers present -> nothing is stripped, and the
        # fresh marked block is simply appended.
        awk '
          BEGIN { skipping = 0 }
          /^<!-- task-state:begin -->[[:space:]]*$/ { skipping = 1; next }
          /^<!-- task-state:end -->[[:space:]]*$/ { if (skipping) { skipping = 0; next } }
          skipping { next }
          { print }
        ' "$handoff_file" > "$tmp_file"

        printf '\n%s' "$section" >> "$tmp_file"
        if mv -f "$tmp_file" "$handoff_file" 2>/dev/null; then
          render_succeeded="true"
        else
          rm -f "$tmp_file" 2>/dev/null
        fi
      fi
    fi
  fi

  if [ "$all_completed" = "true" ] && [ "$render_succeeded" = "true" ]; then
    rm -f "$log_file" 2>/dev/null
  fi
  return 0
)

render_task_state_section "$TRANSCRIPT_PATH" "$SESSION_CWD" || true

exit 0
