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

# --- the fire log a silenced guard must still leave (R-907) -------------------
#
# Exiting silently under the Codex runtime is a bypass, and a bypass that
# leaves no trace is indistinguishable from a guard that never ran at all: the
# fire log written by log-rule-fire.sh is the only place enforcement
# effectiveness data accrues mechanically, and it is what session-end.sh rolls
# up. The runtime check therefore belongs at the point the guard WOULD have
# asked, not above the stdin read, so that a silenced ask is recorded as an
# R-907 fire carrying the outcome codex-runtime, while a file this guard was
# never going to ask about records nothing at all and the telemetry does not
# fill with noise about production files Codex happened to touch.

FIRE_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/codex-test-author-guard-fires.XXXXXX")
trap 'rm -rf "$FIRE_SANDBOX"' EXIT
FIRE_LOG="$FIRE_SANDBOX/rule-fires.log"

# decision_with_fire_log <tool> <path> [runtime]
# Truncates the fire log, runs the guard on one payload with CLAUDE_FIRE_LOG
# pointed at a file inside this fixture's own sandbox, and echoes the
# permission decision, or "none" when the guard stayed silent. The redirection
# is not optional: the shard runner exports CLAUDE_FIRE_LOG=/dev/null, which
# log-rule-fire.sh treats as "record nothing", so without it these cases would
# read an empty log no matter what the guard did.
decision_with_fire_log() {
  local tool="$1" path="$2" runtime="${3:-}" payload out
  : >"$FIRE_LOG"
  payload=$(jq -n --arg t "$tool" --arg f "$path" '{tool_name:$t,tool_input:{file_path:$f}}')
  if [ -n "$runtime" ]; then
    out=$(printf '%s' "$payload" | env CODEX_TEST_GUARD=on CLAUDE_HOOK_RUNTIME="$runtime" CLAUDE_FIRE_LOG="$FIRE_LOG" "$HOOK")
  else
    out=$(printf '%s' "$payload" | env -u CLAUDE_HOOK_RUNTIME CODEX_TEST_GUARD=on CLAUDE_FIRE_LOG="$FIRE_LOG" "$HOOK")
  fi
  if [ -z "$out" ]; then echo none; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "none"'; fi
}

# fire_record_count: how many records the last run appended to the fire log.
# grep -c prints 0 and exits 1 on an empty log, which set -e would take as a
# fixture crash, so the status is swallowed and the count is read from stdout.
fire_record_count() { grep -c . "$FIRE_LOG" 2>/dev/null || true; }

# fire_field <index>: one pipe-separated field of the fire log's first record.
# log-rule-fire.sh writes
# <utc-timestamp>|<rule-or-gate>|<hook>|<decision>|<repo-basename>, so 2 is the
# rule, 3 is the hook, and 4 is the decision or outcome.
fire_field() { head -1 "$FIRE_LOG" 2>/dev/null | cut -d'|' -f"$1"; }

# The bypass itself: silent to the model, loud in the telemetry.
[ "$(decision_with_fire_log Write /repo/apps/server/tests/services/test_score_posting.py codex)" = "none" ] || { echo "FAIL: expected none for a py test file under CLAUDE_HOOK_RUNTIME=codex with the fire log redirected"; exit 1; }
[ "$(fire_record_count)" = "1" ] || { echo "FAIL: expected exactly 1 rule fire for the codex-runtime bypass on a test file, got $(fire_record_count)"; exit 1; }
[ "$(fire_field 2)" = "R-907" ] || { echo "FAIL: expected the bypass fire to name rule R-907, got '$(fire_field 2)'"; exit 1; }
[ "$(fire_field 3)" = "codex-test-author-guard" ] || { echo "FAIL: expected the bypass fire to name hook codex-test-author-guard, got '$(fire_field 3)'"; exit 1; }
[ "$(fire_field 4)" = "codex-runtime" ] || { echo "FAIL: expected the bypass fire outcome to be codex-runtime, got '$(fire_field 4)'"; exit 1; }

# Editing an existing test file is the case that was being denied before the
# marker existed, so it is the case whose bypass most needs a record.
[ "$(decision_with_fire_log Edit /repo/src/__tests__/handlers/authHandler.test.ts codex)" = "none" ] || { echo "FAIL: expected none for an Edit of a ts test file under CLAUDE_HOOK_RUNTIME=codex with the fire log redirected"; exit 1; }
[ "$(fire_record_count)" = "1" ] || { echo "FAIL: expected exactly 1 rule fire for the codex-runtime bypass on an edited ts test file, got $(fire_record_count)"; exit 1; }
[ "$(fire_field 4)" = "codex-runtime" ] || { echo "FAIL: expected the ts bypass fire outcome to be codex-runtime, got '$(fire_field 4)'"; exit 1; }

# A file the guard never cared about is not a bypass and must not be logged as
# one, or every production file Codex writes would look like a suppressed ask.
[ "$(decision_with_fire_log Write /repo/apps/server/app/services/score_posting.py codex)" = "none" ] || { echo "FAIL: expected none for a production py file under CLAUDE_HOOK_RUNTIME=codex"; exit 1; }
[ "$(fire_record_count)" = "0" ] || { echo "FAIL: expected no rule fire for a production file under CLAUDE_HOOK_RUNTIME=codex, got $(fire_record_count)"; exit 1; }
[ "$(decision_with_fire_log Edit /repo/apps/client/web/src/components/Header.vue codex)" = "none" ] || { echo "FAIL: expected none for a Vue component under CLAUDE_HOOK_RUNTIME=codex"; exit 1; }
[ "$(fire_record_count)" = "0" ] || { echo "FAIL: expected no rule fire for a Vue component under CLAUDE_HOOK_RUNTIME=codex, got $(fire_record_count)"; exit 1; }

# Fixture data inside a test tree is not test logic, so it is not a suppressed
# ask either.
[ "$(decision_with_fire_log Write /repo/apps/server/tests/fixtures/greenhouse_board.json codex)" = "none" ] || { echo "FAIL: expected none for json fixture data under CLAUDE_HOOK_RUNTIME=codex"; exit 1; }
[ "$(fire_record_count)" = "0" ] || { echo "FAIL: expected no rule fire for json fixture data under CLAUDE_HOOK_RUNTIME=codex, got $(fire_record_count)"; exit 1; }

# The ask path keeps its own record: moving the runtime check down must not
# cost the fire the guard already logged when it does ask.
[ "$(decision_with_fire_log Write /repo/apps/server/tests/services/test_score_posting.py)" = "ask" ] || { echo "FAIL: expected ask for a py test file with no CLAUDE_HOOK_RUNTIME and the fire log redirected"; exit 1; }
[ "$(fire_record_count)" = "1" ] || { echo "FAIL: expected exactly 1 rule fire for the ask path, got $(fire_record_count)"; exit 1; }
[ "$(fire_field 2)" = "R-907" ] || { echo "FAIL: expected the ask fire to name rule R-907, got '$(fire_field 2)'"; exit 1; }
[ "$(fire_field 4)" = "ask" ] || { echo "FAIL: expected the ask fire outcome to be ask, got '$(fire_field 4)'"; exit 1; }

echo "PASS: codex-test-author-guard"
