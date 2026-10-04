#!/usr/bin/env bash
# route.sh: decides which provider takes a step, and logs why (IAN-603, slice
# 04 PR 3, docs/slices/slice-04-quota-aware-routing.md). Routing changes who
# does a step, never whether it happens: the output is always a provider.
#
# Usage: route.sh <step> --risk <high|standard> [--author <claude|codex>] [--security]
# Prints the provider (claude, codex, or owner) on line 1 and a one-line
# reason on line 2, and appends one JSON line (ts, step, risk, author,
# security, ratios, provider, reason) to $ROUTING_LOG (default
# ~/.claude/routing-log.jsonl).
#
# Rules, in order:
#   - review is always the other provider from --author (cross-model).
#   - A pinned step (route-steps.json: security-review, high-risk implement,
#     merge) stays on its default whatever the quota says.
#   - A routable step moves off its default provider when that provider is
#     near exhaustion and the other is not, or when the default's pace ratio
#     is above 1.2 and the other's ratio is lower.
#   - With no usable quota report, every step keeps its role default and the
#     reason says "quota unavailable".
# Pace data comes from quota-pace.sh report --json (CLAUDE_QUOTA_FILE,
# QUOTA_NOW). Exit codes: 0 routed; 2 a usage error, which logs nothing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEPS_FILE="$HERE/route-steps.json"
PACE="$HERE/quota-pace.sh"
SHIFT_ABOVE="1.2"

usage_error() {
  echo "route: $1" >&2
  echo "usage: route.sh <step> --risk <high|standard> [--author <claude|codex>] [--security]" >&2
  exit 2
}

[ $# -ge 1 ] || usage_error "a step is required"
step="$1"; shift
[ "${#step}" -le 64 ] && [[ "$step" =~ ^[a-z][a-z-]*$ ]] || usage_error "step must be a known step name"
jq -e --arg s "$step" '.steps | has($s)' "$STEPS_FILE" >/dev/null 2>&1 ||
  usage_error "unknown step '$step'; known: $(jq -r '.steps | keys | join(", ")' "$STEPS_FILE" 2>/dev/null)"

risk=""; author=""; security=false
while [ $# -gt 0 ]; do
  case "$1" in
    --risk)
      [ $# -ge 2 ] || usage_error "--risk needs high or standard"
      risk="$2"; shift 2 ;;
    --author)
      [ $# -ge 2 ] || usage_error "--author needs claude or codex"
      author="$2"; shift 2 ;;
    --security) security=true; shift ;;
    *) usage_error "unknown argument" ;;
  esac
done
case "$risk" in high | standard) ;; *) usage_error "--risk must be high or standard" ;; esac
case "$author" in "" | claude | codex) ;; *) usage_error "--author must be claude or codex" ;; esac

rule=$(jq -c --arg s "$step" --arg r "$risk" \
  '.steps[$s] as $d | if $r == "high" and ($d.high // null) != null then $d + $d.high else $d end' "$STEPS_FILE")
crossModel=$(jq -r '.crossModel // false' <<<"$rule")
[ "$crossModel" != true ] || [ -n "$author" ] || usage_error "step '$step' needs --author, since its provider is the other one"

# Quota: provider ratios and exhaustion, or unavailable.
report=""
available=false
if report=$(bash "$PACE" report --json 2>/dev/null) &&
  jq -e '[.providers[]? | select(.provider == "claude" or .provider == "codex")] | length > 0' <<<"$report" >/dev/null 2>&1; then
  available=true
fi
providerField() { # <provider> <field>: prints the value, or null
  if [ "$available" = true ]; then
    jq -c --arg p "$1" --arg f "$2" '([.providers[]? | select(.provider == $p)][0] // {}) | if has($f) then .[$f] else null end' <<<"$report"
  else
    echo null
  fi
}
rClaude=$(providerField claude paceRatio); rCodex=$(providerField codex paceRatio)
xClaude=$(providerField claude exhausted); xCodex=$(providerField codex exhausted)

other() { if [ "$1" = claude ]; then echo codex; else echo claude; fi; }
ratioOf() { if [ "$1" = claude ]; then echo "$rClaude"; else echo "$rCodex"; fi; }
exhaustedOf() { if [ "$1" = claude ]; then echo "$xClaude"; else echo "$xCodex"; fi; }

if [ "$crossModel" = true ]; then
  provider=$(other "$author")
  reason="review is cross-model: the author is $author, so $provider reviews"
else
  default=$(jq -r '.default' <<<"$rule")
  provider="$default"
  if [ "$(jq -r '.pinned // false' <<<"$rule")" = true ]; then
    model=$(jq -r '.model // empty' <<<"$rule")
    reason="pinned: $step stays with $default${model:+ (model $model)} whatever the quota"
  elif [ "$available" != true ]; then
    reason="quota unavailable: $step keeps its role default, $default"
  else
    alt=$(other "$default")
    rd=$(ratioOf "$default"); ro=$(ratioOf "$alt")
    if [ "$(exhaustedOf "$default")" = true ] && [ "$(exhaustedOf "$alt")" = false ]; then
      provider="$alt"
      reason="$default is near exhaustion, so $step moves to $alt"
    elif jq -en --argjson d "$rd" --argjson o "$ro" --argjson t "$SHIFT_ABOVE" \
      '$d != null and $o != null and $d > $t and $o < $d' >/dev/null 2>&1; then
      provider="$alt"
      reason="$default pace $rd is above $SHIFT_ABOVE and $alt is lower at $ro, so $step moves to $alt"
    else
      reason="role default: $step stays with $default (pace claude $rClaude, codex $rCodex)"
    fi
  fi
fi

[ "$available" = true ] || case "$reason" in *"quota unavailable"*) ;; *) reason="$reason (quota unavailable)" ;; esac

log="${ROUTING_LOG:-${HOME:-}/.claude/routing-log.jsonl}"
mkdir -p "$(dirname "$log")" 2>/dev/null
jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg step "$step" --arg risk "$risk" \
  --arg author "$author" --argjson security "$security" \
  --argjson rc "$rClaude" --argjson rx "$rCodex" --arg provider "$provider" --arg reason "$reason" \
  '{ts: $ts, step: $step, risk: $risk, author: (if $author == "" then null else $author end),
    security: $security, ratios: {claude: $rc, codex: $rx}, provider: $provider, reason: $reason}' \
  >>"$log" 2>/dev/null || echo "route: could not append to $log" >&2

printf '%s\n%s\n' "$provider" "$reason"
