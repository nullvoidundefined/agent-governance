#!/usr/bin/env bash
# PreToolUse(Bash) hook. Catches destructive command forms that settings.json
# prefix globs cannot express:
#   - `gh api` with a mutating method, in any flag spelling
#   - curl/wget piped into an interpreter
#   - writes to git core.hooksPath
#   - credential readout (gh auth token, macOS keychain)
#   - tampering with ~/.claude/hooks
#
# Permission rules match a literal prefix, so `gh api --method=DELETE` slips
# past `Bash(gh api -X DELETE*)` while `curl x | shasum` is wrongly caught by
# `Bash(curl * | sh*)`. This hook normalizes flag syntax first, then decides on
# word boundaries. Enforces R-101 (destructive actions), R-102 (secrets never
# enter chat), R-107 (hooksPath drift), R-203 (never bypass a guard).
set -uo pipefail

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -z "$cmd" ] && exit 0

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

# Normalized form: newlines become `;` so they survive as command separators,
# attached shorthand (-XDELETE) splits, flag `=` becomes a space, whitespace
# collapses. Every spelling of a flag reduces to `-X DELETE`.
norm="$(printf '%s' "$cmd" | tr '\n' ';' \
    | sed -e 's/-X\([A-Za-z]\)/-X \1/g' -e 's/=/ /g' -e 's/[[:space:]][[:space:]]*/ /g')"

# Command position: start of string, or just past a separator. Anchoring here is
# what stops `git commit -m "... gh api -X DELETE ..."` from tripping the guard,
# since a quoted mention is preceded by ordinary text rather than a separator.
AT="(^|[;&|(])[[:space:]]*"

# --- gh api: mutating HTTP methods ----------------------------------------

if printf '%s' "$norm" | grep -Eqi "${AT}gh api([[:space:]]|$)"; then
    method="$(printf '%s' "$norm" \
        | grep -Eoi '(-X|--method) [A-Za-z]+' \
        | head -1 \
        | awk '{print toupper($2)}')"

    if [ "$method" = "DELETE" ]; then
        emit deny "destructive-command-guard hook BLOCKED this call: 'gh api' with method DELETE bypasses the Bash(gh repo delete*) and Bash(gh release delete*) deny rules, which match on command text only. Deleting a repo, release, or branch through the raw API is irreversible. A human runs this manually if it is genuinely required."
    fi
    case "$method" in
        PUT | PATCH | POST)
            emit ask "'gh api' with method $method mutates GitHub state through the raw API, bypassing the per-verb gh rules. Confirm the endpoint and payload before running."
            ;;
    esac
fi

# --- curl / wget piped into an interpreter --------------------------------

# The trailing boundary is what keeps `curl ... | shasum` from matching.
if printf '%s' "$norm" \
    | grep -Eqi "${AT}(sudo[[:space:]]+)?(curl|wget)[^|;&]*\|[[:space:]]*(sudo[[:space:]]+)?(sh|bash|zsh|ksh|fish|python3?|node|perl|ruby)([[:space:]]|$)"; then
    emit deny "destructive-command-guard hook BLOCKED this call: a remote payload is piped straight into an interpreter, which executes unreviewed third-party code with your full user privileges (R-203). Download to a file, read it, then run it as a separate step."
fi

# --- git core.hooksPath ---------------------------------------------------

# Reads are fine; hookspath-drift-check.sh depends on them.
if printf '%s' "$norm" | grep -Eqi "${AT}git config[^|;&]*core\.hooksPath" \
    && ! printf '%s' "$norm" | grep -Eqi 'git config (--get|--get-all|--list|-l)([[:space:]]|$)'; then
    emit deny "destructive-command-guard hook BLOCKED this call: writing core.hooksPath redirects or disables every lefthook guard in one command (R-107, R-203). Change it manually if the move is deliberate."
fi

# --- credential readout ---------------------------------------------------

if printf '%s' "$norm" | grep -Eqi "${AT}gh auth token([[:space:]]|$)" \
    || printf '%s' "$norm" | grep -Eqi "${AT}gh auth status[^|;&]*(-t|--show-token)([[:space:]]|$)"; then
    emit deny "destructive-command-guard hook BLOCKED this call: it prints a live GitHub token to stdout, which lands in the transcript, the session log, and scrollback (R-102). Read the token from the keychain at execution time instead of echoing it."
fi

if printf '%s' "$norm" | grep -Eqi "${AT}security (find-generic-password|find-internet-password)[^|;&]*(-w|-g)([[:space:]]|$)"; then
    emit deny "destructive-command-guard hook BLOCKED this call: it prints a keychain secret to stdout (R-102). Resolve the value inside the consuming process so the plaintext never enters the transcript."
fi

# --- tampering with the hooks directory -----------------------------------

if printf '%s' "$norm" | grep -Eqi "${AT}(rm|mv|chmod|chown|truncate|shred)([[:space:]]|$)[^|;&]*\.claude/hooks"; then
    emit deny "destructive-command-guard hook BLOCKED this call: it removes, moves, or strips execution from the hooks directory, disabling the safety harness (R-203). Never bypass a guard without explicit approval in the current turn."
fi

# --- gh commands whose effect is irreversible or rule-evading -------------

if printf '%s' "$norm" | grep -Eqi "${AT}gh alias set([[:space:]]|$)"; then
    emit deny "destructive-command-guard hook BLOCKED this call: a gh alias re-labels a denied command so it no longer matches the deny list, evading Bash(gh repo delete*) and its siblings (R-203)."
fi

if printf '%s' "$norm" | grep -Eqi "${AT}gh repo edit[^|;&]*--visibility public([[:space:]]|$)"; then
    emit deny "destructive-command-guard hook BLOCKED this call: making a repository public is effectively irreversible once forks, caches, and archives pick it up. A human makes this call deliberately."
fi

exit 0
