#!/usr/bin/env bash
# shell-command-scan.sh: sourced helper, not a hook. Reads a Bash tool
# command as the shell would, short of expanding it, so a hook decides from
# the simple commands that really run rather than from text that merely
# mentions them: a "git push" or "gh pr create" quoted inside a commit
# message or a PR body is data, not an invocation. Factored out of
# pr-ticket-ref-gate.sh (IAN-137) so the R-605 gate and the R-517 draft-PR
# hooks share one scanner. Nothing here is evaluated: the input is an
# untrusted tool-call string.

SEPARATOR_TOKEN=$'\001separator'
HEREDOC_TOKEN=$'\001heredoc'
HEREDOC_PATTERN="^<<-?[[:space:]]*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?"

# capture_heredoc <text> <delimiter>: the text starts on the line that
# introduces a heredoc; sets HEREDOC_BODY to the lines after that one up to
# the terminator line, and HEREDOC_END to the offset of the newline that ends
# the terminator line (the text's length when it never appears).
capture_heredoc() {
  local text="$1" delimiter="$2" offset=0 line stripped is_first=1
  HEREDOC_BODY=''
  while IFS= read -r line || [ -n "$line" ]; do
    offset=$((offset + ${#line} + 1))
    if [ "$is_first" -eq 1 ]; then is_first=0; continue; fi
    stripped="${line#"${line%%[!$'\t']*}"}"
    if [ "$stripped" = "$delimiter" ]; then HEREDOC_END=$((offset - 1)); return; fi
    HEREDOC_BODY="$HEREDOC_BODY$line"$'\n'
  done <<< "$text"
  HEREDOC_END=${#text}
}

# flush_word: moves the word being built, if any, onto TOKENS.
flush_word() {
  [ "$HAS_WORD" -eq 1 ] && TOKENS+=("$WORD")
  WORD=''; HAS_WORD=0
}

# push_separator: ends the current simple command on TOKENS, collapsing runs
# of separators (&&, ;;, a blank line) into one.
push_separator() {
  flush_word
  local count=${#TOKENS[@]}
  [ "$count" -gt 0 ] && [ "${TOKENS[count - 1]}" = "$SEPARATOR_TOKEN" ] && return
  TOKENS+=("$SEPARATOR_TOKEN")
}

# scan_command_tokens <command>: splits a Bash tool command into shell words
# on TOKENS, with SEPARATOR_TOKEN between simple commands (at an unquoted ;
# & | ( ) or newline) and HEREDOC_TOKEN plus the body for a heredoc fed to a
# command. Quotes are honored and removed, and a heredoc inside a quoted word
# (--body "$(cat <<'EOF' ...)") stays part of that word. Nothing is expanded
# or evaluated: the input is an untrusted tool-call string.
scan_command_tokens() {
  local text="$1" index=0 length=${#1} char quote='' pending=''
  TOKENS=(); WORD=''; HAS_WORD=0
  while [ "$index" -lt "$length" ]; do
    char="${text:index:1}"
    if [ "$quote" = "'" ]; then
      if [ "$char" = "'" ]; then quote=''; else WORD="$WORD$char"; fi
    elif [ "$char" = '<' ] && [[ "${text:index:80}" =~ $HEREDOC_PATTERN ]]; then
      if [ -n "$quote" ]; then
        capture_heredoc "${text:index}" "${BASH_REMATCH[1]}"
        WORD="$WORD${text:index:HEREDOC_END}"; index=$((index + HEREDOC_END)); continue
      fi
      flush_word; pending="${BASH_REMATCH[1]}"; index=$((index + ${#BASH_REMATCH[0]})); continue
    elif [ "$char" = "\\" ]; then
      index=$((index + 1)); [ "${text:index:1}" = $'\n' ] || { WORD="$WORD${text:index:1}"; HAS_WORD=1; }
    elif [ "$char" = '"' ]; then
      if [ "$quote" = '"' ]; then quote=''; else quote='"'; HAS_WORD=1; fi
    elif [ -n "$quote" ]; then
      WORD="$WORD$char"
    elif [ "$char" = $'\n' ] && [ -n "$pending" ]; then
      flush_word; capture_heredoc "${text:index}" "$pending"
      TOKENS+=("$HEREDOC_TOKEN" "$HEREDOC_BODY"); push_separator
      pending=''; index=$((index + HEREDOC_END)); continue
    else
      case "$char" in
        ' '|$'\t') flush_word ;;
        $'\n'|';'|'&'|'|'|'('|')') push_separator ;;
        "'") quote="'"; HAS_WORD=1 ;;
        *) WORD="$WORD$char"; HAS_WORD=1 ;;
      esac
    fi
    index=$((index + 1))
  done
  push_separator
}

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
  INVOCATION_ARGS=("$@"); INVOCATION_STDIN="$stdin"
  return 0
}
