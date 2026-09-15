#!/usr/bin/env bash
# PreToolUse(Bash) hook. Two tiers:
#   - DENY  (Claude cannot run it, no confirmation offered): destructive
#     data-loss actions targeting PRODUCTION. Hard prohibition per R-101.
#   - ASK   (explicit user confirmation): other large-scale destructive DB
#     actions (staging / remote / ambiguous) and writes against remote DBs.
# Low-noise: read-only operations and local databases pass through untouched.
#
# Added after a staging wipe (integration-test cleanup ran against a remote
# DB and deleted real records). A behavioral rule against destructive ops
# fails silently under pressure; this hook makes it mechanical.
#
# MCP database servers (neon, supabase) reach the same managed Postgres through
# a tool call that carries no shell command, so this hook exited on line 1 for
# every one of them and R-101 was Bash-only (2026-08-21 engineering audit P1-2).
# The MCP path below reuses this file's statement classification rather than
# duplicating it: one authority for what "destructive" means.
set -uo pipefail

input="$(cat)"
tool="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"

# An MCP payload has no .command. Scan the whole tool_input for a statement,
# but only for tools whose action names a SQL or migration primitive: a page
# body or an issue description quoting "DELETE FROM" is prose, not a statement.
is_mcp=0
if [ -z "$cmd" ]; then
    case "$tool" in
        mcp__*)
            action="$(printf '%s' "${tool##*__}" | sed -E 's/([a-z0-9])([A-Z])/\1_\2/g' | tr 'A-Z-' 'a-z_')"
            case "$action" in
                *sql* | *migration* | *migrate* | *ddl* | *execute* | *query*) ;;
                *) exit 0 ;;
            esac
            cmd="$(printf '%s' "$input" | jq -r '.tool_input | tostring' 2>/dev/null)"
            [ -z "$cmd" ] && exit 0
            is_mcp=1
            ;;
        *) exit 0 ;;
    esac
fi

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

# An MCP payload names its target by project or branch identifier, never by
# connection string, so the environment cannot be read off the call. The mapping
# lives in a file the user maintains, one "<environment> <identifier>" pair per
# line (environment is production, staging, or local). An unlisted target is
# unknown, and unknown is never treated as safe: it asks.
mcp_target="unknown"
if [ "$is_mcp" -eq 1 ]; then
    targets_file="${CLAUDE_MCP_DB_TARGETS:-$HOME/.claude/enforce/mcp-database-targets.txt}"
    if [ -f "$targets_file" ]; then
        while read -r environment identifier || [ -n "$environment" ]; do
            case "$environment" in '' | '#'*) continue ;; esac
            [ -z "$identifier" ] && continue
            case "$cmd" in
                *"$identifier"*) mcp_target="$environment"; break ;;
            esac
        done < "$targets_file"
    fi
    case "$mcp_target" in
        production) prod=1; remote=1 ;;
        staging) remote=1 ;;
    esac
fi

# --- Decide ---------------------------------------------------------------

# A local database is the developer's own; never prompt.
if [ "$is_mcp" -eq 1 ] && [ "$mcp_target" = "local" ]; then
    exit 0
fi

# Non-destructive MCP writes already draw one ask from mcp-action-guard (R-105).
# Speaking again here would double-prompt the same call for no new information.
if [ "$is_mcp" -eq 1 ] && [ "$destructive" -eq 0 ]; then
    exit 0
fi

if [ "$is_mcp" -eq 1 ] && [ "$destructive" -eq 1 ] && [ "$prod" -eq 0 ]; then
    emit ask "Destructive SQL (DROP / TRUNCATE / DELETE FROM / migration down) through $tool, against a $mcp_target target. Confirm the project and branch this reaches before running. Record the identifier in enforce/mcp-database-targets.txt so R-101 can classify it next time; an unlisted target can only ask, never hard-block."
fi

# Local databases are the developer's own; never prompt. Exempt only when
# localhost is named and the command is not also remote/production-targeted.
if [ "$remote" -eq 0 ] && [ "$prod" -eq 0 ] \
    && printf '%s\n' "$cmd" | grep -Eqi 'localhost|127\.0\.0\.1'; then
    exit 0
fi

# HARD PROHIBITION (R-101): destructive data-loss against production cannot be
# performed by Claude. Deny outright -- no confirmation option is offered.
if [ "$destructive" -eq 1 ] && [ "$prod" -eq 1 ]; then
    emit deny "Destructive action against PRODUCTION is prohibited (R-101) and cannot be run by Claude. If genuinely required, a human must do it manually."
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
