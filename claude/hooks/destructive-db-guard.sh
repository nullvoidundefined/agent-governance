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
# A session can start this hook with HOME unset; under set -u every $HOME
# expansion below would abort before a decision, which is an allow (IAN-436).
: "${HOME:=$(cd ~ 2>/dev/null && pwd)}"

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

# The statement text, read three ways on one line: as written, with /* */
# comments removed, and with -- comments removed as well, each with all
# whitespace (newlines included) collapsed to one space. A comment cannot then
# split a keyword (DROP/**/TABLE), and a quoted '--' or an option such as
# --host cannot hide the rest, because the first readings keep it.
upper="$(printf '%s' "$cmd" | awk 'BEGIN { RS = "\001" } {
    blocks = $0; gsub(/\/\*([^*]|\*+[^*\/])*\*+\//, " ", blocks)
    lines = blocks; gsub(/--[^\n]*/, " ", lines)
    out = $0 " ; " blocks " ; " lines; gsub(/[[:space:]]+/, " ", out)
    print out
}' | tr '[:lower:]' '[:upper:]')"

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
# Destructive verbs other than DELETE FROM: dropping a database, schema,
# table, owned objects or column, truncating, and the tools that do the same
# (pg_restore, migrate:down, dropdb, mysqladmin drop).
DESTRUCTIVE_SQL_VERBS='DROP[[:space:]]+(DATABASE|SCHEMA|TABLE|OWNED|COLUMN)|TRUNCATE([[:space:]]|$)'
DESTRUCTIVE_TOOLS='pg_restore|migrate:down|(^|[^A-Za-z0-9_-])dropdb([^A-Za-z0-9_-]|$)|mysqladmin[[:space:]].*[[:space:]]drop([[:space:]]|$)'

# True when an ALTER TABLE drops a column without the COLUMN keyword
# (ALTER TABLE t DROP email). Dropping a constraint, index, key, default or
# NOT NULL loses no data.
alter_drops_column() {
    grep -Eo 'ALTER[[:space:]]+TABLE[^;]*' <<< "$upper" \
        | grep -Eo '(^|[^A-Z0-9_])DROP[[:space:]]+[^[:space:];,(]+' \
        | grep -Eqv 'DROP[[:space:]]+(CONSTRAINT|INDEX|KEY|PRIMARY|FOREIGN|CHECK|DEFAULT|NOT|IDENTITY|EXPRESSION|PARTITIONING)$'
}

# True when the command carries a destructive verb other than DELETE FROM.
has_destructive_verb() {
    grep -Eq "$DESTRUCTIVE_SQL_VERBS" <<< "$upper" || alter_drops_column
}

if has_destructive_verb || grep -Eq "DELETE[[:space:]]+FROM" <<< "$upper" \
    || grep -Eqi "$DESTRUCTIVE_TOOLS" <<< "$cmd"; then
    destructive=1
fi

# Aimed at a managed/remote (production OR staging) database.
remote=0
if grep -Eqi 'neon\.tech|railway\.app' <<< "$cmd"; then
    remote=1
fi
if grep -Eqi 'railway[[:space:]]+(run|up)' <<< "$cmd" \
    && grep -Eqi '(-e|--environment)[[:space:]]+(production|staging)' <<< "$cmd"; then
    remote=1
fi

# Specifically production.
prod=0
if grep -Eqi 'railway[[:space:]]+(run|up)' <<< "$cmd" \
    && grep -Eqi '(-e|--environment)[[:space:]]+production' <<< "$cmd"; then
    prod=1
fi
if grep -Eqi 'node_env[^a-z0-9]+production' <<< "$cmd"; then
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

# True when every DELETE FROM statement in the command carries a WHERE.
deletes_are_bounded() {
    local statement
    while IFS= read -r statement; do
        grep -Eq 'WHERE' <<< "$statement" || return 1
    done < <(grep -Eo "DELETE[[:space:]]+FROM[^;\"']*" <<< "$upper")
    return 0
}

# True when the command names no database host other than a local one: every
# -h/--host value and URL host is localhost, 127.0.0.1, ::1, or a unix socket
# path. Anything that can carry a target this cannot read fails it: a shell
# variable ($PROD_DB), a *HOST= or *SERVICE= assignment (PGSERVICE=), a host=
# or service= conninfo, a glued -hHOST, or a launcher that runs the command on
# a remote machine or platform (ssh, heroku, railway, wrangler, fly, kubectl).
names_only_local_target() {
    local host
    grep -Eq '\$\{?[A-Za-z_]' <<< "$cmd" && return 1
    grep -Eqi '(^|[^-A-Za-z0-9_])[A-Za-z_]*(host|service)=' <<< "$cmd" && return 1
    grep -Eq '(^|[[:space:]])-h[^[:space:]]' <<< "$cmd" && return 1
    grep -Eq '(^|[^A-Za-z0-9_-])(heroku|railway|wrangler|fly|flyctl|kubectl|ssh)([^A-Za-z0-9_-]|$)' <<< "$cmd" && return 1
    while IFS= read -r host; do
        host="${host##*@}"
        case "$host" in
            '' | localhost | localhost:* | 127.0.0.1 | 127.0.0.1:* | '[::1]'* | /*) ;;
            *) return 1 ;;
        esac
    done < <(grep -Eo "[A-Za-z][A-Za-z0-9+.-]*://[^/[:space:]\"'?]*" <<< "$cmd" | sed -E 's#^[^:]*://##'
             grep -Eo "(^|[[:space:]])(-h|--host)(=|[[:space:]]+)[^[:space:]]+" <<< "$cmd" \
                 | sed -E "s/^[[:space:]]*(-h|--host)(=|[[:space:]]+)//; s/[\"']//g")
    return 0
}

# B-16 (docs/specs/2026-10-04-harness-hardening.md): a DELETE bounded by WHERE
# against a local target is routine work on the developer's own data. It
# applies only when DELETE FROM is the sole destructive verb in the command.
if [ "$destructive" -eq 1 ] && [ "$is_mcp" -eq 0 ] && [ "$remote" -eq 0 ] && [ "$prod" -eq 0 ] \
    && ! has_destructive_verb \
    && ! grep -Eqi "$DESTRUCTIVE_TOOLS" <<< "$cmd" \
    && deletes_are_bounded && names_only_local_target; then
    destructive=0
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
    && grep -Eqi 'localhost|127\.0\.0\.1' <<< "$cmd"; then
    exit 0
fi

# HARD PROHIBITION (R-101): destructive data-loss against production cannot be
# performed by Claude. Deny outright -- no confirmation option is offered.
if [ "$destructive" -eq 1 ] && [ "$prod" -eq 1 ]; then
    emit deny "Destructive action against PRODUCTION is prohibited (R-101) and cannot be run by Claude. If genuinely required, a human must do it manually."
fi

# ASK: destructive verbs against any other target (staging / remote / unknown).
if [ "$destructive" -eq 1 ]; then
    emit ask "Destructive SQL (DROP / TRUNCATE / DELETE FROM / pg_restore / migrate:down / dropdb) detected. Confirm the target database before running."
fi

# ASK: non-destructive writes against a managed/remote database.
if [ "$remote" -eq 1 ]; then
    if grep -Eqiw 'update|insert|alter|create' <<< "$cmd"; then
        emit ask "Write against a managed/remote (production or staging) database. Confirm before running."
    fi
fi

exit 0
