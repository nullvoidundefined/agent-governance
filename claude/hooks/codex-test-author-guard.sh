#!/usr/bin/env bash
# codex-test-author-guard.sh: PreToolUse (Write, Edit) ask for R-907. Tests
# are authored by the codex CLI (OpenAI) as a separate process; the model
# writing the implementation never writes or edits its own tests. When Claude's
# Write or Edit targets a test file, ask, so touching a test is a decision the
# user confirms (a codex-authored test believed wrong is a DISPUTE, not an
# edit). The codex CLI writes files from its own process, not through these
# tools, so the normal R-907 flow never trips this guard.
#
# What counts as a test file:
#   - basename test_*.py, *_test.py, conftest.py
#   - basename *.test.* or *.spec.* (ts, tsx, js, jsx, mjs)
#   - any path with a /tests/, /__tests__/, or /e2e/ directory segment whose
#     basename matches one of the above, or any .py/.ts/.tsx/.js file directly
#     inside such a segment
# Fixture data (json, sql, txt, captured responses) is not a test and stays
# silent: R-907 covers test logic, not the data it reads.
#
# Escape hatch: CODEX_TEST_GUARD=off in the environment silences the guard
# for harness-internal work (for example this repo's own fixture suite).
# Limitation: a Bash heredoc writing a test file is not seen here; that path
# is covered by content-gate's test-anti-pattern scan, not by this guard.
set -uo pipefail
[ "${CODEX_TEST_GUARD:-on}" = "off" ] && exit 0
INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
case "$TOOL" in Write | Edit) ;; *) exit 0 ;; esac
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""')
[ -n "$FILE" ] || exit 0
BASE=$(basename "$FILE")

is_test=0
case "$BASE" in
  test_*.py | *_test.py | conftest.py) is_test=1 ;;
  *.test.ts | *.test.tsx | *.test.js | *.test.jsx | *.test.mjs) is_test=1 ;;
  *.spec.ts | *.spec.tsx | *.spec.js | *.spec.jsx | *.spec.mjs) is_test=1 ;;
esac
if [ "$is_test" = 0 ]; then
  case "$FILE" in
    */tests/* | */__tests__/* | */e2e/*)
      case "$BASE" in
        *.py | *.ts | *.tsx | *.js) is_test=1 ;;
      esac
      ;;
  esac
fi
[ "$is_test" = 1 ] || exit 0

LOG_RULE_FIRE_HELPER="$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh"
[ -f "$LOG_RULE_FIRE_HELPER" ] && source "$LOG_RULE_FIRE_HELPER"
type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
log_rule_fire "R-907" "codex-test-author-guard" "ask"
jq -n --arg r "codex-test-author-guard (R-907): $BASE is a test file, and tests are authored by the codex CLI, never by the model writing the implementation. Dispatch codex to write or change it, or return DISPUTE: <test> if a codex-authored test looks wrong. Confirm only if this edit genuinely must come from Claude (for example harness plumbing the user asked for)." \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
exit 0
