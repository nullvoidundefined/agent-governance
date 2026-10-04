#!/usr/bin/env bash
# log-rule-fire.sh: sourced helper, not a hook. Appends one line per
# enforcement fire to the telemetry log so effectiveness data accrues
# mechanically instead of by hand (2026-07-31 criticism audit P0: the fire
# log recorded nothing new in 28 days while the rule count grew 63%).
# session-end.sh rolls the log up into global-memory/rule_fires.md.
# Line format: <utc-timestamp>|<rule-or-gate>|<hook>|<decision>|<repo-basename>|<session-id>
# The session ID is the last field so parsers that read the first five keep
# working; it comes from CLAUDE_SESSION_ID, else the hook payload's session_id
# in the caller's INPUT variable, else `-`.
# Fires bound for the default live log are skipped when the repository
# resolves to `unknown` or the working directory sits under $TMPDIR, /tmp, or
# /private/tmp: those are fixture runs in scratch repositories, and they
# drowned the real fires in the pruning data (IAN-568, interlock I9). An
# explicit CLAUDE_FIRE_LOG file still records every fire, so fixtures can
# assert on their own log.
# Never fails or slows the caller; set CLAUDE_FIRE_LOG=/dev/null to disable
# (the test runners do, so test fires never pollute the telemetry).
# With neither CLAUDE_FIRE_LOG nor HOME set there is nowhere to log, so the
# fire is skipped: a bare $HOME under a caller's set -u would abort the hook
# before it prints its decision, and an empty PreToolUse output is an allow
# (IAN-356).

# is_scratch_fire_location: true when the repository resolves to `unknown` or
# the working directory sits under a temporary directory.
is_scratch_fire_location() {
  local repo_name="$1" work_dir tmp_root
  [ "$repo_name" = "unknown" ] && return 0
  work_dir=$(pwd -P 2>/dev/null || pwd)
  for tmp_root in "${TMPDIR:-}" /tmp /private/tmp; do
    [ -d "$tmp_root" ] || continue
    # Compare physical paths: macOS TMPDIR sits under /var, a symlink.
    tmp_root=$(cd "$tmp_root" 2>/dev/null && pwd -P) || continue
    case "$work_dir/" in "${tmp_root%/}"/*) return 0 ;; esac
  done
  return 1
}

# read_fire_session_id: prints the session ID for the fire line, or `-`.
# Both sources lose every `|`, line feed, and carriage return, so a session ID
# can neither shift the fields nor forge a further line (R-109 r1 #6 on PR
# #182).
read_fire_session_id() {
  local session_id
  session_id=$(printf '%s' "${CLAUDE_SESSION_ID:-}" | tr -d '|\n\r')
  if [ -z "$session_id" ] && [ -n "${INPUT:-}" ]; then
    session_id=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -d '|\n\r')
  fi
  printf '%s' "${session_id:--}"
}

# log_rule_fire: appends one fire line; never fails or slows the caller.
log_rule_fire() {
  {
    local fire_log="${CLAUDE_FIRE_LOG:-}" repo_name
    repo_name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo unknown)")
    if [ -z "$fire_log" ]; then
      [ -n "${HOME:-}" ] || return 0
      is_scratch_fire_location "$repo_name" && return 0
      fire_log="$HOME/.claude/telemetry/rule-fires.log"
    fi
    [ "$fire_log" = "/dev/null" ] && return 0
    mkdir -p "$(dirname "$fire_log")"
    printf '%s|%s|%s|%s|%s|%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "${1:-unknown}" \
      "${2:-unknown}" \
      "${3:-deny}" \
      "$repo_name" \
      "$(read_fire_session_id)" \
      >> "$fire_log"
  } 2>/dev/null || true
}
