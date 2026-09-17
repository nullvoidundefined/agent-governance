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
# If ~/.claude/global-memory/ does not exist, it creates it.
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
      if ! sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} //' "$FIRES_LOG" | grep -qFx "$SIG"; then
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
      if ! sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} //' "$MISSES_LOG" | grep -qFx "$SIG"; then
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
# Compute session commit stats and write to a temp file.
# The handoff doc author reads this file for the "Session metrics" section.

# Keyed per repo toplevel to match session-start.sh (2026-09-16 audit P3-4);
# the unkeyed filename is read as a fallback for a session whose start
# predates the keying.
REPO_KEY=$(printf '%s' "$(git rev-parse --show-toplevel 2>/dev/null)" | shasum | awk '{print $1}')
START_SHA_FILE="${TMPDIR:-/tmp}/claude-session-start-sha-$REPO_KEY"
[ -f "$START_SHA_FILE" ] || START_SHA_FILE="${TMPDIR:-/tmp}/claude-session-start-sha"
METRICS_FILE="${TMPDIR:-/tmp}/claude-session-metrics.md"

if [ -f "$START_SHA_FILE" ] && command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  START_SHA=$(cat "$START_SHA_FILE")
  CURRENT_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")

  if [ -n "$START_SHA" ] && [ -n "$CURRENT_SHA" ] && [ "$START_SHA" != "$CURRENT_SHA" ]; then
    COMMIT_COUNT=$(git rev-list --count "$START_SHA..HEAD" 2>/dev/null || echo "0")
    FILES_CHANGED=$(git diff --name-only "$START_SHA..HEAD" 2>/dev/null | sort -u | wc -l | tr -d ' ')

    # Rework commits: files changed by more than one commit in this session.
    REWORK_COUNT=0
    if [ "$COMMIT_COUNT" -gt 1 ]; then
      REWORK_COUNT=$(git log --format="" --name-only "$START_SHA..HEAD" 2>/dev/null \
        | sort | uniq -c | sort -rn \
        | awk '$1 > 1 { count++ } END { print count+0 }')
    fi

    # Velocity flag.
    if [ "$COMMIT_COUNT" -gt 80 ]; then
      FLAG="REVIEW"
    elif [ "$COMMIT_COUNT" -gt 40 ]; then
      FLAG="HIGH"
    else
      FLAG="NORMAL"
    fi

    cat > "$METRICS_FILE" <<METRICS_EOF
## Session metrics
- Commits this session: $COMMIT_COUNT
- Files changed: $FILES_CHANGED
- Rework commits (file touched by 2+ commits): $REWORK_COUNT
- Velocity flag: $FLAG
METRICS_EOF

    if [ "$FLAG" = "HIGH" ] || [ "$FLAG" = "REVIEW" ]; then
      echo "" >> "$METRICS_FILE"
      echo "**Action required:** Review prior session for rework patterns before starting new work." >> "$METRICS_FILE"
    fi
  else
    # No commits this session.
    cat > "$METRICS_FILE" <<METRICS_EOF
## Session metrics
- Commits this session: 0
- Files changed: 0
- Rework commits (file touched by 2+ commits): 0
- Velocity flag: NORMAL
METRICS_EOF
  fi
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

exit 0
