#!/usr/bin/env bash
# Covers: hook:session-start
#
# Verifies session-start.sh records the session's start timestamp (R-503) to
# ~/.claude/projects/<key>/session-start.<session-id> and injects it as
# additionalContext, so ticket-lifecycle's `open` reads started_at instead of
# the model recalling it. Origin: on 2026-09-18 a session opened a ticket with
# a guessed started_at 21 minutes early, overstating actual_minutes (53 vs 31)
# and inverting the estimate_ratio recalibration (1.18 vs 0.69).
#
# Cases: the transcript's first timestamp wins; the record is write-once, so
# a compact or resume re-injects the original value; a transcript not yet on
# disk falls back to the hook's own clock; a payload with no transcript_path
# writes nothing; a stale record from another session is pruned.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
HOOK="$CLAUDE_HARNESS_ROOT/hooks/session-start.sh"

fail=0
check() {
  local name="$1"; shift
  if "$@"; then
    echo "PASS: $name"
  else
    echo "FAIL: $name"
    fail=1
  fi
}
ctx_has()   { printf '%s' "$1" | grep -qF -- "$2"; }
ctx_lacks() { ! printf '%s' "$1" | grep -qF -- "$2"; }
file_holds() { [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; }
no_file()   { [ ! -e "$1" ]; }
is_iso_utc() { printf '%s' "$1" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$'; }
# Shape plus a real calendar instant: strips the fraction, parses, and
# requires the round trip to reproduce the input.
is_iso_utc_valid() {
  is_iso_utc "$1" || return 1
  local whole="${1%%.*}"; whole="${whole%Z}Z"
  [ "$(jq -rn --arg t "$whole" '$t | fromdateiso8601 | todateiso8601' 2>/dev/null)" = "$whole" ]
}

# Runs the hook with HOME=$1 from cwd / (no handoff doc) and payload $2.
get_ctx() {
  local home="$1" payload="$2" raw
  raw=$(cd / && HOME="$home" bash "$HOOK" <<< "$payload" 2>/dev/null || true)
  [ -n "$raw" ] || { printf ''; return 0; }
  printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true
}
payload_for() {
  jq -n --arg s "$1" --arg t "$2" '{source:$s, transcript_path:$t, cwd:"/"}'
}

SANDBOX=$(mktemp -d)
KEY_DIR="$SANDBOX/.claude/projects/-tmp-sample-project"
mkdir -p "$KEY_DIR"

# --- The transcript's first timestamp is the start, not the hook's clock ---
SID="11111111-aaaa-bbbb-cccc-000000000001"
TRANSCRIPT="$KEY_DIR/$SID.jsonl"
RECORD="$KEY_DIR/session-start.$SID"
{
  printf '%s\n' 'not json at all'
  printf '%s\n' '{"type":"summary","summary":"no timestamp on this line"}'
  printf '%s\n' '{"type":"queue-operation","timestamp":"2026-09-18T08:51:37.412Z","sessionId":"x"}'
  printf '%s\n' '{"type":"user","timestamp":"2026-09-18T08:52:00.000Z"}'
} > "$TRANSCRIPT"

CTX=$(get_ctx "$SANDBOX" "$(payload_for startup "$TRANSCRIPT")")
check "record holds the transcript's first timestamp" file_holds "$RECORD" "2026-09-18T08:51:37.412Z"
check "context carries started_at from the transcript" ctx_has "$CTX" "started_at: 2026-09-18T08:51:37.412Z"
check "context names the session id" ctx_has "$CTX" "$SID"
check "context renders the record path under ~, never the real home" ctx_lacks "$CTX" "$SANDBOX"

# --- Write-once: a later start of the same session keeps the original ---
printf '%s\n' '{"type":"user","timestamp":"2026-09-19T00:00:00.000Z"}' > "$TRANSCRIPT"
CTX_COMPACT=$(get_ctx "$SANDBOX" "$(payload_for compact "$TRANSCRIPT")")
check "compact keeps the recorded start" file_holds "$RECORD" "2026-09-18T08:51:37.412Z"
check "compact re-injects the recorded start" ctx_has "$CTX_COMPACT" "started_at: 2026-09-18T08:51:37.412Z"
CTX_RESUME=$(get_ctx "$SANDBOX" "$(payload_for resume "$TRANSCRIPT")")
check "resume re-injects the recorded start" ctx_has "$CTX_RESUME" "started_at: 2026-09-18T08:51:37.412Z"

# --- A corrupt record is replaced, not trusted ---
printf 'yesterday-ish\n' > "$RECORD"
get_ctx "$SANDBOX" "$(payload_for compact "$TRANSCRIPT")" >/dev/null
check "a non-ISO record is rederived from the transcript" file_holds "$RECORD" "2026-09-19T00:00:00.000Z"

# --- A record with the right shape but an impossible date is replaced ---
printf '2026-99-99T99:99:99Z\n' > "$RECORD"
get_ctx "$SANDBOX" "$(payload_for compact "$TRANSCRIPT")" >/dev/null
check "a shape-valid but impossible record is rederived" file_holds "$RECORD" "2026-09-19T00:00:00.000Z"

# --- A transcript timestamp that is not a real instant is not trusted ---
SID_BADTS="11111111-aaaa-bbbb-cccc-000000000004"
printf '%s\n' '{"type":"user","timestamp":"2026-13-45T25:61:00Z"}' > "$KEY_DIR/$SID_BADTS.jsonl"
get_ctx "$SANDBOX" "$(payload_for startup "$KEY_DIR/$SID_BADTS.jsonl")" >/dev/null
check "an impossible transcript timestamp is not recorded" is_iso_utc_valid "$(cat "$KEY_DIR/session-start.$SID_BADTS" 2>/dev/null)"

# --- Resume or compact with no record and no transcript timestamp: the ---
# --- clock is not the start, so nothing is recorded or claimed ---
SID_LATE="11111111-aaaa-bbbb-cccc-000000000003"
printf '%s\n' '{"type":"summary","summary":"no timestamp"}' > "$KEY_DIR/$SID_LATE.jsonl"
for late_source in resume compact; do
  CTX_LATE=$(get_ctx "$SANDBOX" "$(payload_for "$late_source" "$KEY_DIR/$SID_LATE.jsonl")")
  check "$late_source without a transcript timestamp writes no record" no_file "$KEY_DIR/session-start.$SID_LATE"
  check "$late_source without a transcript timestamp injects no start" ctx_lacks "$CTX_LATE" "started_at:"
done

# --- No transcript on disk yet: the hook's own clock is the start ---
SID_FRESH="11111111-aaaa-bbbb-cccc-000000000002"
RECORD_FRESH="$KEY_DIR/session-start.$SID_FRESH"
BEFORE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CTX_FRESH=$(get_ctx "$SANDBOX" "$(payload_for startup "$KEY_DIR/$SID_FRESH.jsonl")")
AFTER=$(date -u +%Y-%m-%dT%H:%M:%SZ)
FRESH_VALUE=$(cat "$RECORD_FRESH" 2>/dev/null || true)
check "fresh session writes a record" [ -n "$FRESH_VALUE" ]
check "fresh record is UTC ISO-8601" is_iso_utc "$FRESH_VALUE"
check "fresh record is not before the hook ran" [ ! "$FRESH_VALUE" \< "$BEFORE" ]
check "fresh record is not after the hook ran" [ ! "$FRESH_VALUE" \> "$AFTER" ]
check "fresh context carries the record" ctx_has "$CTX_FRESH" "started_at: $FRESH_VALUE"

# --- No transcript_path: nothing keyed, nothing written or claimed ---
EMPTY_HOME=$(mktemp -d)
CTX_NONE=$(get_ctx "$EMPTY_HOME" '{}')
check "no transcript_path injects no start block" ctx_lacks "$CTX_NONE" "started_at:"
check "no transcript_path writes no projects tree" no_file "$EMPTY_HOME/.claude/projects"
rm -rf "$EMPTY_HOME"

# --- A stale record from another session is pruned ---
STALE="$KEY_DIR/session-start.99999999-aaaa-bbbb-cccc-000000000009"
printf '2026-08-01T00:00:00Z\n' > "$STALE"
touch -t "$(date -v-20d +%Y%m%d%H%M 2>/dev/null || date -d '20 days ago' +%Y%m%d%H%M)" "$STALE"
# 14 days and 2 hours: past the TTL, but a whole-day `-mtime +14` keeps it.
JUST_STALE="$KEY_DIR/session-start.99999999-aaaa-bbbb-cccc-000000000010"
printf '2026-08-01T00:00:00Z\n' > "$JUST_STALE"
touch -t "$(date -v-14d -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '14 days 2 hours ago' +%Y%m%d%H%M)" "$JUST_STALE"
FRESH_OTHER="$KEY_DIR/session-start.99999999-aaaa-bbbb-cccc-000000000011"
printf '2026-08-01T00:00:00Z\n' > "$FRESH_OTHER"
touch -t "$(date -v-13d +%Y%m%d%H%M 2>/dev/null || date -d '13 days ago' +%Y%m%d%H%M)" "$FRESH_OTHER"
get_ctx "$SANDBOX" "$(payload_for startup "$TRANSCRIPT")" >/dev/null
check "a record older than 14 days is pruned" no_file "$STALE"
check "a record 14 days and 2 hours old is pruned (exact TTL, not whole days)" no_file "$JUST_STALE"
check "another session's 13-day-old record survives" [ -f "$FRESH_OTHER" ]
check "the current session's record survives the prune" [ -f "$RECORD" ]

rm -rf "$SANDBOX"

if [ "$fail" -eq 0 ]; then
  echo "session-start-timestamp.test.sh PASS"
  exit 0
fi
echo "session-start-timestamp.test.sh: FAILURES PRESENT"
exit 1
