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
# Deletion tier (slice B-3, owner decision 1 in
# docs/slices/slice-05-destructive-ops-guard.md). Every simple command that
# deletes or truncates is judged by where its targets resolve, from the hook's
# cwd (or the directory an earlier cd moved to), with ~ and $VAR expanded from
# the hook's own environment and symlinks not followed:
#   deny  the target is /, home, an entry directly under home, a glob at home
#         or root level, an unset or empty variable, or any path outside the
#         repository (through .. or written absolute)
#   ask   every other recursive or forced rm, find -delete or -exec rm, xargs
#         rm, rsync --delete, git clean -f, interpreter one-liner that deletes,
#         truncation inside the repository, and a target the hook cannot resolve
#   none  plain rm, rmdir, unlink, or trash inside the repository
# One decision covers the whole command and the strongest segment wins. The
# lists (programs, patterns) live in ../enforce/destructive-ops.json; the
# deciding logic lives here. A redirect `>` outside the repository asks, except
# under /dev and the temp directories, which run.
#
# Always exits 0: an erroring PreToolUse hook is a non-decision, so the hook
# reports through its output, never its status. Enforces R-101 (destructive
# actions) and R-203 (never bypass a guard).
set -uo pipefail
# A session can start this hook with HOME unset; fill it from the account
# entry first, as every guard does, so ~ and $HOME resolve to the real home
# rather than to nothing (hooks/guard-fail-closed convention). If even that
# fails, HOME stays empty and every home target is treated as protected.
: "${HOME:=$(cd ~ 2>/dev/null && pwd)}"

# Seconds the parser may run before it counts as unusable.
PARSER_TIMEOUT_SECONDS=10

SHELL_SEGMENTS_HELPER="$(dirname "${BASH_SOURCE[0]}")/shell-command-segments.py"
DESTRUCTIVE_OPS_POLICY="$(dirname "${BASH_SOURCE[0]}")/../enforce/destructive-ops.json"
# collapse_path, shared with destructive-command-guard.sh's helper file.
. "$(dirname "${BASH_SOURCE[0]}")/shell-path-helpers.sh"

POLICY_DOWN_REASON="destructive-ops-guard hook BLOCKED this call: its policy file enforce/destructive-ops.json is missing or unreadable, so no delete can be judged. Restore the harness with sync.sh."
RECORDED_ASK_REASON=""
CD_PREFIX=""

PARSER_DOWN_REASON="destructive-ops-guard hook BLOCKED this call: its command parser (python3 running hooks/shell-command-segments.py) is unavailable, failed, or timed out, so no command can be checked. Restore the harness with sync.sh, or install the developer tools that provide python3."

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
    hook_cwd=""
    if command -v jq >/dev/null 2>&1; then
        tool_name="$(printf '%s' "$1" | jq -r '.tool_name // empty' 2>/dev/null)"
        cmd="$(printf '%s' "$1" | jq -r '.tool_input.command // empty' 2>/dev/null)"
        hook_cwd="$(printf '%s' "$1" | jq -r '.cwd // empty' 2>/dev/null)"
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

# Loads the policy lists from enforce/destructive-ops.json into space-joined
# strings (and one pattern each for the regex lists), with one jq call.
# Returns non-zero when the file is missing or unreadable.
load_policy() {
    local lines
    [ -f "$DESTRUCTIVE_OPS_POLICY" ] || return 1
    lines="$(jq -r '
        (.forced_delete_programs | join(" ")),
        (.plain_delete_programs | join(" ")),
        (.truncate_programs | join(" ")),
        (.find_delete_programs | join(" ")),
        (.rsync_delete_options | join("|")),
        (.redirect_exempt_prefixes | join(" ")),
        (.interpreter_programs | join(" ")),
        (.interpreter_delete_patterns | join("|")),
        (.docker_programs | join(" ")),
        (.docker_read_only | join("|"))' "$DESTRUCTIVE_OPS_POLICY" 2>/dev/null)" || return 1
    {
        IFS= read -r FORCED_DELETE_PROGRAMS
        IFS= read -r PLAIN_DELETE_PROGRAMS
        IFS= read -r TRUNCATE_PROGRAMS
        IFS= read -r FIND_DELETE_PROGRAMS
        IFS= read -r RSYNC_DELETE_PATTERN
        IFS= read -r REDIRECT_EXEMPT_PREFIXES
        IFS= read -r INTERPRETER_PROGRAMS
        IFS= read -r INTERPRETER_DELETE_PATTERN
        IFS= read -r DOCKER_PROGRAMS
        IFS= read -r DOCKER_READ_ONLY
    } <<< "$lines"
    [ -n "$FORCED_DELETE_PROGRAMS" ] && [ -n "$INTERPRETER_DELETE_PATTERN" ]
}

