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
# JUDGE_TIMEOUT_SECONDS) every Bash call is denied, and a Read or Grep is
# denied only when its path is a credential path by a plain name check (C-15).
# The judge runs in the background with a watchdog because macOS has no GNU
# timeout.
#
# Stateless, and never echoes a value: reasons name a path's credential entry
# or a variable's name. Always exits 0; it reports through its output.
set -uo pipefail

# Seconds the judge may run before it counts as unusable.
JUDGE_TIMEOUT_SECONDS=10

CREDENTIAL_JUDGE="$(dirname "${BASH_SOURCE[0]}")/credential_judge.py"
JUDGE_DOWN_REASON="credential-read-guard hook BLOCKED this call: its judge (python3 running hooks/credential_judge.py) is unavailable, failed, or timed out, so commands cannot be checked for credentials and a Read or Grep is checked only by its path name. Restore the harness with sync.sh, or install the developer tools that provide python3."

# Prints a deny decision with the judge-down reason and exits.
deny_judge_down() {
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$JUDGE_DOWN_REASON"
    exit 0
}

# True when a path is a credential path by its name or its ~/ entry alone; the
# judge's look-alike and symlink resolution are not available here.
is_credential_path() {
    local path="$1" name="${1##*/}" home="${HOME:-/nonexistent}"
    case "$path" in "~/"*) path="$home/${path#\~/}" ;; esac
    case "$name" in
        *.pub | known_hosts | .env.example | .env.sample | .env.template | .env.dist) return 1 ;;
        .env | .env.* | .envrc | .npmrc | id_rsa* | id_ed25519* | ?*.tfvars | ?*.tfstate | ?*.tfstate.backup \
            | ?*.pem | ?*.key | ?*.p12 | ?*.pfx | environ) return 0 ;;
    esac
    case "$path" in
        "$home"/.aws | "$home"/.aws/* | "$home"/.ssh | "$home"/.ssh/* | "$home"/.gnupg | "$home"/.gnupg/* \
            | "$home"/.kube | "$home"/.kube/* | "$home"/.azure | "$home"/.azure/* \
            | "$home"/.config/gcloud | "$home"/.config/gcloud/* | "$home"/.config/doctl | "$home"/.config/doctl/* \
            | "$home"/.wrangler | "$home"/.wrangler/* | "$home"/.config/.wrangler | "$home"/.config/.wrangler/* \
            | "$home"/.cloudflared | "$home"/.cloudflared/* | "$home"/.fly | "$home"/.fly/* \
            | "$home"/.docker/config.json | "$home"/.config/gh/hosts.yml | "$home"/.netrc | "$home"/.pgpass \
            | "$home"/.my.cnf | "$home"/.pypirc | "$home"/.terraform.d/credentials.tfrc.json) return 0 ;;
    esac
    return 1
}

# Called when the judge is unusable: a Bash call is denied; a Read or Grep is
# denied only when its path is a credential path by is_credential_path (C-15).
judge_down() {
    local tool path
    command -v jq >/dev/null 2>&1 || deny_judge_down
    tool="$(printf '%s' "$input" | jq -r '.tool_name // "Bash"' 2>/dev/null)" || deny_judge_down
    case "$tool" in
        Read) path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null)" || deny_judge_down ;;
        Grep) path="$(printf '%s' "$input" | jq -r '.tool_input.path // ""' 2>/dev/null)" || deny_judge_down ;;
        *) deny_judge_down ;;
    esac
    [ -n "$path" ] && is_credential_path "$path" && deny_judge_down
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
command -v python3 >/dev/null 2>&1 && [ -f "$CREDENTIAL_JUDGE" ] || judge_down

out_file="$(mktemp 2>/dev/null)" || judge_down
python3 "$CREDENTIAL_JUDGE" <<< "$input" >"$out_file" 2>/dev/null &
pid=$!
ticks=0
max_ticks=$((JUDGE_TIMEOUT_SECONDS * 100))
while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$max_ticks" ]; then
        kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        rm -f "$out_file"
        judge_down
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
