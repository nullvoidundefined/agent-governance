#!/usr/bin/env bash
# commit-message-guard.sh: PreToolUse gate on `git commit -m` messages.
# Denies a non-conventional subject or more than two triage IDs in the scope
# (R-505); asks on a body longer than three non-trailer lines (R-506, whose
# multi-line exemption is a user judgment). Unparseable commands fail open.
set -euo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

printf '%s' "$CMD" | grep -Eq '(^|[;&|[:space:]])git[[:space:]]+commit' || exit 0
printf '%s' "$CMD" | grep -qE '(^|[[:space:]])-m([[:space:]]|$)' || exit 0

deny() {
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}
ask() {
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
  exit 0
}

# Extract the first -m argument. Handles "..."/'...' spanning newlines and the
# heredoc form -m "$(cat <<'EOF' ... EOF)". Anything else fails open.
if printf '%s' "$CMD" | grep -q "<<'EOF'"; then
  MSG=$(printf '%s\n' "$CMD" | sed -n "/<<'EOF'/,/^EOF/p" | sed '1d;$d')
else
  MSG=$(printf '%s' "$CMD" | awk '
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