# True when $1 is one of the space-separated words in $2.
is_listed() {
    [[ " $2 " == *" $1 "* ]]
}

# True when a word is a shell variable assignment (NAME=value).
is_assignment_word() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]
}

# True when the word contains a shell glob character.
has_glob_character() {
    [[ "$1" == *[\*\?\[]* ]]
}

# Sets REPO_ROOT, once, to the git toplevel of the working directory, or to the
# working directory itself outside a repository.
find_repo_root() {
    [ -n "$REPO_ROOT" ] && return
    REPO_ROOT="$(git -C "$WORKING_DIR" rev-parse --show-toplevel 2>/dev/null)" || REPO_ROOT=""
    [ -n "$REPO_ROOT" ] || REPO_ROOT="$WORKING_DIR"
    collapse_path "$REPO_ROOT"
    REPO_ROOT="$COLLAPSED_PATH"
}

# Remembers a NAME=value assignment from an earlier segment, so a later
# $NAME resolves to it rather than to the hook's own environment.
record_assignment() {
    local name="${1%%=*}"
    printf -v "ASSIGNED_$name" '%s' "${1#*=}"
}

# Sets EXPANDED_WORD to the word with every $NAME and ${NAME} replaced by its
# value (an earlier assignment in the command, else the hook's environment).
# Sets TARGET_CLASS to protected when a variable is unset or empty, to
# unresolved when other $ or backtick syntax remains, and leaves it empty
# otherwise.
expand_variables() {
    local word="$1" pattern='\$(\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))' name value matched passes=0 local_name
    while [[ "$word" =~ $pattern ]]; do
        matched="${BASH_REMATCH[0]}"
        name="${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
        local_name="ASSIGNED_$name"
        if [ -n "${!local_name+set}" ]; then
            value="${!local_name}"
        else
            value="${!name-}"
        fi
        if [ -z "$value" ]; then
            TARGET_WHY="the variable \$$name, which is unset or empty here, so it can expand to the filesystem root"
            TARGET_CLASS=protected
            EXPANDED_WORD="$word"
            return
        fi
        word="${word/"$matched"/"$value"}"
        passes=$((passes + 1))
        [ "$passes" -lt 16 ] || break
    done
    EXPANDED_WORD="$word"
    if [[ "$word" == *'$'* || "$word" == *'`'* ]]; then
        TARGET_WHY="a path built by a command substitution or a shell expansion this hook cannot resolve"
        TARGET_CLASS=unresolved
    fi
}

# Sets TARGET_PATH to the absolute path the word names, TARGET_CLASS to
# protected, outside, unresolved, or inside, and TARGET_WHY to a phrase naming
# the reason. Expands variables and ~, places a relative word under the
# directory an earlier cd moved to (else the cwd), resolves . and .., then
# applies the owner-decision-1 rules: the root, home, an entry directly under
# home, or a glob at either level is protected; a path outside the repository
# is outside; anything under the repository root is inside.
classify_single_target() {
    local word="$1" home rest first base
    TARGET_CLASS=""
    TARGET_WHY=""
    TARGET_PATH=""
    expand_variables "$word"
    word="$EXPANDED_WORD"
    [ "$TARGET_CLASS" = protected ] && return
    home="${HOME:-}"
    home="${home%/}"
    case "$word" in
        "~" | "~/"*)
            if [ -z "$home" ]; then
                TARGET_CLASS=protected
                TARGET_WHY="~ while HOME is unset"
                return
            fi
            word="$home${word#\~}"
            ;;
        "~"*)
            TARGET_CLASS=protected
            TARGET_WHY="$word, another user's home directory"
            return
            ;;
    esac
    [ "$TARGET_CLASS" = unresolved ] && return
    case "$word" in
        /*) ;;
        *)
            base="${CD_PREFIX:-$WORKING_DIR}"
            if [ "$base" = "?" ]; then
                TARGET_CLASS=unresolved
                TARGET_WHY="a relative path after a cd this hook cannot resolve"
                return
            fi
            word="$base/$word"
            ;;
    esac
    collapse_path "$word"
    TARGET_PATH="$COLLAPSED_PATH"
    find_repo_root
    if [ "$TARGET_PATH" = "/" ]; then
        TARGET_CLASS=protected
        TARGET_WHY="the filesystem root"
        return
    fi
    first="${TARGET_PATH#/}"
    first="${first%%/*}"
    if has_glob_character "$first"; then
        TARGET_CLASS=protected
        TARGET_WHY="a glob at the filesystem root ($TARGET_PATH)"
        return
    fi
    if [ -n "$home" ]; then
        if [ "$TARGET_PATH" = "$home" ]; then
            TARGET_CLASS=protected
            TARGET_WHY="the home directory"
            return
        fi
        if [[ "$TARGET_PATH" == "$home"/* ]]; then
            rest="${TARGET_PATH#"$home"/}"
            first="${rest%%/*}"
            if [ "$first" = "$rest" ]; then
                TARGET_CLASS=protected
                TARGET_WHY="$TARGET_PATH, an entry directly under the home directory"
                return
            fi
            if has_glob_character "$first"; then
                TARGET_CLASS=protected
                TARGET_WHY="a glob directly under the home directory ($TARGET_PATH)"
                return
            fi
        fi
    fi
    if [ "$TARGET_PATH" = "$REPO_ROOT" ] || [[ "$TARGET_PATH" == "$REPO_ROOT"/* ]]; then
        TARGET_CLASS=inside
    else
        TARGET_CLASS=outside
        TARGET_WHY="$TARGET_PATH, a path outside the repository"
    fi
}

# Returns the strength of a target class: protected 3, outside 2, unresolved 1,
# inside 0.
rank_target_class() {
    case "$1" in
        protected) return 3 ;;
        outside) return 2 ;;
        unresolved) return 1 ;;
        *) return 0 ;;
    esac
}

# Sets TARGET_CLASS, TARGET_WHY, and TARGET_PATH for a word after brace
# expansion: the strongest class among the alternatives wins.
classify_target() {
    local alternative best_class="inside" best_why="" best_path="" best_rank=0 rank=0
    expand_braces "$1"
    for alternative in "${EXPANDED_WORDS[@]}"; do
        classify_single_target "$alternative"
        rank_target_class "$TARGET_CLASS"
        rank=$?
        if [ "$rank" -gt "$best_rank" ]; then
            best_rank="$rank"
            best_class="$TARGET_CLASS"
            best_why="$TARGET_WHY"
        fi
        [ -n "$best_path" ] || best_path="$TARGET_PATH"
    done
    TARGET_CLASS="$best_class"
    TARGET_WHY="$best_why"
    TARGET_PATH="$best_path"
}

# Emits the deny for a delete or truncation of $1 (a phrase from
# classify_target); the reason names R-101 and what to do instead.
deny_target() {
    emit deny "destructive-ops-guard hook BLOCKED this call: it deletes or truncates $1. That is outside what an agent may remove: a human runs it deliberately. Delete named files inside the repository instead, or ask the user to run it."
}

# Records an ask, keeping the first reason; main emits it after every segment
# has been checked, because a later deny outranks it. $1 = what asks.
record_ask() {
    [ -n "$RECORDED_ASK_REASON" ] ||
        RECORDED_ASK_REASON="destructive-ops-guard hook asks before this call: $1. Confirm only if the data is replaceable or committed; otherwise name the exact files, or delete inside the repository one path at a time."
}

# Applies the class of the target just classified: protected and outside deny,
# unresolved asks, inside runs unless $1 is "ask", which asks for it too.
apply_target_class() {
    case "$TARGET_CLASS" in
        protected | outside) deny_target "$TARGET_WHY" ;;
        unresolved) record_ask "it deletes $TARGET_WHY" ;;
        *) [ "${1:-}" = ask ] && record_ask "${2:-it deletes recursively or by force}" ;;
    esac
}

# True when an option word asks for a recursive or forced delete: -r, -R, -f
# in any cluster, or --recursive or --force.
is_forcing_option() {
    case "$1" in
        --recursive | --force) return 0 ;;
        --*) return 1 ;;
        -*[rRf]*) return 0 ;;
    esac
    return 1
}

# Sets ARGUMENTS to the segment's words after the program with redirect
# operators and their targets removed, and FORCING_OPTION to 1 when any
# option before `--` is recursive or forced. After `--` every word is an
# argument, never an option.
collect_arguments() {
    local index word after_marker=0
    ARGUMENTS=()
    FORCING_OPTION=0
    for ((index = COMMAND_START + 1; index < ${#WORDS[@]}; index++)); do
        word="${WORDS[index]}"
        if [[ "$word" == "$REDIRECT_MARK"* ]]; then
            index=$((index + 1))
            continue
        fi
        if [ "$after_marker" -eq 0 ] && [ "$word" = "--" ]; then
            after_marker=1
            ARGUMENTS+=("$word")
            continue
        fi
        if [ "$after_marker" -eq 0 ] && [[ "$word" == -* ]] && [ "$word" != "-" ]; then
            is_forcing_option "$word" && FORCING_OPTION=1
        fi
        ARGUMENTS+=("$word")
    done
}

# Judges one rm-family segment: every non-option argument is a target (all
# arguments after `--`). $1 = how the program treats flags: "forced" (rm: a
# recursive or forced flag asks, no target asks), "plain" (rmdir, unlink,
# trash), or "truncate" (truncate, shred: even a target inside the repository
# asks).
judge_delete_segment() {
    local mode="$1" word after_marker=0 target_count=0
    for word in ${ARGUMENTS[@]+"${ARGUMENTS[@]}"}; do
        if [ "$after_marker" -eq 0 ]; then
            [ "$word" = "--" ] && { after_marker=1; continue; }
            [[ "$word" == -* ]] && [ "$word" != "-" ] && continue
        fi
        [ -n "$word" ] || continue
        target_count=$((target_count + 1))
        classify_target "$word"
        # Deleting the repository root itself is denied (owner decision 2026-10-03).
        if [ "$TARGET_CLASS" = inside ] && [ "$TARGET_PATH" = "$REPO_ROOT" ]; then
            TARGET_CLASS=protected
            TARGET_WHY="$TARGET_PATH, the repository root itself"
        fi
        if [ "$mode" = truncate ]; then
            apply_target_class ask "it truncates or overwrites a file"
        else
            apply_target_class
        fi
    done
    if [ "$mode" = forced ]; then
        if [ "$FORCING_OPTION" -eq 1 ]; then
            record_ask "it is a recursive or forced delete"
        elif [ "$target_count" -eq 0 ]; then
            record_ask "it runs rm with no named target (from xargs or standard input)"
        fi
    fi
}

# Judges a find segment: -delete, or -exec/-execdir/-ok/-okdir of a delete
# program, asks; the start paths (words before the first expression) decide
# deny the way rm targets do.
judge_find_segment() {
    local index word next deletes=0 starts=() in_starts=1
    for ((index = COMMAND_START + 1; index < ${#WORDS[@]}; index++)); do
        word="${WORDS[index]}"
        [[ "$word" == "$REDIRECT_MARK"* ]] && { index=$((index + 1)); continue; }
        if [ "$in_starts" -eq 1 ]; then
            case "$word" in
                -* | "(" | "!" | ")" | ",") in_starts=0 ;;
                *) starts+=("$word") ;;
            esac
        fi
        case "$word" in
            -delete) deletes=1 ;;
            -exec | -execdir | -ok | -okdir)
                next="${WORDS[index + 1]:-}"
                is_listed "${next##*/}" "$FIND_DELETE_PROGRAMS" && deletes=1
                ;;
        esac
    done
    [ "$deletes" -eq 1 ] || return 0
    [ "${#starts[@]}" -gt 0 ] || starts=(.)
    for word in "${starts[@]}"; do
        classify_target "$word"
        apply_target_class ask "it is a find that deletes"
    done
    record_ask "it is a find that deletes"
}

