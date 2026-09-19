#!/usr/bin/env bash
# PreToolUse(Bash) hook. Catches destructive command forms that settings.json
# prefix globs cannot express:
#   - `gh api` with a mutating method, in any flag spelling
#   - curl/wget piped into an interpreter
#   - writes to git core.hooksPath, and one-command overrides of it (-c,
#     --config-env, GIT_CONFIG_KEY_n, GIT_CONFIG_PARAMETERS)
#   - skipping git hooks with --no-verify (any accepted spelling), commit -n,
#     or a hook-manager variable (HUSKY=0, SKIP, LEFTHOOK=0)
#   - deleting, disabling, or overwriting files under .git/hooks
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

# --- skipping or removing git hooks ---------------------------------------

# settings.json could only ask on `git commit --no-verify*`, a literal prefix
# that missed abbreviations, flags placed before the subcommand, other
# subcommands, and every non-flag way to skip a hook (2026-09-19 ECC audit).
# shell-command-segments.py splits the command into simple commands the way
# bash does, with quotes, escapes, continuations, and comments resolved, so a
# flag cannot hide inside quotes and a commit message that mentions one is
# still just the value of -m.
SHELL_SEGMENTS_HELPER="$(dirname "${BASH_SOURCE[0]}")/shell-command-segments.py"
REDIRECT_MARK=$'\036'

# Fails closed: without the parser the git checks below cannot run, so any
# command that could reach git or its hooks is refused.
if ! command -v python3 >/dev/null 2>&1 || [ ! -f "$SHELL_SEGMENTS_HELPER" ]; then
    if grep -Eq 'git|hooks' <<< "$cmd"; then
        emit deny "destructive-command-guard hook BLOCKED this call: its command parser (python3 and hooks/shell-command-segments.py) is unavailable, so git hook skips cannot be checked (R-203). Restore the harness with sync.sh."
    fi
fi

# Prints the command's simple commands, one per line, words separated by \037
# and redirect operators prefixed with \036.
list_command_segments() {
    python3 "$SHELL_SEGMENTS_HELPER" <<< "$1" 2>/dev/null
}

# True when a word is a shell variable assignment (NAME=value).
is_assignment_word() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]
}

# Prints the argument lowercased (bash 3.2 has no ${var,,}).
to_lowercase() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Sets COMMAND_START to the index in WORDS of the program name, past leading
# VAR=value assignments and the env, sudo, and command wrappers.
find_command_start() {
    local index=0
    while [ "$index" -lt "${#WORDS[@]}" ]; do
        case "${WORDS[index]}" in
            env | sudo | command) ;;
            *) is_assignment_word "${WORDS[index]}" || break ;;
        esac
        index=$((index + 1))
    done
    COMMAND_START=$index
}

# True when an assignment ahead of the program name satisfies the predicate.
has_leading_assignment() {
    local predicate="$1" index
    for ((index = 0; index < COMMAND_START; index++)); do
        "$predicate" "${WORDS[index]}" && return 0
    done
    return 1
}

# True when an assignment after `export` satisfies the predicate.
has_exported_assignment() {
    local predicate="$1" index
    for ((index = COMMAND_START + 1; index < ${#WORDS[@]}; index++)); do
        "$predicate" "${WORDS[index]}" && return 0
    done
    return 1
}

# Sets SUBCOMMAND_INDEX to the index of git's subcommand, past its global
# options; the options that take a separate argument skip it.
find_git_subcommand() {
    local index=$((COMMAND_START + 1))
    while [ "$index" -lt "${#WORDS[@]}" ]; do
        case "${WORDS[index]}" in
            -C | -c | --git-dir | --work-tree | --namespace | --super-prefix | --config-env) index=$((index + 2)) ;;
            -*) index=$((index + 1)) ;;
            *) break ;;
        esac
    done
    SUBCOMMAND_INDEX=$index
}

