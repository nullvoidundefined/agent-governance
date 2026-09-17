#!/usr/bin/env bash
# git-invocation.sh: normalize a Bash command so `git <global options>
# <subcommand>` matches hooks written against `git <subcommand>` adjacency,
# and recover the repository that command actually targets. Source this from
# any push- or commit-boundary hook; never re-enumerate options inline. The
# 2026-08-21 audit closed `git -C` and `git -c`; the 2026-09-16 audit (P2-1)
# found `--no-pager`, `--git-dir`, `--work-tree`, and every other global option
# reopening the same bypass because the fix enumerated two options instead of
# stripping the class.
#
# Stripping alone is only half the job, and the missing half was the 2026-09-18
# audit's defect 4. A hook that strips `-C /other/repo` recognizes the push,
# then runs `git remote get-url origin`, `resolve_outgoing_base` and `git diff`
# in whatever repository the hook process happens to be sitting in, so a push
# aimed at another checkout is judged against the wrong diff and the wrong
# exemptions. parse_git_target_options recovers the target from the same
# command and run_git_on_target replays it onto every query the hook makes.
#
# Two shapes are stripped in one pass, options that take an argument
# (separate or `=`-joined) and bare flags; the subcommand itself never
# starts with `-`, so the strip always stops in front of it.
#
# An option argument may be quoted, which the unquoted-only pattern used to
# handle by consuming up to the first space: `git -C "/repos/my project" push`
# had `-C "/repos/my` removed and was left as `git project" push`, where the
# subcommand no longer sits next to `git` and the push stopped being recognized
# at all (2026-09-18 audit, defect 4). The argument alternation below accepts a
# double-quoted run, a single-quoted run, or an unquoted run, in that order.
strip_git_global_options() {
  local single_quote="'"
  local option='(-C|-c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix|--config-env)'
  local argument="(\"[^\"]*\"|${single_quote}[^${single_quote}]*${single_quote}|[^[:space:];&|]+)"
  sed -E "s/git([[:space:]]+(${option}([[:space:]]+|=)${argument}|-{1,2}[A-Za-z][A-Za-z0-9-]*(=[^[:space:];&|]*)?))+/git/g"
}

# The repository-selecting options recovered from the inspected command, ready
# to splice in front of a git subcommand. Empty means "the ambient repository",
# which is the behaviour every caller had before this array existed.
GIT_TARGET_ARGS=()

# Splits a command string into shell-like words in the TOKENS array, honoring
# single and double quotes so that a path containing spaces survives as one
# word. Deliberately does not expand variables, run substitutions, or evaluate
# anything: the input is an untrusted tool-call string, and `eval` on it would
# turn a guard into an execution primitive. Operators such as && and | are left
# attached to their neighbours, which is harmless here because the scan that
# follows only ever looks for the literal word `git`.
tokenize_command() {
  local text="$1" index=0 char quote='' token='' has_token=0
  TOKENS=()
  while [ "$index" -lt "${#text}" ]; do
    char="${text:index:1}"
    index=$((index + 1))
    if [ -n "$quote" ]; then
      if [ "$char" = "$quote" ]; then quote=''; else token="$token$char"; fi
      continue
    fi
    case "$char" in
      \'|\") quote="$char"; has_token=1 ;;
      ' '|$'\t'|$'\n') [ "$has_token" -eq 1 ] && { TOKENS+=("$token"); token=''; has_token=0; } ;;
      *) token="$token$char"; has_token=1 ;;
    esac
  done
  [ "$has_token" -eq 1 ] && TOKENS+=("$token")
  return 0
}

# Reads the global options of one git invocation, starting at the word after
# the `git` token whose index is given. Repository-selecting options are
# appended to GIT_TARGET_ARGS and the invocation's subcommand is left in
# GIT_INVOCATION_SUBCOMMAND; every other global option is skipped, consuming
# the separate argument that the argument-taking ones carry. Both results come
# back through globals rather than stdout because a command substitution would
# run this in a subshell and discard the array it builds.
read_git_invocation() {
  local index="$1" count="${#TOKENS[@]}" word
  GIT_INVOCATION_SUBCOMMAND=''
  while [ "$index" -lt "$count" ]; do
    word="${TOKENS[index]}"
    case "$word" in
      -C|--git-dir|--work-tree)
        [ $((index + 1)) -lt "$count" ] || return 0
        GIT_TARGET_ARGS+=("$word" "${TOKENS[index + 1]}")
        index=$((index + 2)) ;;
      --git-dir=*|--work-tree=*)
        GIT_TARGET_ARGS+=("$word")
        index=$((index + 1)) ;;
      -c|--namespace|--exec-path|--super-prefix|--config-env)
        index=$((index + 2)) ;;
      -*)
        index=$((index + 1)) ;;
      *)
        GIT_INVOCATION_SUBCOMMAND="$word"
        return 0 ;;
    esac
  done
  return 0
}

# Fills GIT_TARGET_ARGS with the -C, --git-dir and --work-tree options of the
# git invocation in the given command whose subcommand matches the second
# argument (`push` for the push-boundary gates). A command holding several git
# invocations is read left to right and the matching one wins, so that
# `git -C /a fetch && git -C /b push` is judged against /b; when no invocation
# names that subcommand the array is left empty and callers fall back to the
# ambient repository, which is the safe direction for a guard.
parse_git_target_options() {
  local command_text="$1" wanted="$2" index count
  GIT_TARGET_ARGS=()
  tokenize_command "$command_text"
  count="${#TOKENS[@]}"
  for ((index = 0; index < count; index++)); do
    [ "${TOKENS[index]}" = "git" ] || continue
    GIT_TARGET_ARGS=()
    read_git_invocation $((index + 1))
    [ "$GIT_INVOCATION_SUBCOMMAND" = "$wanted" ] && return 0
  done
  GIT_TARGET_ARGS=()
  return 0
}

# Prints the working directory that the parsed target names, or nothing when
# the command named none. `-C` and `--work-tree` both select a working tree and
# the last one given wins, which matches git's own precedence; `--git-dir` is
# skipped here because it names a repository directory rather than a working
# tree, and a caller that reasons in working directories cannot use it. Call
# parse_git_target_options first.
read_git_target_directory() {
  local index count directory=''
  count="${#GIT_TARGET_ARGS[@]}"
  for ((index = 0; index < count; index++)); do
    case "${GIT_TARGET_ARGS[index]}" in
      -C|--work-tree) [ $((index + 1)) -lt "$count" ] && directory="${GIT_TARGET_ARGS[index + 1]}" ;;
      --work-tree=*) directory="${GIT_TARGET_ARGS[index]#--work-tree=}" ;;
    esac
  done
  printf '%s' "$directory"
}

# Runs one git query against the repository the inspected command targets.
# With GIT_TARGET_ARGS empty this is plain git against the ambient repository,
# so a caller that never parsed a target keeps its previous behaviour exactly.
run_git_on_target() {
  git ${GIT_TARGET_ARGS[@]+"${GIT_TARGET_ARGS[@]}"} "$@"
}
