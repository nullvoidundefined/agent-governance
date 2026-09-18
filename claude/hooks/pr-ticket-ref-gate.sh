#!/usr/bin/env bash
# pr-ticket-ref-gate.sh: on `gh pr create`, deny a pull request that carries
# no tracker ticket reference (R-605). A reference is a line of the form
# `Refs: <KEY>`, KEY matching [A-Z][A-Z0-9]+-[0-9]+, found either in the
# message of a commit in the pull request's range or in the body passed with
# --body/-b or --body-file/-F. The `Refs:` form is required rather than a bare
# key match, because rule IDs (R-605) and strings such as SHA-256 would
# otherwise read as ticket keys.
#
# Three exemptions, in order: a range whose every changed path is a Markdown
# file or sits under docs/ (a docs-only change needs no ticket); a task-start
# ledger (.claude/task-tier.json) recording the trivial tier for the current
# branch, since R-605 asks for a ticket only above the trivial tier; and an
# absent ~/.claude/TICKET-TRACKER.json, where R-605's degraded path applies,
# so the call is allowed with a warning in the hook's context and never in
# silence.
#
# Base: the pull request's base branch (--base/-B, else origin's default
# branch, else main or master), merged with HEAD. resolve-outgoing-base.sh is
# deliberately not used: its first choice is the branch's own push tracking
# ref, and a branch is normally pushed before its pull request is opened, so
# that range would be empty and every PR would read as carrying no commits.
# CLAUDE_ENFORCE_BASE still overrides, as it does for every push gate.
#
# set -uo, no -e: an unexpected internal error under -e kills the hook before
# it can emit a decision, and a PreToolUse hook that emits nothing is an
# allow; a guard fails closed by structure, never open by accident
# (2026-09-16 audit P2-8; convention documented in enforce/README.md).
set -uo pipefail

KEY_PATTERN='[A-Z][A-Z0-9]+-[0-9]+'
REFS_LINE_PATTERN="^[[:space:]\"']*Refs:[[:space:]]*${KEY_PATTERN}([^A-Za-z0-9-]|\$)"
# A cheap prefilter only: a command that mentions the words reaches the
# shell-aware scan below, which decides whether gh pr create really runs.
PREFILTER_PATTERN='gh[[:space:]]+pr[[:space:]]+(create|new)'
SEPARATOR_TOKEN=$'\001separator'
HEREDOC_TOKEN=$'\001heredoc'
HEREDOC_PATTERN="^<<-?[[:space:]]*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?"

# has_refs_line <text>: true when some line of the text is a Refs trailer
# naming a ticket key, optionally preceded by an opening quote.
has_refs_line() {
  grep -Eq -- "$REFS_LINE_PATTERN" <<< "$1"
}

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

# inspect_simple_command <stdin> <word>...: for a cd, moves TARGET_DIR; for
# gh pr create (or its alias new), records its arguments in INVOCATION_ARGS
# and its heredoc in INVOCATION_STDIN and returns 0. Leading VAR=value
# assignments are skipped.
inspect_simple_command() {
  local stdin="$1"; shift
  while [ "$#" -gt 0 ] && [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do shift; done
  [ "$#" -gt 0 ] || return 1
  if [ "$1" = "cd" ]; then shift; apply_cd "$@"; return 1; fi
  [ "$1" = "gh" ] && [ "${2:-}" = "pr" ] || return 1
  case "${3:-}" in create|new) ;; *) return 1 ;; esac
  shift 3
  INVOCATION_ARGS=("$@"); INVOCATION_STDIN="$stdin"
  return 0
}

