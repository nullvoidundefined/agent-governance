#!/usr/bin/env bash
# push-rubocop-gate.sh: on `git push`, run the bundled enforcement RuboCop
# config over the Ruby files added/changed in the outgoing diff. Deny the push
# on any violation of the AST-tier rule analogs (R-327 plus R-316/R-317/R-324
# naming support; cop mapping in enforce/rubocop-enforce.yml). Sibling of
# push-eslint-gate/push-ruff-gate: heavy work once per push, added lines only
# (--added-only parity, 2026-07-10, Ian-approved), fails OPEN with a stderr
# note when no RuboCop is available.
set -euo pipefail

# shellcheck source=../enforce/resolveOutgoingBase.sh
source "$HOME/.claude/enforce/resolveOutgoingBase.sh"

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
printf '%s' "$CMD" | grep -Eq '(^|[;&|[:space:]])git[[:space:]]+push' || exit 0

# Repo exemption: same allowlist as the other push gates (origin URL per line).
EXEMPT_FILE="$HOME/.claude/enforce/exempt-repos.txt"
if [ -f "$EXEMPT_FILE" ]; then
  ORIGIN_URL=$(git remote get-url origin 2>/dev/null || true)
  if [ -n "$ORIGIN_URL" ] && grep -qxF "$ORIGIN_URL" "$EXEMPT_FILE"; then
    exit 0
  fi
fi

BASE=$(resolve_outgoing_base)
[ -z "$BASE" ] && exit 0

FILES=$(git diff --name-only --diff-filter=ACMR "$BASE"..HEAD 2>/dev/null | grep -E '\.rb$' || true)
[ -z "$FILES" ] && exit 0

TOP="$(git rev-parse --show-toplevel)"
# SECURITY (2026-07-31 security audit P0): never resolve RuboCop through the
# target repo's bundle. `bundle exec` evaluates that repo's Gemfile (arbitrary
# Ruby) at push time, handing a cloned repo code execution. PATH-resolved
# RuboCop with our explicit --config only parses source; it executes nothing
# from the repo. Repos wanting their own RuboCop version run it in their own
# pre-commit, not here.
if [ -n "${CLAUDE_RUBOCOP_CMD:-}" ]; then
  RUBOCOP="$CLAUDE_RUBOCOP_CMD"
elif command -v rubocop >/dev/null 2>&1; then
  RUBOCOP="rubocop"
else
  echo "push-rubocop-gate: no rubocop on PATH, skipping the Ruby AST gate" >&2
  exit 0
fi

CONFIG="$HOME/.claude/enforce/rubocop-enforce.yml"

# The set of file:line pairs the outgoing diff adds; only these can deny.
ADDED=$(git diff -U0 --diff-filter=ACMR "$BASE"..HEAD -- '*.rb' 2>/dev/null | awk '
  /^\+\+\+ b\// { file = substr($0, 7); next }
  /^@@/ {
    split($3, parts, ",")
    start = substr(parts[1], 2) + 0
    count = (length(parts) > 1) ? parts[2] + 0 : 1
    for (i = 0; i < count; i++) print file ":" (start + i)
  }')
[ -z "$ADDED" ] && exit 0

RESULTS=$(cd "$TOP" && printf '%s\n' "$FILES" | xargs $RUBOCOP --format json --config "$CONFIG" -- 2>/dev/null || true)
printf '%s' "$RESULTS" | jq -e '.files | type == "array"' >/dev/null 2>&1 || {
  echo "push-rubocop-gate: rubocop produced no parseable output, skipping (fails open)" >&2
  exit 0
}

REPORT=$(printf '%s' "$RESULTS" | jq -r --arg added "$ADDED" '
  ($added | split("\n") | map(select(length > 0))) as $lines
  | [ .files[]
      | .path as $rel
      | .offenses[]
      | ($rel + ":" + (.location.start_line // .location.line | tostring)) as $key
      | select($lines | index($key))
      | "\($key) \(.cop_name) \(.message)" ]
  | .[]' 2>/dev/null || true)

if [ -n "$REPORT" ]; then
  jq -n --arg r "RuboCop enforcement failed on the outgoing diff (R-327 plus naming support; mapping in enforce/rubocop-enforce.yml). Fix the violations:
$REPORT" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
fi
exit 0
