#!/usr/bin/env bash
# enforcement-guard-check.sh: at session start, verify every hook the manifest
# requires is registered in settings.json. Warns (never blocks) when one is
# missing, so the enforcement system cannot silently lose a gate. Mirrors
# redaction-guard-check.sh. Required hooks are derived from the manifest: each
# "hook:<name>" enforcer, plus push-eslint-gate whenever any "eslint:*" rule exists.
set -euo pipefail
cat >/dev/null 2>&1 || true   # drain stdin

MANIFEST="${CLAUDE_MANIFEST_FILE:-$HOME/.claude/enforce/manifest.json}"
SETTINGS="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
[ -f "$MANIFEST" ] && [ -f "$SETTINGS" ] || exit 0

REQUIRED=$(jq -r '.rules[].enforcer' "$MANIFEST" | awk '
  /^hook:/   { sub(/^hook:/,""); print $0 ".sh" }
  /^eslint:/ { print "push-eslint-gate.sh" }
' | sort -u)

REGISTERED=$(jq -r '[.. | .command? // empty] | .[]' "$SETTINGS" | sed 's#.*/##' | sort -u)

MISSING=""
while IFS= read -r h; do
  [ -z "$h" ] && continue
  printf '%s\n' "$REGISTERED" | grep -qx "$h" || MISSING="$MISSING $h"
done <<< "$REQUIRED"

if [ -n "$MISSING" ]; then
  jq -n --arg m "Rule-enforcement guard: these manifest-required hooks are NOT registered in settings.json:$MISSING. Enforcement is degraded until they are re-registered." \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$m}}'
fi
exit 0
