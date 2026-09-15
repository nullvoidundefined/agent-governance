#!/usr/bin/env bash
# settings-change-guard.sh: ConfigChange hook (R-516, R-203). When
# ~/.claude/settings.json changes mid-session, refuse to apply a version that
# no longer registers a hook the manifest requires, or that does not parse.
# The required set is derived the same way enforcement-guard-check.sh derives
# it; that guard runs at SessionStart only, so a mid-session edit (a typo, a
# tool call, a tampering write) was never seen until the next start
# (2026-09-04 config audit P3-3; 2026-07-31 criticism P2 "a typo silently
# drops a hook registration").
#
# Blocks with decision:"block", which keeps the running session on the
# configuration it already has. Claude Code shows a ConfigChange block to
# nobody (documented), so the reason also goes to stderr for the debug log and
# the fire is logged for the session-end rollup. Silent for every other
# source: project and local settings carry no hook registrations this guard
# owns, and policy settings cannot be blocked.
#
# Manual test:
#   jq -n '{hook_event_name:"ConfigChange",source:"user_settings",file_path:"'"$HOME"'/.claude/settings.json"}' | ~/.claude/hooks/settings-change-guard.sh
# Should print nothing while every manifest-required hook stays registered.
set -euo pipefail

INPUT=$(cat 2>/dev/null || true)
SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // ""' 2>/dev/null || true)
[ "$SOURCE" = "user_settings" ] || exit 0

FILE=$(printf '%s' "$INPUT" | jq -r '.file_path // ""' 2>/dev/null || true)
[ -n "$FILE" ] || FILE="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
MANIFEST="${CLAUDE_MANIFEST_FILE:-$HOME/.claude/enforce/manifest.json}"
[ -f "$MANIFEST" ] || exit 0

block() {
  source "$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh" 2>/dev/null || true
  type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
  log_rule_fire "R-516" "settings-change-guard" "block"
  echo "settings-change-guard: $1" >&2
  jq -n --arg r "$1" '{decision: "block", reason: $r}'
  exit 0
}

[ -f "$FILE" ] || block "settings file $FILE is missing; keeping the running configuration (R-203)."
jq -e . "$FILE" >/dev/null 2>&1 || block "settings file $FILE does not parse; keeping the running configuration (R-203)."

REQUIRED=$(jq -r '.rules[].enforcer' "$MANIFEST" | awk '
  /^hook:/     { sub(/^hook:/,""); print $0 ".sh" }
  /^eslint:/   { print "push-eslint-gate.sh" }
  /^ruff:/     { print "push-ruff-gate.sh" }
  /^rubocop:/  { print "push-rubocop-gate.sh" }
  /^golangci:/ { print "push-golangci-gate.sh" }
' | sort -u)
REGISTERED=$(jq -r '[.. | .command? // empty] | .[]' "$FILE" | sed 's#.*/##' | sort -u)
MISSING=$(comm -23 <(printf '%s\n' "$REQUIRED") <(printf '%s\n' "$REGISTERED") | tr '\n' ' ')
[ -z "$MISSING" ] || block "the new settings.json drops manifest-required hook(s): ${MISSING}(R-516). Restore the registration, or remove the manifest row first, and save again."

exit 0
