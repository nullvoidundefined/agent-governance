#!/usr/bin/env bash
# migration-defaults-guard.sh
#
# PreToolUse hook. Enforces R-328 for files under a /migrations/ path.
# Denies the two unambiguous migration-default anti-patterns:
#   1. Nested quotes:        default: "'active'"   (double-wrapped literal)
#   2. Bare-string SQL call: default: 'now()'      (must be pgm.func(...))
#
# Correct forms pass untouched: bare constant (default: 'active'),
# pgm.func() expressions (default: pgm.func('now()')), and non-string
# defaults (default: 0). Files outside /migrations/ are ignored.
#
# Claude Code feeds stdin JSON: { tool_name, tool_input: { ... } }.
# Matched content per tool: Write -> .tool_input.content,
# Edit -> .tool_input.new_string. Match emits a deny on stdout; no match
# emits nothing. Exit 0 either way (the JSON controls the decision).

set -euo pipefail

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')

case "$TOOL" in
  Write) CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // ""') ;;
  Edit)  CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // ""') ;;
  *)     exit 0 ;;
esac

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""')
if ! printf '%s' "$FILE_PATH" | grep -q '/migrations/'; then
  exit 0
fi

# Nested quotes inside a default value: a quoted string that itself
# contains the other quote character right after `default:`.
NESTED_RE='default:[[:space:]]*("[^"]*'\''|'\''[^'\'']*")'
# Bare single-quoted default whose value is a SQL function call (has
# parentheses). pgm.func(...) is exempt because its value starts with
# `pgm`, not a quote, so this anchored pattern never matches it.
SQL_CALL_RE='default:[[:space:]]*'\''[^'\'']*\([^'\'']*\)[^'\'']*'\'''

if printf '%s' "$CONTENT" | grep -qE "$NESTED_RE" \
   || printf '%s' "$CONTENT" | grep -qE "$SQL_CALL_RE"; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "migration-defaults-guard hook BLOCKED this migration edit: a column default violates R-328. Use a bare string for a constant (default: '\''active'\'') and pgm.func() for a SQL expression (default: pgm.func('\''now()'\'')). Never nest quotes (default: \"'\''active'\''\" is wrong) and never pass a SQL call as a bare string (default: '\''now()'\'' is wrong). Fix the default and retry."
    }
  }'
fi

exit 0
