#!/usr/bin/env bash
# status-line.sh: the session HUD (hardening spec B-5). Reads the statusLine
# stdin JSON and prints one line: model | branch(+* when dirty) | context %
# | session cost | elapsed | 5h rate limit | 7d rate limit. Every field degrades to "-" when
# its input is null or absent (a percentage also when it falls outside
# 0..100, which is how an overflowed value renders on Linux), and every
# failure path still prints a line
# and exits 0: a broken HUD must never break the session.
#
# The 7d figure is Claude's all-models weekly bucket. When it and its reset
# time are both valid, it is also recorded as a quota snapshot (IAN-603, slice
# 04 PR 2) through quota-pace.sh, in the background and at most once every
# QUOTA_RECORD_MIN_MINUTES (default 30), counting a snapshot from any source.
# Invalid input shows no 7d figure and records nothing. QUOTA_NOW pins the
# clock for tests; CLAUDE_QUOTA_FILE names the quota file.
set -uo pipefail

emit_fallback() { echo "claude | - | ctx - | \$- | - | 5h -%"; exit 0; }
trap emit_fallback ERR

# record_weekly <pct> <iso>: starts quota-pace.sh record in the background
# unless the newest claude snapshot, from any source, is younger than the
# throttle. Never waits and never fails the line.
record_weekly() {
  local min="${QUOTA_RECORD_MIN_MINUTES:-30}" now qfile latest qp dir
  [[ "$min" =~ ^[0-9]+([.][0-9]+)?$ ]] || min=30
  now="${QUOTA_NOW:-}"
  [[ "$now" =~ ^[0-9]+$ ]] || now=$(date +%s)
  qfile="${CLAUDE_QUOTA_FILE:-${HOME:-}/.claude/quota.json}"
  latest=$(jq -r '[(.buckets.claude.snapshots // [])[] | (.at | try fromdateiso8601 catch empty)] | max // empty' "$qfile" 2>/dev/null) || latest=""
  if [[ "$latest" =~ ^[0-9]+$ ]] && jq -en --argjson n "$now" --argjson l "$latest" --argjson m "$min" '($n - $l) < ($m * 60)' >/dev/null 2>&1; then
    return 0
  fi
  # A quota file the recorder cannot use fails every record, and with no
  # snapshot to throttle on, every render would start another doomed recorder.
  if [ -e "$qfile" ]; then
    [ -f "$qfile" ] && [ -w "$qfile" ] && jq -e . "$qfile" >/dev/null 2>&1 || return 0
  else
    dir=$(dirname "$qfile")
    while [ ! -e "$dir" ]; do dir=$(dirname "$dir"); done
    [ -d "$dir" ] && [ -w "$dir" ] || return 0
  fi
  qp="$(dirname "$0")/enforce/quota-pace.sh"
  ( "$qp" record claude "$1" --resets-at "$2" --source statusline </dev/null >/dev/null 2>&1 & ) 2>/dev/null
  return 0
}

INPUT=$(cat 2>/dev/null || true)
jq -e . >/dev/null 2>&1 <<<"$INPUT" || emit_fallback

field() { jq -r "$1 // empty" <<<"$INPUT" 2>/dev/null; }

MODEL=$(field '.model.display_name'); [ -n "$MODEL" ] || MODEL="claude"
CWD=$(field '.cwd'); [ -n "$CWD" ] || CWD=$(field '.workspace.current_dir')
BRANCH="-"
if [ -n "$CWD" ] && git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null)
  [ -n "$BRANCH" ] || BRANCH="detached"
  [ -z "$(git -C "$CWD" status --porcelain 2>/dev/null | head -1)" ] || BRANCH="${BRANCH}*"
fi
CTX=$(field '.context_window.used_percentage')
if [ -n "$CTX" ] && CTX_FMT=$(printf '%.0f' "$CTX" 2>/dev/null) && [[ "$CTX_FMT" =~ ^[0-9]+$ ]] && [ "$CTX_FMT" -le 100 ]; then
  CTX="${CTX_FMT}%"
else
  CTX="-"
fi
COST=$(field '.cost.total_cost_usd')
if [ -n "$COST" ] && COST_FMT=$(printf '%.2f' "$COST" 2>/dev/null) && [[ "$COST_FMT" =~ ^-?[0-9]+\.[0-9]{2}$ ]]; then
  COST="$COST_FMT"
else
  COST="-"
fi
MS=$(field '.cost.total_duration_ms')
if [ -n "$MS" ] && [ "$MS" -gt 0 ] 2>/dev/null; then
  ELAPSED="$((MS / 3600000))h$(((MS % 3600000) / 60000))m"
else
  ELAPSED="-"
fi
RATE=$(field '.rate_limits.five_hour.used_percentage')
if [ -n "$RATE" ] && RATE_FMT=$(printf '%.0f' "$RATE" 2>/dev/null) && [[ "$RATE_FMT" =~ ^[0-9]+$ ]] && [ "$RATE_FMT" -le 100 ]; then
  RATE="$RATE_FMT"
else
  RATE="-"
fi

# Weekly bucket: used_percentage a number in 0..100, resets_at epoch seconds
# (number or digit string) or ISO 8601 with Z or an offset. Anything else
# leaves both empty, so nothing is shown or recorded.
SEVEN=""
SEVEN_FIELDS=$(jq -r '
  .rate_limits.seven_day as $s
  | ($s.used_percentage) as $p
  | ($s.resets_at) as $r
  | (if ($p | type) == "number" and $p >= 0 and $p <= 100 then $p else null end) as $pct
  | (try (if ($r | type) == "number" and $r >= 0 then ($r | floor | todate)
          elif ($r | type) == "string" and ($r | test("^[0-9]{1,12}$")) then ($r | tonumber | todate)
          elif ($r | type) == "string" and ($r | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?(\\.[0-9]+)?(Z|[+-](0[0-9]|1[0-4]):?[0-5][0-9])$")) then $r
          else null end) catch null) as $iso
  | if $pct != null and $iso != null then "\($pct)\t\($iso)" else empty end
' <<<"$INPUT" 2>/dev/null) || SEVEN_FIELDS=""
if [ -n "$SEVEN_FIELDS" ]; then
  SEVEN_PCT=${SEVEN_FIELDS%%$'\t'*}
  SEVEN_ISO=${SEVEN_FIELDS#*$'\t'}
  if SEVEN_REC=$(printf '%.2f' "$SEVEN_PCT" 2>/dev/null) && [[ "$SEVEN_REC" =~ ^[0-9]+\.[0-9]{2}$ ]]; then
    SEVEN=" | 7d $(printf '%.0f' "$SEVEN_PCT")%"
    record_weekly "$SEVEN_REC" "$SEVEN_ISO" || true
  fi
fi

echo "$MODEL | $BRANCH | ctx $CTX | \$$COST | $ELAPSED | 5h ${RATE}%${SEVEN}"
exit 0
