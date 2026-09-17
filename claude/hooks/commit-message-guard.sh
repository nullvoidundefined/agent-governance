#!/usr/bin/env bash
# commit-message-guard.sh: PreToolUse gate on `git commit -m` messages.
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

printf '%s' "$CMD" | grep -Eq '(^|[;&|[:space:]])git[[:space:]]+commit' || exit 0
# Either message-bearing form: `-m` or `-F -` fed by a heredoc. `-F <file>`
# keeps the message on disk rather than in the command, so it stays out of
# reach and out of this gate (2026-09-17 audit P2-7).
printf '%s' "$CMD" | grep -qE '(^|[[:space:]])(-m|-F[[:space:]]+-)([[:space:]]|$)' || exit 0

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

# Narrow the command to the `git commit` invocation before reading a message
# out of it. Everything before the `git commit` token belongs to some other
# command in the same Bash call (a `git add`, a python or jq heredoc payload),
# and reading a message out of that text is how the guard came to deny its own
# well-formed commit over a line of someone else's heredoc body (2026-09-17,
# reported on PR #8). An empty tail means no `git commit` token survived the
# earlier grep, which fails open exactly as an unparseable command does.
COMMIT_TAIL=$(printf '%s' "$CMD" | perl -0777 -ne 'if (/(git\s+commit\b.*)/s) { print $1; }')
[ -z "$COMMIT_TAIL" ] && exit 0

# Extract the first -m argument. Handles "..."/'...' spanning newlines and the
# heredoc form -m "$(cat <<'EOF' ... EOF)". Anything else fails open.
# Any heredoc delimiter word, not the literal EOF alone: `<<MSG` and `<<'ANY'`
# fell through to the -m extractor and out, which is how every heredoc commit
# in this repo escaped both R-505 and R-506 (audit P2-7). The delimiter search
# runs from the `git commit` token to the first command separator, so a heredoc
# opened by a later command on the same line (`git commit -m "..." && cat >
# file <<EOF`) is not mistaken for this commit's message, and the closing
# delimiter ends the message at its own line so further commands may follow it.
if printf '%s' "$COMMIT_TAIL" | perl -0777 -ne 'exit(/\Agit\s+commit\b[^\n;&|]*<<-?\s*['\''"]?[A-Za-z_][A-Za-z0-9_]*/ms ? 0 : 1)'; then
  MSG=$(printf '%s' "$COMMIT_TAIL" | perl -0777 -ne '
    if (/\Agit\s+commit\b[^\n;&|]*?<<-?\s*['\''"]?([A-Za-z_][A-Za-z0-9_]*)['\''"]?[ \t]*\n(.*?)\n[ \t]*\1[ \t]*(?:\)|"|$)/ms) { print $2; }
  ')
else
  MSG=$(printf '%s' "$COMMIT_TAIL" | awk '
    BEGIN { RS = "\x01" }
    {
      s = $0
      i = match(s, /(^|[[:space:]])-m[[:space:]]*/)
      if (i == 0) exit
      rest = substr(s, i + RLENGTH)
      q = substr(rest, 1, 1)
      if (q == "\"" || q == "\x27") {
        rest = substr(rest, 2)
        j = index(rest, q)
        if (j > 0) { print substr(rest, 1, j - 1) } else { print rest }
      } else {
        j = match(rest, /[[:space:]]/)
        if (j > 0) { print substr(rest, 1, j - 1) } else { print rest }
      }
    }')
fi
[ -z "$MSG" ] && exit 0

SUBJECT=$(printf '%s\n' "$MSG" | head -1)

if ! printf '%s' "$SUBJECT" | grep -qE '^(feat|fix|chore|docs|refactor|test|perf|style|build|ci|revert)(\([^)]*\))?!?: .+'; then
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
