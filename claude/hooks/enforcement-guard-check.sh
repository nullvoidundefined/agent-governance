#!/usr/bin/env bash
# enforcement-guard-check.sh: at session start, verify both directions of the
# enforcement mapping. Forward: every hook the manifest requires is registered
# in settings.json. Reverse (P2-1): every hook:/eslint: enforcer cited in a
# rule-file Enforcement line has a manifest entry, so coverage drift is
# self-detecting rather than audit-detected. Warns (never blocks). Mirrors
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

RULE_FILES="${CLAUDE_RULES_FILES:-$HOME/.claude/CLAUDE.md $HOME/.claude/rules/agents.md $HOME/.claude/rules/audits.md $HOME/.claude/rules/cost.md}"
CITED=$(cat $RULE_FILES 2>/dev/null | grep -E '^  Enforcement:' | grep -oE '(hook|eslint):[A-Za-z0-9_-]+' | sort -u || true)
ENFORCERS=$(jq -r '.rules[].enforcer' "$MANIFEST" | sort -u)

UNMAPPED=""
while IFS= read -r cited_enforcer; do
  [ -z "$cited_enforcer" ] && continue
  printf '%s\n' "$ENFORCERS" | grep -qxF "$cited_enforcer" || UNMAPPED="$UNMAPPED $cited_enforcer"
done <<< "$CITED"

WARNING=""
[ -n "$MISSING" ] && WARNING="These manifest-required hooks are NOT registered in settings.json:$MISSING."
[ -n "$UNMAPPED" ] && WARNING="$WARNING These rule-cited enforcers have NO manifest entry (R-516):$UNMAPPED."

if [ -n "$WARNING" ]; then
  jq -n --arg m "Rule-enforcement guard: $WARNING Enforcement is degraded until the mapping is repaired." \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$m}}'
fi
exit 0
