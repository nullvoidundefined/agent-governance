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

# Writes to core.hooksPath, include.path, and hook-skipping aliases are denied
# in the git-hook section below, on the parsed command, so a global option, a
# quoted key, or the `git config set` form cannot slip past, and a read
# followed by a redirect (`2>/dev/null`) is not mistaken for a value.
# hookspath-drift-check.sh and the R-107 investigation depend on the reads.

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
    case "${WORDS[SUBCOMMAND_INDEX]:-}" in commit | push | merge | rebase | am | pull) return 0 ;; esac
    return 1
}

# True when one VAR=value word turns a hook manager off: husky, the
# pre-commit framework's SKIP list, or lefthook.
is_hook_skip_assignment() {
    case "$1" in
        HUSKY=0 | HUSKY_SKIP_HOOKS=1 | HUSKY_SKIP_HOOKS=true | SKIP=* | LEFTHOOK=0 | LEFTHOOK=false | LEFTHOOK_EXCLUDE=*) return 0 ;;
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

# True when a VAR=value word points git at a different config file, which
# can set core.hooksPath or an include without touching this repository.
is_config_file_assignment() {
    case "$1" in
        GIT_CONFIG_GLOBAL=* | GIT_CONFIG_SYSTEM=* | GIT_CONFIG=* | HOME=* | XDG_CONFIG_HOME=*) return 0 ;;
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

# True when the word ($2) is --no-verify or a prefix the subcommand ($1)
# accepts for it: --no-veri is the shortest where --no-verbose also exists,
# --no-v on am, which has no --verbose.
is_no_verify_spelling() {
    local shortest=9
    [ "$1" = am ] && shortest=6
    [ "${#2}" -ge "$shortest" ] || return 1
    case "--no-verify" in "$2"*) return 0 ;; esac
    return 1
}

# True when a short-flag cluster ($2) of commit or am ($1) sets -n, their
# --no-verify, before any flag whose argument is attached (commit -mn is the
# message "n", -uno the mode "no"; am -C3 and -p1 take a number).
is_no_verify_cluster() {
    local cluster="${2#-}" attached_value_flags index
    case "$1" in
        commit) attached_value_flags="mFCctuS" ;;
        am) attached_value_flags="CpS" ;;
        *) return 1 ;;
    esac
    for ((index = 0; index < ${#cluster}; index++)); do
        [ "${cluster:index:1}" = n ] && return 0
        case "$attached_value_flags" in *"${cluster:index:1}"*) return 1 ;; esac
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
        pull:-s | pull:--strategy | pull:-X | pull:--strategy-option | pull:--depth | pull:--upload-pack) return 0 ;;
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
        is_no_verify_spelling "$subcommand" "$word" && return 0
        takes_separate_value "$subcommand" "$word" && { index=$((index + 1)); continue; }
        [[ "$word" =~ ^-[A-Za-z0-9]+$ ]] || continue
        is_no_verify_cluster "$subcommand" "$word" && return 0
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

# Prints the value of a leading NAME=value assignment for the named variable.
print_leading_value() {
    local index
    for ((index = 0; index < COMMAND_START; index++)); do
        case "${WORDS[index]}" in "$1="*) printf '%s' "${WORDS[index]#*=}"; return 0 ;; esac
    done
}

# Sets CONFIG_SETTINGS to the key=value settings this one git command
# receives through -c and the GIT_CONFIG_KEY_n/GIT_CONFIG_VALUE_n pairs.
collect_config_settings() {
    local index=$((COMMAND_START + 1)) key_number key
    CONFIG_SETTINGS=()
    while [ "$index" -lt "$SUBCOMMAND_INDEX" ]; do
        [ "${WORDS[index]}" = -c ] && CONFIG_SETTINGS+=("${WORDS[index + 1]:-}")
        index=$((index + 1))
    done
    for ((index = 0; index < COMMAND_START; index++)); do
        [[ "${WORDS[index]}" =~ ^GIT_CONFIG_KEY_([0-9]+)=(.*)$ ]] || continue
        key_number="${BASH_REMATCH[1]}"
        key="${BASH_REMATCH[2]}"
        CONFIG_SETTINGS+=("$key=$(print_leading_value "GIT_CONFIG_VALUE_$key_number")")
    done
}

# True when a config key (any case) is one that changes which hooks run.
is_include_key() {
    case "$(to_lowercase "$1")" in include.path | includeif.*.path) return 0 ;; esac
    return 1
}

# True when this git command receives an include.path or includeIf setting.
has_include_setting() {
    local setting
    for setting in ${CONFIG_SETTINGS[@]+"${CONFIG_SETTINGS[@]}"}; do
        is_include_key "${setting%%=*}" && return 0
    done
    return 1
}

# Prints the value of an alias the git command defines for the named
# subcommand, if it defines one.
print_alias_value() {
    local setting wanted
    wanted="alias.$(to_lowercase "$1")"
    for setting in ${CONFIG_SETTINGS[@]+"${CONFIG_SETTINGS[@]}"}; do
        [ "$(to_lowercase "${setting%%=*}")" = "$wanted" ] && { printf '%s' "${setting#*=}"; return 0; }
    done
}

