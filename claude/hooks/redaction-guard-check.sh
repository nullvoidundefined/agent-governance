#!/usr/bin/env bash
# redaction-guard-check.sh
#
# SessionStart hook. Enforces R-102: the secret-handling hooks must be active.
# Without secret-scan.sh (PreToolUse) a session loses the pre-execution block,
# which is the half that actually prevents a secret from reaching argv, a file,
# or the transcript. Without redact-output.sh (PostToolUse) it loses the
# exposure warning: raw tool output reaches the transcript in either case,
# because a PostToolUse hook cannot rewrite or remove a result, but with the
# hook registered the model is at least told that a credential leaked and that
# it needs rotating. Both failures are silent by nature, so this hook makes a
# missing one LOUD. It WARNS via additionalContext plus a systemMessage; it
# never blocks. The session continues either way.
#
# Silent when both hooks are registered in ~/.claude/settings.json and present
# on disk.
#
# Limitation: cannot detect `disableAllHooks` (that would also disable this
# checker). It also only inspects the user settings file, where these hooks
# live; it does not resolve project/managed merges.
#
# Stdin JSON is the SessionStart payload (unused). Output, on a gap, is
# { systemMessage, hookSpecificOutput: { hookEventName: "SessionStart", additionalContext } }.

set -euo pipefail

cat >/dev/null

SETTINGS="${REDACTION_GUARD_SETTINGS:-$HOME/.claude/settings.json}"
[ -f "$SETTINGS" ] || exit 0

missing=""

if ! jq -e '[.hooks.PreToolUse[]?.hooks[]?.command // empty] | any(test("secret-scan\\.sh"))' "$SETTINGS" >/dev/null 2>&1; then
  missing+="- secret-scan.sh (PreToolUse) is NOT registered"$'\n'
fi

if ! jq -e '[.hooks.PostToolUse[]?.hooks[]?.command // empty] | any(test("redact-output\\.sh"))' "$SETTINGS" >/dev/null 2>&1; then
  missing+="- redact-output.sh (PostToolUse) is NOT registered"$'\n'
fi

for s in secret-scan.sh redact-output.sh; do
  [ -f "$HOME/.claude/hooks/$s" ] || missing+="- ~/.claude/hooks/$s is MISSING on disk"$'\n'
done

[ -n "$missing" ] || exit 0

CTX="## Secret-redaction guard (R-102)"$'\n\n'
CTX+="The secret-handling hooks are not all active this session. Without secret-scan.sh nothing blocks a command or a write that carries a credential; without redact-output.sh nothing tells you when one has already reached the output and the transcript:"$'\n\n'
CTX+="$missing"$'\n'
CTX+="Do not run commands that could print secrets until this is fixed. Restore the missing hook(s) in ~/.claude/settings.json, confirm the script exists in ~/.claude/hooks/, then reload via /hooks or restart."

jq -n --arg ctx "$CTX" '{
  systemMessage: "Secret-handling hook(s) not active this session (R-102); a leaked credential may go unblocked and unreported.",
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $ctx
  }
}'

exit 0