# find_pr_invocation <session-dir>: walks TOKENS one simple command at a
# time from the session's directory, replaying each cd, and stops at the
# first gh pr create; returns 1 when the command never runs one.
find_pr_invocation() {
  local token stdin='' is_heredoc_next=0
  local -a words=()
  TARGET_DIR="$1"
  for token in ${TOKENS[@]+"${TOKENS[@]}"}; do
    if [ "$is_heredoc_next" -eq 1 ]; then stdin="$token"; is_heredoc_next=0; continue; fi
    case "$token" in
      "$HEREDOC_TOKEN") is_heredoc_next=1 ;;
      "$SEPARATOR_TOKEN")
        inspect_simple_command "$stdin" ${words[@]+"${words[@]}"} && return 0
        words=(); stdin='' ;;
      *) words+=("$token") ;;
    esac
  done
  return 1
}

# parse_invocation_flags: reads the body, body file, and base out of
# INVOCATION_ARGS word by word, so a flag spelled inside another argument's
# quoted value (a title mentioning --body) is never taken for the flag.
parse_invocation_flags() {
  local arg expected=''
  BODY_TEXT=''; BODY_FILE=''; BASE_NAME=''
  for arg in ${INVOCATION_ARGS[@]+"${INVOCATION_ARGS[@]}"}; do
    case "$expected" in
      body) BODY_TEXT="$arg"; expected=''; continue ;;
      file) BODY_FILE="$arg"; expected=''; continue ;;
      base) BASE_NAME="$arg"; expected=''; continue ;;
    esac
    case "$arg" in
      --body|-b) expected='body' ;;
      --body=*) BODY_TEXT="${arg#--body=}" ;;
      --body-file|-F) expected='file' ;;
      --body-file=*) BODY_FILE="${arg#--body-file=}" ;;
      --base|-B) expected='base' ;;
      --base=*) BASE_NAME="${arg#--base=}" ;;
    esac
  done
}