# Judges an rsync segment: a delete option makes the last path argument (the
# destination) a delete target, and asks even inside the repository.
judge_rsync_segment() {
    local word destination="" deletes=0
    for word in ${ARGUMENTS[@]+"${ARGUMENTS[@]}"}; do
        if [[ "$word" =~ ^($RSYNC_DELETE_PATTERN)$ ]]; then
            deletes=1
        elif [[ "$word" != -* ]]; then
            destination="$word"
        fi
    done
    [ "$deletes" -eq 1 ] || return 0
    if [ -n "$destination" ] && [[ "$destination" =~ ^[^/~.][^/]*: ]]; then
        record_ask "it is an rsync --delete to a remote destination"
        return 0
    fi
    if [ -n "$destination" ]; then
        classify_target "$destination"
        apply_target_class ask "it is an rsync --delete"
    fi
    record_ask "it is an rsync --delete"
}

# Judges a git segment: `git clean` with force (any flag order) and without a
# dry-run flag asks; a -C directory outside the repository denies.
judge_git_segment() {
    local index word subcommand="" skip_value=0 forced=0 dry=0 directory=""
    for ((index = COMMAND_START + 1; index < ${#WORDS[@]}; index++)); do
        word="${WORDS[index]}"
        [[ "$word" == "$REDIRECT_MARK"* ]] && { index=$((index + 1)); continue; }
        if [ "$skip_value" -eq 1 ]; then
            [ "$skip_value_for" = "-C" ] && directory="$word"
            skip_value=0
            continue
        fi
        if [ -z "$subcommand" ]; then
            case "$word" in
                -C | -c | --git-dir | --work-tree | --namespace) skip_value=1; skip_value_for="$word" ;;
                -*) ;;
                *) subcommand="$word" ;;
            esac
            continue
        fi
        case "$word" in
            --force) forced=1 ;;
            --dry-run) dry=1 ;;
            --*) ;;
            -*f*) forced=1; [[ "$word" == -*n* ]] && dry=1 ;;
            -*n*) dry=1 ;;
        esac
    done
    [ "$subcommand" = clean ] && [ "$forced" -eq 1 ] && [ "$dry" -eq 0 ] || return 0
    if [ -n "$directory" ]; then
        classify_target "$directory"
        apply_target_class
    fi
    record_ask "it is git clean with force, which deletes untracked files for good"
}

