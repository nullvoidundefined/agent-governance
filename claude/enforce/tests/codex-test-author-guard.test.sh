#!/usr/bin/env bash
# Covers: hook:codex-test-author-guard
# Verifies codex-test-author-guard.sh (PreToolUse Write/Edit, R-907): silent
# on non-test files and fixture data, asks when Claude's Write or Edit targets
# a test file in any supported naming convention, silent for other tools, and
# silenced entirely by CODEX_TEST_GUARD=off.
#
# Also verifies the runtime marker. The guard is registered under Codex itself
# through codex/hooks/codex-hook-adapter.sh (the Write|Edit matcher in
# codex/hooks.json), and the adapter translates an ask into a deny, so without a
# marker the guard denied Codex the very job R-907 assigns it: on 2026-09-19 in
# template-fastapi-nuxt, creating a new test file happened to work while every
# Edit of an existing test file was denied. The adapter therefore exports
# CLAUDE_HOOK_RUNTIME=codex into every hook child, and the guard exits silently
# on that value. A Claude Code session sets no such variable, so the ask path
# must survive both an unset variable and any other value.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/codex-test-author-guard.sh"

# decision <tool> <path> [guard] [agent] [runtime]
# Builds one PreToolUse payload, runs the guard on it, and echoes the
# permission decision, or "none" when the guard stayed silent. The trailing
# runtime argument, when non-empty, is exported as CLAUDE_HOOK_RUNTIME into the
# guard's environment; when it is omitted the variable is explicitly unset,
# which is what a Claude Code session looks like regardless of what the
# surrounding shell happens to carry.
decision() {
  local tool="$1" path="$2" guard="${3:-on}" agent="${4:-}" runtime="${5:-}"
  local payload out
  payload=$(jq -n --arg t "$tool" --arg f "$path" --arg a "$agent" '{tool_name:$t,tool_input:{file_path:$f}} + (if $a == "" then {} else {agent_type:$a} end)')
  if [ -n "$runtime" ]; then
    out=$(printf '%s' "$payload" | env CODEX_TEST_GUARD="$guard" CLAUDE_HOOK_RUNTIME="$runtime" "$HOOK")
  else
    out=$(printf '%s' "$payload" | env -u CLAUDE_HOOK_RUNTIME CODEX_TEST_GUARD="$guard" "$HOOK")
  fi
  if [ -z "$out" ]; then echo none; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "none"'; fi
}

# Production source files are none of this hook's business.
[ "$(decision Write /repo/apps/server/app/services/score_posting.py)" = "none" ] || { echo "FAIL: expected none for a production py file"; exit 1; }
[ "$(decision Edit /repo/apps/client/web/src/components/Header.vue)" = "none" ] || { echo "FAIL: expected none for a Vue component"; exit 1; }

# Test files ask, across the naming conventions.
[ "$(decision Write /repo/apps/server/tests/services/test_score_posting.py)" = "ask" ] || { echo "FAIL: expected ask for test_*.py"; exit 1; }
[ "$(decision Edit /repo/apps/server/tests/conftest.py)" = "ask" ] || { echo "FAIL: expected ask for conftest.py"; exit 1; }
[ "$(decision Write /repo/src/__tests__/handlers/authHandler.test.ts)" = "ask" ] || { echo "FAIL: expected ask for *.test.ts"; exit 1; }
[ "$(decision Write /repo/e2e/onboarding.spec.ts)" = "ask" ] || { echo "FAIL: expected ask for an e2e spec"; exit 1; }
[ "$(decision Edit /repo/apps/server/tests/helpers.py)" = "ask" ] || { echo "FAIL: expected ask for a bare py file inside tests/"; exit 1; }

# Fixture data inside a test tree is not test logic.
[ "$(decision Write /repo/apps/server/tests/fixtures/greenhouse_board.json)" = "none" ] || { echo "FAIL: expected none for json fixture data"; exit 1; }
[ "$(decision Write /repo/e2e/fixtures/seed_users.sql)" = "none" ] || { echo "FAIL: expected none for sql fixture data"; exit 1; }

