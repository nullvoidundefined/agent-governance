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
# R-002 is asserted too, because it carries its own imperative to read the same files and would
# otherwise instruct exactly what R-001 now excuses. The hand-authored Codex skill is asserted
# because no generator run reaches it and its description is what a model matches against before
# it has read any rule.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
ROOT="$CLAUDE_HARNESS_ROOT"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"

MECHANICAL_TEST='Skip this procedure when no user turn follows the invocation'
NAMED_INVOCATIONS='`codex exec` and `claude -p` with a supplied prompt'
EXCLUSIONS='Every interactive session runs it, cloud and resumed sessions included, and so does every dispatched subagent'
R002_SCOPE='at every session start R-001 applies to'
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
requireText "$ROOT/CLAUDE.md" "$MECHANICAL_TEST" \
    "CLAUDE.md R-001 does not state the mechanical test: $MECHANICAL_TEST"
requireText "$ROOT/CLAUDE.md" "$NAMED_INVOCATIONS" \
    "CLAUDE.md R-001 does not name the exempt invocations: $NAMED_INVOCATIONS"
requireText "$ROOT/CLAUDE.md" "$EXCLUSIONS" \
    "CLAUDE.md R-001 does not name the exclusions: $EXCLUSIONS"
forbidText "$ROOT/CLAUDE.md" "$RATIONALE_CLAUSE" \
    "CLAUDE.md R-001 carries rationale that belongs in PROTOCOL.md (R-206): $RATIONALE_CLAUSE"
forbidText "$ROOT/CLAUDE.md" "$LOOSE_WORDING" \
    "CLAUDE.md R-001 still carries the undefined wording: $LOOSE_WORDING"
requireText "$ROOT/CLAUDE.md" "$R002_SCOPE" \
    "CLAUDE.md R-002 is unscoped and instructs the reads R-001 excuses"

requireText "$ROOT/rulebook/reference.md" "$MECHANICAL_TEST" \
    "rulebook/reference.md R-001 Spec lacks the scope the norm line carries"
requireText "$ROOT/rulebook/reference.md" "$EXCLUSIONS" \
    "rulebook/reference.md R-001 Spec does not name the exclusions: $EXCLUSIONS"
requireText "$ROOT/rulebook/reference.md" "$R002_SCOPE" \
    "rulebook/reference.md R-002 is unscoped and contradicts R-001"

# The ports, present only when the test runs beside a repository checkout.
CODEX_AGENTS="$REPO_ROOT/codex/AGENTS.md"
if [ -f "$CODEX_AGENTS" ]; then
    requireText "$CODEX_AGENTS" "$MECHANICAL_TEST" \
        "the Codex port of CLAUDE.md lacks the R-001 scope"
    requireText "$CODEX_AGENTS" "$EXCLUSIONS" \
        "the Codex port of CLAUDE.md does not name the R-001 exclusions"
    forbidText "$CODEX_AGENTS" "$LOOSE_WORDING" \
        "the Codex port of CLAUDE.md still carries the undefined wording"
fi

CURSOR_GLOBAL="$REPO_ROOT/cursor/rules/000-global-rules.mdc"
if [ -f "$CURSOR_GLOBAL" ]; then
    requireText "$CURSOR_GLOBAL" "$MECHANICAL_TEST" \
        "the Cursor port of CLAUDE.md lacks the R-001 scope"
    requireText "$CURSOR_GLOBAL" "$EXCLUSIONS" \
        "the Cursor port of CLAUDE.md does not name the R-001 exclusions"
fi

CODEX_SKILL="$REPO_ROOT/codex/skills/session-start/SKILL.md"
if [ -f "$CODEX_SKILL" ]; then
    requireText "$CODEX_SKILL" "every interactive Codex session" \
        "the hand-authored Codex session-start skill still applies to every Codex session"
    forbidText "$CODEX_SKILL" "at the start of every Codex session" \
        "the hand-authored Codex session-start skill still applies to every Codex session"
fi

echo "$(basename "$0") PASS"
