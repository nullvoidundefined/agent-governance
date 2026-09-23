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
# otherwise instruct exactly what R-001 now excuses.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
ROOT="$CLAUDE_HARNESS_ROOT"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"

MECHANICAL_TEST='Skip this procedure when no user turn follows the invocation'
NAMED_INVOCATIONS='`codex exec` and `claude -p` with a supplied prompt'
EXCLUSIONS='Every interactive session runs it, cloud and resumed sessions included, and so does every dispatched subagent'
R002_SCOPE='Load the R-001 files at every session start R-001 applies to'
R002_REFERENCE_SCOPE='at every session start R-001 applies to'

fail() {
    echo "$(basename "$0") FAIL: $1" >&2
    exit 1
}

assert_contains() {
    local file="$1" needle="$2" label="$3"
    [ -f "$file" ] || fail "$label: $file does not exist"
    grep -qF -- "$needle" "$file" || fail "$label: $file is missing: $needle"
}

assert_absent() {
    local file="$1" needle="$2" label="$3"
    [ -f "$file" ] || return 0
    grep -qF -- "$needle" "$file" && fail "$label: $file still carries the looser wording: $needle"
    return 0
}

for target in \
    "$REPO_ROOT/claude/CLAUDE.md" \
    "$REPO_ROOT/claude/rulebook/reference.md" \
    "$REPO_ROOT/codex/AGENTS.md" \
    "$REPO_ROOT/cursor/rules/000-global-rules.mdc"; do
    assert_contains "$target" "$MECHANICAL_TEST" "R-001 scope"
    assert_contains "$target" "$NAMED_INVOCATIONS" "R-001 named invocations"
    assert_contains "$target" "$EXCLUSIONS" "R-001 exclusions"
    # The rationale belongs in PROTOCOL.md (R-206), and stated as a reason it is a general test a
    # model applies past the cases named here.
    assert_absent "$target" "the reads buy nothing" "R-001 rationale"
    assert_absent "$target" "A one-shot non-interactive invocation" "R-001 looser wording"
done

assert_contains "$REPO_ROOT/claude/CLAUDE.md" "$R002_SCOPE" "R-002 scope"
assert_contains "$REPO_ROOT/claude/rulebook/reference.md" "$R002_REFERENCE_SCOPE" "R-002 scope"

# The hand-authored Codex skill is the surface a model matches before it has read any rule, and no
# generator run reaches it, so it has to carry the boundary itself.
assert_contains \
    "$REPO_ROOT/codex/skills/session-start/SKILL.md" \
    "every interactive Codex session" \
    "Codex session-start skill"
assert_absent \
    "$REPO_ROOT/codex/skills/session-start/SKILL.md" \
    "at the start of every Codex session" \
    "Codex session-start skill"

echo "$(basename "$0") PASS"