# True when git's subcommand runs hooks.
is_hook_running_git() {
    case "${WORDS[SUBCOMMAND_INDEX]:-}" in commit | push | merge | rebase | am) return 0 ;; esac
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
    case "$(to_lowercase "$1")" in
        git_config_key_[0-9]*=core.hookspath | git_config_parameters=*core.hookspath*) return 0 ;;
    esac
    return 1
}

# True when a key=value config setting sets core.hooksPath.
is_hookspath_setting() {
    case "$(to_lowercase "$1")" in core.hookspath=*) return 0 ;; esac
    return 1
}

# True when git's global options override core.hooksPath through -c or
# --config-env.
has_hookspath_option() {
    local index=$((COMMAND_START + 1)) word
    while [ "$index" -lt "$SUBCOMMAND_INDEX" ]; do
        word="${WORDS[index]}"
        case "$word" in
            -c | --config-env) is_hookspath_setting "${WORDS[index + 1]:-}" && return 0 ;;
            --config-env=*) is_hookspath_setting "${word#--config-env=}" && return 0 ;;
        esac
        index=$((index + 1))
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

# True when an option of the subcommand takes the next word as its value, so
# `commit -m --no-verify` is a message, not the flag.
takes_separate_value() {
    case "$1:$2" in
        commit:-m | commit:--message | commit:-F | commit:--file | commit:-C | commit:--reuse-message \
            | commit:-c | commit:--reedit-message | commit:--fixup | commit:--squash | commit:--author \
            | commit:--date | commit:-t | commit:--template | commit:--trailer | commit:--cleanup) return 0 ;;
        merge:-m | merge:-F | merge:--file | merge:-s | merge:--strategy | merge:-X | merge:--strategy-option) return 0 ;;
        push:-o | push:--push-option | push:--repo | push:--receive-pack | push:--exec) return 0 ;;
        rebase:-s | rebase:--strategy | rebase:-X | rebase:--strategy-option | rebase:--onto | rebase:-x | rebase:--exec) return 0 ;;
    esac
    return 1
}

# True when a commit short-flag cluster ends in a flag whose value is the next
# word (-am "message").
cluster_ends_with_value() {
    [ "$1" = commit ] || return 1
    case "${2: -1}" in m | F | C | c | t) return 0 ;; esac
    return 1
}

# True when the subcommand's arguments skip its hooks through a flag. Values
# of value-taking options, redirect targets, and everything after `--` are
# not flags.
skips_git_hooks() {
    local subcommand="${WORDS[SUBCOMMAND_INDEX]}" index=$((SUBCOMMAND_INDEX + 1)) word
    while [ "$index" -lt "${#WORDS[@]}" ]; do
        word="${WORDS[index]}"
        index=$((index + 1))
        case "$word" in "$REDIRECT_MARK"*) index=$((index + 1)); continue ;; --) return 1 ;; esac
        is_no_verify_spelling "$word" && return 0
        takes_separate_value "$subcommand" "$word" && { index=$((index + 1)); continue; }
        [[ "$word" =~ ^-[A-Za-z]+$ ]] || continue
        [ "$subcommand" = commit ] && is_commit_no_verify_cluster "$word" && return 0
        cluster_ends_with_value "$subcommand" "$word" && index=$((index + 1))
    done
    return 1
}

