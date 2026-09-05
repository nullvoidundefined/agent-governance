#!/usr/bin/env bash
# llm-rule-judge.sh: on git push, ask a fast model to judge the outgoing diff
# against the semantic-tier rules in the manifest (those a linter cannot express).
# ASK (2026-09-05, human-in-the-loop) on a violation whose rule has severity
# "error" in the manifest AND confidence >= threshold: the human adjudicates a
# naming finding at push time instead of the model losing the push to a judge. Warn-severity rule violations are printed to stderr
# but do not block the push. Fails OPEN (allows the push, logs to stderr) if the
# key is unset or the judge errors / returns unparseable output: the deterministic
# gates remain the hard guarantee, and a flaky model must not block legitimate work.
set -euo pipefail

# shellcheck source=../enforce/resolveOutgoingBase.sh
source "$HOME/.claude/enforce/resolveOutgoingBase.sh"

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
printf '%s' "$CMD" | grep -Eq '(^|[;&|[:space:]])git[[:space:]]+push' || exit 0

# EGRESS NOTE (2026-07-31 security audit P1): when live, this hook sends the
# outgoing diff to api.anthropic.com under ANTHROPIC_API_KEY. Repos listed in
# exempt-repos.txt are excluded, same as the linter gates; the judge previously
# carried no exemption at all. Disclosure lives in README.md (Enforcement).
EXEMPT_FILE="$HOME/.claude/enforce/exempt-repos.txt"
if [ -f "$EXEMPT_FILE" ]; then
  ORIGIN_URL=$(git remote get-url origin 2>/dev/null || true)
  if [ -n "$ORIGIN_URL" ] && grep -qxF "$ORIGIN_URL" "$EXEMPT_FILE"; then
    exit 0
  fi
fi

BASE=$(resolve_outgoing_base)
[ -z "$BASE" ] && exit 0

DIFF=$(git diff --diff-filter=ACMR "$BASE"..HEAD -- '*.ts' '*.tsx' '*.py' '*.rb' '*.go' 2>/dev/null || true)
[ -z "$DIFF" ] && exit 0

THRESH=0.8
MANIFEST="${CLAUDE_MANIFEST_FILE:-$HOME/.claude/enforce/manifest.json}"

if [ -n "${CLAUDE_JUDGE_CMD:-}" ]; then
  RESP=$("$CLAUDE_JUDGE_CMD")
else
  # Key resolution: env first, then the macOS keychain (2026-08-01, judge
  # activation). The keychain keeps the key out of dotfiles, transcripts, and
  # hook argv (R-102); provision once, interactively so the value never
  # touches a shell history or session:
  #   security add-generic-password -a "$USER" -s claude-judge-api-key -w
  JUDGE_KEYCHAIN_SERVICE="${CLAUDE_JUDGE_KEYCHAIN_SERVICE:-claude-judge-api-key}"
  if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    ANTHROPIC_API_KEY=$(security find-generic-password -s "$JUDGE_KEYCHAIN_SERVICE" -w 2>/dev/null || true)
  fi
  if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "llm-rule-judge: no API key in env or keychain ($JUDGE_KEYCHAIN_SERVICE), skipping semantic gate" >&2
    exit 0
  fi
  RULE_IDS=$(jq -r '.rules[] | select(.tier=="llm-judge") | .id' "$MANIFEST")
  # Full rule blocks (norm + Spec) from the reference file; CLAUDE.md carries
  # only one-line norms since the 2026-07-29 restructure.
  RULETEXT=$(for r in $RULE_IDS; do
    awk -v id="$r" '
      index($0, id ": ") == 1 || index($0, id " [") == 1 { p = 1; print; next }
      p && (/^R-[0-9]/ || /^## /) { exit }
      p { print }
    ' "$HOME/.claude/rulebook/reference.md" || true
  done)
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
  # A rule id can carry several manifest rows across tiers (R-324/R-329 have
  # eslint+ruff+golangci entries); take the llm-judge row's severity, falling
  # back to the strictest row for the id (2026-07-31 criticism audit P1: the
  # unfiltered multi-line result never equaled "error", silently downgrading
  # every judged rule to warn).
  severity=$(jq -r --arg id "$rule_id" '
    [.rules[] | select(.id==$id)] as $rows
    | ([$rows[] | select(.tier=="llm-judge")] | first // ($rows | first))
    | .severity // "error"' "$MANIFEST" 2>/dev/null || echo "error")
  [ -z "$severity" ] && severity="error"
  if [ "$severity" = "error" ]; then
    DENY_HITS=$(printf '%s\n%s' "$DENY_HITS" "$violation" | jq -cs '.[0] + [.[1:][]]' 2>/dev/null || echo "$DENY_HITS")
  else
    why=$(printf '%s' "$violation" | jq -r '"[warn] \(.rule) [\(.file)]: \(.why)"')
    echo "llm-rule-judge: $why" >&2
  fi
done < <(printf '%s' "$ALL_HITS" | jq -c '.[]?' 2>/dev/null || true)

COUNT=$(printf '%s' "$DENY_HITS" | jq 'length' 2>/dev/null || echo 0)
if [ "${COUNT:-0}" -gt 0 ]; then
  source "$(dirname "${BASH_SOURCE[0]}")/log-rule-fire.sh" 2>/dev/null || true
  type log_rule_fire >/dev/null 2>&1 || log_rule_fire() { :; }
  while IFS= read -r fired_rule; do
    [ -n "$fired_rule" ] && log_rule_fire "$fired_rule" "llm-rule-judge" "ask"
  done < <(printf '%s' "$DENY_HITS" | jq -r '.[].rule' 2>/dev/null || true)
  REASON=$(printf '%s' "$DENY_HITS" | jq -r '.[] | "\(.rule) [\(.file)]: \(.why)"')
  jq -n --arg r "Rule-judge findings on the outgoing diff (confidence >= $THRESH); approve the push only if each is a false positive:
$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
fi
exit 0
