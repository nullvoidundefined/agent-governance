#!/usr/bin/env bash
# claude-md-lint.test.sh: guard the always-loaded prompt's context budget and
# the CLAUDE.md <-> rulebook/reference.md split introduced 2026-07-29.
# Three invariants:
#   1. CLAUDE.md stays under 200 lines (published adherence threshold).
#   2. Every rule ID with a norm line has a full-Spec block in rulebook/reference.md
#      and vice versa (no drift between norm lines and reference Specs). A norm
#      line may live in CLAUDE.md or in a skills/*/SKILL.md: the 2026-09-04
#      config audit moved the conditional, mechanically enforced structure rules
#      into skills/structure-conventions so they stop costing context on every
#      session. Relocation is allowed; an orphan Spec with no norm line anywhere
#      is still a failure.
#   3. Un-frontmattered files in ~/.claude/rules/ auto-load into every session,
#      so only session-types.md may live there without a paths: header.
set -euo pipefail

CLAUDE_MD="${CLAUDE_MD_FILE:-$HOME/.claude/CLAUDE.md}"
REFERENCE_MD="${CLAUDE_REFERENCE_FILE:-$HOME/.claude/rulebook/reference.md}"
# Overridable like the two inputs above it: with CLAUDE_MD_FILE and
# CLAUDE_REFERENCE_FILE pointed at a checkout and this one hardwired to the live
# copy, the fixture linted two different trees at once and a rules/ defect in
# the repo went unlinted until it was synced (2026-09-17 audit P2-8).
RULES_DIR="${CLAUDE_RULES_DIR:-$HOME/.claude/rules}"
MAX_LINES=200

LINE_COUNT=$(wc -l < "$CLAUDE_MD" | tr -d ' ')
if [ "$LINE_COUNT" -gt "$MAX_LINES" ]; then
  echo "FAIL: CLAUDE.md is $LINE_COUNT lines (max $MAX_LINES). Collapse rule prose into rulebook/reference.md; the always-loaded file carries one norm line per rule." >&2
  exit 1
fi

SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
CLAUDE_MD_IDS=$(grep -oE '^R-[0-9]{3}' "$CLAUDE_MD" | sort -u)
SKILL_IDS=$(cat "$SKILLS_DIR"/*/SKILL.md 2>/dev/null | grep -oE '^R-[0-9]{3}' | sort -u)
NORM_IDS=$(printf '%s\n%s\n' "$CLAUDE_MD_IDS" "$SKILL_IDS" | grep -E '^R-[0-9]{3}$' | sort -u)
REFERENCE_IDS=$(grep -oE '^R-[0-9]{3}' "$REFERENCE_MD" | sort -u)
MISSING_IN_REFERENCE=$(comm -23 <(printf '%s\n' "$NORM_IDS") <(printf '%s\n' "$REFERENCE_IDS"))
MISSING_NORM_LINE=$(comm -13 <(printf '%s\n' "$NORM_IDS") <(printf '%s\n' "$REFERENCE_IDS"))
DUPLICATED=$(comm -12 <(printf '%s\n' "$CLAUDE_MD_IDS") <(printf '%s\n' "$SKILL_IDS"))
if [ -n "$MISSING_IN_REFERENCE" ]; then
  echo "FAIL: rule IDs with a norm line but no Spec block in rulebook/reference.md: $(echo "$MISSING_IN_REFERENCE" | tr '\n' ' ')" >&2
  exit 1
fi
if [ -n "$MISSING_NORM_LINE" ]; then
  echo "FAIL: rule IDs in rulebook/reference.md with no norm line in CLAUDE.md or any skills/*/SKILL.md: $(echo "$MISSING_NORM_LINE" | tr '\n' ' ')" >&2
  exit 1
fi
# A rule carried in both places drifts silently. It belongs in exactly one.
if [ -n "$DUPLICATED" ]; then
  echo "FAIL: rule IDs with a norm line in BOTH CLAUDE.md and a skill: $(echo "$DUPLICATED" | tr '\n' ' ')" >&2
  exit 1
fi

# Invariant 3 inspected nothing and passed in silence when the glob matched
# no file, the same shape P1-4 found in deny-tier-set-convention.test.sh. The
# directory always holds session-types.md plus the path-scoped stack symlinks,
# so an empty match means the wrong tree, not a valid layout (audit P3-4).
RULES_FILE_COUNT=0
for rule_file in "$RULES_DIR"/*.md; do
  [ -e "$rule_file" ] || continue
  RULES_FILE_COUNT=$((RULES_FILE_COUNT + 1))
  BASENAME=$(basename "$rule_file")
  [ "$BASENAME" = "session-types.md" ] && continue
  if [ "$(head -1 "$rule_file")" != "---" ]; then
    echo "FAIL: $BASENAME sits in rules/ without paths: frontmatter, so it auto-loads into every session. Add frontmatter or move it to rulebook/." >&2
    exit 1
  fi
done

if [ "$RULES_FILE_COUNT" -eq 0 ]; then
  echo "FAIL: invariant 3 inspected no file under $RULES_DIR, so it proved nothing; the directory should hold session-types.md plus the path-scoped stack rule files" >&2
  exit 1
fi

echo "claude-md-lint.test.sh PASS ($LINE_COUNT lines, $(printf '%s\n' "$NORM_IDS" | wc -l | tr -d ' ') rules in sync, $(printf '%s\n' "$SKILL_IDS" | grep -cE '^R-' || true) carried by skills)"
