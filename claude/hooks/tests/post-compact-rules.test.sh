#!/usr/bin/env bash
# Verifies post-compact-rules.sh, the SessionStart(compact) re-injection
# (2026-09-04). Four invariants:
#   1. A compact-sourced SessionStart emits the rules as valid SessionStart JSON.
#   2. Any other source stays silent, so the hook cannot flood a startup.
#   3. settings.json registers it under a "compact" matcher and nothing remains
#      on PreCompact or UserPromptSubmit (the retired sentinel pair).
#   4. The sentinel pair is gone: no pre-compact.sh, no sentinel file written.
set -euo pipefail
HOOK="$HOME/.claude/hooks/post-compact-rules.sh"
SETTINGS="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
SENTINEL="$HOME/.claude/.post-compact-pending"

# 1. Compact source emits the rules.
OUT=$(echo '{"hook_event_name":"SessionStart","source":"compact"}' | "$HOOK")
printf '%s' "$OUT" | jq -e . >/dev/null || { echo "FAIL: emitted invalid JSON"; exit 1; }
EVENT=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName')
[ "$EVENT" = "SessionStart" ] || { echo "FAIL: hookEventName is '$EVENT', not SessionStart"; exit 1; }
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext')
printf '%s' "$CTX" | grep -q 'R-504' || { echo "FAIL: rules missing from additionalContext"; exit 1; }
printf '%s' "$OUT" | grep -q 'PreCompact\|UserPromptSubmit' && { echo "FAIL: emits a retired event name"; exit 1; } || true

# 5. The task-start ledger (2026-09-17 skills audit S-8) is re-injected when
#    the working tree carries .claude/task-tier.json, and absent otherwise.
printf '%s' "$CTX" | grep -q 'Task ledger' && { echo "FAIL: ledger section emitted with no ledger on disk"; exit 1; } || true
LEDGER_REPO=$(mktemp -d)
git -C "$LEDGER_REPO" init -q
mkdir -p "$LEDGER_REPO/.claude"
printf '{"tier":"complex","reason":"touches auth across packages","branch":"feat/x","startedAt":1,"startedAtIso":"2026-09-17T00:00:00Z"}\n' > "$LEDGER_REPO/.claude/task-tier.json"
LEDGER_CTX=$(cd "$LEDGER_REPO" && echo '{"hook_event_name":"SessionStart","source":"compact"}' | "$HOOK" | jq -r '.hookSpecificOutput.additionalContext')
printf '%s' "$LEDGER_CTX" | grep -q 'Task ledger' || { echo "FAIL: ledger section missing when .claude/task-tier.json exists"; exit 1; }
printf '%s' "$LEDGER_CTX" | grep -q 'Tier: complex. Reason: touches auth across packages' || { echo "FAIL: ledger tier and reason not re-injected"; exit 1; }
rm -rf "$LEDGER_REPO"

# 2. Other sources stay silent.
for source in startup resume clear fork; do
  OUT=$(printf '{"hook_event_name":"SessionStart","source":"%s"}' "$source" | "$HOOK")
  [ -z "$OUT" ] || { echo "FAIL: emitted rules on source '$source'"; exit 1; }
done

# 3. Registration shape.
MATCHER=$(jq -r '.hooks.SessionStart[] | select(.hooks[].command | test("post-compact-rules")) | .matcher' "$SETTINGS")
[ "$MATCHER" = "compact" ] || { echo "FAIL: post-compact-rules.sh is registered under matcher '$MATCHER', not 'compact'"; exit 1; }
for retired in PreCompact UserPromptSubmit; do
  jq -e --arg e "$retired" '.hooks[$e] // empty' "$SETTINGS" >/dev/null && { echo "FAIL: settings.json still carries a $retired hook group"; exit 1; } || true
done

# 4. The sentinel pair is gone.
[ ! -e "$HOME/.claude/hooks/pre-compact.sh" ] || { echo "FAIL: pre-compact.sh still exists"; exit 1; }
[ ! -e "$SENTINEL" ] || { echo "FAIL: a sentinel file is present; nothing should write it now"; exit 1; }

echo "post-compact-rules.test.sh PASS"
