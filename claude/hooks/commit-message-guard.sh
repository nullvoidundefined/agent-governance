#!/usr/bin/env bash
# commit-message-guard.sh: PreToolUse gate on the messages of the `git commit`
# invocations a Bash command really runs (-m, or -F - fed by a heredoc).
# Denies a non-conventional subject or more than two triage IDs in the scope
# (R-505); asks on a body longer than three non-trailer lines (R-506, whose
# multi-line exemption is a user judgment). Unparseable commands fail open.
# set -uo, no -e: an unexpected internal error under -e kills the hook before
# it can emit a decision, and a PreToolUse hook that emits nothing is an
# allow; a guard fails closed by structure, never open by accident
# (2026-09-16 audit P2-8; convention documented in enforce/README.md).
set -uo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

case "$CMD" in *commit*) ;; *) exit 0 ;; esac

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

# Find the commit the way the shell would run it, through the quote-aware scan
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
scan_command_tokens "$CMD"
find_simple_command "$PWD" is_git_commit_command || exit 0

# read_substituted_heredoc <word>: prints the body of a `$(cat <<'EOF' ...
# EOF)` substitution, the form a multi-line -m message usually takes; prints
# nothing for any other substitution, whose value the scan never computes.
read_substituted_heredoc() {
  printf '%s' "$1" | perl -0777 -ne '
    if (/\A\$\(\s*cat\s*<<-?\s*['\''"]?([A-Za-z_][A-Za-z0-9_]*)['\''"]?[ \t]*\n(.*?)\n[ \t]*\1[ \t]*\n?\s*\)\s*\z/s) { print $2; }
  '
}

# read_commit_message: sets MSG from the commit's own arguments: every -m
# (git joins several with a blank line), or the heredoc behind `-F -`. `-F
# <file>` keeps the message on disk rather than in the command, so it stays out
# of reach and out of this gate (2026-09-17 audit P2-7). The values of options
# that take one are skipped, so `--author "-m x"` is not a message.
read_commit_message() {
  local message
  local -a messages=()
  MSG=''
  set -- ${INVOCATION_ARGS[@]+"${INVOCATION_ARGS[@]}"}
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -m | --message) [ "$#" -ge 2 ] && messages+=("$2"); shift 2 2>/dev/null || shift ;;
      --message=*) messages+=("${1#--message=}"); shift ;;
      -m?*) messages+=("${1#-m}"); shift ;;
      -F | --file) [ "${2:-}" = "-" ] && MSG="$INVOCATION_STDIN"; shift 2 2>/dev/null || shift ;;
      -F- | --file=-) MSG="$INVOCATION_STDIN"; shift ;;
      -C | -c | -t | --author | --date | --template | --fixup | --squash | --cleanup | --trailer | --reuse-message | --reedit-message | --pathspec-from-file)
        shift 2 2>/dev/null || shift ;;
      --) break ;;
      *) shift ;;
    esac
  done
  [ "${#messages[@]}" -gt 0 ] || return 0
  MSG=''
  for message in "${messages[@]}"; do
    # shellcheck disable=SC2016  # the literal `$(` of a substitution, not an expansion
    case "$message" in
      *'$('* | *'`'*) message=$(read_substituted_heredoc "$message"); [ -n "$message" ] || { MSG=''; return 0; } ;;
    esac
    MSG="${MSG:+$MSG$'\n\n'}$message"
  done
}

read_commit_message
[ -z "$MSG" ] && exit 0

SUBJECT=$(printf '%s\n' "$MSG" | head -1)

if ! grep -qE '^(feat|fix|chore|docs|refactor|test|perf|style|build|ci|revert)(\([^)]*\))?!?: .+' <<< "$SUBJECT"; then
  deny "commit-message-guard BLOCKED this commit (R-505): subject '$SUBJECT' is not in conventional form 'type(scope): summary'. Types: feat|fix|chore|docs|refactor|test|perf|style|build|ci|revert."
fi

SCOPE=$(printf '%s' "$SUBJECT" | sed -nE 's/^[a-z]+\(([^)]*)\).*/\1/p')
if [ -n "$SCOPE" ]; then
  COMMAS=$(printf '%s' "$SCOPE" | tr -cd ',' | wc -c | tr -d ' ')
  if [ "$COMMAS" -gt 1 ]; then
    deny "commit-message-guard BLOCKED this commit (R-505): scope '($SCOPE)' carries more than two triage IDs. One commit per triage ID; two IDs max when inseparable."
  fi
fi

BODY_LINES=$(printf '%s\n' "$MSG" | tail -n +2 \
  | grep -v '^[[:space:]]*$' \
  | grep -vE '^(Co-Authored-By|Signed-off-by|Reviewed-by|Refs):' \
  | grep -cv "Generated with" || true)
if [ "${BODY_LINES:-0}" -gt 3 ]; then
  ask "commit-message-guard (R-506): the body has $BODY_LINES non-trailer lines; the norm is a one-sentence body, with multi-line reserved for business-logic bugs, architectural refactors, and security changes. Confirm to proceed if this commit qualifies."
fi

exit 0
