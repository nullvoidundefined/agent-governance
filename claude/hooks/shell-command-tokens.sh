#!/usr/bin/env bash
# shell-command-tokens.sh: a quote-aware scan of a Bash tool command into shell
# words, for hooks that must know which simple commands really run rather than
# which substrings a command's text contains. Source it; it defines functions
# and constants only and runs nothing. Extracted from pr-ticket-ref-gate.sh on
# 2026-09-19 so git-workflow-guard.sh could find `gh pr merge` the same way:
# a regex over the raw text had missed merges hidden by braces, subshells,
# quoting, and escapes, and had read merges into quoted commit messages.
#
# scan_command_tokens <command> fills TOKENS with the words of each simple
# command, SEPARATOR_TOKEN between simple commands (at an unquoted ; & | ( )
# or newline), and HEREDOC_TOKEN followed by the body for a heredoc fed to a
# command. Quotes are honored and removed, a backslash escapes the next
# character, and a backslash-newline is a line continuation. Nothing is
# expanded or evaluated: the input is an untrusted tool-call string.

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
