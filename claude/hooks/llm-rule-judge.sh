#!/usr/bin/env bash
# llm-rule-judge.sh: on git push, ask a fast model to judge the outgoing diff
# against the semantic-tier rules in the manifest (those a linter cannot express).
# Deny the push ONLY on a violation whose rule has severity "error" in the manifest
# AND confidence >= threshold. Warn-severity rule violations are printed to stderr
# but do not block the push. Fails OPEN (allows the push, logs to stderr) if the
# key is unset or the judge errors / returns unparseable output: the deterministic
# gates remain the hard guarantee, and a flaky model must not block legitimate work.
set -euo pipefail

# shellcheck source=../enforce/resolveOutgoingBase.sh
source "$HOME/.claude/enforce/resolveOutgoingBase.sh"

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
printf '%s' "$CMD" | grep -Eq '(^|[;&|[:space:]])git[[:space:]]+push' || exit 0

BASE=$(resolve_outgoing_base)
[ -z "$BASE" ] && exit 0

DIFF=$(git diff --diff-filter=ACMR "$BASE"..HEAD -- '*.ts' '*.tsx' 2>/dev/null || true)
[ -z "$DIFF" ] && exit 0

THRESH=0.8
MANIFEST="${CLAUDE_MANIFEST_FILE:-$HOME/.claude/enforce/manifest.json}"

if [ -n "${CLAUDE_JUDGE_CMD:-}" ]; then
  RESP=$("$CLAUDE_JUDGE_CMD")
else
  if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "llm-rule-judge: ANTHROPIC_API_KEY unset, skipping semantic gate" >&2
    exit 0
  fi
  RULE_IDS=$(jq -r '.rules[] | select(.tier=="llm-judge") | .id' "$MANIFEST")
  RULETEXT=$(for r in $RULE_IDS; do grep -m1 -E "^$r([: ])" "$HOME/.claude/CLAUDE.md" || true; done)
  SYS=$(cat "$HOME/.claude/enforce/judge-prompt.md")
  USERMSG=$(jq -n --arg rt "$RULETEXT" --arg d "$DIFF" '{rules:$rt, diff:$d} | tostring')
  BODY=$(jq -n --arg s "$SYS" --arg u "$USERMSG" '{model:"claude-haiku-4-5-20251001",max_tokens:1024,temperature:0,system:$s,messages:[{role:"user",content:$u}]}')
  RAW=$(curl -sS https://api.anthropic.com/v1/messages \
    -H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
    -d "$BODY" 2>/dev/null || true)
  TEXT=$(printf '%s' "$RAW" | jq -r '.content[0].text // ""' 2>/dev/null || true)
  # Extract the first balanced-brace JSON object; Haiku may append trailing prose after the
  # closing fence, which would survive a simple sed strip and break jq.
  RESP=$(printf '%s' "$TEXT" | awk '
    BEGIN { depth=0; buf=""; capturing=0 }
    {
      n = split($0, chars, "")
      for (i = 1; i <= n; i++) {
        c = chars[i]
        if (!capturing && c == "{") { capturing = 1 }
        if (capturing) {
          buf = buf c
          if (c == "{") depth++
          else if (c == "}") { depth--; if (depth == 0) { print buf; exit } }
        }
      }
      if (capturing) buf = buf "\n"
    }
  ')
fi

# Partition violations: those with confidence >= threshold get checked against manifest severity.
# Only "error"-severity rules produce a deny; "warn"-severity rules print to stderr.
ALL_HITS=$(printf '%s' "$RESP" | jq -c --argjson t "$THRESH" '[.violations[]? | select(.confidence >= $t)]' 2>/dev/null || echo '[]')

DENY_HITS='[]'
while IFS= read -r violation; do
  rule_id=$(printf '%s' "$violation" | jq -r '.rule // ""')
  severity=$(jq -r --arg id "$rule_id" '.rules[] | select(.id==$id) | .severity // "error"' "$MANIFEST" 2>/dev/null || echo "error")
  if [ "$severity" = "error" ]; then
    DENY_HITS=$(printf '%s\n%s' "$DENY_HITS" "$violation" | jq -cs '.[0] + [.[1:][]]' 2>/dev/null || echo "$DENY_HITS")
  else
    why=$(printf '%s' "$violation" | jq -r '"[warn] \(.rule) [\(.file)]: \(.why)"')
    echo "llm-rule-judge: $why" >&2
  fi
done < <(printf '%s' "$ALL_HITS" | jq -c '.[]?' 2>/dev/null || true)

COUNT=$(printf '%s' "$DENY_HITS" | jq 'length' 2>/dev/null || echo 0)
if [ "${COUNT:-0}" -gt 0 ]; then
  REASON=$(printf '%s' "$DENY_HITS" | jq -r '.[] | "\(.rule) [\(.file)]: \(.why)"')
  jq -n --arg r "Rule-judge blocked the push (confidence >= $THRESH):
$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
fi
exit 0
