#!/usr/bin/env bash
# Covers: ci:llm-rule-judge
# Asserts the IAN-321 scope on R-001 in CLAUDE.md, in rulebook/reference.md, and in the generated
# Codex and Cursor ports of both. The test is "no user turn follows the invocation", never
# "one-shot": an interactive session's first turn is also a single supplied prompt and is also,
# until a second turn arrives, one shot, so a model given the looser wording can exempt a session
# that should run the procedure. The three exclusions are asserted by name because each was a
# defect in the first attempt. A cloud session is the case R-003 scopes for having no `~/.claude`
# at all, which is where the reads carry the most information. A dispatched subagent learns Tier 2
# rules only through step 3, R-706's fifty-call cap among them, and no role file restates it.
# R-002 was deleted on 2026-10-01 (IAN-518) because it restated R-001; the test forbids its return,
# because a second rule carrying its own imperative to read the same files would instruct exactly
# what R-001 excuses. The hand-authored Codex skill is asserted
# because no generator run reaches it and its description is what a model matches against before
# it has read any rule.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
ROOT="$CLAUDE_HARNESS_ROOT"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"

MECHANICAL_TEST='Skip this procedure when no user turn follows the invocation'
NAMED_INVOCATIONS='`codex exec` and `claude -p` with a supplied prompt'
EXCLUSIONS='Every interactive session runs it, cloud and resumed sessions included, and so does every dispatched subagent'
RETIRED_R002='R-002:'
LOOSE_WORDING='A one-shot non-interactive invocation'
RATIONALE_CLAUSE='the reads buy nothing'

fail() {
    echo "$(basename "$0") FAIL: $1" >&2
    exit 1
}

requireText() {
    grep -qF -- "$2" "$1" || fail "$3"
}

forbidText() {
    grep -qF -- "$2" "$1" && fail "$3"
    return 0
}

# The canon, always present under the harness root.
# R-001 is a default since 2026-10-02 (IAN-568): its norm line left CLAUDE.md,
# so the scope is checked in the reference Spec, and CLAUDE.md only indexes it.
grep -qE '^- Session start: R-001' "$ROOT/CLAUDE.md" \
    || fail "CLAUDE.md's Defaults index does not name R-001"
grep -qE '^R-001:' "$ROOT/CLAUDE.md" \
    && fail "CLAUDE.md still carries an R-001 norm line; R-001 is a default"
requireText "$ROOT/rulebook/reference.md" "$NAMED_INVOCATIONS" \
    "rulebook/reference.md R-001 does not name the exempt invocations: $NAMED_INVOCATIONS"
forbidText "$ROOT/rulebook/reference.md" 'First line of the response after the reads' \
    "rulebook/reference.md R-001 still requires the declaration line"
forbidText "$ROOT/CLAUDE.md" "$RATIONALE_CLAUSE" \
    "CLAUDE.md R-001 carries rationale that belongs in PROTOCOL.md (R-206): $RATIONALE_CLAUSE"
forbidText "$ROOT/CLAUDE.md" "$LOOSE_WORDING" \
    "CLAUDE.md R-001 still carries the undefined wording: $LOOSE_WORDING"
forbidText "$ROOT/CLAUDE.md" "$RETIRED_R002" \
    "CLAUDE.md carries the deleted R-002, which restates the reads R-001 scopes"

requireText "$ROOT/rulebook/reference.md" "$MECHANICAL_TEST" \
    "rulebook/reference.md R-001 Spec lacks the scope the norm line carries"
requireText "$ROOT/rulebook/reference.md" "$EXCLUSIONS" \
    "rulebook/reference.md R-001 Spec does not name the exclusions: $EXCLUSIONS"
forbidText "$ROOT/rulebook/reference.md" "$RETIRED_R002" \
    "rulebook/reference.md carries the deleted R-002, which restates the reads R-001 scopes"

# The ports, present only when the test runs beside a repository checkout.
CODEX_AGENTS="$REPO_ROOT/codex/AGENTS.md"
if [ -f "$CODEX_AGENTS" ]; then
    forbidText "$CODEX_AGENTS" "$LOOSE_WORDING" \
        "the Codex port of CLAUDE.md still carries the undefined wording"
fi

CURSOR_REFERENCE="$REPO_ROOT/cursor/rules/rulebook-reference-r0xx-session-init.mdc"
if [ -f "$CURSOR_REFERENCE" ]; then
    requireText "$CURSOR_REFERENCE" "$MECHANICAL_TEST" \
        "the Cursor port of reference.md lacks the R-001 scope"
fi

CODEX_SKILL="$REPO_ROOT/codex/skills/session-start/SKILL.md"
if [ -f "$CODEX_SKILL" ]; then
    requireText "$CODEX_SKILL" "every interactive Codex session" \
        "the hand-authored Codex session-start skill still applies to every Codex session"
    forbidText "$CODEX_SKILL" "at the start of every Codex session" \
        "the hand-authored Codex session-start skill still applies to every Codex session"
fi

echo "$(basename "$0") PASS"
