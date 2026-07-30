#!/usr/bin/env bash
# push-ruff-gate.sh: on `git push`, run the bundled enforcement ruff config over
# the Python files added/changed in the outgoing diff. Deny the push on any
# violation of the AST-tier rule analogs (R-324/R-326/R-329; code mapping in
# enforce/ruff-enforce.toml). The Python counterpart of push-eslint-gate.sh:
# heavy work runs once per push, not per edit; only lines the outgoing diff
# adds can deny (--added-only parity, 2026-07-10, Ian-approved); fails OPEN
# with a stderr note when no ruff binary is available, because a missing tool
# must not block legitimate work.
set -euo pipefail

# shellcheck source=../enforce/resolveOutgoingBase.sh
source "$HOME/.claude/enforce/resolveOutgoingBase.sh"

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
printf '%s' "$CMD" | grep -Eq '(^|[;&|[:space:]])git[[:space:]]+push' || exit 0

# Repo exemption: same allowlist as push-eslint-gate (origin URL per line).
EXEMPT_FILE="$HOME/.claude/enforce/exempt-repos.txt"
if [ -f "$EXEMPT_FILE" ]; then
  ORIGIN_URL=$(git remote get-url origin 2>/dev/null || true)
  if [ -n "$ORIGIN_URL" ] && grep -qxF "$ORIGIN_URL" "$EXEMPT_FILE"; then
    exit 0
  fi
fi

BASE=$(resolve_outgoing_base)
[ -z "$BASE" ] && exit 0

FILES=$(git diff --name-only --diff-filter=ACMR "$BASE"..HEAD 2>/dev/null | grep -E '\.py$' || true)
[ -z "$FILES" ] && exit 0

if [ -n "${CLAUDE_RUFF_CMD:-}" ]; then
  RUFF="$CLAUDE_RUFF_CMD"
elif command -v ruff >/dev/null 2>&1; then
  RUFF="ruff"
elif command -v uvx >/dev/null 2>&1; then
  RUFF="uvx ruff"
else
  echo "push-ruff-gate: no ruff or uvx on PATH, skipping the Python AST gate (install ruff or uv)" >&2
  exit 0
fi

TOP="$(git rev-parse --show-toplevel)"
CONFIG="$HOME/.claude/enforce/ruff-enforce.toml"

# The set of file:line pairs the outgoing diff adds; only these can deny.
ADDED=$(git diff -U0 --diff-filter=ACMR "$BASE"..HEAD -- '*.py' 2>/dev/null | awk '
  /^\+\+\+ b\// { file = substr($0, 7); next }
  /^@@/ {
    split($3, parts, ",")
    start = substr(parts[1], 2) + 0
    count = (length(parts) > 1) ? parts[2] + 0 : 1
    for (i = 0; i < count; i++) print file ":" (start + i)
  }')
[ -z "$ADDED" ] && exit 0

RESULTS=$(cd "$TOP" && printf '%s\n' "$FILES" | xargs $RUFF check --config "$CONFIG" --output-format json --no-cache 2>/dev/null || true)
printf '%s' "$RESULTS" | jq -e 'type == "array"' >/dev/null 2>&1 || {
  echo "push-ruff-gate: ruff produced no parseable output, skipping (fails open)" >&2
  exit 0
}

REPORT=$(printf '%s' "$RESULTS" | jq -r --arg added "$ADDED" --arg top "$TOP/" '
  ($added | split("\n") | map(select(length > 0))) as $lines
  | [ .[]
      | (.filename | ltrimstr($top)) as $rel
      | ($rel + ":" + (.location.row | tostring)) as $key
      | select($lines | index($key))
      | "\($rel):\(.location.row) \(.code) \(.message)" ]
  | .[]' 2>/dev/null || true)

if [ -n "$REPORT" ]; then
  jq -n --arg r "ruff enforcement failed on the outgoing diff (R-324/R-326/R-329 Python analogs; mapping in enforce/ruff-enforce.toml). Fix the violations:
$REPORT" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
fi
exit 0