# True when this guard denies the given command text. An alias is judged by
# what it expands to, so its expansion is run through the guard itself; the
# depth cap stops an alias that expands into an alias from looping, and
# treats that depth as a deny.
is_denied_command() {
    local depth="${GUARD_RECURSION_DEPTH:-0}"
    [ "$depth" -lt 3 ] || return 0
    jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' \
        | GUARD_RECURSION_DEPTH=$((depth + 1)) bash "${BASH_SOURCE[0]}" \
        | grep -q '"permissionDecision": *"deny"'
}

# True when running an alias value skips hooks: a `!` alias runs its text in
# the shell, any other alias runs as `git <value>`.
is_hook_skipping_alias() {
    case "$1" in
        '!'*) is_denied_command "${1#!}" ;;
        *) is_denied_command "git $1" ;;
    esac
}

# Sets CONFIG_KEY and CONFIG_VALUE when the git config command writes, and
# returns 1 for a read. Handles the flag forms (--unset, --add) and the
# subcommand forms (set, unset, get, list) of git 2.46 and later.
parse_git_config_write() {
    local index=$((SUBCOMMAND_INDEX + 1)) word is_unset=0 positionals=()
    while [ "$index" -lt "${#WORDS[@]}" ]; do
        word="${WORDS[index]}"
        index=$((index + 1))
        case "$word" in
            "$REDIRECT_MARK"*) index=$((index + 1)) ;;
            --get | --get-all | --get-regexp | --get-urlmatch | --list | -l | --get-color | --get-colorbool | --edit | -e) return 1 ;;
            --unset | --unset-all) is_unset=1 ;;
            -f | --file | --blob | --type | --default | --comment | --value) index=$((index + 1)) ;;
            -*) ;;
            *) positionals+=("$word") ;;
        esac
    done
    case "${positionals[0]:-}" in
        get | list | get-regexp | get-urlmatch | get-color | get-colorbool | edit) return 1 ;;
        set) positionals=("${positionals[@]:1}") ;;
        unset) is_unset=1; positionals=("${positionals[@]:1}") ;;
    esac
    CONFIG_KEY="${positionals[0]:-}"
    CONFIG_VALUE="${positionals[1]:-}"
    [ -n "$CONFIG_KEY" ] && { [ "$is_unset" -eq 1 ] || [ "${#positionals[@]}" -ge 2 ]; }
}

# True when a git config write changes which hooks run: core.hooksPath and the
# include keys in any write, an alias only when its value skips hooks.
is_protected_config_write() {
    local key
    key="$(to_lowercase "$CONFIG_KEY")"
    case "$key" in
        core.hookspath) return 0 ;;
        alias.*) [ -n "$CONFIG_VALUE" ] && is_hook_skipping_alias "$CONFIG_VALUE" ;;
        *) is_include_key "$key" ;;
    esac
}

# True when the segment defines a shell function or alias named git, which
# would put arbitrary text in front of every later git command.
defines_git_command() {
    local index
    case "${WORDS[COMMAND_START]}" in
        function) [ "${WORDS[COMMAND_START + 1]:-}" = git ] ;;
        alias)
            for ((index = COMMAND_START + 1; index < ${#WORDS[@]}; index++)); do
                case "${WORDS[index]}" in git=*) return 0 ;; esac
            done
            return 1
            ;;
        *) return 1 ;;
    esac
}

