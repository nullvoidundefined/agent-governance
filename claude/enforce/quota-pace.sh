#!/usr/bin/env bash
# quota-pace.sh: the quota input and pace calculator behind quota-aware
# routing (IAN-603, docs/slices/slice-04-quota-aware-routing.md). Neither
# CLI offers a usage read that a script can call on demand: Claude Code hands
# its weekly figure only to the status line command, and Codex shows usage
# only on its interactive screen. So the input is a small JSON file of
# snapshots, written by hand or by the status line through `record`, and
# this script turns it into a pace ratio per bucket and per provider.
#
# Usage:
#   quota-pace.sh record <bucket> <usedPct> [--resets-at <iso>] [--provider <p>]
#                 [--window-days <n>] [--at <iso>] [--source <s>]
#   quota-pace.sh report [--json]
#
# Math, per bucket (owner decisions 2026-10-02):
#   daysLeft    = (resetsAt - now) / 1 day
#   dailyBudget = (100 - usedPct) / daysLeft
#   burn        = trailing: (used - usedPrev) / days between, where usedPrev is
#                 the most recent snapshot at least 12h older in this window;
#                 else window-average: used / days since the window opened
#   paceRatio   = burn / dailyBudget
#   exhausted   = usedPct >= 90, or less than one day left at this burn while
#                 the reset is further away than that
# A provider's ratio is its worst bucket's; it is exhausted when any bucket is.
#
# Environment: CLAUDE_QUOTA_FILE (default ~/.claude/quota.json), QUOTA_NOW
# (epoch seconds, pins the clock for tests), QUOTA_STALE_HOURS (default 24).
# Exit codes: 0 ok; 1 a missing or malformed quota file or argument.
# Bash 3.2 safe: no mapfile, no associative arrays.
set -uo pipefail

QUOTA_FILE="${CLAUDE_QUOTA_FILE:-${HOME:-~}/.claude/quota.json}"
STALE_HOURS="${QUOTA_STALE_HOURS:-24}"
MAX_SNAPSHOTS=50

