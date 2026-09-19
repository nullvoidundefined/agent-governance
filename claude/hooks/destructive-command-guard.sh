#!/usr/bin/env bash
# PreToolUse(Bash) hook. Catches destructive command forms that settings.json
# prefix globs cannot express:
#   - `gh api` with a mutating method, in any flag spelling
#   - curl/wget piped into an interpreter
#   - writes to git core.hooksPath, and one-command overrides of it (-c,
#     --config-env, GIT_CONFIG_KEY_n, GIT_CONFIG_PARAMETERS)
#   - skipping git hooks with --no-verify (any accepted spelling), commit -n,
#     or a hook-manager variable (HUSKY=0, SKIP, LEFTHOOK=0)
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

if grep -Eqi "${AT}gh api([[:space:]]|$)" <<< "$norm"; then
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

# Reads are fine; hookspath-drift-check.sh and the R-107 investigation depend
# on them. A write is the key followed by a value token (or an --unset); a
# read leaves core.hooksPath as the final token, whatever read flag spelling
# precedes it (2026-09-16 audit P2-2: the old flag-spelling exemption denied
# the bare `git config core.hooksPath` read the rule itself mandates).
if grep -Eqi "${AT}git config[^|;&]*core\.hooksPath[[:space:]]+[^-[:space:];&|]" <<< "$norm" \
    || grep -Eqi "${AT}git config[^|;&]*--unset[^|;&]*core\.hooksPath" <<< "$norm"; then
    emit deny "destructive-command-guard hook BLOCKED this call: writing core.hooksPath redirects or disables every git hook in one command (R-107, R-203). Change it manually if the move is deliberate."
fi

# --- skipping git hooks: flags and hook-manager variables ----------------

# settings.json could only ask on `git commit --no-verify*`, a literal prefix
# that missed abbreviations, flags placed before the subcommand, and other
# subcommands (2026-09-19 ECC audit). Quoted text is blanked before splitting,
# so a commit message that mentions a flag never reads as the flag itself.
GIT_INVOCATION_HELPER="$(dirname "${BASH_SOURCE[0]}")/git-invocation.sh"
[ -f "$GIT_INVOCATION_HELPER" ] && . "$GIT_INVOCATION_HELPER"

# Prints one line per simple command in the input: newlines join as `;`, the
# text splits on separators, and leading space is trimmed. A quoted run stays
# one word: its quote marks become a leading Q, so `-m "--no-verify"` is not
# the flag, while separators and spaces inside it become `_`, so quoted text
# never starts a command. The content survives for checks that need it, such
# as `git -c "core.hooksPath=x"`. awk ends every line with a newline, which
# `read` needs: it drops an unterminated last line.
list_command_segments() {
    printf '%s' "$1" | tr '\n' ';' | awk '{
        text = ""; quote = ""
        for (i = 1; i <= length($0); i++) {
            c = substr($0, i, 1)
            if (quote != "") {
                if (c == quote) { quote = ""; continue }
                if (c ~ /[;&|() \t]/) c = "_"
                text = text c; continue
            }
            if (c == "\"" || c == "\047") { quote = c; text = text "Q"; continue }
            text = text c
        }
        print text
    }' | tr ';&|()' '\n\n\n\n\n' | awk '{ sub(/^[[:space:]]+/, ""); print }'
}

# Prints the command a segment runs once its leading `env` and VAR=value
# words are dropped.
drop_command_prefix() {
    printf '%s\n' "$1" \
        | sed -E 's/^((env[[:space:]]+)|([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+))*//'
}

# Prints a git command with its global options stripped, so the subcommand
# follows `git` directly.
strip_git_options() {
    printf '%s\n' "$1" \
        | if declare -F strip_git_global_options >/dev/null; then strip_git_global_options; else cat; fi
}

# True when a git invocation's subcommand runs hooks.
is_hook_running_git() {
    set -f
    set -- $1
    set +f
    [ "${1:-}" = git ] || return 1
    case "${2:-}" in commit | push | merge | rebase | am) return 0 ;; esac
    return 1
}

# True when one VAR=value word turns a hook manager off: husky, the
# pre-commit framework's SKIP list, or lefthook.
is_hook_skip_assignment() {
    case "$1" in
        HUSKY=0 | HUSKY_SKIP_HOOKS=* | SKIP=* | LEFTHOOK=0 | LEFTHOOK=false | LEFTHOOK_EXCLUDE=*) return 0 ;;
    esac
    return 1
}

# True when a VAR=value word sets core.hooksPath through git's environment
# config channels: GIT_CONFIG_KEY_n or GIT_CONFIG_PARAMETERS.
is_hookspath_env_assignment() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        git_config_key_[0-9]*=core.hookspath | git_config_key_[0-9]*=qcore.hookspath) return 0 ;;
        git_config_parameters=*core.hookspath*) return 0 ;;
    esac
    return 1
}

# True when a `key=value` config setting (quote marker allowed) sets
# core.hooksPath; the caller has lowercased it.
is_hookspath_setting() {
    case "${1#q}" in core.hookspath=*) return 0 ;; esac
    return 1
}

# True when the global options of one git command override core.hooksPath
# through -c or --config-env; options that take a separate argument skip it.
has_hookspath_option() {
    local word pending=""
    set -f
    set -- $(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    set +f
    shift
    for word in "$@"; do
        if [ -n "$pending" ]; then
            [ "$pending" = setting ] && is_hookspath_setting "$word" && return 0
            pending=""
            continue
        fi
        case "$word" in
            -c | --config-env) pending=setting ;;
            --config-env=*) is_hookspath_setting "${word#--config-env=}" && return 0 ;;
            -C | --git-dir | --work-tree | --namespace | --super-prefix) pending=argument ;;
            -*) ;;
            *) return 1 ;;
        esac
    done
    return 1
}

