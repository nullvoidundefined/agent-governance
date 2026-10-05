#!/usr/bin/env bash
# PreToolUse(Bash) hook. Gates commands that mutate cloud infrastructure, DNS
# or email-auth records, clusters, PaaS apps, or a production database: cloud
# CLIs, provider API calls, terraform, pulumi, kubectl, helm, PaaS CLIs, ORM
# and migration commands, and SQL without a WHERE (spec
# docs/specs/2026-10-04-harness-hardening.md, B-1 to B-18). defaultMode is
# auto, so an ask can resolve without a person; anything human-only is denied,
# and the reason names the command for the human to run.
#
# This file is the thin fail-closed layer; the rules live in infra_judge.py,
# which decides per simple command using shell-command-segments.py, the parser
# destructive-ops-guard.sh uses. While the judge is unusable (python3 missing,
# the judge file absent, a non-zero exit, or no finish within
# JUDGE_TIMEOUT_SECONDS) every Bash call is denied. The judge runs in the
# background with a watchdog because macOS has no GNU timeout (bash 3.2).
#
# Always exits 0: an erroring PreToolUse hook is a non-decision, so the hook
# reports through its output, never its status.
set -uo pipefail

# Seconds the judge may run before it counts as unusable.
JUDGE_TIMEOUT_SECONDS=10

INFRA_JUDGE="$(dirname "${BASH_SOURCE[0]}")/infra_judge.py"
JUDGE_DOWN_REASON="infra-mutation-guard hook BLOCKED this call: its judge (python3 running hooks/infra_judge.py) is unavailable, failed, or timed out, so no cloud, DNS, infrastructure or production command can be checked. Restore the harness with sync.sh, or install the developer tools that provide python3."

# log_audit_output <decision JSON>: appends the decision to the tool-call audit
# log through hooks/audit-log-append.sh; never fails, prints, or changes it.
log_audit_output() {
    local helper
    helper="$(dirname "${BASH_SOURCE[0]}")/audit-log-append.sh"
    [ -f "$helper" ] && . "$helper" && audit_log_hook_output "${input:-}" infra-mutation-guard "$1"
    return 0
}

# Prints a deny decision with the judge-down reason and exits.
deny_judge_down() {
    log_audit_output "{\"hookSpecificOutput\":{\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"judge unavailable\"}}"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$JUDGE_DOWN_REASON"
    exit 0
}

# True when the event is a Bash call with a command. Uses jq when present;
# without it, any event naming the Bash tool counts, so it fails closed.
is_bash_call() {
    if command -v jq >/dev/null 2>&1; then
        [ "$(printf '%s' "$1" | jq -r 'if (.tool_name // "Bash") == "Bash" then (.tool_input.command // "") else "" end' 2>/dev/null)" != "" ]
        return
    fi
    printf '%s' "$1" | grep -Eq '"tool_name"[[:space:]]*:[[:space:]]*"Bash"|"command"[[:space:]]*:'
}

input="$(cat)"
is_bash_call "$input" || exit 0
command -v python3 >/dev/null 2>&1 && [ -f "$INFRA_JUDGE" ] || deny_judge_down

out_file="$(mktemp 2>/dev/null)" || deny_judge_down
python3 "$INFRA_JUDGE" <<< "$input" >"$out_file" 2>/dev/null &
pid=$!
ticks=0
max_ticks=$((JUDGE_TIMEOUT_SECONDS * 20))
while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$max_ticks" ]; then
        kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        rm -f "$out_file"
        deny_judge_down
    fi
    sleep 0.05
    ticks=$((ticks + 1))
done
status=0
wait "$pid" 2>/dev/null || status=$?
decision="$(cat "$out_file")"
rm -f "$out_file"
[ "$status" -eq 0 ] || deny_judge_down
[ -z "$decision" ] || { log_audit_output "$decision"; printf '%s\n' "$decision"; }
exit 0
