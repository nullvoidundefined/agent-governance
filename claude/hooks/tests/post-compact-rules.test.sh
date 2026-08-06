#!/usr/bin/env bash
# Verifies the compaction rule-injection pair (2026-08-06). PreCompact cannot
# inject context: its hookSpecificOutput has no schema variant, so an object
# carrying additionalContext is rejected whole and the rules are silently lost.
# pre-compact.sh therefore emits nothing and only sets a sentinel;
# post-compact-rules.sh emits the rules once, on the next UserPromptSubmit.
set -euo pipefail
PRE="$HOME/.claude/hooks/pre-compact.sh"
POST="$HOME/.claude/hooks/post-compact-rules.sh"
SENTINEL="$HOME/.claude/.post-compact-pending"

SAVED=""
if [ -f "$SENTINEL" ]; then SAVED=$(mktemp); cp "$SENTINEL" "$SAVED"; fi
restore() {
  rm -f "$SENTINEL"
  if [ -n "$SAVED" ]; then cp "$SAVED" "$SENTINEL"; rm -f "$SAVED"; fi
}
trap restore EXIT

# pre-compact.sh must emit NOTHING. Any payload is rejected by the validator,
# which is the defect this pair replaced.
rm -f "$SENTINEL"
OUT=$(echo '{}' | "$PRE")
[ -z "$OUT" ] || { echo "FAIL: pre-compact.sh emitted output; PreCompact accepts none"; exit 1; }
[ -f "$SENTINEL" ] || { echo "FAIL: pre-compact.sh did not set the sentinel"; exit 1; }

# With the sentinel set, the rules are emitted as valid UserPromptSubmit JSON.
OUT=$(echo '{}' | "$POST")
printf '%s' "$OUT" | jq -e . >/dev/null || { echo "FAIL: post-compact-rules.sh emitted invalid JSON"; exit 1; }
EVENT=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName')
[ "$EVENT" = "UserPromptSubmit" ] || { echo "FAIL: hookEventName is '$EVENT', not UserPromptSubmit"; exit 1; }
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext')
printf '%s' "$CTX" | grep -q 'R-504' || { echo "FAIL: rules missing from additionalContext"; exit 1; }

# The event name must never regress to PreCompact, the rejected form.
printf '%s' "$OUT" | grep -q 'PreCompact' && { echo "FAIL: emits the rejected PreCompact event name"; exit 1; } || true

# The sentinel is consumed: a second prompt must stay silent, or the rules
# would be re-injected on every turn for the rest of the session.
[ -f "$SENTINEL" ] && { echo "FAIL: sentinel not cleared after injection"; exit 1; } || true
OUT2=$(echo '{}' | "$POST")
[ -z "$OUT2" ] || { echo "FAIL: emitted rules with no compaction pending"; exit 1; }

echo "post-compact-rules.test.sh PASS"