# Other tools pass through untouched.
[ "$(decision Bash /repo/apps/server/tests/test_queue.py)" = "none" ] || { echo "FAIL: expected none for a non-Write/Edit tool"; exit 1; }

# The escape hatch silences the guard.
[ "$(decision Write /repo/apps/server/tests/test_queue.py off)" = "none" ] || { echo "FAIL: expected none with CODEX_TEST_GUARD=off"; exit 1; }

# The dedicated test-author role (R-707) never writes implementation (R-411),
# so R-907's different-author intent is already satisfied: silent for it.
[ "$(decision Write /repo/src/__tests__/handlers/authHandler.test.ts on test-author)" = "none" ] || { echo "FAIL: expected none for the test-author agent"; exit 1; }
# Every other subagent still asks; the implementer must never touch tests.
[ "$(decision Write /repo/src/__tests__/handlers/authHandler.test.ts on implementer)" = "ask" ] || { echo "FAIL: expected ask for the implementer agent"; exit 1; }

# Under the Codex runtime the guard is silent: R-907 names the codex CLI as the
# author of tests, and the adapter turns an ask into a deny, so an ask here
# blocks Codex from its own job. Edit of an existing test file is listed
# explicitly because that is the case template-fastapi-nuxt hit on 2026-09-19;
# Write of a new file happened to work and must keep working.
[ "$(decision Write /repo/apps/server/tests/services/test_score_posting.py on "" codex)" = "none" ] || { echo "FAIL: expected none for a new py test file under CLAUDE_HOOK_RUNTIME=codex"; exit 1; }
[ "$(decision Edit /repo/apps/server/tests/services/test_score_posting.py on "" codex)" = "none" ] || { echo "FAIL: expected none for an Edit of an existing py test file under CLAUDE_HOOK_RUNTIME=codex"; exit 1; }
[ "$(decision Write /repo/src/__tests__/handlers/authHandler.test.ts on "" codex)" = "none" ] || { echo "FAIL: expected none for a new ts test file under CLAUDE_HOOK_RUNTIME=codex"; exit 1; }
[ "$(decision Edit /repo/src/__tests__/handlers/authHandler.test.ts on "" codex)" = "none" ] || { echo "FAIL: expected none for an Edit of an existing ts test file under CLAUDE_HOOK_RUNTIME=codex"; exit 1; }
[ "$(decision Edit /repo/apps/server/tests/conftest.py on "" codex)" = "none" ] || { echo "FAIL: expected none for an Edit of conftest.py under CLAUDE_HOOK_RUNTIME=codex"; exit 1; }

# A Claude Code session sets no runtime marker, so the R-907 ask must survive
# the variable being absent entirely. This is the path the marker must not cost.
[ "$(decision Write /repo/apps/server/tests/services/test_score_posting.py)" = "ask" ] || { echo "FAIL: expected ask for a py test file with no CLAUDE_HOOK_RUNTIME set"; exit 1; }
[ "$(decision Edit /repo/src/__tests__/handlers/authHandler.test.ts)" = "ask" ] || { echo "FAIL: expected ask for an Edit of a ts test file with no CLAUDE_HOOK_RUNTIME set"; exit 1; }

# The guard matches the value, not the mere presence of the variable: any
# runtime other than codex is still an author R-907 keeps away from tests.
[ "$(decision Write /repo/apps/server/tests/services/test_score_posting.py on "" claude)" = "ask" ] || { echo "FAIL: expected ask for a py test file under CLAUDE_HOOK_RUNTIME=claude"; exit 1; }
[ "$(decision Edit /repo/src/__tests__/handlers/authHandler.test.ts on "" claude)" = "ask" ] || { echo "FAIL: expected ask for an Edit of a ts test file under CLAUDE_HOOK_RUNTIME=claude"; exit 1; }
[ "$(decision Edit /repo/src/__tests__/handlers/authHandler.test.ts on "" codex-review)" = "ask" ] || { echo "FAIL: expected ask for a ts test file under a runtime that merely starts with codex"; exit 1; }

echo "PASS: codex-test-author-guard"