# True when the segment's program exports what it assigns: export, or
# declare and typeset with -x.
is_export_program() {
    local index
    case "${WORDS[COMMAND_START]}" in
        export) return 0 ;;
        declare | typeset) ;;
        *) return 1 ;;
    esac
    for ((index = COMMAND_START + 1; index < ${#WORDS[@]}; index++)); do
        [[ "${WORDS[index]}" =~ ^-[A-Za-z]*x ]] && return 0
    done
    return 1
}

# True when the segment turns on allexport (set -a, set -o allexport), after
# which every plain assignment is exported.
is_allexport_set() {
    local index
    [ "${WORDS[COMMAND_START]}" = set ] || return 1
    for ((index = COMMAND_START + 1; index < ${#WORDS[@]}; index++)); do
        [[ "${WORDS[index]}" =~ ^-[A-Za-z]*a|^allexport$ ]] && return 0
    done
    return 1
}

# Checks one assignment that reaches git's environment against the hook-skip
# and hooksPath predicates.
note_exported_assignment() {
    is_hook_skip_assignment "$1" && exported_hook_skip=1
    is_hookspath_env_assignment "$1" && exported_hookspath=1
    is_config_file_assignment "$1" && exported_config_file=1
    return 0
}

# Exports every earlier plain assignment of the named variable.
export_earlier_assignment() {
    local assignment
    for assignment in ${plain_assignments[@]+"${plain_assignments[@]}"}; do
        [ "${assignment%%=*}" = "$1" ] && note_exported_assignment "$assignment"
    done
    return 0
}

# Applies an export segment: its assignments are exported now, and a bare
# name exports that variable's earlier plain assignment and any later one.
apply_export_segment() {
    local index word
    for ((index = COMMAND_START + 1; index < ${#WORDS[@]}; index++)); do
        word="${WORDS[index]}"
        case "$word" in -*) continue ;; esac
        if is_assignment_word "$word"; then
            note_exported_assignment "$word"
        else
            exported_names="$exported_names $word "
            export_earlier_assignment "$word"
        fi
    done
}

# Applies a segment that only assigns variables: an assignment is exported
# when allexport is on or its name was exported earlier, and is remembered
# otherwise, since bash does not pass an unexported variable to git.
apply_assignment_segment() {
    local index word
    for ((index = 0; index < COMMAND_START; index++)); do
        word="${WORDS[index]}"
        if [ "$auto_export" -eq 1 ] || [[ "$exported_names" == *" ${word%%=*} "* ]]; then
            note_exported_assignment "$word"
        else
            plain_assignments+=("$word")
        fi
    done
}

# An export earlier in the command reaches every later git in the same call,
# so it is remembered across segments; a bare prefix reaches only its own.
exported_hook_skip=0
exported_hookspath=0
exported_config_file=0
exported_names=" "
auto_export=0
plain_assignments=()
while IFS=$'\037' read -r -a WORDS; do
    [ "${#WORDS[@]}" -gt 0 ] || continue
    find_command_start
    program="${WORDS[COMMAND_START]:-}"
    if [ -z "$program" ]; then
        apply_assignment_segment
        continue
    fi
    if is_export_program; then
        apply_export_segment
        continue
    fi
    if is_allexport_set; then
        auto_export=1
        continue
    fi
    if tampers_with_git_hooks; then
        emit deny "destructive-command-guard hook BLOCKED this call: it deletes, moves, disables, or overwrites a file under .git/hooks, which silently removes the pre-commit and pre-push gates (R-203). Reading the hooks is fine; reinstall them with the harness installer rather than editing them by hand."
    fi
    if defines_git_command; then
        emit deny "destructive-command-guard hook BLOCKED this call: it defines a shell function or alias named git, which can add a hook-skipping option to every later git command without it appearing in the command text (R-203). Call git directly."
    fi
    [ "$program" = git ] || continue
    find_git_subcommand
    collect_config_settings
    alias_value="$(print_alias_value "${WORDS[SUBCOMMAND_INDEX]:-}")"
    if [ -n "$alias_value" ] && is_hook_skipping_alias "$alias_value"; then
        emit deny "destructive-command-guard hook BLOCKED this call: it runs a git alias, defined for this command, whose expansion skips git hooks (R-203). Run the underlying command without the skip."
    fi
    if [ "${WORDS[SUBCOMMAND_INDEX]:-}" = config ] && parse_git_config_write && is_protected_config_write; then
        emit deny "destructive-command-guard hook BLOCKED this call: it writes a git config key that changes which hooks run (core.hooksPath, include.path, includeIf, or a hook-skipping alias), redirecting or disabling git hooks for every later command (R-107, R-203). Change it manually if the move is deliberate."
    fi
    is_hook_running_git || continue
    if has_include_setting; then
        emit deny "destructive-command-guard hook BLOCKED this call: it passes an include.path or includeIf setting to a git command that runs hooks, which can load a config file that sets core.hooksPath (R-107, R-203). Run the command without the include."
    fi
    if [ "$exported_config_file" -eq 1 ] || has_leading_assignment is_config_file_assignment; then
        emit deny "destructive-command-guard hook BLOCKED this call: it points a git command that runs hooks at a different config file (GIT_CONFIG_GLOBAL, GIT_CONFIG_SYSTEM, HOME, or XDG_CONFIG_HOME), which can set core.hooksPath without touching this repository (R-107, R-203). Run the command in the normal environment."
    fi
    if [ "$exported_hookspath" -eq 1 ] || has_leading_assignment is_hookspath_env_assignment || has_hookspath_option; then
        emit deny "destructive-command-guard hook BLOCKED this call: it overrides core.hooksPath for this git command (-c, --config-env, GIT_CONFIG_KEY_n, or GIT_CONFIG_PARAMETERS), which redirects or disables every git hook without touching git config (R-107, R-203). Run the command without the override."
    fi
    if [ "$exported_hook_skip" -eq 1 ] || has_leading_assignment is_hook_skip_assignment; then
        emit deny "destructive-command-guard hook BLOCKED this call: it sets an environment variable that turns the hook manager off (HUSKY=0, HUSKY_SKIP_HOOKS, SKIP, LEFTHOOK=0, or LEFTHOOK_EXCLUDE) for a git command that runs hooks (R-203). Fix what the hook reports instead; a human skips a hook manually if that is genuinely required."
    fi
    if skips_git_hooks; then
        emit deny "destructive-command-guard hook BLOCKED this call: it skips git hooks (--no-verify, an abbreviation of it, or commit and am -n), which turns off the git hooks for this change (R-203). Fix what the hook reports instead; a human skips a hook manually if that is genuinely required."
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
