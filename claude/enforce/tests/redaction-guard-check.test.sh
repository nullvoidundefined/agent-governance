#!/usr/bin/env bash
# Verifies redaction-guard-check.sh warns when a secret-handling hook is missing
# from settings and stays silent when both are registered (R-102). Uses the
# REDACTION_GUARD_SETTINGS override with throwaway settings files.
set -euo pipefail
HOOK="$HOME/.claude/hooks/redaction-guard-check.sh"
TMP=$(mktemp -d)

cat > "$TMP/missing.json" <<'EOF'
{ "hooks": { "PreToolUse": [], "PostToolUse": [] } }
EOF
OUT=$(echo '{}' | REDACTION_GUARD_SETTINGS="$TMP/missing.json" "$HOOK")
printf '%s' "$OUT" | jq -e '.systemMessage' >/dev/null || { echo "FAIL: expected warning for missing hooks"; exit 1; }
printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext' | grep -q 'secret-scan.sh (PreToolUse) is NOT registered' || { echo "FAIL: expected secret-scan gap named"; exit 1; }

cat > "$TMP/complete.json" <<'EOF'
{ "hooks": {
    "PreToolUse":  [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "~/.claude/hooks/secret-scan.sh" } ] } ],
    "PostToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "~/.claude/hooks/redact-output.sh" } ] } ]
} }
EOF
OUT=$(echo '{}' | REDACTION_GUARD_SETTINGS="$TMP/complete.json" "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: expected silence when both hooks registered"; exit 1; }

rm -rf "$TMP"
echo "redaction-guard-check.test.sh PASS"
