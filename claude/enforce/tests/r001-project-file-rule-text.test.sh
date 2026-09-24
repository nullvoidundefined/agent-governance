#!/usr/bin/env bash
# Covers: ci:llm-rule-judge
# Asserts the IAN-364 wording of R-001's project-file step in CLAUDE.md, in rulebook/reference.md,
# in the generated Codex and Cursor ports of both, and in the two hand-authored session-start ports.
# The step names the project instruction file of whichever tool is running (Claude Code, Codex,
# Cursor), because the same rule text is projected into all three and a literal `CLAUDE.md` sends
# Codex and Cursor to a file they do not load. The step confirms the file loaded rather than
# re-reading it, since Claude Code and Codex inject it on their own. A repository with no project
# file is named explicitly, because the unconditional wording left a session with nothing to read
# and, in practice, no `Session:` line at all.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
ROOT="$CLAUDE_HARNESS_ROOT"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"

CONFIRM_STEP="confirm the running tool loaded its project instruction file"
CLAUDE_FILE='Claude Code: `CLAUDE.md` or `.claude/CLAUDE.md`'
CODEX_FILE='Codex: `AGENTS.md`'
CURSOR_FILE='Cursor: `.cursor/rules/`'
ABSENT_CASE='a repo with none lists `no project file` under Skipped'
OLD_NORM_STEP='(5) read the project `CLAUDE.md`;'
OLD_SPEC_STEP='6. Read the project `CLAUDE.md`.'
OLD_PORT_STEP='Read the project `CLAUDE.md` or `AGENTS.md` if present.'

fail() {
    echo "$(basename "$0") FAIL: $1" >&2
    exit 1
}

requireText() {
    grep -qiF -- "$2" "$1" || fail "$3"
}

forbidText() {
    grep -qF -- "$2" "$1" && fail "$3"
    return 0
}

# Asserts the full per-tool wording in one file that carries the shared rule text.
requireSharedWording() {
    local file="$1" label="$2"
    requireText "$file" "$CONFIRM_STEP" "$label R-001 does not confirm the running tool's project file"
    requireText "$file" "$CLAUDE_FILE" "$label R-001 does not name the Claude Code project file"
    requireText "$file" "$CODEX_FILE" "$label R-001 does not name the Codex project file"
    requireText "$file" "$CURSOR_FILE" "$label R-001 does not name the Cursor project file"
    requireText "$file" "$ABSENT_CASE" "$label R-001 does not say what a repo without a project file records"
}

# The canon, always present under the harness root.
requireSharedWording "$ROOT/CLAUDE.md" "CLAUDE.md"
forbidText "$ROOT/CLAUDE.md" "$OLD_NORM_STEP" "CLAUDE.md R-001 still hard-codes the project CLAUDE.md"
requireSharedWording "$ROOT/rulebook/reference.md" "rulebook/reference.md"
forbidText "$ROOT/rulebook/reference.md" "$OLD_SPEC_STEP" \
    "rulebook/reference.md R-001 Spec still hard-codes the project CLAUDE.md"

# The generated ports, present only when the test runs beside a repository checkout.
CODEX_AGENTS="$REPO_ROOT/codex/AGENTS.md"
if [ -f "$CODEX_AGENTS" ]; then
    requireSharedWording "$CODEX_AGENTS" "the Codex port of CLAUDE.md"
    forbidText "$CODEX_AGENTS" "$OLD_NORM_STEP" "the Codex port still hard-codes the project CLAUDE.md"
fi

CURSOR_GLOBAL="$REPO_ROOT/cursor/rules/000-global-rules.mdc"
if [ -f "$CURSOR_GLOBAL" ]; then
    requireSharedWording "$CURSOR_GLOBAL" "the Cursor port of CLAUDE.md"
    forbidText "$CURSOR_GLOBAL" "$OLD_NORM_STEP" "the Cursor port still hard-codes the project CLAUDE.md"
fi

CURSOR_REFERENCE="$REPO_ROOT/cursor/rules/rulebook-reference-r0xx-session-init.mdc"
if [ -f "$CURSOR_REFERENCE" ]; then
    requireSharedWording "$CURSOR_REFERENCE" "the Cursor port of reference.md"
    forbidText "$CURSOR_REFERENCE" "$OLD_SPEC_STEP" "the Cursor reference port still hard-codes the project CLAUDE.md"
fi

# The hand-authored ports name only their own tool's file; no generator run reaches them.
CODEX_SKILL="$REPO_ROOT/codex/skills/session-start/SKILL.md"
if [ -f "$CODEX_SKILL" ]; then
    requireText "$CODEX_SKILL" 'Confirm Codex loaded the project `AGENTS.md`' \
        "the Codex session-start skill does not confirm AGENTS.md loaded"
    requireText "$CODEX_SKILL" "$ABSENT_CASE" \
        "the Codex session-start skill does not say what a repo without AGENTS.md records"
    forbidText "$CODEX_SKILL" "$OLD_PORT_STEP" "the Codex session-start skill still names CLAUDE.md"
fi

CURSOR_COMMAND="$REPO_ROOT/cursor/commands/session-start.md"
if [ -f "$CURSOR_COMMAND" ]; then
    requireText "$CURSOR_COMMAND" 'Confirm Cursor loaded the project `.cursor/rules/`' \
        "the Cursor session-start command does not confirm .cursor/rules/ loaded"
    requireText "$CURSOR_COMMAND" "$ABSENT_CASE" \
        "the Cursor session-start command does not say what a repo without project rules records"
    forbidText "$CURSOR_COMMAND" "$OLD_PORT_STEP" "the Cursor session-start command still names CLAUDE.md"
fi

echo "$(basename "$0") PASS"