# True when an assignment ahead of the segment's command name (bare, after
# env, or after export) satisfies the named predicate.
has_leading_assignment() {
    local predicate="$1" word
    set -f
    set -- $2
    set +f
    for word in "$@"; do
        case "$word" in
            env | export) continue ;;
            *=*) "$predicate" "$word" && return 0 ;;
            *) return 1 ;;
        esac
    done
    return 1
}

# True when the argument is --no-verify or a prefix git accepts for it:
# --no-veri is the shortest, because --no-ve also matches --no-verbose.
is_no_verify_spelling() {
    [ "${#1}" -ge 9 ] || return 1
    case "--no-verify" in "$1"*) return 0 ;; esac
    return 1
}

# True when a short-flag cluster such as -an sets -n before any flag whose
# argument is attached (-mn is the message "n", -uno the mode "no").
is_commit_no_verify_cluster() {
    local cluster="${1#-}" index
    for ((index = 0; index < ${#cluster}; index++)); do
        case "${cluster:index:1}" in
            n) return 0 ;;
            m | F | C | c | t | u | S) return 1 ;;
        esac
    done
    return 1
}

# True when one hook-running `git <subcommand> <args>` line skips its hooks
# through a flag.
skips_git_hooks() {
    local subcommand arg
    set -f
    set -- $1
    set +f
    subcommand="${2:-}"
    shift 2
    for arg in "$@"; do
        is_no_verify_spelling "$arg" && return 0
        [ "$subcommand" = commit ] && [[ "$arg" =~ ^-[A-Za-z]+$ ]] \
            && is_commit_no_verify_cluster "$arg" && return 0
    done
    return 1
}

# An export earlier in the command reaches every later git in the same call,
# so it is remembered across segments; a bare prefix reaches only its own.
exported_hook_skip=0
exported_hookspath=0
while IFS= read -r segment; do
    if [[ "$segment" =~ ^export[[:space:]] ]]; then
        has_leading_assignment is_hook_skip_assignment "$segment" && exported_hook_skip=1
        has_leading_assignment is_hookspath_env_assignment "$segment" && exported_hookspath=1
        continue
    fi
    git_command="$(drop_command_prefix "$segment")"
    [[ "$git_command" =~ ^git([[:space:]]|$) ]] || continue
    if [ "$exported_hookspath" -eq 1 ] || has_leading_assignment is_hookspath_env_assignment "$segment" \
        || has_hookspath_option "$git_command"; then
        emit deny "destructive-command-guard hook BLOCKED this call: it overrides core.hooksPath for this git command (-c, --config-env, GIT_CONFIG_KEY_n, or GIT_CONFIG_PARAMETERS), which redirects or disables every git hook without touching git config (R-107, R-203). Run the command without the override."
    fi
    git_invocation="$(strip_git_options "$git_command")"
    is_hook_running_git "$git_invocation" || continue
    if [ "$exported_hook_skip" -eq 1 ] || has_leading_assignment is_hook_skip_assignment "$segment"; then
        emit deny "destructive-command-guard hook BLOCKED this call: it sets an environment variable that turns the hook manager off (HUSKY=0, HUSKY_SKIP_HOOKS, SKIP, LEFTHOOK=0, or LEFTHOOK_EXCLUDE) for a git command that runs hooks (R-203). Fix what the hook reports instead; a human skips a hook manually if that is genuinely required."
    fi
    if skips_git_hooks "$git_invocation"; then
        emit deny "destructive-command-guard hook BLOCKED this call: it skips git hooks (--no-verify, an abbreviation of it, or commit -n), which turns off the pre-commit and pre-push gates for this change (R-203). Fix what the hook reports instead; a human skips a hook manually if that is genuinely required."
    fi
done < <(list_command_segments "$cmd")

# --- credential readout ---------------------------------------------------

if grep -Eqi "${AT}gh auth token([[:space:]]|$)" <<< "$norm" \
    || grep -Eqi "${AT}gh auth status[^|;&]*(-t|--show-token)([[:space:]]|$)" <<< "$norm"; then
    emit deny "destructive-command-guard hook BLOCKED this call: it prints a live GitHub token to stdout, which lands in the transcript, the session log, and scrollback (R-102). Read the token from the keychain at execution time instead of echoing it."
fi

if grep -Eqi "${AT}security (find-generic-password|find-internet-password)[^|;&]*(-w|-g)([[:space:]]|$)" <<< "$norm"; then
    emit deny "destructive-command-guard hook BLOCKED this call: it prints a keychain secret to stdout (R-102). Resolve the value inside the consuming process so the plaintext never enters the transcript."
fi

# --- tampering with the hooks directory -----------------------------------

if grep -Eqi "${AT}(rm|mv|chmod|chown|truncate|shred)([[:space:]]|$)[^|;&]*\.claude/hooks" <<< "$norm"; then
    emit deny "destructive-command-guard hook BLOCKED this call: it removes, moves, or strips execution from the hooks directory, disabling the safety harness (R-203). Never bypass a guard without explicit approval in the current turn."
fi

# --- gh commands whose effect is irreversible or rule-evading -------------

if grep -Eqi "${AT}gh alias set([[:space:]]|$)" <<< "$norm"; then
    emit deny "destructive-command-guard hook BLOCKED this call: a gh alias re-labels a denied command so it no longer matches the deny list, evading Bash(gh repo delete*) and its siblings (R-203)."
fi

if grep -Eqi "${AT}gh repo edit[^|;&]*--visibility public([[:space:]]|$)" <<< "$norm"; then
    emit deny "destructive-command-guard hook BLOCKED this call: making a repository public is effectively irreversible once forks, caches, and archives pick it up. A human makes this call deliberately."
fi

exit 0
