#!/usr/bin/env bash
# handoff-check.sh: PostToolUse(Write) reminder for R-602 (2026-09-17 skills
# audit, S-5). session-start.sh SHA-verifies a handoff only when the next
# session loads it, one session too late to fix a wrong SHA, and nothing
# checked the size cap or the section order at all. When the written file is
# docs/session-handoff/session-handoff.md this reminds, naming each miss:
#   - over 8 KB (R-602's cap);
#   - a missing or out-of-order section; the six, in order, are last commit,
#     production state, session metrics, what shipped, pending, next session
#     (matched case-insensitively against the "## " headings, so numbering
#     and wording around the keywords are free);
#   - no commit SHA in backticks, or one that does not resolve in the
#     repository the file lives in (session-start.sh applies the same test).
# Silent for every other path. Never blocks; any internal fault exits 0 so
# the hook can never break a Write. Advisory, so no `set -e` (enforce/README,
# hook set convention).
set -uo pipefail

INPUT=$(cat 2>/dev/null || true)
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || true)
case "$FILE" in */docs/session-handoff/session-handoff.md|docs/session-handoff/session-handoff.md) ;; *) exit 0 ;; esac
CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // ""' 2>/dev/null || true)
[ -n "$CONTENT" ] || exit 0

MAX_BYTES=8192
missing=()

bytes=$(printf '%s' "$CONTENT" | wc -c | tr -d ' ')
[ "$bytes" -le "$MAX_BYTES" ] || missing+=("it is $bytes bytes, over the 8 KB cap; cut detail, not sections")

HEADINGS=$(printf '%s\n' "$CONTENT" | grep -E '^## ' | tr '[:upper:]' '[:lower:]' || true)
EXPECTED=("last commit" "production state" "session metrics" "what shipped" "pending" "next session")
last_index=0
absent=()
disordered=()
for key in "${EXPECTED[@]}"; do
  index=$(printf '%s\n' "$HEADINGS" | grep -n -F "$key" | head -1 | cut -d: -f1 || true)
  if [ -z "$index" ]; then
    absent+=("$key")
  elif [ "$index" -lt "$last_index" ]; then
    disordered+=("$key")
  else
    last_index="$index"
  fi
done
[ "${#absent[@]}" -eq 0 ] || missing+=("no section for: $(IFS=', '; echo "${absent[*]}")")
[ "${#disordered[@]}" -eq 0 ] || missing+=("out of order: $(IFS=', '; echo "${disordered[*]}") (the fixed order is last commit, production state, session metrics, what shipped, pending, next session)")

SHA=$(printf '%s' "$CONTENT" | grep -oE '`[0-9a-f]{7,40}`' | head -1 | tr -d '`' || true)
if [ -z "$SHA" ]; then
  missing+=("no commit SHA in backticks under the last-commit section (session-start.sh verifies it before trusting the file)")
else
  DIR=$(dirname "$FILE")
  [ -d "$DIR" ] || DIR=.
  if ! git -C "$DIR" cat-file -e "${SHA}^{commit}" 2>/dev/null; then
    missing+=("the recorded SHA $SHA does not resolve in this repository; the next session will load the handoff as UNVERIFIED")
  fi
fi

[ "${#missing[@]}" -gt 0 ] || exit 0
MSG="Handoff $FILE does not meet R-602: $(IFS='; '; echo "${missing[*]}"). The section order and the cap are in rulebook/reference.md under R-602; hooks/session-metrics.sh prints the metrics block."
jq -n --arg m "$MSG" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}' 2>/dev/null || true
exit 0
