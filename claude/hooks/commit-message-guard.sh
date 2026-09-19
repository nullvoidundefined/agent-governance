#!/usr/bin/env bash
# commit-message-guard.sh: PreToolUse gate on the messages of every `git
# commit` a Bash command really runs (-m, or -F - fed by a heredoc), including
# one run through `bash -c`, `sh -c`, `eval`, or a heredoc fed to a shell.
# Denies a non-conventional subject or more than two triage IDs in the scope
# (R-505); asks on a body longer than three non-trailer lines (R-506, whose
# multi-line exemption is a user judgment), and a deny on any commit in the
# command wins over an ask on another. A message holding a command
# substitution whose output the hook cannot read is an ask; `-F <file>` is out
# of reach and allowed.
# set -uo, no -e: an unexpected internal error under -e kills the hook before
# it can emit a decision, and a PreToolUse hook that emits nothing is an
# allow; a guard fails closed by structure, never open by accident
# (2026-09-16 audit P2-8; convention documented in enforce/README.md).
set -uo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

# A cheap superset of every command that can run a commit: a `git` word and the
# text `commit` somewhere after it. Everything else skips the word scan, whose
# cost grows with the command's length.
grep -Eq '(^|[^[:alnum:]_.-])git([^[:alnum:]_-]|$)' <<< "$CMD" || exit 0
grep -q 'commit' <<< "$CMD" || exit 0

LOG_RULE_FIRE_HELPER="$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh"
[ -f "$LOG_RULE_FIRE_HELPER" ] && source "$LOG_RULE_FIRE_HELPER"
type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }

deny() {
  log_rule_fire "R-505" "commit-message-guard" "deny"
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}
ask() {
  log_rule_fire "R-506" "commit-message-guard" "ask"
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
  exit 0
}

# Find each commit the way the shell would run it, through the quote-aware scan
# in shell-command-scan.sh (shared with pr-ticket-ref-gate.sh). A grep over the
# raw text read `git commit -m ...` written as data, inside a quoted argument
# or a heredoc fed to cat, as a commit, and denied a subagent writing a test
# file on 2026-09-19 (IAN-149). The scan also reads a real commit behind env
# assignments, wrappers (env, time, nice, timeout, command), and git's global
# options (-C, -c).
SHELL_COMMAND_SCAN_HELPER="$(dirname "${BASH_SOURCE[0]}")/shell-command-scan.sh"
# shellcheck source=shell-command-scan.sh
[ -f "$SHELL_COMMAND_SCAN_HELPER" ] && source "$SHELL_COMMAND_SCAN_HELPER"
if ! type scan_command_tokens >/dev/null 2>&1 || ! type is_git_commit_command >/dev/null 2>&1; then
  deny "commit-message-guard (R-505): a helper this hook sources (shell-command-scan.sh or shell-command-tokens.sh) is missing, so this hook cannot read the command; re-run ./sync.sh to restore it."
fi

# read_substituted_heredoc <word>: prints the body of a `$(cat <<'EOF' ...
# EOF)` substitution, the form a multi-line -m message usually takes; prints
# nothing for any other substitution, whose value the scan never computes.
read_substituted_heredoc() {
  printf '%s' "$1" | perl -0777 -ne '
    if (/\A\$\(\s*cat\s*<<-?\s*['\''"]?([A-Za-z_][A-Za-z0-9_]*)['\''"]?[ \t]*\n(.*?)\n[ \t]*\1[ \t]*\n?\s*\)\s*\z/s) { print $2; }
  '
}

