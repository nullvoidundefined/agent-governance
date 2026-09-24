#!/usr/bin/env bash
# codex-test-author-guard.sh: PreToolUse (Write, Edit) ask for R-907. Tests
# are authored by the codex CLI (OpenAI) as a separate process; the model
# writing the implementation never writes or edits its own tests. When Claude's
# Write or Edit targets a test file, ask, so touching a test is a decision the
# user confirms (a codex-authored test believed wrong is a DISPUTE, not an
# edit).
#
# Tier scope (IAN-333, owner decision 2026-09-23): the ask applies only when the
# task-start ledger records Complex or Saga, or records nothing, for the branch
# checked out in the test file's repository. A Standard or Trivial ledger lets
# the session write its own failing test, which the R-412 lock still forces to
# come before the implementation.
#
# Runtime marker: codex is not outside this guard. Its CLI runs the same hooks
# through codex/hooks/codex-hook-adapter.sh, which registers this guard on the
# Write|Edit matcher (codex/hooks.json) and translates an ask into a deny,
# because Codex hooks cannot pause for a confirmation. Unmarked, the guard
# therefore denied codex the one job R-907 gives it: a `codex exec
# -s workspace-write` run writing a test file was blocked by this hook
# (observed 2026-09-19 in template-fastapi-nuxt). The adapter now exports
# CLAUDE_HOOK_RUNTIME=codex into every hook child it runs, and this guard
# exits silently on exactly that value. A Claude Code session sets no such
# variable, so its own writes to a test file still ask. The match is equality,
# not a prefix: a neighbouring runtime name must not inherit the silence.
#
# Residual scope, deliberately accepted: the marker names the RUNTIME, not the
# ROLE. R-907's invariant is about role, that tests never come from the author
# of the implementation, so the silence is wider than the invariant: any codex
# run may now write a test file, including one doing implementation rather than
# the orchestrated test-author dispatch. Inside that dispatch `tdd.sh validate
# test-author` still proves every changed path is a test or fixture path;
# outside it, nothing does. Narrowing this needs a slice marker the orchestrator
# sets and the adapter forwards, which is a separate change.
#
# The 2026-09-19 report also said new test files were created successfully while
# edits of existing ones were denied. That asymmetry is not reproducible and is
# not claimed here: this guard reads Write and Edit identically, and a pre-fix
# adapter denies an `Add File` of a test path as readily as an `Update File`.
# Either the report conflated two runs, or those creates reached no Write|Edit
# gate at all, which would mean secret-scan, structure-gate, content-gate and
# protected-path-guard missed them too and that route is still open. Re-derive
# it from a CLAUDE_CODEX_HOOK_DEBUG log before treating it as understood.
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
# Scope: R-907 targets the author that also writes implementation. The
# dedicated test-author subagent (R-707) never writes implementation, since
# R-411 confines it to test and fixture trees, so it satisfies the
# different-author intent and passes silently; every other agent_type asks.
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
AGENT=$(printf '%s' "$INPUT" | jq -r '.agent_type // ""')
[ "$AGENT" = "test-author" ] && exit 0
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
# The codex CLI authoring a test IS R-907's intended flow, so there is nothing
# to ask about; only the adapter sets this marker (see the header). The check
# sits here, past the test-file decision, rather than at the top of the script,
# so that a silenced guard is recorded: a bypass that writes no telemetry is
# indistinguishable in the fire log from a guard that was never reached.
if [ "${CLAUDE_HOOK_RUNTIME:-}" = "codex" ]; then
  log_rule_fire "R-907" "codex-test-author-guard" "codex-runtime"
  exit 0
fi
# read_ledger_tier <file>: prints the tier the task-start ledger records for
# the branch checked out in <file>'s repository, or nothing when there is no
# repository, no readable ledger, or a ledger written for another branch.
read_ledger_tier() {
  local dir top branch ledger
  dir=$(dirname "$1")
  while [ ! -d "$dir" ] && [ "$dir" != "/" ]; do dir=$(dirname "$dir"); done
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 0
  branch=$(git -C "$top" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 0
  ledger="$top/.claude/task-tier.json"
  [ -f "$ledger" ] || return 0
  jq -r --arg b "$branch" 'select(type == "object" and .branch == $b) | .tier // "" | strings' "$ledger" 2>/dev/null
}
# Standard and Trivial work writes its own failing test under the R-412 lock
# (owner decision 2026-09-23, IAN-333); the independent author R-907 asks for
# is a Complex and Saga requirement, so only those tiers reach the ask.
case "$(read_ledger_tier "$FILE")" in
  standard | trivial)
    log_rule_fire "R-907" "codex-test-author-guard" "tier-exempt"
    exit 0
    ;;
esac
log_rule_fire "R-907" "codex-test-author-guard" "ask"
jq -n --arg r "codex-test-author-guard (R-907): $BASE is a test file, and in the Complex and Saga tiers tests come from an author other than the implementer: the test-author subagent by default, or the codex CLI when the owner opts in. Dispatch one of them, or return DISPUTE: <test> if a locked test looks wrong. Confirm only if this edit genuinely must come from this session (for example harness plumbing the user asked for)." \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
exit 0
