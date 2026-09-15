#!/usr/bin/env bash
# verification-gate.sh: Stop hook closing the R-509 hole. The four push-*-gate
# hooks lint at push time and nothing anywhere ran tests, so a turn could end
# on a red suite and only CI would say so. This runs the project's own checks
# before the turn is allowed to end.
#
# Silent on success. On failure it blocks the Stop with the real command
# output, not a summary, so the next turn sees the actual error.
#
# Scope decisions (2026-09-04 config audit):
#   - Global, not per-project: the mechanism (find and run THIS project's
#     checks) is universal; the commands are discovered, never hardcoded, so
#     `pnpm test` never fires in a Go repo. A per-project Stop hook would have
#     to be recreated in every repo, which is what ~/.claude exists to avoid.
#   - Dirty-tree gated: a read-only exploration turn must not pay a full suite
#     (R-9xx, lesson_hook_runtime_budget). Checks run only when the working
#     tree is dirty or the branch carries unpushed commits.
#   - Fails open: a repo with no discoverable check command is not blocked,
#     otherwise every prose repo deadlocks on every turn.
#
# Per-project override and escape hatch: `.claude/verify.sh` in the project
# root wins over all discovery. `CLAUDE_SKIP_VERIFY=1` bypasses entirely.
#
# Registered on Stop and, since 2026-09-06, on SubagentStop (the TDD harness
# assessment C-4: the implementer subagent is the role that makes a slice
# green, and it was the one turn the gate never saw). On SubagentStop the
# agent_type field selects: a role whose enforce/role-policy.json entry is
# deny ["any"] (slice-critic, spec-conformance-review) writes nothing and is
# never blocked by a red tree it cannot fix; every other subagent is gated
# exactly like the main session. .claude/verify.sh is a gate input protected
# by hooks/protected-path-guard.sh (R-410).
set -uo pipefail

INPUT=$(cat)

# stop_hook_active means this Stop was already blocked once. Continuing would
# loop forever on a suite that stays red.
[ "$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')" = "true" ] && exit 0
[ -n "${CLAUDE_SKIP_VERIFY:-}" ] && exit 0

# SubagentStop: skip the roles that cannot have written anything.
EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // "Stop"')
if [ "$EVENT" = "SubagentStop" ]; then
  AGENT=$(printf '%s' "$INPUT" | jq -r '.agent_type // ""')
  POLICY="${CLAUDE_ROLE_POLICY_FILE:-$HOME/.claude/enforce/role-policy.json}"
  if [ -n "$AGENT" ] && [ -f "$POLICY" ] && jq -e --arg a "$AGENT" '.roles[$a].deny == ["any"]' "$POLICY" >/dev/null 2>&1; then
    exit 0
  fi
fi

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""')
[ -n "$CWD" ] || CWD="$PWD"
[ -d "$CWD" ] || exit 0
cd "$CWD" 2>/dev/null || exit 0

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$ROOT" 2>/dev/null || exit 0

# Nothing changed this session means nothing to verify.
has_changes() {
  [ -n "$(git status --porcelain 2>/dev/null)" ] && return 0
  git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 || return 1
  [ "$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)" -gt 0 ]
}
has_changes || exit 0

# Memo of the last tree the checks passed on (2026-09-04 config audit P3-2). A
# long editing session ends many turns on the same dirty tree; without this
# every one of them paid the full suite. The key covers HEAD, the diff against
# it, and the content of every untracked file, so any edit invalidates it and a
# red run never writes it.
MEMO_DIR="${CLAUDE_VERIFY_MEMO_DIR:-$HOME/.claude/.verify-memo}"
tree_key() {
  {
    git rev-parse HEAD 2>/dev/null
    git diff HEAD 2>/dev/null
    git ls-files -o --exclude-standard -z 2>/dev/null | while IFS= read -r -d '' untracked; do
      shasum -a 256 "$untracked" 2>/dev/null
    done
  } | shasum -a 256 | awk '{print $1}'
}
MEMO_FILE="$MEMO_DIR/$(printf '%s' "$ROOT" | shasum | awk '{print $1}')"
TREE_KEY=$(tree_key)
if [ -n "$TREE_KEY" ] && [ -f "$MEMO_FILE" ] && [ "$(cat "$MEMO_FILE" 2>/dev/null)" = "$TREE_KEY" ]; then
  exit 0
