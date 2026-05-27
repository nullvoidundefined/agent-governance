#!/usr/bin/env bash
# session-end.sh
#
# SessionEnd hook for Claude Code. Scans per-project feedback memory
# files for lines starting with `fired:` or `miss:` (the R-305 prefix
# convention) and routes new entries into ~/.claude/global-memory/
# rule_fires.md or rule_misses.md respectively.
#
# Why this exists: R-305 in ~/.claude/CLAUDE.md says every session ends
# by routing what it learned to the surface that will use it next. The
# fire and miss logs are what closes the loop between work performed,
# mistakes made, and successes logged. Without this hook, the routing
# is honor-system and decays the moment attention lapses.
#
# How it works: on SessionEnd, scan every *.md file under
# ~/.claude/projects/*/memory/ for lines starting with `fired:` or
# `miss:`. For each match, construct a dated log entry in the format
# `YYYY-MM-DD R-NNN <project> <context>` and append to the appropriate
# global-memory log file ONLY if that exact line is not already present.
# Deduplication is by full-line content; the same entry can be emitted
# repeatedly by the session writer without creating duplicate log rows.
#
# Project identification: the memory directory path under
# ~/.claude/projects/<sanitized-cwd>/memory/ encodes the project. The
# hook extracts the sanitized-cwd segment and uses it as the project
# field in the log entry.
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

PROJECTS_DIR="$HOME/.claude/projects"
GLOBAL_MEMORY="$HOME/.claude/global-memory"
FIRES_LOG="$GLOBAL_MEMORY/rule_fires.md"
MISSES_LOG="$GLOBAL_MEMORY/rule_misses.md"
TODAY=$(date +%Y-%m-%d)

mkdir -p "$GLOBAL_MEMORY"
touch "$FIRES_LOG" "$MISSES_LOG"

# Initialize header if the file is empty (first run).
if [ ! -s "$FIRES_LOG" ]; then
  printf '# Rule fires log\n\nAppend-only. Written by ~/.claude/hooks/session-end.sh per R-305.\nFormat: YYYY-MM-DD R-NNN <project> <context>\n\n' > "$FIRES_LOG"
fi
if [ ! -s "$MISSES_LOG" ]; then
  printf '# Rule misses log\n\nAppend-only. Written by ~/.claude/hooks/session-end.sh per R-305.\nFormat: YYYY-MM-DD R-NNN <project> MISS <context>; gap: <what the rule would need to catch this>\n\n' > "$MISSES_LOG"
fi

# Nothing to scan if there are no project memory directories yet.
if [ ! -d "$PROJECTS_DIR" ]; then
  exit 0
fi

# Iterate every memory file under every project.
find "$PROJECTS_DIR" -type d -name memory 2>/dev/null | while IFS= read -r MEM_DIR; do
  # Extract the sanitized-cwd segment: .../projects/<cwd>/memory.
  PROJECT=$(basename "$(dirname "$MEM_DIR")")

  # Find memory files and scan them. Use || true after greps so that
  # no-match (exit 1) does not fail under set -euo pipefail.
  find "$MEM_DIR" -maxdepth 2 -type f -name '*.md' 2>/dev/null | while IFS= read -r MEM_FILE; do
    # Process fired: lines.
    (grep -E '^fired: R-[0-9]{3} ' "$MEM_FILE" 2>/dev/null || true) | while IFS= read -r LINE; do
      [ -z "$LINE" ] && continue
      CONTENT="${LINE#fired: }"
      RULE="${CONTENT%% *}"
      CTX="${CONTENT#* }"
      ENTRY="$TODAY $RULE $PROJECT $CTX"
      if ! grep -qFx "$ENTRY" "$FIRES_LOG" 2>/dev/null; then
        printf '%s\n' "$ENTRY" >> "$FIRES_LOG"
      fi
    done

    # Process miss: lines.
    (grep -E '^miss: R-[0-9]{3} ' "$MEM_FILE" 2>/dev/null || true) | while IFS= read -r LINE; do
      [ -z "$LINE" ] && continue
      CONTENT="${LINE#miss: }"
      RULE="${CONTENT%% *}"
      CTX="${CONTENT#* }"
      ENTRY="$TODAY $RULE $PROJECT MISS $CTX"
      if ! grep -qFx "$ENTRY" "$MISSES_LOG" 2>/dev/null; then
        printf '%s\n' "$ENTRY" >> "$MISSES_LOG"
      fi
    done
  done
done

# Velocity metrics (R-302)
# Compute session commit stats and write to a temp file.
# The handoff doc author reads this file for the "Session metrics" section.

START_SHA_FILE="${TMPDIR:-/tmp}/claude-session-start-sha"
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

exit 0