# Judges an interpreter or package-runner segment: any word that matches a
# delete pattern (shutil.rmtree, fs.rmSync, rimraf, and kin) asks, since the
# targets sit inside a string this hook cannot resolve.
judge_interpreter_segment() {
    local joined="${WORDS[COMMAND_START]} ${ARGUMENTS[*]-}"
    [[ "$joined" =~ $INTERPRETER_DELETE_PATTERN ]] || return 0
    record_ask "it runs an interpreter one-liner or package runner that deletes files"
}

# Judges every `>`-style redirect in the segment: it truncates its target, so
# a protected or outside target denies, except under the exempt prefixes
# (/dev, the temp directories), and an unresolved one asks.
judge_redirects() {
    local index word target prefix exempt
    for ((index = 0; index < ${#WORDS[@]}; index++)); do
        word="${WORDS[index]}"
        case "$word" in
            "$REDIRECT_MARK>" | "$REDIRECT_MARK>|" | "$REDIRECT_MARK&>") ;;
            *) continue ;;
        esac
        target="${WORDS[index + 1]:-}"
        [ -n "$target" ] || continue
        classify_target "$target"
        case "$TARGET_CLASS" in
            protected) deny_target "$TARGET_WHY" ;;
            unresolved) record_ask "it redirects output over $TARGET_WHY" ;;
            outside)
                exempt=0
                for prefix in $REDIRECT_EXEMPT_PREFIXES; do
                    [[ "$TARGET_PATH" == "$prefix"* ]] && exempt=1
                done
                [ "$exempt" -eq 1 ] || record_ask "it redirects output over $TARGET_PATH, a file outside the repository"
                ;;
        esac
    done
}