fi

TIMEOUT_SECONDS="${CLAUDE_VERIFY_TIMEOUT:-600}"
MAX_OUTPUT_LINES=200
MAX_OUTPUT_CHARS=8000

# Discovery. Each branch appends shell commands, one per line, in run order.
CHECKS=""
add_check() { CHECKS="${CHECKS}${1}"$'\n'; }

package_manager() {
  [ -f pnpm-lock.yaml ] && { echo pnpm; return; }
  [ -f yarn.lock ] && { echo yarn; return; }
  echo npm
}

has_npm_script() { jq -e --arg s "$1" '.scripts[$s] // empty' package.json >/dev/null 2>&1; }

if [ -f .claude/verify.sh ]; then
  add_check "bash .claude/verify.sh"
elif [ -f enforce/tests/run-tests.sh ] && [ -f hooks/tests/run-tests.sh ] && [ -f CLAUDE.md ]; then
  # The ~/.claude repo itself. It has no typecheck: no TypeScript source, and
  # enforce/*.mjs is plain JS with no tsc. Both fixture suites are the checks.
  add_check "bash enforce/tests/run-tests.sh"
  add_check "bash hooks/tests/run-tests.sh"
elif [ -f package.json ]; then
  PM=$(package_manager)
  has_npm_script test && add_check "$PM test"
  for script in typecheck type-check; do
    has_npm_script "$script" && { add_check "$PM run $script"; break; }
  done
elif [ -f pyproject.toml ] || [ -f requirements.txt ] || [ -f setup.py ]; then
  command -v pytest >/dev/null 2>&1 && add_check "pytest -q"
  if command -v mypy >/dev/null 2>&1 && { grep -q '\[tool.mypy\]' pyproject.toml 2>/dev/null || [ -f mypy.ini ]; }; then
    add_check "mypy ."
  fi
elif [ -f go.mod ]; then
  command -v go >/dev/null 2>&1 && { add_check "go test ./..."; add_check "go vet ./..."; }
elif [ -f Gemfile ] && [ -d spec ]; then
  command -v bundle >/dev/null 2>&1 && add_check "bundle exec rspec"
fi

CHECKS=$(printf '%s' "$CHECKS" | sed '/^$/d')
[ -n "$CHECKS" ] || exit 0

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT_SECONDS" bash -c "$1" 2>&1
  else
    bash -c "$1" 2>&1
  fi
}

block() {
  source "$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh" 2>/dev/null || true
  type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
  log_rule_fire "R-509" "verification-gate" "block"
  jq -n --arg r "$1" '{decision:"block",reason:$r}'
  exit 0
}

while IFS= read -r check; do
  [ -n "$check" ] || continue
  OUTPUT=$(run_with_timeout "$check")
  STATUS=$?
  [ "$STATUS" -eq 0 ] && continue

  TAIL=$(printf '%s' "$OUTPUT" | tail -n "$MAX_OUTPUT_LINES" | tail -c "$MAX_OUTPUT_CHARS")
  if [ "$STATUS" -eq 124 ]; then
    TAIL="Command exceeded CLAUDE_VERIFY_TIMEOUT (${TIMEOUT_SECONDS}s) and was killed."$'\n\n'"$TAIL"
  fi
  block "R-509 verification gate: \`${check}\` failed (exit ${STATUS}) in ${ROOT}.

${TAIL}

Fix the root cause (R-204: never make this pass by relaxing the gate that caught it). To end the turn without fixing, re-run with CLAUDE_SKIP_VERIFY=1 set."
done <<< "$CHECKS"

# Every check passed: remember this tree so the next turn on it is free.
if [ -n "$TREE_KEY" ]; then
  mkdir -p "$MEMO_DIR" 2>/dev/null && printf '%s\n' "$TREE_KEY" > "$MEMO_FILE" 2>/dev/null || true
fi

exit 0
