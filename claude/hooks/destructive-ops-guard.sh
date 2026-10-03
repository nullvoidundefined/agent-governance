#!/usr/bin/env bash
# PreToolUse(Bash) hook. Guards commands that delete, overwrite, or tear down
# things outside git: file removal, container and cluster tooling, infrastructure
# tools, and disk utilities. It decides per simple command, using the parse that
# shell-command-segments.py produces, so a quoted mention of a program is not a
# call to it.
#
# This file holds the fail-closed layer: when the parser (python3 running
# hooks/shell-command-segments.py) is missing or fails, any command that names
# a guarded program as a word is denied, and every other command passes with no
# decision. Per-segment policy is added on top of this layer.
#
# Always exits 0: an erroring PreToolUse hook is a non-decision, so the hook
# reports through its output, never its status. Enforces R-101 (destructive
# actions) and R-203 (never bypass a guard).
set -uo pipefail

# Guarded programs, as an extended-regex alternation. The one place to extend
# the list; a name matches only as a whole word (see deny_when_unparsed).
GUARDED_PROGRAMS='rm|rmdir|unlink|trash|find|xargs|rsync|docker|docker-compose|podman|nerdctl|kubectl|helm|terraform|pulumi|dd|diskutil|mkfs'

input="$(cat)"
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"
[ "$tool_name" = "Bash" ] || exit 0
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -z "$cmd" ] && exit 0

# Prints a PreToolUse decision and exits. $1 = permissionDecision (deny|ask),
# $2 = reason.
emit() {
    jq -n --arg d "$1" --arg r "$2" '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: $d,
            permissionDecisionReason: $r
        }
    }'
    exit 0
}

SHELL_SEGMENTS_HELPER="$(dirname "${BASH_SOURCE[0]}")/shell-command-segments.py"

# Fails closed: when the parser is missing or fails (a python3 that exists but
# exits non-zero, such as the macOS stub without developer tools, or an
# exception in the helper), the per-segment checks cannot run, so any command
# naming a guarded program is refused. A program matches as a word, never
# inside a longer one such as dockerfile or firmware.
deny_when_unparsed() {
    if grep -Eq "(^|[^A-Za-z0-9_-])(${GUARDED_PROGRAMS})([^A-Za-z0-9_-]|\$)" <<< "$cmd"; then
        emit deny "destructive-ops-guard hook BLOCKED this call: its command parser (python3 and hooks/shell-command-segments.py) is unavailable or failed, so destructive commands cannot be checked (R-203). Restore the harness with sync.sh, or install the developer tools that provide python3."
    fi
    COMMAND_SEGMENTS=""
}

# Prints the command's simple commands, one per line, words separated by \037
# and redirect operators prefixed with \036; exits non-zero when the parser is
# missing or fails.
list_command_segments() {
    command -v python3 >/dev/null 2>&1 && [ -f "$SHELL_SEGMENTS_HELPER" ] || return 1
    python3 "$SHELL_SEGMENTS_HELPER" <<< "$1" 2>/dev/null
}

COMMAND_SEGMENTS="$(list_command_segments "$cmd")" || deny_when_unparsed

exit 0