# read_short_option_cluster <word> <next word>: reads one bundled short-option
# word the way git does (`-am msg`, `-qm msg`, `-am"msg"`): letters before the
# first option that takes a value are flags, and that option's value is the
# rest of the word or, when the word ends there, the next word. Appends an -m
# value to MESSAGES, sets IS_STDIN_MESSAGE for `-F -`, and sets
# IS_NEXT_WORD_TAKEN when the value was the next word.
read_short_option_cluster() {
  local cluster="${1#-}" letter value
  IS_NEXT_WORD_TAKEN=0
  while [ -n "$cluster" ]; do
    letter="${cluster:0:1}"; cluster="${cluster:1}"
    case "$letter" in
      m | F | C | c | t)
        value="$cluster"
        if [ -z "$value" ] && [ "$#" -ge 2 ]; then value="$2"; IS_NEXT_WORD_TAKEN=1; fi
        [ "$letter" = "m" ] && MESSAGES+=("$value")
        [ "$letter" = "F" ] && [ "$value" = "-" ] && IS_STDIN_MESSAGE=1
        return 0 ;;
      S | u) return 0 ;;
    esac
  done
}

# collect_commit_messages <word>...: fills MESSAGES with every -m value of one
# commit's arguments and sets IS_STDIN_MESSAGE for `-F -`. `-F <file>` keeps
# the message on disk rather than in the command, so it stays out of reach and
# out of this gate (2026-09-17 audit P2-7). The values of long options that
# take one are skipped, so `--author "-m x"` is not a message.
collect_commit_messages() {
  MESSAGES=(); IS_STDIN_MESSAGE=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --message) [ "$#" -ge 2 ] && MESSAGES+=("$2"); shift 2 2>/dev/null || shift ;;
      --message=*) MESSAGES+=("${1#--message=}"); shift ;;
      --file) [ "${2:-}" = "-" ] && IS_STDIN_MESSAGE=1; shift 2 2>/dev/null || shift ;;
      --file=-) IS_STDIN_MESSAGE=1; shift ;;
      --author | --date | --template | --fixup | --squash | --cleanup | --trailer | --reuse-message | --reedit-message | --pathspec-from-file)
        shift 2 2>/dev/null || shift ;;
      --) break ;;
      --*) shift ;;
      -?*)
        read_short_option_cluster "$@"
        if [ "$IS_NEXT_WORD_TAKEN" -eq 1 ]; then shift 2; else shift; fi ;;
      *) shift ;;
    esac
  done
}

# join_commit_messages: sets MSG to the MESSAGES git would join with a blank
# line, each `$(cat <<EOF ...)` value read from its heredoc. Any other command
# substitution's output is unknown, so it sets IS_MESSAGE_UNCOUNTABLE: a value
# that starts with one is dropped, and when that is the first value, which
# carries the subject, MSG stays empty; a substitution later in a value is kept
# as literal text, since the subject's conventional prefix is literal either
# way, but its output may add body lines (Copilot on PR #79).
join_commit_messages() {
  local message index=0
  MSG=''; IS_MESSAGE_UNCOUNTABLE=0
  for message in ${MESSAGES[@]+"${MESSAGES[@]}"}; do
    # shellcheck disable=SC2016  # the literal `$(` of a substitution, not an expansion
    case "$message" in
      '$('* | '`'*)
        message=$(read_substituted_heredoc "$message")
        if [ -z "$message" ]; then
          IS_MESSAGE_UNCOUNTABLE=1
          [ "$index" -eq 0 ] && return 0
          index=$((index + 1)); continue
        fi ;;
      *'$('* | *'`'*) IS_MESSAGE_UNCOUNTABLE=1 ;;
    esac
    MSG="${MSG:+$MSG$'\n\n'}$message"
    index=$((index + 1))
  done
}

