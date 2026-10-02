#!/usr/bin/env bash
# Covers: hook:git-workflow-guard
# Asserts the build-fast prose (IAN-401, spec B-4 and B-5, acceptance
# criterion 7): the build-fast skill runs on Haiku through its frontmatter and
# states each step, stop condition, and hard rule; the R-211, R-514, and R-517
# norm lines and their reference.md Specs carry the build-fast clauses;
# task-start defers the process to build-fast's lane and tier matrix; and the
# generated Codex and Cursor ports carry the new R-514 norm line.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
ROOT="$CLAUDE_HARNESS_ROOT"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
SKILL="$ROOT/skills/build-fast/SKILL.md"
R211_BUILD_FAST='under build-fast, the forks are asked in the opening batch'
R514_BUILD_FAST='under build-fast, the merge mode the owner chose in the opening batch'
R517_BUILD_FAST='under build-fast, the reviewer runs on `securityReviewModel`'
TASK_START_BUILD_FAST="build-fast's lane and tier matrix decides the process"

# requireText <file> <literal> <failure message>
# Fails the fixture unless the file contains the literal text.
requireText() {
  grep -qF -- "$2" "$1" || { echo "FAIL: $3"; exit 1; }
}

# normLine <rule id>
# Prints the rule's one norm line from CLAUDE.md.
normLine() {
  grep -E "^$1:" "$ROOT/CLAUDE.md" || true
}

# requireNormText <rule id> <literal>
# Fails the fixture unless the rule's own norm line contains the literal text.
requireNormText() {
  local ruleNorm
  ruleNorm=$(normLine "$1")
  grep -qF -- "$2" <<< "$ruleNorm" || { echo "FAIL: CLAUDE.md $1 norm line lacks: $2"; exit 1; }
}

# The skill runs on Haiku through its frontmatter, not through its body text.
[ -f "$SKILL" ] || { echo "FAIL: skills/build-fast/SKILL.md is missing"; exit 1; }
SKILL_FRONTMATTER=$(awk 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { exit } inside { print }' "$SKILL")
grep -qxF -- 'model: haiku' <<< "$SKILL_FRONTMATTER" || { echo "FAIL: build-fast frontmatter lacks model: haiku"; exit 1; }

# Each step, stop condition, and hard rule of B-4.
for skillLiteral in \
  'Opening batch' \
  'build-lane.sh predict' \
  'Approach review, only when opted in' \
  'tdd.sh' \
  'Paperwork commit' \
  'build-lane.sh classify' \
  'security-review-record.sh' \
  'in parallel with CI' \
  'One fix round' \
  'Stop conditions' \
  'securityReviewModel' \
  'task-tier.sh set' \
  '--merge-mode' \
  'No bug or issue hunting' \
  'No yak-shaving' \
  'never bypass' \
  'only the owner waives' \
  'raises a new finding' \
  'a security finding is unfixed' \
  'CI is red after the fix round' \
  'a gate blocks' \
  'widen the declared scope' \
  'mask a symptom' \
  'an action is destructive' \
  'gh pr merge' \
  'landed on `main`' \
  'completed_at' \
  'actual_minutes'; do
  requireText "$SKILL" "$skillLiteral" "build-fast SKILL.md lacks: $skillLiteral"
done

# B-5: the norm lines carry their build-fast clauses on the rule's own line.
requireNormText 'R-211' "$R211_BUILD_FAST"
# R-514 and R-517 norm lines were shortened on 2026-10-02 (IAN-568); their
# build-fast clauses live in the reference Specs, checked below.

# B-5: the reference.md Specs carry the same clauses.
requireText "$ROOT/rulebook/reference.md" "$R211_BUILD_FAST" "reference.md R-211 Spec lacks the build-fast opening-batch clause"
requireText "$ROOT/rulebook/reference.md" "$R514_BUILD_FAST" "reference.md R-514 Spec lacks the build-fast merge-mode clause"
requireText "$ROOT/rulebook/reference.md" "$R517_BUILD_FAST" "reference.md R-517 Spec lacks the build-fast reviewer clause"

# B-5: task-start defers the process to build-fast's lane and tier matrix.
requireText "$ROOT/skills/task-start/SKILL.md" "$TASK_START_BUILD_FAST" "task-start SKILL.md lacks the build-fast paragraph"

# The generated ports carry the new R-514 norm line.
if [ -f "$REPO_ROOT/codex/AGENTS.md" ]; then
  requireText "$REPO_ROOT/codex/AGENTS.md" "$R211_BUILD_FAST" "codex/AGENTS.md was not regenerated"
fi
if [ -f "$REPO_ROOT/cursor/rules/000-global-rules.mdc" ]; then
  requireText "$REPO_ROOT/cursor/rules/000-global-rules.mdc" "$R211_BUILD_FAST" "cursor global rules were not regenerated"
fi

# PR 161 review fix: the speed rule limits agent passes, never the flow's own
# steps, and the skill no longer claims the gates alone carry reliability.
# forbidText <file> <literal> <failure message>
# Fails the fixture when the file contains the literal text.
forbidText() {
  if grep -qF -- "$2" "$1"; then echo "FAIL: $3"; exit 1; fi
}
forbidText "$SKILL" 'Skip any step that does not change whether' "build-fast SKILL.md still lets a step be skipped"
forbidText "$SKILL" 'Reliability comes from the deterministic gates' "build-fast SKILL.md still carries the old reliability sentence"
requireText "$SKILL" "Spend no agent pass that does not change whether the requested change works or is safe; the flow's own steps are never skipped" \
  "build-fast SKILL.md lacks the revised speed rule"
# IAN-568 R-517 r1 #1: the flow follows owner decisions 2, 5, and 8.
forbidText "$SKILL" 'One `tdd.sh` slice for the whole change' "build-fast SKILL.md still locks every change"
forbidText "$SKILL" 'Search the tracker by branch, then open or advance the ticket' "build-fast SKILL.md still opens the ticket in Setup"
requireText "$SKILL" 'Guarded lane (high-risk or security): one `tdd.sh` slice' "build-fast SKILL.md lacks the guarded-lane lock"
requireText "$SKILL" 'only when round one found a HIGH' "build-fast SKILL.md lacks the one-round review rule"
requireText "$SKILL" '`fixed <sha>`' "build-fast SKILL.md lacks the fixed-sha findings record"
requireText "$SKILL" '(title, tier, branch, `started_at`, `actual_minutes`, `risk`)' "build-fast SKILL.md lacks the six close fields"
echo "build-fast-rule-text.test.sh PASS"