# Moves CD_PREFIX to the directory a cd or pushd names (home for a bare cd);
# a target this hook cannot resolve (cd -, $(...)) becomes "?", which makes
# later relative paths unresolved.
apply_cd_segment() {
    local target="${ARGUMENTS[0]-}" index
    for ((index = 0; index < ${#ARGUMENTS[@]}; index++)); do
        case "${ARGUMENTS[index]}" in -*) ;; *) target="${ARGUMENTS[index]}"; break ;; esac
    done
    [ "${#ARGUMENTS[@]}" -gt 0 ] || target="~"
    [ "$target" = "-" ] && { CD_PREFIX="?"; return; }
    classify_target "$target"
    if [ "$TARGET_CLASS" = unresolved ] || [ -z "$TARGET_PATH" ]; then
        CD_PREFIX="?"
    else
        CD_PREFIX="$TARGET_PATH"
    fi
}

# Docker and its look-alikes (owner decision 2026-10-03, after an unscoped
# `docker rm -f` deleted every container): read-only subcommands run, every
# other subcommand asks. $1 = the program's base name.
judge_docker_segment() {
    local index=0 word sub="" sub2=""
    local -a words=("${ARGUMENTS[@]+"${ARGUMENTS[@]}"}")
    [ "$1" = docker-compose ] && sub=compose
    for ((index = 0; index < ${#words[@]}; index++)); do
        word="${words[index]}"
        case "$word" in
            --context | -c | --host | -H | --config | --log-level | -l | -f | --file | -p | --project-name | --env-file | --profile)
                index=$((index + 1)); continue ;;
            -*) continue ;;
        esac
        if [ -z "$sub" ]; then
            sub="$word"
            case "$sub" in container | image | volume | network | context | system | compose | builder | buildx) ;; *) break ;; esac
        else
            sub2="$word"; break
        fi
    done
    local key="$sub"
    [ -n "$sub2" ] && key="$sub $sub2"
    [ -n "$key" ] || return 0
    printf '%s\n' "$DOCKER_READ_ONLY" | tr '|' '\n' | grep -qxF -- "$key" && return 0
    record_ask "it runs \`$1 $key\`, which can change or remove containers, images, volumes, or networks; only read-only $1 commands run without asking"
}

