#!/usr/bin/env bash
# Covers: manual:r110-rule-text
# Asserts the IAN-521 risk-tiered process wording (owner decisions 2026-10-01)
# across CLAUDE.md, the rulebook, and the skills: R-110 classifies each slice
# by risk and records it at Gate 1 with one owner tile per fuzzy control; the
# slice-role triad and the per-slice critic follow the risk, not the tier
# (R-412, R-707, R-907); the R-517 reviewer runs on sonnet for every PR with a
# two-round cap; ticket-lifecycle records the risk measures and reports them.
# R-110 is a manual rule, so this fixture pins its text rather than a hook.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
ROOT="$CLAUDE_HARNESS_ROOT"

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
  grep -E "^$1:" "$ROOT/CLAUDE.md" || true
}

# requireNormText <rule id> <literal>
# Fails the fixture unless the rule's own norm line contains the literal text.
requireNormText() {
  grep -qF -- "$2" <<< "$(normLine "$1")" || { echo "FAIL: CLAUDE.md $1 norm line lacks: $2"; exit 1; }
}

# R-110: the classification, the Gate 1 record, the fuzzy-control tiles, manual.
requireNormText 'R-110' 'Classify every slice and PR by risk'
requireNormText 'R-110' '`**Risk:** high|standard`'
requireNormText 'R-110' 'defaulting to high when unsure'
requireNormText 'R-110' 'R-109 security-surface detector'
requireNormText 'R-110' 'one owner tile per control'
requireNormText 'R-110' '[manual]'
requireText "$ROOT/rulebook/reference.md" 'R-110: Classify every slice and PR by risk' "reference.md has no R-110 entry"
requireText "$ROOT/rulebook/reference.md" 'are deferred to follow-up work' "reference.md R-110 does not name the deferred detector and merge-time checks"

# R-412, R-707, R-907: risk, not tier, decides the triad.
requireNormText 'R-412' 'only for a high-risk slice (R-110), at any task tier'
requireText "$ROOT/rulebook/agents.md" 'for every high-risk slice (R-110), at any task tier, and for no other slice' "agents.md R-707 still dispatches by tier"
forbidText "$ROOT/rulebook/agents.md" 'Dispatch the `slice-critic` for Complex and Saga' "agents.md R-705 still dispatches the critic by tier"
requireText "$ROOT/rulebook/cost.md" 'for every high-risk slice (R-110), at any task tier' "cost.md R-907 still separates the author by tier"
requireText "$ROOT/skills/tdd-gated-dispatch/SKILL.md" '## High-risk slice: three roles, fresh context each' "tdd-gated-dispatch still sections the roles by tier"

# R-517: sonnet for every PR, two-round cap, LOW ticketed, security never ticketed.
requireNormText 'R-517' 'on `sonnet` for every PR, security-touching ones included'
requireNormText 'R-517' 'run at most two review rounds per PR'
requireNormText 'R-517' 'a security finding is never ticketed (R-109)'
forbidText "$ROOT/CLAUDE.md" 'only when the owner opts in or the diff touches auth, money, or concurrency' "CLAUDE.md R-517 still escalates the reviewer model by diff content"
requireText "$ROOT/rulebook/reference.md" 'the merge gate does not yet parse review rounds' "reference.md R-517 does not say the round cap is not yet gated"
requireText "$ROOT/prompts/codex-pr-review-prompt.md" '| # | Round | Severity |' "the PR review prompt's output table has no Round column"

# Gate 1 and measurement.
requireText "$ROOT/skills/build-by-slice-require-review/SKILL.md" '## Fuzzy controls (asked before any code, at Gate 1)' "build-by-slice lacks the fuzzy-control tiles"
requireText "$ROOT/skills/build-by-slice-require-review/SKILL.md" '**Round cap:**' "build-by-slice lacks the review round cap"
requireText "$ROOT/skills/task-cleanup/SKILL.md" '**Round cap.**' "task-cleanup lacks the review round cap"
requireText "$ROOT/skills/ticket-lifecycle/SKILL.md" '## Operation: report risk' "ticket-lifecycle lacks the report risk rollup"
for field in '`risk`' '`findings_by_round`' '`escaped_bugs`'; do
  requireText "$ROOT/skills/ticket-lifecycle/SKILL.md" "| $field |" "ticket-lifecycle lacks the canonical field $field"
done

echo "r110-rule-text.test.sh PASS"
