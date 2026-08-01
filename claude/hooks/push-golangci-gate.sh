#!/usr/bin/env bash
# push-golangci-gate.sh: on `git push`, run the bundled enforcement golangci
# config over the module when the outgoing diff touches Go files. Deny the push
# on any violation of the AST-tier rule analogs (R-324 mnd, R-329 nolintlint;
# mapping in enforce/golangci-enforce.yml) that sits on a line the diff adds.
# golangci-lint analyzes packages, not file lists, so the run covers ./... and
# the added-lines filter scopes the deny (--added-only parity, 2026-07-10,
# Ian-approved). Fails OPEN with a stderr note when golangci-lint is absent or
# its output is unparseable (v1/v2 flag drift; see the config header).
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

FILES=$(git diff --name-only --diff-filter=ACMR "$BASE"..HEAD 2>/dev/null | grep -E '\.go$' || true)
[ -z "$FILES" ] && exit 0

if [ -n "${CLAUDE_GOLANGCI_CMD:-}" ]; then
  # Explicit operator override: trusted by definition (test/dev configuration).
  GOLANGCI="$CLAUDE_GOLANGCI_CMD"
elif command -v golangci-lint >/dev/null 2>&1; then
  # SECURITY (2026-07-31 security audit P0): golangci-lint compiles the target
  # tree, and compilation of untrusted Go (cgo directives, toolchain edge
  # cases) is a code-execution surface. Unlike lint-only parsing, this cannot
  # be made safe by config, so the real binary runs ONLY in repos the operator
  # has explicitly trusted (origin URL per line, mirror of exempt-repos.txt).
  TRUSTED_FILE="$HOME/.claude/enforce/gate-trusted-repos.txt"
  ORIGIN_URL=$(git remote get-url origin 2>/dev/null || true)
  if [ -z "$ORIGIN_URL" ] || [ ! -f "$TRUSTED_FILE" ] || ! grep -qxF "$ORIGIN_URL" "$TRUSTED_FILE"; then
    echo "push-golangci-gate: repo not in enforce/gate-trusted-repos.txt, skipping the Go AST gate (linting Go requires compiling the tree; add the origin URL to opt in)" >&2
    exit 0
  fi
  GOLANGCI="golangci-lint"
else
  echo "push-golangci-gate: no golangci-lint on PATH, skipping the Go AST gate" >&2
  exit 0
fi

TOP="$(git rev-parse --show-toplevel)"
CONFIG="$HOME/.claude/enforce/golangci-enforce.yml"

# The set of file:line pairs the outgoing diff adds; only these can deny.
ADDED=$(git diff -U0 --diff-filter=ACMR "$BASE"..HEAD -- '*.go' 2>/dev/null | awk '
  /^\+\+\+ b\// { file = substr($0, 7); next }
  /^@@/ {
    split($3, parts, ",")
    start = substr(parts[1], 2) + 0
    count = (length(parts) > 1) ? parts[2] + 0 : 1
    for (i = 0; i < count; i++) print file ":" (start + i)
  }')
[ -z "$ADDED" ] && exit 0

# v1 emits JSON with --out-format json; v2 moved to --output.json.path stdout.
RESULTS=$(cd "$TOP" && $GOLANGCI run --config "$CONFIG" --out-format json ./... 2>/dev/null || true)
printf '%s' "$RESULTS" | jq -e '.Issues | type == "array"' >/dev/null 2>&1 \
  || RESULTS=$(cd "$TOP" && $GOLANGCI run --config "$CONFIG" --output.json.path stdout ./... 2>/dev/null || true)
printf '%s' "$RESULTS" | jq -e '.Issues | type == "array"' >/dev/null 2>&1 || {
  echo "push-golangci-gate: golangci-lint produced no parseable output, skipping (fails open)" >&2
  exit 0
}

REPORT=$(printf '%s' "$RESULTS" | jq -r --arg added "$ADDED" '
  ($added | split("\n") | map(select(length > 0))) as $lines
  | [ .Issues[]
      | (.Pos.Filename + ":" + (.Pos.Line | tostring)) as $key
      | select($lines | index($key))
      | "\($key) \(.FromLinter) \(.Text)" ]
  | .[]' 2>/dev/null || true)

if [ -n "$REPORT" ]; then
  source "$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh" 2>/dev/null || true
  type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
  log_rule_fire "golangci-ast" "push-golangci-gate" "deny"
  jq -n --arg r "golangci-lint enforcement failed on the outgoing diff (R-324/R-329 Go analogs; mapping in enforce/golangci-enforce.yml). Fix the violations:
$REPORT" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
fi
exit 0
