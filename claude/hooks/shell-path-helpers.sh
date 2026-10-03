#!/usr/bin/env bash
# shell-path-helpers.sh: string-only path and brace helpers shared by the
# command guards (destructive-command-guard.sh, destructive-ops-guard.sh). Source
# it; it defines functions and runs nothing. It uses only bash string
# operations, because a fork per argument made a long command take seconds and
# got the hook process killed, which lets the call through. bash 3.2 safe.

# Sets NORMALIZED_PATH to $1 with repeated slashes, `/./`, a leading `./`, a
# trailing `/.`, and `x/..` pairs removed. A leading `..` is kept as written.
normalize_path() {
    local path="$1" pattern
    # The patterns live in variables: bash 3.2 keeps a backslash-escaped slash
    # literally in a replacement, so ${path//\/\//\/} would insert "\/".
    local slash='/' double_slash='//' dot_segment='/./'
    while [[ "$path" == *//* ]]; do path="${path//$double_slash/$slash}"; done
    while [[ "$path" == */./* ]]; do path="${path//$dot_segment/$slash}"; done
    while [[ "$path" == ./* ]]; do path="${path#./}"; done
    [[ "$path" == */. ]] && path="${path%/.}"
    pattern='^(.*/)?([^/]+)/\.\.(/.*)?$'
    while [[ "$path" =~ $pattern ]] && [ "${BASH_REMATCH[2]}" != ".." ]; do
        path="${BASH_REMATCH[1]}${BASH_REMATCH[3]#/}"
    done
    NORMALIZED_PATH="$path"
}

# Sets EXPANDED_WORDS to the words brace expansion makes of the argument
# ({a,b} groups, expanded one at a time; capped at 64 results). A word
# without a brace is its own only expansion.
expand_braces() {
    local pending=("$1") word parts alternative prefix suffix pattern='^(.*)\{([^{}]*,[^{}]*)\}(.*)$'
    EXPANDED_WORDS=()
    while [ "${#pending[@]}" -gt 0 ] && [ "${#EXPANDED_WORDS[@]}" -lt 64 ]; do
        word="${pending[0]}"
        pending=(${pending[@]+"${pending[@]:1}"})
        if [[ "$word" == *'{'* ]] && [[ "$word" =~ $pattern ]]; then
            prefix="${BASH_REMATCH[1]}"
            suffix="${BASH_REMATCH[3]}"
            IFS=, read -r -a parts <<< "${BASH_REMATCH[2]},"
            for alternative in "${parts[@]}"; do pending+=("$prefix$alternative$suffix"); done
        else
            EXPANDED_WORDS+=("$word")
        fi
    done
}

# Sets COLLAPSED_PATH to the absolute path $1 with every `.` and `..` segment
# and repeated slash resolved against the root, so `/a/b/../../x` is `/x` and
# `/..` is `/`. Unlike normalize_path it handles consecutive `..` segments;
# it never touches the filesystem, so symlinks are not followed.
collapse_path() {
    local component kept=() parts=() joined="" index
    IFS=/ read -r -a parts <<< "$1"
    for component in ${parts[@]+"${parts[@]}"}; do
        case "$component" in
            "" | .) ;;
            ..) [ "${#kept[@]}" -gt 0 ] && kept=("${kept[@]:0:$((${#kept[@]} - 1))}") ;;
            *) kept+=("$component") ;;
        esac
    done
    for ((index = 0; index < ${#kept[@]}; index++)); do joined="$joined/${kept[index]}"; done
    COLLAPSED_PATH="${joined:-/}"
}
