#!/usr/bin/env bash
# route.sh: names the agent that takes a step, and logs why (slice 05 PR 1,
# docs/slices/slice-05-tiered-agents-and-local-qwen-implementer.md). Routing
# changes who does a step, never whether it happens: the output is always an
# agent.
#
# Usage: route.sh <step> --risk <high|standard> [--author <name>] [--security]
# Prints the agent (claude, qwen or owner) on line 1 and a one-line reason on
# line 2, and appends one JSON line (ts, step, risk, tier, provider, reason)
# to $ROUTING_LOG (default ~/.claude/routing-log.jsonl).
#
# A lookup in two tables:
#   - route-steps.json gives each step (and risk) a tier: primary, secondary
#     or owner.
#   - The machine file, $AGENT_TIER_ASSIGNMENTS_FILE (default
#     ~/.claude/agent-tier-assignments.json), gives primary and secondary an
#     agent. Known agents: claude, qwen. Primary defaults to claude. A
#     secondary that is unset or names an unknown agent resolves to primary.
#   - A missing machine file, or one that is not valid JSON (one warning on
#     stderr), leaves every tier on claude. The owner tier is always owner.
# --author and --security are accepted and ignored until the Codex port and
# the quota-based routing are removed in the follow-up slice.
# Exit codes: 0 routed; 2 a usage error, which logs nothing.
# With ROUTING_LOG, CLAUDE_HOME and HOME all unset, nothing is logged.
# CLAUDE_HOME names the Claude config directory and outranks $HOME/.claude
# for the machine file and for the default log path.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEPS_FILE="$HERE/route-steps.json"
KNOWN_AGENTS="claude qwen"

. "$HERE/resolve-machine-file.sh"
machine=$(resolve_machine_file)

# strip_controls <text>: strips control characters so the result fits in one
# stdout line and stays valid JSON.
strip_controls() {
  printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]'
}

# usage_error <message>: prints the message and the usage line to stderr, exit 2.
usage_error() {
  echo "route: $1" >&2
  echo "usage: route.sh <step> --risk <high|standard> [--author <name>] [--security]" >&2
  exit 2
}

[ $# -ge 1 ] || usage_error "a step is required"
step="$1"; shift
[ "${#step}" -le 64 ] && [[ "$step" =~ ^[a-z][a-z-]*$ ]] || usage_error "step must be a known step name"
jq -e --arg s "$step" '.steps | has($s)' "$STEPS_FILE" >/dev/null 2>&1 ||
  usage_error "unknown step '$step'; known: $(jq -r '.steps | keys | join(", ")' "$STEPS_FILE" 2>/dev/null)"

risk=""
risk_seen=0
while [ $# -gt 0 ]; do
  case "$1" in
    --risk)
      [ "$risk_seen" -eq 0 ] || usage_error "repeated --risk"
      [ $# -ge 2 ] || usage_error "--risk needs high or standard"
      risk="$2"; risk_seen=1; shift 2 ;;
    --author)
      [ $# -ge 2 ] || usage_error "--author needs a name"
      [ "${#2}" -le 64 ] && [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] || usage_error "--author must be a plain name"
      shift 2 ;;
    --security) shift ;;
    *) usage_error "unknown argument" ;;
  esac
done
case "$risk" in high | standard) ;; *) usage_error "--risk must be high or standard" ;; esac

rule=$(jq -c --arg s "$step" --arg r "$risk" \
  '.steps[$s] as $d | if $r == "high" and ($d.high // null) != null then $d + $d.high else $d end' "$STEPS_FILE")
tier=$(jq -r '.tier' <<<"$rule")
model=$(jq -r '.model // empty' <<<"$rule")

# Machine file: found and valid, absent, or invalid.
config="{}"
fileNote=""
if [ -z "$machine" ]; then
  fileNote="HOME is unset, so there is no machine file"
elif [ ! -f "$machine" ]; then
  fileNote="no machine file found at $(strip_controls "$machine")"
elif config=$(jq -c -- 'if type == "object" then . else error("not an object") end' "$machine" 2>/dev/null); then
  :
else
  config="{}"
  fileNote="machine file $(strip_controls "$machine") is not valid JSON"
  echo "route: warning: $fileNote; every tier uses claude" >&2
fi

# agentOf <tier>: prints the tier's configured agent, or nothing when unset.
agentOf() { jq -r --arg t "$1" '(.[$t] // {}) | if type == "object" then (.agent // "") else "" end | if type == "string" then . else "" end' <<<"$config"; }
# isKnownAgent <name>: true for an agent this harness can run.
isKnownAgent() { case " $KNOWN_AGENTS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

primary=$(agentOf primary)
primary=$(strip_controls "$primary")
isKnownAgent "$primary" || primary=claude

case "$tier" in
  owner)
    provider=owner
    reason="$step is the owner's, whatever the machine file says" ;;
  secondary)
    configured=$(agentOf secondary)
    configured=$(strip_controls "$configured")
    if [ -z "$configured" ]; then
      provider="$primary"
      reason="no secondary agent configured, so $step uses the primary agent, $primary"
    elif isKnownAgent "$configured"; then
      provider="$configured"
      reason="$step is secondary work and this machine assigns it to $configured"
    else
      provider="$primary"
      reason="secondary agent '$configured' is unknown, so $step uses the primary agent, $primary"
    fi ;;
  *)
    provider="$primary"
    reason="$step is primary work and this machine assigns it to $primary" ;;
esac
[ -z "$model" ] || reason="$reason (model $model)"
[ -z "$fileNote" ] || reason="$reason; $fileNote"

if [ -n "${ROUTING_LOG:-}" ]; then
  log="$ROUTING_LOG"
elif [ -n "${CLAUDE_HOME:-}" ]; then
  log="$CLAUDE_HOME/routing-log.jsonl"
elif [ -n "${HOME:-}" ]; then
  log="$HOME/.claude/routing-log.jsonl"
else
  log=""
fi
if [ -n "$log" ]; then
  mkdir -p "$(dirname "$log")" 2>/dev/null
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg step "$step" --arg risk "$risk" \
    --arg tier "$tier" --arg provider "$provider" --arg reason "$reason" \
    '{ts: $ts, step: $step, risk: $risk, tier: $tier, provider: $provider, reason: $reason}' \
    >>"$log" 2>/dev/null || echo "route: could not append to $log" >&2
fi

printf '%s\n%s\n' "$provider" "$reason"
