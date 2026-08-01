#!/usr/bin/env bash
# log-rule-fire.sh: sourced helper, not a hook. Appends one line per
# enforcement fire to the telemetry log so effectiveness data accrues
# mechanically instead of by hand (2026-07-31 criticism audit P0: the fire
# log recorded nothing new in 28 days while the rule count grew 63%).
# session-end.sh rolls the log up into global-memory/rule_fires.md.
# Line format: <utc-timestamp>|<rule-or-gate>|<hook>|<decision>|<repo-basename>
# Never fails or slows the caller; set CLAUDE_FIRE_LOG=/dev/null to disable
# (the fixture-test runners do, so test fires never pollute the telemetry).

log_rule_fire() {
  {
    local fire_log="${CLAUDE_FIRE_LOG:-$HOME/.claude/telemetry/rule-fires.log}"
    [ "$fire_log" = "/dev/null" ] && return 0
    mkdir -p "$(dirname "$fire_log")"
    printf '%s|%s|%s|%s|%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "${1:-unknown}" \
      "${2:-unknown}" \
      "${3:-deny}" \
      "$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo unknown)")" \
      >> "$fire_log"
  } 2>/dev/null || true
}
