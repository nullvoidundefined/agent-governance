#!/usr/bin/env bash
# enforcement-guard-check.sh: at session start, verify both directions of the
# enforcement mapping. Forward: every hook the manifest requires is registered
# in settings.json. Reverse (P2-1): every hook:/eslint: enforcer cited in a
# rule-file Enforcement line has a manifest entry, so coverage drift is
# self-detecting rather than audit-detected. Warns (never blocks). Mirrors
# redaction-guard-check.sh. Required hooks are derived from the manifest: each
# "hook:<name>" enforcer, plus the matching push gate whenever any "eslint:*",
# "ruff:*", "rubocop:*", or "golangci:*" rule exists.
set -euo pipefail
cat >/dev/null 2>&1 || true   # drain stdin

MANIFEST="${CLAUDE_MANIFEST_FILE:-$HOME/.claude/enforce/manifest.json}"
SETTINGS="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
[ -f "$MANIFEST" ] && [ -f "$SETTINGS" ] || exit 0

REQUIRED=$(jq -r '.rules[].enforcer' "$MANIFEST" | awk '
  /^hook:/     { sub(/^hook:/,""); print $0 ".sh" }
  /^eslint:/   { print "push-eslint-gate.sh" }
  /^ruff:/     { print "push-ruff-gate.sh" }
  /^rubocop:/  { print "push-rubocop-gate.sh" }
  /^golangci:/ { print "push-golangci-gate.sh" }
' | sort -u)

REGISTERED=$(jq -r '[.. | .command? // empty] | .[]' "$SETTINGS" | sed 's#.*/##' | sort -u)

MISSING=""
while IFS= read -r h; do
  [ -z "$h" ] && continue
  printf '%s\n' "$REGISTERED" | grep -qx "$h" || MISSING="$MISSING $h"
done <<< "$REQUIRED"

RULE_FILES="${CLAUDE_RULES_FILES:-$HOME/.claude/rulebook/reference.md $HOME/.claude/rulebook/agents.md $HOME/.claude/rulebook/audits.md $HOME/.claude/rulebook/cost.md}"
CITED=$(cat $RULE_FILES 2>/dev/null | grep -E '^  Enforcement:' | grep -oE '(hook|eslint|ruff|rubocop|golangci):[A-Za-z0-9_/-]+' | sort -u || true)
ENFORCERS=$(jq -r '.rules[].enforcer' "$MANIFEST" | sort -u)

UNMAPPED=""
while IFS= read -r cited_enforcer; do
  [ -z "$cited_enforcer" ] && continue
  printf '%s\n' "$ENFORCERS" | grep -qxF "$cited_enforcer" || UNMAPPED="$UNMAPPED $cited_enforcer"
done <<< "$CITED"

WARNING=""
[ -n "$MISSING" ] && WARNING="These manifest-required hooks are NOT registered in settings.json:$MISSING."
[ -n "$UNMAPPED" ] && WARNING="$WARNING These rule-cited enforcers have NO manifest entry (R-516):$UNMAPPED."

# Judge-tier liveness (2026-07-31 criticism audit P0: the judge exited
# silently for want of a key for its entire life, leaving its error-severity
# rules honor-system with green stub tests concealing it). Warn whenever
# llm-judge rules exist but the hook environment carries no way to run them.
JUDGE_RULES=$(jq -r '[.rules[] | select(.tier=="llm-judge")] | length' "$MANIFEST" 2>/dev/null || echo 0)
JUDGE_ACCEPT_FILE="${CLAUDE_JUDGE_ACCEPT_FILE:-$HOME/.claude/enforce/judge-accepted-honor-system}"
JUDGE_KEYCHAIN_SERVICE="${CLAUDE_JUDGE_KEYCHAIN_SERVICE:-claude-judge-api-key}"
JUDGE_KEY_AVAILABLE=0
{ [ -n "${ANTHROPIC_API_KEY:-}" ] || security find-generic-password -s "$JUDGE_KEYCHAIN_SERVICE" >/dev/null 2>&1; } && JUDGE_KEY_AVAILABLE=1
if [ "${JUDGE_RULES:-0}" -gt 0 ] && [ "$JUDGE_KEY_AVAILABLE" -eq 0 ] && [ -z "${CLAUDE_JUDGE_CMD:-}" ] && [ ! -f "$JUDGE_ACCEPT_FILE" ]; then
  WARNING="$WARNING The llm-judge tier ($JUDGE_RULES manifest rules, including error-severity naming rules) CANNOT run: no ANTHROPIC_API_KEY in the hook environment and no keychain entry ($JUDGE_KEYCHAIN_SERVICE), so llm-rule-judge.sh fail-opens on every push. Provision it interactively with: security add-generic-password -a \"\$USER\" -s $JUDGE_KEYCHAIN_SERVICE -w   (egress disclosure in README Enforcement), or touch enforce/judge-accepted-honor-system to record the deliberate choice and silence this warning."
fi

if [ -n "$WARNING" ]; then
  jq -n --arg m "Rule-enforcement guard: $WARNING Enforcement is degraded until the mapping is repaired." \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$m}}'
fi
exit 0
