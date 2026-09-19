#!/usr/bin/env bash
# shell-command-scan.sh: sourced helper, not a hook. Reads a Bash tool
# command as the shell would, short of expanding it, so a hook decides from
# the simple commands that really run rather than from text that merely
# mentions them: a "git push" or "gh pr create" quoted inside a commit
# message or a PR body is data, not an invocation. Factored out of
# pr-ticket-ref-gate.sh (IAN-137) so the R-605 gate and the R-518 draft-PR
# hooks share one command walk. Nothing here is evaluated: the input is an
# untrusted tool-call string.

# The word scan itself (scan_command_tokens, SEPARATOR_TOKEN, HEREDOC_TOKEN)
# is shell-command-tokens.sh's, shared with git-workflow-guard.sh; this file
# adds the walk over the scanned words. A caller that finds scan_command_tokens
# undefined after sourcing this file treats the helpers as missing.
SHELL_COMMAND_TOKENS_HELPER="$(dirname "${BASH_SOURCE[0]}")/shell-command-tokens.sh"
# shellcheck source=shell-command-tokens.sh
[ -f "$SHELL_COMMAND_TOKENS_HELPER" ] && source "$SHELL_COMMAND_TOKENS_HELPER"

# apply_cd <word>...: replays one cd onto TARGET_DIR, skipping its options;
# a target that does not exist leaves the directory unchanged, as the shell
# would after the failed cd, and `cd -` is not followed.
apply_cd() {
  local target=""
  while [ "$#" -gt 0 ]; do case "$1" in -?*) shift ;; *) target="$1"; break ;; esac; done
  case "$target" in
    ""|"~") target="$HOME" ;;
    "~"/*) target="$HOME/${target#\~/}" ;;
    -) return 0 ;;
    /*) ;;
    *) target="$TARGET_DIR/$target" ;;
  esac
  [ -d "$target" ] && TARGET_DIR="$target"
  return 0
}

# find_simple_command <session-dir> <matcher>: walks TOKENS one simple
# command at a time from the session's directory, replaying each cd onto
# TARGET_DIR, and calls `<matcher> <stdin> <word>...` for every other simple
# command (leading VAR=value assignments skipped); stops and returns 0 at the
# first command the matcher accepts, 1 when none does.
find_simple_command() {
  local matcher="$2" token stdin='' is_heredoc_next=0
  local -a words=()
  TARGET_DIR="$1"
  for token in ${TOKENS[@]+"${TOKENS[@]}"}; do
    if [ "$is_heredoc_next" -eq 1 ]; then stdin="$token"; is_heredoc_next=0; continue; fi
    case "$token" in
      "$HEREDOC_TOKEN") is_heredoc_next=1 ;;
      "$SEPARATOR_TOKEN")
        inspect_simple_command "$matcher" "$stdin" ${words[@]+"${words[@]}"} && return 0
        words=(); stdin='' ;;
      *) words+=("$token") ;;
    esac
  done
  return 1
}

# inspect_simple_command <matcher> <stdin> <word>...: replays a cd, otherwise
# hands the command's words, minus leading assignments, to the matcher.
inspect_simple_command() {
  local matcher="$1" stdin="$2"; shift 2
  while [ "$#" -gt 0 ] && [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do shift; done
  [ "$#" -gt 0 ] || return 1
  if [ "$1" = "cd" ]; then shift; apply_cd "$@"; return 1; fi
  "$matcher" "$stdin" "$@"
}

# is_pr_create_command <stdin> <word>...: a matcher for gh pr create (or its
# alias new); records its arguments in INVOCATION_ARGS and its heredoc in
# INVOCATION_STDIN.
is_pr_create_command() {
  local stdin="$1"; shift
  [ "${1:-}" = "gh" ] && [ "${2:-}" = "pr" ] || return 1
  case "${3:-}" in create|new) ;; *) return 1 ;; esac
  shift 3
  # Both are read by the hook that sources this helper.
  # shellcheck disable=SC2034
  INVOCATION_ARGS=("$@")
  # shellcheck disable=SC2034
  INVOCATION_STDIN="$stdin"
  return 0
}
