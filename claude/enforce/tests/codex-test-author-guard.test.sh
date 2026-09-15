#!/usr/bin/env bash
# Verifies codex-test-author-guard.sh (PreToolUse Write/Edit, R-907): silent
# on non-test files and fixture data, asks when Claude's Write or Edit targets
# a test file in any supported naming convention, silent for other tools, and
# silenced entirely by CODEX_TEST_GUARD=off.
set -euo pipefail
HOOK="$HOME/.claude/hooks/codex-test-author-guard.sh"

decision() {
  local tool="$1" path="$2" guard="${3:-on}"
  local out
  out=$(jq -n --arg t "$tool" --arg f "$path" '{tool_name:$t,tool_input:{file_path:$f}}' | CODEX_TEST_GUARD="$guard" "$HOOK")
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

echo "PASS: codex-test-author-guard"