# judge_commit_message: denies the commit in MSG on an R-505 subject problem,
# or records an R-506 ask in PENDING_ASK_REASON for after every commit is read.
judge_commit_message() {
  local subject scope comma_count body_line_count
  subject=$(printf '%s\n' "$MSG" | head -1)
  if ! grep -qE '^(feat|fix|chore|docs|refactor|test|perf|style|build|ci|revert)(\([^)]*\))?!?: .+' <<< "$subject"; then
    deny "commit-message-guard BLOCKED this commit (R-505): subject '$subject' is not in conventional form 'type(scope): summary'. Types: feat|fix|chore|docs|refactor|test|perf|style|build|ci|revert."
  fi
  scope=$(printf '%s' "$subject" | sed -nE 's/^[a-z]+\(([^)]*)\).*/\1/p')
  if [ -n "$scope" ]; then
    comma_count=$(printf '%s' "$scope" | tr -cd ',' | wc -c | tr -d ' ')
    if [ "$comma_count" -gt 1 ]; then
      deny "commit-message-guard BLOCKED this commit (R-505): scope '($scope)' carries more than two triage IDs. One commit per triage ID; two IDs max when inseparable."
    fi
  fi
  body_line_count=$(printf '%s\n' "$MSG" | tail -n +2 \
    | grep -v '^[[:space:]]*$' \
    | grep -vE '^(Co-Authored-By|Signed-off-by|Reviewed-by|Refs):' \
    | grep -cv "Generated with" || true)
  if [ "${body_line_count:-0}" -gt 3 ]; then
    PENDING_ASK_REASON="commit-message-guard (R-506): the body has $body_line_count non-trailer lines; the norm is a one-sentence body, with multi-line reserved for business-logic bugs, architectural refactors, and security changes. Confirm to proceed if this commit qualifies."
  fi
}

# read_shell_script <stdin> <word>...: sets SHELL_SCRIPT to the script a shell
# command runs, when the words are a shell with `-c <string>` (or a cluster
# ending in c, such as -lc), eval, or a shell reading a heredoc with no script
# file; returns 1 for any other command.
read_shell_script() {
  local stdin="$1"
  shift
  SHELL_SCRIPT=''
  case "$(basename -- "${1:-}")" in
    eval) shift; SHELL_SCRIPT="$*"; return 0 ;;
    sh | bash | zsh | dash | ksh) shift ;;
    *) return 1 ;;
  esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -O | +O | -o | +o | --rcfile | --init-file) shift 2 2>/dev/null || shift ;;
      -*c) SHELL_SCRIPT="${2:-}"; return 0 ;;
      -* | +*) shift ;;
      *) return 1 ;;
    esac
  done
  SHELL_SCRIPT="$stdin"
  [ -n "$SHELL_SCRIPT" ]
}

# judge_simple_command <stdin> <word>...: the find_simple_command matcher.
# Judges a git commit's message, walks the script of a shell or eval as a
# command of its own (to a depth of four), and always returns 1 so the walk
# goes on to every later command.
judge_simple_command() {
  if is_git_commit_command "$@"; then
    collect_commit_messages ${INVOCATION_ARGS[@]+"${INVOCATION_ARGS[@]}"}
    IS_MESSAGE_UNCOUNTABLE=0
    if [ "$IS_STDIN_MESSAGE" -eq 1 ] && [ "${#MESSAGES[@]}" -eq 0 ]; then MSG="$INVOCATION_STDIN"; else join_commit_messages; fi
    [ -n "$MSG" ] && judge_commit_message
    if [ "$IS_MESSAGE_UNCOUNTABLE" -eq 1 ] && [ -z "$PENDING_ASK_REASON" ]; then
      PENDING_ASK_REASON="commit-message-guard (R-505, R-506): the message holds a command substitution whose output this hook cannot read, so it cannot check the subject or count the body. Confirm to proceed if the resulting message has a conventional subject and a short body."
    fi
    return 1
  fi
  local stdin="$1"
  shift
  strip_command_prefixes "$@"
  [ "${#STRIPPED_WORDS[@]}" -gt 0 ] && read_shell_script "$stdin" "${STRIPPED_WORDS[@]}" || return 1
  [ "$SHELL_DEPTH" -lt 4 ] || return 1
  SHELL_DEPTH=$((SHELL_DEPTH + 1))
  judge_command_text "$SHELL_SCRIPT"
  SHELL_DEPTH=$((SHELL_DEPTH - 1))
  return 1
}

# judge_command_text <command>: scans a command and judges every commit in it.
judge_command_text() {
  scan_command_tokens "$1"
  find_simple_command "$PWD" judge_simple_command
}

PENDING_ASK_REASON=''
SHELL_DEPTH=0
judge_command_text "$CMD"
[ -n "$PENDING_ASK_REASON" ] && ask "$PENDING_ASK_REASON"
exit 0