# body_has_reference: true when --body, a readable --body-file, or the
# heredoc behind `--body-file -` carries a Refs line.
body_has_reference() {
  local file="$BODY_FILE"
  has_refs_line "$BODY_TEXT" && return 0
  if [ "$file" = "-" ]; then has_refs_line "$INVOCATION_STDIN"; return; fi
  [ -n "$file" ] || return 1
  case "$file" in "~"/*) file="$HOME/${file#\~/}" ;; /*) ;; *) file="$TARGET_DIR/$file" ;; esac
  [ -f "$file" ] && has_refs_line "$(cat "$file" 2>/dev/null)"
}

# resolve_pr_base <base-name> <repo-top>: prints the merge base of HEAD with
# the pull request's base branch; empty when none of the candidates exist.
resolve_pr_base() {
  local named="$1" dir="$2" default="" candidate merge_base
  if [ -n "${CLAUDE_ENFORCE_BASE:-}" ]; then printf '%s' "$CLAUDE_ENFORCE_BASE"; return; fi
  default=$(git -C "$dir" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
  for candidate in ${named:+"origin/$named" "$named"} ${default:+"$default"} origin/main main origin/master master; do
    git -C "$dir" rev-parse --verify -q "$candidate" >/dev/null 2>&1 || continue
    merge_base=$(git -C "$dir" merge-base "$candidate" HEAD 2>/dev/null || true)
    [ -n "$merge_base" ] && { printf '%s' "$merge_base"; return; }
  done
}

# commits_have_reference <target-dir> <base>: true when a commit message in
# base..HEAD carries a Refs line.
commits_have_reference() {
  local dir="$1" base="$2"
  [ -n "$base" ] || return 1
  has_refs_line "$(git -C "$dir" log --format=%B "$base..HEAD" 2>/dev/null)"
}

# is_docs_only_range <target-dir> <base>: true when the range changes at
# least one path and every changed path is *.md or under docs/. An empty or
# unreadable range is not docs-only, so it cannot exempt anything.
is_docs_only_range() {
  local dir="$1" base="$2" changed
  [ -n "$base" ] || return 1
  changed=$(git -C "$dir" diff --name-only "$base...HEAD" 2>/dev/null) || return 1
  [ -n "$changed" ] || return 1
  ! grep -Evq '(\.md$|^docs/)' <<< "$changed"
}

# is_trivial_tier <repo-top>: true when task-start's ledger records the
# trivial tier for the branch currently checked out (a ledger left from an
# earlier branch does not count).
is_trivial_tier() {
  local top="$1" ledger="$1/.claude/task-tier.json" branch
  [ -f "$ledger" ] || return 1
  branch=$(git -C "$top" branch --show-current 2>/dev/null || true)
  jq -e --arg b "$branch" '.tier == "trivial" and ((.branch // "") == "" or .branch == $b)' "$ledger" >/dev/null 2>&1
}

# record_fire <decision>: logs one R-605 fire through the shared telemetry
# helper when it is present.
record_fire() {
  local helper
  helper="$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh"
  # shellcheck source=log-rule-fire.sh
  [ -f "$helper" ] && source "$helper"
  type log_rule_fire >/dev/null 2>&1 && log_rule_fire "R-605" "pr-ticket-ref-gate" "$1"
  return 0
}

# emit_degraded_warning: allows the call with context naming R-605's
# degraded path, for a machine with no tracker configured.
emit_degraded_warning() {
  record_fire "warn"
  jq -nc --arg m "R-605 (ticket reference): this pull request carries no \`Refs: <KEY>\` line in its commits or body, and no tracker is configured (~/.claude/TICKET-TRACKER.json is absent), so it proceeds on R-605's degraded path. Record the ticket field set (title, tier, assist, model, estimate, repo, branch) in docs/session-handoff/session-handoff.md, and copy ~/.claude/TICKET-TRACKER.template.json to TICKET-TRACKER.json to turn the tracker on." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$m}}'
}

# emit_deny <base>: denies the call, naming R-605 and the fix.
emit_deny() {
  local note=""
  [ -n "$1" ] || note=" No repository or base branch could be resolved, so the commits were not read; the body alone was checked."
  record_fire "deny"
  jq -nc --arg r "R-605 (ticket reference): no commit in this pull request and no --body/--body-file text carries a \`Refs: <KEY>\` line (KEY like IAN-119; a bare rule ID or key does not count). Open the ticket with /ticket-lifecycle, then add \`Refs: <KEY>\` as a commit trailer or a line of the PR body. Exempt: docs-only changes and a trivial tier recorded by task-tier.sh for this branch.${note}" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
}

INPUT=$(cat)
CMD=$(jq -r '.tool_input.command // "" | strings' 2>/dev/null <<< "$INPUT" || true)
grep -Eq -- "$PREFILTER_PATTERN" <<< "$CMD" || exit 0

SESSION_DIR=$(jq -r '.cwd // "" | strings' 2>/dev/null <<< "$INPUT" || true)
[ -n "$SESSION_DIR" ] && [ -d "$SESSION_DIR" ] || SESSION_DIR="$PWD"
# Read the command as shell: the cds before the invocation decide the
# directory, and only the invocation's own words supply the body and flags,
# so quoted text, an earlier `-b`, or a later command's heredoc or `-F` is
# never taken for the pull request's.
scan_command_tokens "$CMD"
find_pr_invocation "$SESSION_DIR" || exit 0
parse_invocation_flags

body_has_reference && exit 0
# Outside a repository (gh pr create -R owner/repo --head branch) there are
# no commits or ledger to read; the body was the only source, so the call
# falls through to the tracker check and the deny rather than exiting open.
TOP=$(git -C "$TARGET_DIR" rev-parse --show-toplevel 2>/dev/null || true)
BASE=""
if [ -n "$TOP" ]; then
  BASE=$(resolve_pr_base "$BASE_NAME" "$TOP")
  commits_have_reference "$TOP" "$BASE" && exit 0
  is_docs_only_range "$TOP" "$BASE" && exit 0
  is_trivial_tier "$TOP" && exit 0
fi
if [ ! -f "$HOME/.claude/TICKET-TRACKER.json" ]; then
  emit_degraded_warning
  exit 0
fi
emit_deny "$BASE"
exit 0
