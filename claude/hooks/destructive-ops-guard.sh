#!/usr/bin/env bash
# PreToolUse(Bash) hook. Guards commands that delete, overwrite, or tear down
# things outside git: file removal, container and cluster tooling, infrastructure
# tools, and disk utilities. It decides per simple command, using the parse that
# shell-command-segments.py produces, so a quoted mention of a program is not a
# call to it.
#
# This file holds the fail-closed layer: while the parser (python3 running
# hooks/shell-command-segments.py) is unusable, every Bash call is denied, since
# word matching is bypassed by quoting, case, and eval (owner decision
# 2026-10-03). The parser is unusable when python3 is missing, exits non-zero,
# the helper file is absent, it prints nothing for a non-empty command, or it
# does not finish within PARSER_TIMEOUT_SECONDS. A missing jq also denies every
# Bash call it can identify; non-Bash calls and empty or malformed input get no
# decision. Per-segment policy is added on top of this layer.
#
# Always exits 0: an erroring PreToolUse hook is a non-decision, so the hook
# reports through its output, never its status. Enforces R-101 (destructive
# actions) and R-203 (never bypass a guard).
set -uo pipefail

# Seconds the parser may run before it counts as unusable.
PARSER_TIMEOUT_SECONDS=10

SHELL_SEGMENTS_HELPER="$(dirname "${BASH_SOURCE[0]}")/shell-command-segments.py"

PARSER_DOWN_REASON="destructive-ops-guard hook BLOCKED this call: its command parser (python3 running hooks/shell-command-segments.py) is unavailable, failed, or timed out, so no command can be checked (R-203). Restore the harness with sync.sh, or install the developer tools that provide python3."

# Prints a PreToolUse decision and exits. $1 = permissionDecision (deny|ask),
# $2 = reason. Without jq the JSON is built by hand; callers pass reasons with
# no quote or backslash characters.
emit() {
    if command -v jq >/dev/null 2>&1; then
        jq -n --arg d "$1" --arg r "$2" '{
            hookSpecificOutput: {
                hookEventName: "PreToolUse",
                permissionDecision: $d,
                permissionDecisionReason: $r
            }
        }'
    else
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$1" "$2"
    fi
    exit 0
}

# Sets tool_name and cmd from the hook input in $1 when jq is present. Without
# jq it asks python3's json module; if that also fails, it greps for a Bash
# tool name and treats the command as present, so Bash calls still get denied.
read_hook_input() {
    tool_name=""
    cmd=""
    if command -v jq >/dev/null 2>&1; then
        tool_name="$(printf '%s' "$1" | jq -r '.tool_name // empty' 2>/dev/null)"
        cmd="$(printf '%s' "$1" | jq -r '.tool_input.command // empty' 2>/dev/null)"
        return
    fi
    if command -v python3 >/dev/null 2>&1; then
        tool_name="$(printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_name") or "")' 2>/dev/null)" || tool_name=""
        if [ -n "$tool_name" ]; then
            cmd="$(printf '%s' "$1" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("tool_input") or {}).get("command") or "")' 2>/dev/null)"
            return
        fi
    fi
    if printf '%s' "$1" | grep -Eq '"tool_name"[[:space:]]*:[[:space:]]*"Bash"'; then
        tool_name="Bash"
        cmd="(command unreadable without jq)"
    fi
}

# Prints the command's simple commands, one per line, words separated by \037
# and redirect operators prefixed with \036, into COMMAND_SEGMENTS. Returns
# non-zero when the parser is missing, fails, prints nothing, or runs past
# PARSER_TIMEOUT_SECONDS. The parser runs in the background writing to a temp
# file (not the hook's stdout), so a watchdog can kill it without leaving the
# hook's output open and without GNU timeout, which macOS lacks.
list_command_segments() {
    COMMAND_SEGMENTS=""
    command -v python3 >/dev/null 2>&1 && [ -f "$SHELL_SEGMENTS_HELPER" ] || return 1
    local out_file pid status=0 ticks=0 max_ticks=$((PARSER_TIMEOUT_SECONDS * 10))
    out_file="$(mktemp 2>/dev/null)" || return 1
    python3 "$SHELL_SEGMENTS_HELPER" <<< "$1" >"$out_file" 2>/dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$ticks" -ge "$max_ticks" ]; then
            kill -9 "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            rm -f "$out_file"
            return 1
        fi
        sleep 0.1
        ticks=$((ticks + 1))
    done
    wait "$pid" 2>/dev/null || status=$?
    COMMAND_SEGMENTS="$(cat "$out_file")"
    rm -f "$out_file"
    [ "$status" -eq 0 ] && [ -n "$COMMAND_SEGMENTS" ]
}

input="$(cat)"
read_hook_input "$input"
[ "$tool_name" = "Bash" ] || exit 0
[ -z "$cmd" ] && exit 0

# Without jq the per-segment policy cannot read its input, so the call is denied.
command -v jq >/dev/null 2>&1 || emit deny "destructive-ops-guard hook BLOCKED this call: jq is not installed, so the command parser output cannot be checked (R-203). Install jq."
list_command_segments "$cmd" || emit deny "$PARSER_DOWN_REASON"

exit 0
