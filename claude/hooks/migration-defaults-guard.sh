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
# Python migration files (.py, Alembic) get the server_default analogs:
# nested quotes and bare-string SQL calls deny; sa.text(...) passes.
#
# Claude Code feeds stdin JSON: { tool_name, tool_input: { ... } }.
# Matched content per tool: Write -> .tool_input.content,
# Edit -> .tool_input.new_string. Match emits a deny on stdout; no match
# emits nothing. Exit 0 either way (the JSON controls the decision).

# set -uo, no -e: an unexpected internal error under -e kills the hook before
# it can emit a decision, and a PreToolUse hook that emits nothing is an
# allow; a guard fails closed by structure, never open by accident
# (2026-09-16 audit P2-8; convention documented in enforce/README.md).
set -uo pipefail

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')

case "$TOOL" in
  Write) CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // ""') ;;
  Edit)  CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // ""') ;;
  *)     exit 0 ;;
esac

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""')
if ! grep -qE '/migrations/|(^|/)db/migrate/' <<< "$FILE_PATH"; then
  exit 0
fi

if grep -qE '(^|/)db/migrate/.*\.rb$' <<< "$FILE_PATH"; then
  # Rails (Ruby analog of R-328, CLAUDE-RUBY.md Migrations section).
  # Nested quotes: default: "'active'". Bare-string SQL call in either quote
  # style: default: "now()" / default: 'now()' (must be a lambda:
  # default: -> { "now()" }). The lambda form starts with ->, not a quote,
  # so neither pattern matches it.
  NESTED_RE='default:[[:space:]]*("[^"]*'\''|'\''[^'\'']*")'
  SQL_CALL_RE='default:[[:space:]]*("[^"]*\([^"]*\)[^"]*"|'\''[^'\'']*\([^'\'']*\)[^'\'']*'\'')'
  REASON="migration-defaults-guard hook BLOCKED this migration edit: a column default violates R-328 (Rails form). Use a bare string for a constant (default: \"active\") and a lambda for a SQL expression (default: -> { \"now()\" }). Never nest quotes (default: \"'active'\" is wrong) and never pass a SQL call as a bare string (default: \"now()\" is wrong). Fix the default and retry."
elif grep -q '\.py$' <<< "$FILE_PATH"; then
  # Alembic (Python analog of R-328, CLAUDE-PYTHON.md Migrations section).
  # Nested quotes: server_default="'active'". Bare-string SQL call:
  # server_default="now()" (must be sa.text(...)). sa.text("now()") is exempt
  # because after `=` comes `sa.text(`, not a quote.
  NESTED_RE='server_default[[:space:]]*=[[:space:]]*("[^"]*'\''|'\''[^'\'']*")'
  SQL_CALL_RE='server_default[[:space:]]*=[[:space:]]*("[^"]*\([^"]*\)[^"]*"|'\''[^'\'']*\([^'\'']*\)[^'\'']*'\'')'
  REASON="migration-defaults-guard hook BLOCKED this migration edit: a column default violates R-328 (Alembic form). Use a bare string for a constant (server_default=\"active\") and sa.text() for a SQL expression (server_default=sa.text(\"now()\")). Never nest quotes (server_default=\"'active'\" is wrong) and never pass a SQL call as a bare string (server_default=\"now()\" is wrong). Fix the default and retry."
else
  # Nested quotes inside a default value: a quoted string that itself
  # contains the other quote character right after `default:`.
  NESTED_RE='default:[[:space:]]*("[^"]*'\''|'\''[^'\'']*")'
  # Bare single-quoted default whose value is a SQL function call (has
  # parentheses). pgm.func(...) is exempt because its value starts with
  # `pgm`, not a quote, so this anchored pattern never matches it.
  SQL_CALL_RE='default:[[:space:]]*'\''[^'\'']*\([^'\'']*\)[^'\'']*'\'''
  REASON="migration-defaults-guard hook BLOCKED this migration edit: a column default violates R-328. Use a bare string for a constant (default: 'active') and pgm.func() for a SQL expression (default: pgm.func('now()')). Never nest quotes (default: \"'active'\" is wrong) and never pass a SQL call as a bare string (default: 'now()' is wrong). Fix the default and retry."
fi

if grep -qE "$NESTED_RE" <<< "$CONTENT" \
   || grep -qE "$SQL_CALL_RE" <<< "$CONTENT"; then
  LOG_RULE_FIRE_HELPER="$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh"
  [ -f "$LOG_RULE_FIRE_HELPER" ] && source "$LOG_RULE_FIRE_HELPER"
  type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
  log_rule_fire "R-328" "migration-defaults-guard" "deny"
  jq -n --arg r "$REASON" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
fi

exit 0
