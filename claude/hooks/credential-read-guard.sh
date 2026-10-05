#!/usr/bin/env bash
# PreToolUse(Bash, Read, Grep) hook. Denies a call that would bring a
# credential's value into the agent's context: a command naming a credential
# file (.env, ~/.aws, *.tfvars, ...), an environment dump, a print of one
# credential variable, or a Read or Grep of a credential path (spec
# docs/specs/2026-10-05-credential-reads.md, C-1 to C-7). Programs may still
# use credentials; only printing them into the transcript is stopped.
#
# This file is the thin fail-closed layer; the rules live in
# credential_judge.py, which decides per simple command using
# shell-command-segments.py. While the judge is unusable (python3 missing, the
# judge file absent, a non-zero exit, or no finish within
# JUDGE_TIMEOUT_SECONDS) every Bash, Read and Grep call is denied. The judge
# runs in the background with a watchdog because macOS has no GNU timeout.
#
# Stateless, and never echoes a value: reasons name a path's credential entry
# or a variable's name. Always exits 0; it reports through its output.
set -uo pipefail

# Seconds the judge may run before it counts as unusable.
JUDGE_TIMEOUT_SECONDS=10

CREDENTIAL_JUDGE="$(dirname "${BASH_SOURCE[0]}")/credential_judge.py"
JUDGE_DOWN_REASON="credential-read-guard hook BLOCKED this call: its judge (python3 running hooks/credential_judge.py) is unavailable, failed, or timed out, so no command or file read can be checked for credentials. Restore the harness with sync.sh, or install the developer tools that provide python3."

# Prints a deny decision with the judge-down reason and exits.
deny_judge_down() {
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$JUDGE_DOWN_REASON"
    exit 0
}

# True when the event is a call this guard judges: Bash with a command, or
# Read or Grep. Without jq, any event naming one of those tools counts, so it
# fails closed.
is_judged_call() {
    if command -v jq >/dev/null 2>&1; then
        [ "$(printf '%s' "$1" | jq -r '(.tool_name // "Bash") as $t
            | if $t == "Bash" then (if (.tool_input.command // "") != "" then "yes" else "" end)
              elif $t == "Read" or $t == "Grep" then "yes" else "" end' 2>/dev/null)" = "yes" ]
        return
    fi
    printf '%s' "$1" | grep -Eq '"tool_name"[[:space:]]*:[[:space:]]*"(Bash|Read|Grep)"|"command"[[:space:]]*:'
}

input="$(cat)"
is_judged_call "$input" || exit 0
command -v python3 >/dev/null 2>&1 && [ -f "$CREDENTIAL_JUDGE" ] || deny_judge_down

out_file="$(mktemp 2>/dev/null)" || deny_judge_down
python3 "$CREDENTIAL_JUDGE" <<< "$input" >"$out_file" 2>/dev/null &
pid=$!
ticks=0
max_ticks=$((JUDGE_TIMEOUT_SECONDS * 100))
while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$max_ticks" ]; then
        kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        rm -f "$out_file"
        deny_judge_down
    fi
    sleep 0.01
    ticks=$((ticks + 1))
done
status=0
wait "$pid" 2>/dev/null || status=$?
decision="$(cat "$out_file")"
rm -f "$out_file"
[ "$status" -eq 0 ] || deny_judge_down
[ -z "$decision" ] || printf '%s\n' "$decision"
exit 0
