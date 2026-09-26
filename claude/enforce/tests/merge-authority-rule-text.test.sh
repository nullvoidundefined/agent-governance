#!/usr/bin/env bash
# Covers: hook:git-workflow-guard
# Asserts the IAN-433 rule wording (program row 1, IAN-427): R-514 states the
# trivial-tier merge exception once, in its norm line and its Spec, and the
# task-start and task-cleanup skills agree with it; the no-Copilot decision
# lives only in R-514's Spec bullet, which also names the disabled ruleset;
# R-211's approved-plan clause defers each PR's merge to the plan's recorded
# merge mode; and the generated Codex and Cursor ports carry the new R-514
# norm line.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
ROOT="$CLAUDE_HARNESS_ROOT"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
TRIVIAL_EXCEPTION='a trivial-tier PR merges on green CI without per-PR authorization when the task-tier ledger records the trivial tier for its head branch'
R211_MERGE_MODE='each PR then merges or waits for the owner as the plan'"'"'s `**Merge mode:**` line records (R-514)'

# requireText <file> <literal> <failure message>
# Fails the fixture unless the file contains the literal text.
requireText() {
  grep -qF -- "$2" "$1" || { echo "FAIL: $3"; exit 1; }
}

# forbidText <file> <literal> <failure message>
# Fails the fixture when the file still contains the literal text.
forbidText() {
  if grep -qF -- "$2" "$1"; then echo "FAIL: $3"; exit 1; fi
}

# normLine <rule id>
# Prints the rule's one norm line from CLAUDE.md.
normLine() {
  grep -E "^$1:" "$ROOT/CLAUDE.md"
}

R514_NORM=$(normLine 'R-514')
R211_NORM=$(normLine 'R-211')

# Trivial-tier exception, stated once in the rule and matched by the skills.
grep -qF -- "$TRIVIAL_EXCEPTION" <<< "$R514_NORM" || { echo "FAIL: CLAUDE.md R-514 lacks the trivial-tier merge exception"; exit 1; }
requireText "$ROOT/rulebook/reference.md" "$TRIVIAL_EXCEPTION" "reference.md R-514 Spec lacks the trivial-tier merge exception"
forbidText "$ROOT/rulebook/reference.md" 'under the same merge authorization as any PR' "reference.md R-514 still requires per-PR authorization for a trivial PR"
requireText "$ROOT/skills/task-cleanup/SKILL.md" 'merge on green CI' "task-cleanup lost the trivial merge-on-green path"
requireText "$ROOT/skills/task-start/SKILL.md" 'merge on green CI' "task-start lost the trivial merge-on-green path"

# Copilot: one source, the R-514 Spec bullet with the disabled ruleset.
if grep -qF -- 'Copilot' <<< "$R514_NORM"; then echo "FAIL: CLAUDE.md R-514 still repeats the Copilot clause"; exit 1; fi
forbidText "$ROOT/skills/task-cleanup/SKILL.md" 'Copilot' "task-cleanup still repeats the Copilot clause"
forbidText "$ROOT/skills/task-start/SKILL.md" 'Copilot' "task-start still repeats the Copilot clause"
requireText "$ROOT/rulebook/reference.md" 'Never request Copilot review, on any PR' "reference.md R-514 lost the no-Copilot decision"
requireText "$ROOT/rulebook/reference.md" 'copilot-review-main-and-slice' "reference.md R-514 lost the disabled Copilot ruleset"

# R-211 defers each PR's merge to the plan's recorded merge mode.
if grep -qF -- 'work runs from PR to PR and slice to slice without ending a turn to ask' <<< "$R211_NORM"; then
  echo "FAIL: CLAUDE.md R-211 still runs PR to PR without the merge mode"; exit 1
fi
grep -qF -- "$R211_MERGE_MODE" <<< "$R211_NORM" || { echo "FAIL: CLAUDE.md R-211 does not defer merges to the plan's merge mode"; exit 1; }
requireText "$ROOT/rulebook/reference.md" "$R211_MERGE_MODE" "reference.md R-211 Approved plans does not defer merges to the merge mode"

# The generated ports carry the new R-514 norm line.
if [ -f "$REPO_ROOT/codex/AGENTS.md" ]; then
  requireText "$REPO_ROOT/codex/AGENTS.md" "$TRIVIAL_EXCEPTION" "codex/AGENTS.md was not regenerated"
fi
if [ -f "$REPO_ROOT/cursor/rules/000-global-rules.mdc" ]; then
  requireText "$REPO_ROOT/cursor/rules/000-global-rules.mdc" "$TRIVIAL_EXCEPTION" "cursor global rules were not regenerated"
fi
echo "merge-authority-rule-text.test.sh PASS"
