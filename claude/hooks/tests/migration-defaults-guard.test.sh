#!/usr/bin/env bash
# Test harness for migration-defaults-guard.sh (backs R-214).
#
# R-214: migration defaults use bare strings for constants
# (default: 'active') and pgm.func() for SQL expressions; never nest
# quotes. This hook denies the two unambiguous anti-patterns in any
# file under a /migrations/ path:
#   1. Nested quotes:        default: "'active'"
#   2. Bare-string SQL call: default: 'now()'   (should be pgm.func(...))
# It must NOT flag bare constants, pgm.func(...) defaults, non-string
# defaults, or any file outside /migrations/.
#
# Run: ~/.claude/hooks/tests/migration-defaults-guard.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../migration-defaults-guard.sh"

fail=0
check() {
    local name="$1"; shift
    if "$@"; then
        echo "PASS: $name"
    else
        echo "FAIL: $name"
        fail=1
    fi
}

# Build a PreToolUse input JSON for a given tool/path/content and run the
# hook, capturing stdout. jq -n --arg keeps quoting safe for payloads
# that themselves contain single and double quotes.
run_hook() {
    local tool="$1" key="$2" fp="$3" content="$4"
    jq -n --arg tool "$tool" --arg key "$key" --arg fp "$fp" --arg c "$content" \
        '{tool_name: $tool, tool_input: ({file_path: $fp} + {($key): $c})}' \
        | bash "$HOOK"
}

emits_deny()    { [ -n "$(run_hook "$@")" ] && run_hook "$@" | grep -q '"permissionDecision": "deny"'; }
emits_nothing() { [ -z "$(run_hook "$@")" ]; }

MIG="app/migrations/1700000000000_add_status.ts"
SRC="app/services/jobs/buildResume.ts"

# --- DENY: the two anti-patterns, in a migration file ---
check "deny nested quotes (Write)" \
    emits_deny  Write content "$MIG" "  status: { type: 'text', default: \"'active'\" },"
check "deny bare-string SQL call (Write)" \
    emits_deny  Write content "$MIG" "  created: { type: 'timestamptz', default: 'now()' },"
check "deny nested quotes (Edit new_string)" \
    emits_deny  Edit new_string "$MIG" "  status: { default: \"'active'\" },"

# --- ALLOW: correct forms, in a migration file ---
check "allow bare constant string" \
    emits_nothing Write content "$MIG" "  status: { type: 'text', default: 'active' },"
check "allow pgm.func() SQL expression" \
    emits_nothing Write content "$MIG" "  created: { type: 'timestamptz', default: pgm.func('now()') },"
check "allow non-string default" \
    emits_nothing Write content "$MIG" "  retries: { type: 'integer', default: 0 },"

# --- PASSTHROUGH: anti-pattern outside a migration file is ignored ---
check "passthrough anti-pattern in non-migration file" \
    emits_nothing Write content "$SRC" "const x = { default: 'now()' };"

exit "$fail"
