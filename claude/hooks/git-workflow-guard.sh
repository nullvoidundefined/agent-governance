#!/usr/bin/env bash
# git-workflow-guard.sh: PreToolUse(Bash). Keeps the owner in charge of what
# reaches the trunk:
#   - a push to main or master, or a force push, asks first
#   - every `gh pr merge` asks first: the owner approves each PR
#   - `gh pr merge` is denied when the PR body has no `## Review` heading, the
#     record of the one fresh-context review every PR gets (when gh cannot
#     read the body, the merge still asks)
#   - `gh pr merge --merge` is denied; feature branches squash-merge
# Commands are split with shell-command-segments.py, so quoting, wrappers
# (env, sudo, command, bash -c, eval) and absolute paths do not hide a push.
# When the parser is unavailable, a command that names git push or gh pr
# merge asks instead of passing.
set -uo pipefail

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$cmd" ] || exit 0
grep -Eq '(^|[^A-Za-z0-9_-])(git|gh)([^A-Za-z0-9_-]|$)' <<< "$cmd" || exit 0

emit() {
    jq -n --arg d "$1" --arg r "$2" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $r}}'
    exit 0
}

SEGMENTS_HELPER="$(dirname "${BASH_SOURCE[0]}")/shell-command-segments.py"
if ! segments="$(command -v python3 >/dev/null 2>&1 && [ -f "$SEGMENTS_HELPER" ] && python3 "$SEGMENTS_HELPER" <<< "$cmd" 2>/dev/null)"; then
    if grep -Eq 'push|merge' <<< "$cmd"; then
        emit ask "git-workflow-guard could not parse this command (python3 or shell-command-segments.py is unavailable), and it may push or merge. Confirm it."
    fi
    exit 0
fi

current_branch() {
    git -C "${cwd:-.}" symbolic-ref --quiet --short HEAD 2>/dev/null
}

is_trunk_ref() {
    case "$1" in
        main | master | refs/heads/main | refs/heads/master | *:main | *:master | *:refs/heads/main | *:refs/heads/master) return 0 ;;
        HEAD | HEAD:*) case "$(current_branch)" in main | master) return 0 ;; esac ;;
    esac
    return 1
}

check_git() {
    # $@ = the words after the git program name
    local word sub="" i=0
    local -a args=("$@")
    while [ "$i" -lt "${#args[@]}" ]; do
        word="${args[i]}"
        case "$word" in
            -C | -c | --git-dir | --work-tree | --namespace) i=$((i + 2)); continue ;;
            -*) i=$((i + 1)); continue ;;
            *) sub="$word"; i=$((i + 1)); break ;;
        esac
    done
    [ "$sub" = "push" ] || return 0
    local refspecs=0 positional=0 force=0
    for word in "${args[@]:i}"; do
        case "$word" in
            -f | --force | --force-with-lease* | --force-if-includes | --mirror | --delete | -d) force=1 ;;
            -*) ;;
            *)
                positional=$((positional + 1))
                # the first positional word is the remote
                if [ "$positional" -gt 1 ]; then
                    refspecs=$((refspecs + 1))
                    case "$word" in +*) force=1 ;; esac
                    is_trunk_ref "${word#+}" && emit ask "This pushes to ${word#+}, the trunk. Pushing to main or master needs the owner's go-ahead in this turn. Confirm it, or push a feature branch and open a PR."
                fi ;;
        esac
    done
    if [ "$refspecs" -eq 0 ]; then
        case "$(current_branch)" in
            main | master) emit ask "This pushes the current branch, $(current_branch), which is the trunk. Confirm it, or push a feature branch and open a PR." ;;
        esac
    fi
    [ "$force" -eq 1 ] && emit ask "This is a force push, a delete, or a mirror push, which can overwrite or remove remote history. Confirm it."
    return 0
}

check_gh() {
    [ "${1:-}" = "pr" ] && [ "${2:-}" = "merge" ] || return 0
    local word pr="" body pending=""
    local -a repo_args=()
    for word in "${@:3}"; do
        case "$pending" in
            repo) repo_args=(--repo "$word"); pending=""; continue ;;
            value) pending=""; continue ;;
        esac
        case "$word" in
            --merge | -m) emit deny "Feature branches squash-merge so each PR is one commit on main. Re-run with --squash." ;;
            -R | --repo) pending=repo ;;
            --repo=*) repo_args=("$word") ;;
            -b | --body | -t | --subject | -F | --body-file | -A | --author-email | --match-head-commit) pending=value ;;
            -*) ;;
            *) [ -n "$pr" ] || pr="$word" ;;
        esac
    done
    if body="$(cd "${cwd:-.}" 2>/dev/null && gh pr view ${pr:+"$pr"} ${repo_args[@]+"${repo_args[@]}"} --json body --jq .body 2>/dev/null)"; then
        printf '%s\n' "$body" | grep -Eq '^##[[:space:]]+Review[[:space:]]*$' ||
            emit deny "This PR body has no '## Review' section. Every PR gets one fresh-context review before it merges: run the pr-reviewer agent on the diff, fix or answer its findings, and record the reviewer, the range, and the findings with their dispositions under '## Review'."
    fi
    emit ask "Merging a PR needs the owner's approval of that PR. Confirm this merge, or wait for the owner to approve it."
}

while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS=$'\037' read -r -a words <<< "$line"
    start=0
    while [ "$start" -lt "${#words[@]}" ]; do
        case "${words[start]}" in
            env | sudo | command | nohup | time | exec) start=$((start + 1)) ;;
            [A-Za-z_]*=*) start=$((start + 1)) ;;
            $'\036'*) start=$((start + 2)) ;;
            *) break ;;
        esac
    done
    [ "$start" -lt "${#words[@]}" ] || continue
    program="$(basename -- "${words[start]}")"
    rest=()
    for word in "${words[@]:start+1}"; do
        case "$word" in $'\036'*) continue ;; esac
        rest+=("$word")
    done
    case "$program" in
        git) check_git ${rest[@]+"${rest[@]}"} ;;
        gh) check_gh ${rest[@]+"${rest[@]}"} ;;
    esac
done <<< "$segments"
exit 0