# jq helpers shared by both commands. toEpoch accepts epoch seconds (a
# number or an all-digit string, the form Claude Code's status line gives
# resets_at in) or ISO 8601 with Z or a +HH:MM/-HH:MM offset (jq's
# fromdateiso8601 takes only Z).
JQ_LIB='
def toEpoch:
  if type == "number" then .
  elif test("^[0-9]+$") then tonumber
  else
    (capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2})(?<s>:[0-9]{2})?(\\.[0-9]+)?(?<tz>Z|[+-][0-9]{2}:?[0-9]{2})$")
      // error("bad timestamp: \(.)")) as $m
    | ((($m.d + ($m.s // ":00") + "Z") | fromdateiso8601)) as $local
    | if $m.tz == "Z" then $local
      else ($m.tz | gsub(":"; "")) as $z
        | ((if ($z[0:1]) == "-" then -1 else 1 end)
           * (($z[1:3] | tonumber) * 3600 + ($z[3:5] | tonumber) * 60)) as $off
        | $local - $off
      end
  end;
'

# fail <message>: prints the message to stderr and exits 1.
fail() {
  echo "quota-pace: $1" >&2
  exit 1
}

# nowEpoch: prints the current time in epoch seconds, or QUOTA_NOW when set.
nowEpoch() {
  if [ -n "${QUOTA_NOW:-}" ]; then
    printf '%s\n' "$QUOTA_NOW"
  else
    date +%s
  fi
}

# readQuotaFile: prints the quota file's JSON, failing loudly when it is
# missing or does not carry a buckets object, never reading as zero usage.
readQuotaFile() {
  [ -f "$QUOTA_FILE" ] || fail "no quota file at $QUOTA_FILE; copy ~/.claude/quota.template.json there or run 'quota-pace.sh record'"
  jq -e '.buckets | type == "object"' "$QUOTA_FILE" >/dev/null 2>&1 ||
    fail "$QUOTA_FILE is not valid JSON with a \"buckets\" object"
  cat "$QUOTA_FILE"
}

# writeQuotaFile <json>: replaces the quota file atomically through a temp
# file in the same directory, so a reader never sees a half-written file.
writeQuotaFile() {
  local dir tmp
  dir=$(dirname "$QUOTA_FILE")
  mkdir -p "$dir" || fail "cannot create $dir"
  tmp=$(mktemp "$dir/.quota.json.XXXXXX") || fail "cannot create a temp file in $dir"
  printf '%s\n' "$1" >"$tmp" && mv "$tmp" "$QUOTA_FILE" || {
    rm -f "$tmp"
    fail "cannot write $QUOTA_FILE"
  }
}

# recordSnapshot <args...>: appends one snapshot to a bucket, creating the
# file or bucket when needed. A changed reset time opens a new window and
# drops snapshots taken before it, so the last window's usage never feeds
# this window's burn.
recordSnapshot() {
  local bucket="${1:-}" used="${2:-}"
  [ -n "$bucket" ] && [ -n "$used" ] || fail "usage: record <bucket> <usedPct> [--resets-at <iso>] [--provider <p>] [--window-days <n>] [--at <iso>] [--source <s>]"
  shift 2
  local resets="" provider="" window="" at="" source="owner"
  while [ $# -gt 0 ]; do
    case "$1" in
      --resets-at) resets="${2:-}"; shift 2 ;;
      --provider) provider="${2:-}"; shift 2 ;;
      --window-days) window="${2:-}"; shift 2 ;;
      --at) at="${2:-}"; shift 2 ;;
      --source) source="${2:-}"; shift 2 ;;
      *) fail "unknown option '$1'" ;;
    esac
  done
  [[ "$bucket" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail "bucket name '$bucket' must be lowercase letters, digits, - or _"
  [[ "$used" =~ ^[0-9]+([.][0-9]+)?$ ]] && jq -en --argjson u "$used" '$u <= 100' >/dev/null ||
    fail "usedPct '$used' must be a number from 0 to 100"
  [ -z "$window" ] || [[ "$window" =~ ^[1-9][0-9]*$ ]] || fail "--window-days '$window' must be a positive integer"

  local current now
  if [ -f "$QUOTA_FILE" ]; then current=$(readQuotaFile) || exit 1; else current='{"buckets":{}}'; fi
  now=$(nowEpoch)
  local updated
  updated=$(jq -e "$JQ_LIB"'
    ($resets | if . == "" then null else (toEpoch | todate) end) as $newReset
    | (if $at == "" then ($now | tonumber) else ($at | toEpoch) end) as $atE
    | (.buckets[$b] // null) as $old
    | if $old == null and $newReset == null then error("bucket \($b) is new: pass --resets-at")
      else . end
    | ($old // {}) as $o
    | ($newReset // $o.resetsAt) as $reset
    | ((if $window == "" then null else ($window | tonumber) end) // $o.windowDays // 7) as $wd
    | (($reset | toEpoch) - $wd * 86400) as $start
    | (if $o.resetsAt != null and $newReset != null and (($o.resetsAt | toEpoch) != ($newReset | toEpoch))
       then [($o.snapshots // [])[] | select((.at | toEpoch) >= $start)]
       else ($o.snapshots // []) end) as $kept
    | .buckets[$b] = ($o + {
        provider: (if $provider == "" then ($o.provider // $b) else $provider end),
        resetsAt: $reset,
        windowDays: $wd,
        snapshots: (($kept + [{at: ($atE | todate), usedPct: ($used | tonumber), source: $source}])
                    | sort_by(.at | toEpoch) | .[-($max):])
      })
  ' --arg b "$bucket" --arg used "$used" --arg resets "$resets" --arg provider "$provider" \
    --arg window "$window" --arg at "$at" --arg source "$source" --arg now "$now" \
    --argjson max "$MAX_SNAPSHOTS" <<<"$current" 2>&1) || fail "record failed: $updated"
  writeQuotaFile "$updated"
}

# reportJson <quota json>: prints the per-bucket and per-provider pace report
# as JSON. A bucket with no usable data reports a null ratio and a status
# saying why, so a caller can never mistake missing data for a zero burn.
reportJson() {
  local now
  now=$(nowEpoch)
  jq "$JQ_LIB"'
    ($now | tonumber) as $now
    | ($staleH | tonumber * 3600) as $staleS
    | def round2: (. * 100 | round) / 100;
      def bucketReport($name):
        (.windowDays // 7) as $wd
        | (.resetsAt | toEpoch) as $reset
        | ($reset - $wd * 86400) as $start
        | ([(.snapshots // [])[] | {at: (.at | toEpoch), used: .usedPct, source: (.source // "owner")}
            | select(.at >= $start and .at <= $now)] | sort_by(.at)) as $snaps
        | {bucket: $name, provider: (.provider // $name), resetsAt: .resetsAt}
        + if $reset <= $now then
            {status: "window-rolled", paceRatio: null, exhausted: false,
             note: "the reset time has passed; record a snapshot with the new --resets-at"}
          elif ($snaps | length) == 0 then
            {status: "no-data", paceRatio: null, exhausted: false,
             note: "no snapshot inside the current window"}
          else
            ($snaps[-1]) as $last
            | (($reset - $now) / 86400) as $daysLeft
            | (100 - $last.used) as $remaining
            | ([$snaps[] | select(.at <= $last.at - 43200)] | last) as $prev
            | (if $prev != null then
                 {burn: ([($last.used - $prev.used) / (($last.at - $prev.at) / 86400), 0] | max),
                  burnMethod: "trailing"}
               elif ($last.at - $start) >= 3600 then
                 {burn: ($last.used / (($last.at - $start) / 86400)), burnMethod: "window-average"}
               else {burn: null, burnMethod: "insufficient"} end) as $b
            | ($remaining / $daysLeft) as $budget
            | (if $b.burn == null then null
               elif $remaining <= 0 then null
               else $b.burn / $budget end) as $ratio
            | (if $b.burn != null and $b.burn > 0 then $remaining / $b.burn else null end) as $projected
            | {status: (if ($now - $last.at) > $staleS then "stale" else "ok" end),
               usedPct: $last.used,
               snapshotAt: ($last.at | todate),
               snapshotSource: $last.source,
               daysLeft: ($daysLeft | round2),
               dailyBudget: ($budget | round2),
               burn: (if $b.burn == null then null else ($b.burn | round2) end),
               burnMethod: $b.burnMethod,
               paceRatio: (if $ratio == null then null else ($ratio | round2) end),
               projectedDaysLeft: (if $projected == null then null else ($projected | round2) end),
               exhausted: ($last.used >= 90
                           or ($projected != null and $projected < 1 and $daysLeft > $projected))}
          end;
      [.buckets | to_entries[] | (.key) as $k | .value | bucketReport($k)] as $buckets
    | {now: ($now | todate),
       buckets: $buckets,
       providers: ($buckets | group_by(.provider) | map({
         provider: .[0].provider,
         paceRatio: ([.[].paceRatio | select(. != null)] | max),
         worstBucket: ((map(select(.paceRatio != null)) | max_by(.paceRatio) | .bucket) // null),
         exhausted: any(.[]; .exhausted),
         status: (if any(.[]; .status == "ok") then
                    (if any(.[]; .status != "ok") then "partial" else "ok" end)
                  else "no-usable-data" end)
       }))}
  ' --arg now "$now" --arg staleH "$STALE_HOURS"
}

# reportText <report json>: prints the report as an aligned table for the
# owner, one row per bucket, then one line per provider. Padding is done in
# awk because `column` is missing from minimal Linux images.
reportText() {
  jq -r '
    def f: if . == null then "-" else tostring end;
    (["bucket", "used%", "daysLeft", "budget/d", "burn/d", "method", "ratio", "projDays", "exhausted", "status"] | @tsv),
    (.buckets[] | [.bucket, (.usedPct | f), (.daysLeft | f), (.dailyBudget | f), (.burn | f),
                   (.burnMethod | f), (.paceRatio | f), (.projectedDaysLeft | f), (.exhausted | f), .status] | @tsv),
    "",
    (.providers[] | "provider \(.provider): ratio \(.paceRatio | f) (worst bucket \(.worstBucket | f)), exhausted \(.exhausted), \(.status)")
  ' <<<"$1" | awk -F '\t' '
    { rows[NR] = $0; cells[NR] = NF; if (NF > 1) for (i = 1; i <= NF; i++) if (length($i) > w[i]) w[i] = length($i) }
    END {
      for (r = 1; r <= NR; r++) {
        if (cells[r] < 2) { print rows[r]; continue }
        split(rows[r], c, "\t"); line = ""
        for (i = 1; i <= cells[r]; i++) line = line sprintf("%-" (w[i] + 2) "s", c[i])
        sub(/ +$/, "", line); print line
      }
    }'

}

case "${1:-}" in
  record)
    shift
    recordSnapshot "$@"
    ;;
  report)
    shift
    quota=$(readQuotaFile) || exit 1
    report=$(reportJson <<<"$quota" 2>&1) || fail "cannot compute the report: $report"
    if [ "${1:-}" = "--json" ]; then printf '%s\n' "$report"; else reportText "$report"; fi
    ;;
  *)
    fail "usage: quota-pace.sh record <bucket> <usedPct> [options] | report [--json]"
    ;;
esac
