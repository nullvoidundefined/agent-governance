#!/usr/bin/env bash
# claude-md-lint.test.sh: guard the always-loaded prompt's context budget and
# the CLAUDE.md <-> rulebook/reference.md split introduced 2026-07-29.
# Three invariants:
#   1. CLAUDE.md stays under 200 lines (published adherence threshold).
#   2. Every rule ID in CLAUDE.md has a full-Spec block in rulebook/reference.md
#      and vice versa (no drift between norm lines and reference Specs).
#   3. Un-frontmattered files in ~/.claude/rules/ auto-load into every session,
#      so only session-types.md may live there without a paths: header.
set -euo pipefail

CLAUDE_MD="${CLAUDE_MD_FILE:-$HOME/.claude/CLAUDE.md}"
REFERENCE_MD="${CLAUDE_REFERENCE_FILE:-$HOME/.claude/rulebook/reference.md}"
RULES_DIR="$HOME/.claude/rules"
MAX_LINES=200

LINE_COUNT=$(wc -l < "$CLAUDE_MD" | tr -d ' ')
if [ "$LINE_COUNT" -gt "$MAX_LINES" ]; then
  echo "FAIL: CLAUDE.md is $LINE_COUNT lines (max $MAX_LINES). Collapse rule prose into rulebook/reference.md; the always-loaded file carries one norm line per rule." >&2
  exit 1
fi

NORM_IDS=$(grep -oE '^R-[0-9]{3}' "$CLAUDE_MD" | sort -u)
REFERENCE_IDS=$(grep -oE '^R-[0-9]{3}' "$REFERENCE_MD" | sort -u)
MISSING_IN_REFERENCE=$(comm -23 <(printf '%s\n' "$NORM_IDS") <(printf '%s\n' "$REFERENCE_IDS"))
MISSING_IN_CLAUDE_MD=$(comm -13 <(printf '%s\n' "$NORM_IDS") <(printf '%s\n' "$REFERENCE_IDS"))
if [ -n "$MISSING_IN_REFERENCE" ]; then
  echo "FAIL: rule IDs in CLAUDE.md with no Spec block in rulebook/reference.md: $(echo "$MISSING_IN_REFERENCE" | tr '\n' ' ')" >&2
  exit 1
fi
if [ -n "$MISSING_IN_CLAUDE_MD" ]; then
  echo "FAIL: rule IDs in rulebook/reference.md with no norm line in CLAUDE.md: $(echo "$MISSING_IN_CLAUDE_MD" | tr '\n' ' ')" >&2
  exit 1
fi

for rule_file in "$RULES_DIR"/*.md; do
  [ -e "$rule_file" ] || continue
  BASENAME=$(basename "$rule_file")
  [ "$BASENAME" = "session-types.md" ] && continue
  if [ "$(head -1 "$rule_file")" != "---" ]; then
    echo "FAIL: $BASENAME sits in rules/ without paths: frontmatter, so it auto-loads into every session. Add frontmatter or move it to rulebook/." >&2
    exit 1
  fi
done

echo "claude-md-lint.test.sh PASS ($LINE_COUNT lines, $(printf '%s\n' "$NORM_IDS" | wc -l | tr -d ' ') rules in sync)"