# True when a path word names the .git/hooks directory or a file under it,
# relative or absolute.
is_git_hooks_path() {
    case "$1" in
        .git/hooks | .git/hooks/* | */.git/hooks | */.git/hooks/*) return 0 ;;
    esac
    return 1
}

# Sets ARGUMENTS to the program's words after COMMAND_START with redirect
# operators and their targets removed, and REDIRECT_TARGETS to the targets of
# output redirects.
collect_arguments() {
    local index=$((COMMAND_START + 1)) word
    ARGUMENTS=()
    REDIRECT_TARGETS=()
    while [ "$index" -lt "${#WORDS[@]}" ]; do
        word="${WORDS[index]}"
        case "$word" in
            "$REDIRECT_MARK"'>'* | "$REDIRECT_MARK"'&>'*) REDIRECT_TARGETS+=("${WORDS[index + 1]:-}"); index=$((index + 2)) ;;
            "$REDIRECT_MARK"*) index=$((index + 2)) ;;
            *) ARGUMENTS+=("$word"); index=$((index + 1)) ;;
        esac
    done
}

# True when any argument is a .git/hooks path.
has_git_hooks_word() {
    local word
    for word in "$@"; do
        is_git_hooks_path "$word" && return 0
    done
    return 1
}

# True when any argument matches the extended regular expression.
has_word_matching() {
    local pattern="$1" word
    for word in ${ARGUMENTS[@]+"${ARGUMENTS[@]}"}; do
        [[ "$word" =~ $pattern ]] && return 0
    done
    return 1
}

# True when the segment deletes, moves, disables, or overwrites .git/hooks or
# a file in it: removal and permission tools on any argument, copy and link
# tools on their destination, in-place editors, find with a delete action,
# and any output redirect into the directory.
tampers_with_git_hooks() {
    collect_arguments
    has_git_hooks_word ${REDIRECT_TARGETS[@]+"${REDIRECT_TARGETS[@]}"} && return 0
    case "${WORDS[COMMAND_START]:-}" in
        rm | unlink | mv | chmod | chown | truncate | shred | tee) has_git_hooks_word ${ARGUMENTS[@]+"${ARGUMENTS[@]}"} ;;
        cp | ln | install) [ "${#ARGUMENTS[@]}" -gt 0 ] && is_git_hooks_path "${ARGUMENTS[${#ARGUMENTS[@]} - 1]}" ;;
        sed | perl) has_word_matching '^-i' && has_git_hooks_word "${ARGUMENTS[@]}" ;;
        find) has_word_matching '^-(delete|exec|execdir|ok)$' && has_git_hooks_word "${ARGUMENTS[@]}" ;;
        *) return 1 ;;
    esac
}

# An export earlier in the command reaches every later git in the same call,
# so it is remembered across segments; a bare prefix reaches only its own.
exported_hook_skip=0
exported_hookspath=0
while IFS=$'\037' read -r -a WORDS; do
    [ "${#WORDS[@]}" -gt 0 ] || continue
    find_command_start
    program="${WORDS[COMMAND_START]:-}"
    if [ "$program" = export ]; then
        has_exported_assignment is_hook_skip_assignment && exported_hook_skip=1
        has_exported_assignment is_hookspath_env_assignment && exported_hookspath=1
        continue
    fi
    if tampers_with_git_hooks; then
        emit deny "destructive-command-guard hook BLOCKED this call: it deletes, moves, disables, or overwrites a file under .git/hooks, which silently removes the pre-commit and pre-push gates (R-203). Reading the hooks is fine; reinstall them with the harness installer rather than editing them by hand."
    fi
    [ "$program" = git ] || continue
    find_git_subcommand
    if [ "$exported_hookspath" -eq 1 ] || has_leading_assignment is_hookspath_env_assignment || has_hookspath_option; then
        emit deny "destructive-command-guard hook BLOCKED this call: it overrides core.hooksPath for this git command (-c, --config-env, GIT_CONFIG_KEY_n, or GIT_CONFIG_PARAMETERS), which redirects or disables every git hook without touching git config (R-107, R-203). Run the command without the override."
    fi
    is_hook_running_git || continue
    if [ "$exported_hook_skip" -eq 1 ] || has_leading_assignment is_hook_skip_assignment; then
        emit deny "destructive-command-guard hook BLOCKED this call: it sets an environment variable that turns the hook manager off (HUSKY=0, HUSKY_SKIP_HOOKS, SKIP, LEFTHOOK=0, or LEFTHOOK_EXCLUDE) for a git command that runs hooks (R-203). Fix what the hook reports instead; a human skips a hook manually if that is genuinely required."
    fi
    if skips_git_hooks; then
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