# Judges one segment (WORDS holds its words): records assignments, follows cd,
# and applies the rule for the delete route its program belongs to.
judge_segment() {
    local index word program
    for ((index = 0; index < ${#WORDS[@]}; index++)); do
        word="${WORDS[index]}"
        [[ "$word" == "$REDIRECT_MARK"* ]] && { index=$((index + 1)); continue; }
        is_assignment_word "$word" || break
    done
    COMMAND_START=$index
    judge_redirects
    program="${WORDS[COMMAND_START]:-}"
    if [ -z "$program" ]; then
        for word in "${WORDS[@]}"; do
            is_assignment_word "$word" && record_assignment "$word"
        done
        return
    fi
    collect_arguments
    if [ "$program" = cd ] || [ "$program" = pushd ]; then
        apply_cd_segment
    elif is_listed "$program" "$FORCED_DELETE_PROGRAMS"; then
        judge_delete_segment forced
    elif is_listed "$program" "$PLAIN_DELETE_PROGRAMS"; then
        judge_delete_segment plain
    elif is_listed "$program" "$TRUNCATE_PROGRAMS"; then
        judge_delete_segment truncate
    elif [ "$program" = find ]; then
        judge_find_segment
    elif [ "$program" = rsync ]; then
        judge_rsync_segment
    elif [ "$program" = git ]; then
        judge_git_segment
    elif is_listed "${program##*/}" "$DOCKER_PROGRAMS"; then
        judge_docker_segment "${program##*/}"
    elif is_listed "$program" "$INTERPRETER_PROGRAMS"; then
        judge_interpreter_segment
    fi
}

input="$(cat)"
read_hook_input "$input"
[ "$tool_name" = "Bash" ] || exit 0
[ -z "$cmd" ] && exit 0

# Without jq the per-segment policy cannot read its input, so the call is denied.
command -v jq >/dev/null 2>&1 || emit deny "destructive-ops-guard hook BLOCKED this call: jq is not installed, so the command parser output cannot be checked. Install jq."
list_command_segments "$cmd" || emit deny "$PARSER_DOWN_REASON"
load_policy || emit deny "$POLICY_DOWN_REASON"

WORKING_DIR="${hook_cwd:-$PWD}"
REPO_ROOT=""
REDIRECT_MARK=$'\036'
while IFS=$'\037' read -r -a WORDS; do
    [ "${#WORDS[@]}" -gt 0 ] || continue
    judge_segment
done <<< "$COMMAND_SEGMENTS"

[ -z "$RECORDED_ASK_REASON" ] || emit ask "$RECORDED_ASK_REASON"
exit 0
