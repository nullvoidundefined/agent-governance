#!/usr/bin/env bash
# PreToolUse(Bash) hook. Two tiers:
#   - DENY  (Claude cannot run it, no confirmation offered): destructive
#     data-loss actions targeting PRODUCTION. Hard prohibition per R-110.
#   - ASK   (explicit user confirmation): other large-scale destructive DB
#     actions (staging / remote / ambiguous) and writes against remote DBs.
# Low-noise: read-only operations and local databases pass through untouched.
#
# Added after a staging wipe (integration-test cleanup ran against a remote
# DB and deleted real records). A behavioral rule against destructive ops
# fails silently under pressure; this hook makes it mechanical.
set -uo pipefail

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -z "$cmd" ] && exit 0

upper="$(printf '%s' "$cmd" | tr '[:lower:]' '[:upper:]')"

emit() {
    # $1 = permissionDecision (deny|ask), $2 = reason
    jq -n --arg d "$1" --arg r "$2" '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: $d,
            permissionDecisionReason: $r
        }
    }'
    exit 0
}

# --- Classify the command -------------------------------------------------

# Destructive = irreversible data loss. Benign writes (UPDATE/INSERT) are NOT
# destructive, so admin updates against prod are not hard-denied (they still ask).
destructive=0
if printf '%s\n' "$upper" | grep -Eq 'DROP[[:space:]]+(DATABASE|TABLE)|TRUNCATE([[:space:]]|$)|DELETE[[:space:]]+FROM' \
    || printf '%s\n' "$cmd" | grep -Eqi 'pg_restore|migrate:down'; then
    destructive=1
fi

# Aimed at a managed/remote (production OR staging) database.
remote=0
if printf '%s\n' "$cmd" | grep -Eqi 'neon\.tech|railway\.app'; then
    remote=1
fi
if printf '%s\n' "$cmd" | grep -Eqi 'railway[[:space:]]+(run|up)' \
    && printf '%s\n' "$cmd" | grep -Eqi '(-e|--environment)[[:space:]]+(production|staging)'; then
    remote=1
fi

# Specifically production.
prod=0
if printf '%s\n' "$cmd" | grep -Eqi 'railway[[:space:]]+(run|up)' \
    && printf '%s\n' "$cmd" | grep -Eqi '(-e|--environment)[[:space:]]+production'; then
    prod=1
fi
if printf '%s\n' "$cmd" | grep -Eqi 'node_env[^a-z0-9]+production'; then
    prod=1
fi

# --- Decide ---------------------------------------------------------------

# Local databases are the developer's own; never prompt. Exempt only when
# localhost is named and the command is not also remote/production-targeted.
if [ "$remote" -eq 0 ] && [ "$prod" -eq 0 ] \
    && printf '%s\n' "$cmd" | grep -Eqi 'localhost|127\.0\.0\.1'; then
    exit 0
fi

# HARD PROHIBITION (R-110): destructive data-loss against production cannot be
# performed by Claude. Deny outright -- no confirmation option is offered.
if [ "$destructive" -eq 1 ] && [ "$prod" -eq 1 ]; then
    emit deny "Destructive action against PRODUCTION is prohibited (R-110) and cannot be run by Claude. If genuinely required, a human must do it manually."
fi

# ASK: destructive verbs against any other target (staging / remote / unknown).
if [ "$destructive" -eq 1 ]; then
    emit ask "Destructive SQL (DROP / TRUNCATE / DELETE FROM / pg_restore / migrate:down) detected. Confirm the target database before running."
fi

# ASK: non-destructive writes against a managed/remote database.
if [ "$remote" -eq 1 ]; then
    if printf '%s\n' "$cmd" | grep -Eqiw 'update|insert|alter|create'; then
        emit ask "Write against a managed/remote (production or staging) database. Confirm before running."
    fi
fi

exit 0
