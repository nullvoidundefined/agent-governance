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
# A provider's ratio is its worst current bucket's: a stale bucket never sets
# it, so a caller reading paceRatio alone cannot act on old data. When a
# current bucket has no ratio (100% used, or under an hour into its window),
# the provider's ratio is null and ratioComplete false, so that bucket can
# never hide behind a healthier sibling. A provider
# is exhausted when any bucket, stale ones included, says so.
#
# Environment: CLAUDE_QUOTA_FILE (default ~/.claude/quota.json), QUOTA_NOW
# (epoch seconds, pins the clock for tests), QUOTA_STALE_HOURS (default 24).
# Exit codes: 0 ok; 1 a missing or malformed quota file or argument.
# Bash 3.2 safe: no mapfile, no associative arrays.
set -uo pipefail

if [ -n "${CLAUDE_QUOTA_FILE:-}" ]; then
  case "$CLAUDE_QUOTA_FILE" in
    /*) ;;
    *)
      echo "quota-pace: CLAUDE_QUOTA_FILE '$CLAUDE_QUOTA_FILE' is not an absolute path" >&2
      exit 1
      ;;
  esac
  QUOTA_FILE="$CLAUDE_QUOTA_FILE"
elif [ -n "${HOME:-}" ]; then
  case "$HOME" in
    /*) ;;
    *)
      echo "quota-pace: HOME '$HOME' is not an absolute path; set CLAUDE_QUOTA_FILE" >&2
      exit 1
      ;;
  esac
  QUOTA_FILE="$HOME/.claude/quota.json"
else
  echo "quota-pace: HOME is unset; set CLAUDE_QUOTA_FILE" >&2
  exit 1
fi
STALE_HOURS="${QUOTA_STALE_HOURS:-24}"
MAX_SNAPSHOTS=50

# jq helpers shared by both commands. toEpoch accepts epoch seconds (a
# number or an all-digit string, the form Claude Code's status line gives
# resets_at in) or ISO 8601 with Z or a +HH:MM/-HH:MM offset (jq's
# fromdateiso8601 takes only Z). An offset beyond +/-14:59 is refused, since
# no zone uses one and a typo there would move the reset by days.
JQ_LIB='
def toEpoch:
  if type == "number" then .
  elif test("^[0-9]+$") then tonumber
  else
    (capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2})(?<s>:[0-9]{2})?(\\.[0-9]+)?(?<tz>Z|[+-](0[0-9]|1[0-4]):?[0-5][0-9])$")
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
    [[ "$QUOTA_NOW" =~ ^[0-9]+$ ]] || fail "QUOTA_NOW '$QUOTA_NOW' must be epoch seconds"
    printf '%s\n' "$QUOTA_NOW"
  else
    date +%s
  fi
}

# readQuotaFile: prints the quota file's JSON, failing loudly when it is
# missing or does not carry a buckets object, never reading as zero usage.
readQuotaFile() {
  [ ! -d "$QUOTA_FILE" ] || fail "$QUOTA_FILE is a directory, not a quota file"
  [ ! -L "$QUOTA_FILE" ] || fail "$QUOTA_FILE is a symlink; point CLAUDE_QUOTA_FILE at the real file"
  [ -f "$QUOTA_FILE" ] || fail "no quota file at $QUOTA_FILE; copy ~/.claude/quota.template.json there or run 'quota-pace.sh record'"
  jq -e '.buckets | type == "object"' "$QUOTA_FILE" >/dev/null 2>&1 ||
    fail "$QUOTA_FILE is not valid JSON with a \"buckets\" object"
  jq -e '.buckets | length > 0' "$QUOTA_FILE" >/dev/null 2>&1 ||
    fail "$QUOTA_FILE has no buckets; record one with 'quota-pace.sh record'"
  cat "$QUOTA_FILE"
}

# writeQuotaFile <json>: replaces the quota file atomically through a temp
# file in the same directory, so a reader never sees a half-written file.
writeQuotaFile() {
  local dir tmp
  [ ! -d "$QUOTA_FILE" ] || fail "$QUOTA_FILE is a directory, not a quota file"
  [ ! -L "$QUOTA_FILE" ] || fail "$QUOTA_FILE is a symlink; point CLAUDE_QUOTA_FILE at the real file"
  dir=$(dirname "$QUOTA_FILE")
  mkdir -p "$dir" || fail "cannot create $dir"
  tmp=$(mktemp "$dir/.quota.json.XXXXXX") || fail "cannot create a temp file in $dir"
  printf '%s\n' "$1" >"$tmp" || {
    rm -f "$tmp"
    fail "cannot write $QUOTA_FILE"
  }
  ownsQuotaLock || {
    rm -f "$tmp"
    fail "the writer lock no longer names this process; snapshot not written, run it again"
  }
  mv "$tmp" "$QUOTA_FILE" || {
    rm -f "$tmp"
    fail "cannot write $QUOTA_FILE"
  }
}

# lockQuotaFile: takes the writer lock, so two recorders, such as the status
# line and the owner, never lose each other's snapshot. The lock is a
# symlink whose target is the owner's pid: `ln -s` creates it atomically
# (it fails if anything exists at the path), so the lock and its owner token
# are one step and can never disagree (R-109 r4).
#
# A lock is broken only when its owner process is dead. A live owner keeps
# it however long it has been stalled (a sleeping laptop, a stopped process),
# and the waiter fails loudly after about five seconds instead of risking an
# overwrite; round 1 to 4 reviews showed every age-based rule loses writes to
# a live but slow holder. Breaking takes a second pid lock, `.lock.break`,
# and re-reads the lock inside it, removing it only while it still names the
# same dead pid. A break lock whose owner is dead is cleared the same way.
# Anything at either path that is not a pid symlink is never deleted: the
# writer fails and names it. A recycled pid makes a dead lock read as live,
# which fails closed (the waiter stops and names the pid).
#
# Accepted residuals, each failing loudly rather than losing a write: pids
# are judged in the local pid namespace, so the quota file is per host and
# per container, and a holder in another namespace reads as dead or as a
# recycled pid; clearing a dead break lock re-reads it before removing it but
# is not atomic, so two waiters clearing the same dead breaker in the same
# instant can briefly both hold it, after which the displaced writer fails at
# the ownership check before its write.
lockQuotaFile() {
  local lock="$QUOTA_FILE.lock" brk="$QUOTA_FILE.lock.break" tries=0 owner
  mkdir -p "$(dirname "$QUOTA_FILE")" || fail "cannot create $(dirname "$QUOTA_FILE")"
  until claimPidLink "$lock"; do
    tries=$((tries + 1))
    owner=$(lockOwner "$lock") ||
      fail "$lock exists and is not a quota-pace lock; remove it by hand if nothing is writing $QUOTA_FILE"
    if [ "$tries" -gt 50 ]; then
      if [ -L "$brk" ] || [ -e "$brk" ]; then
        fail "the quota file is locked ($lock, pid $owner) and a break lock is held ($brk)"
      fi
      fail "the quota file is locked by a running process (pid $owner, $lock)"
    fi
    if [ -n "$owner" ] && isDeadPid "$owner"; then
      breakDeadLock "$lock" "$owner" "$brk" && continue
    fi
    sleep 0.1
  done
  trap 'releaseQuotaLock' EXIT
}

# claimPidLink <path>: creates a symlink at the path naming this process and
# succeeds only when the link it made is the object at that path. `ln -s`
# into an existing directory, or a symlink to one, creates the link inside
# it and reports success, which would let every waiter think it held the
# lock (R-109 r5); such a path is refused before and verified after, and a
# link that landed inside a directory is removed again.
claimPidLink() {
  local path="$1"
  if [ -d "$path" ]; then
    fail "$path is a directory, not a quota-pace lock; remove it by hand if nothing is writing $QUOTA_FILE"
  fi
  ln -sn "$$" "$path" 2>/dev/null || return 1
  if [ ! -L "$path" ] || [ "$(readlink "$path" 2>/dev/null)" != "$$" ]; then
    [ -L "$path/$$" ] && rm -f "$path/$$"
    fail "$path is not a quota-pace lock; remove it by hand if nothing is writing $QUOTA_FILE"
  fi
  return 0
}

# lockOwner <path>: prints the pid a lock symlink names (empty when the lock
# vanished meanwhile) and fails when the path holds anything other than a
# pid symlink.
lockOwner() {
  local target
  if [ -L "$1" ]; then
    target=$(readlink "$1" 2>/dev/null) || return 0
    [[ "$target" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s\n' "$target"
  elif [ -e "$1" ]; then
    return 1
  fi
  return 0
}

# procHidesPids: succeeds when /proc is mounted with hidepid (or a value
# other than 0), which hides other users' live processes, so a missing
# /proc/<pid> proves nothing there (R-109 r6). An unreadable mounts file
# counts as hiding. QUOTA_PROC_MOUNTS names another mounts file for tests;
# any value it can take only moves the check toward ps or "alive".
procHidesPids() {
  local mounts="${QUOTA_PROC_MOUNTS:-/proc/mounts}"
  [ -r "$mounts" ] || return 0
  awk '$2 == "/proc" && $3 == "proc" { print $4 }' "$mounts" 2>/dev/null |
    grep -Eq '(^|,)hidepid=([1-9]|invisible|noaccess|ptraceable)'
}

# isDeadPid <pid>: succeeds only when no process with that pid exists. A
# process owned by another user makes kill -0 fail with EPERM, so a failed
# kill -0 is confirmed through /proc where it exists and shows every pid,
# else through a working ps; with neither, the pid counts as alive, failing
# closed (R-109 r5, r6).
isDeadPid() {
  kill -0 "$1" 2>/dev/null && return 1
  if [ -d /proc/self ] && ! procHidesPids; then
    [ ! -d "/proc/$1" ]
  elif ps -p "$$" >/dev/null 2>&1; then
    ! ps -p "$1" >/dev/null 2>&1
  else
    return 1
  fi
}

# breakDeadLock <lock> <dead pid> <break lock>: removes the lock while
# holding the break lock, only if it still names the same dead pid. Clears a
# break lock whose own owner is dead. Succeeds when the lock was removed.
breakDeadLock() {
  local lock="$1" dead="$2" brk="$3" brkOwner removed=1
  if claimPidLink "$brk"; then
    [ "$(lockOwner "$lock" 2>/dev/null)" = "$dead" ] && rm -f "$lock" && removed=0
    rm -f "$brk"
    return $removed
  fi
  brkOwner=$(lockOwner "$brk") ||
    fail "$brk exists and is not a quota-pace break lock; remove it by hand if nothing is writing $QUOTA_FILE"
  if [ -n "$brkOwner" ] && isDeadPid "$brkOwner" && [ "$(lockOwner "$brk" 2>/dev/null)" = "$brkOwner" ]; then
    rm -f "$brk"
  fi
  return 1
}

# ownsQuotaLock: succeeds while the writer lock names this process. Since a
# live owner's lock is never broken, this holds from acquisition to release;
# it is checked before the write as a last guard all the same.
ownsQuotaLock() {
  [ "$(readlink "$QUOTA_FILE.lock" 2>/dev/null)" = "$$" ]
}

# releaseQuotaLock: removes the writer lock on exit while it names this
# process.
releaseQuotaLock() {
  ownsQuotaLock && rm -f "$QUOTA_FILE.lock"
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
      --*) [ $# -ge 2 ] || fail "option $1 needs a value" ;;
    esac
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
  [ -z "$provider" ] || [[ "$provider" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail "provider '$provider' must be lowercase letters, digits, - or _"
  [[ "$source" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail "source '$source' must be lowercase letters, digits, - or _"
  [[ "$used" =~ ^[0-9]+([.][0-9]+)?$ ]] && jq -en --argjson u "$used" '$u <= 100' >/dev/null ||
    fail "usedPct '$used' must be a number from 0 to 100"
  [ -z "$window" ] || { [[ "$window" =~ ^[1-9][0-9]{0,2}$ ]] && [ "$window" -le 366 ]; } ||
    fail "--window-days '$window' must be a whole number of days from 1 to 366"

  local current now
  now=$(nowEpoch) || exit 1
  lockQuotaFile
  if [ -f "$QUOTA_FILE" ] && jq -e '.buckets | type == "object" and length == 0' "$QUOTA_FILE" >/dev/null 2>&1; then
    current='{"buckets":{}}'
  elif [ -f "$QUOTA_FILE" ]; then
    current=$(readQuotaFile) || exit 1
  else
    current='{"buckets":{}}'
  fi
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
  now=$(nowEpoch) || exit 1
  jq "$JQ_LIB"'
    ($now | tonumber) as $now
    | ($staleH | tonumber * 3600) as $staleS
    | def round2: (. * 100 | round) / 100;
      def checkName($what): if type == "string" and test("^[a-z0-9][a-z0-9_-]*$") then .
        else error("\($what) \(tojson) must be lowercase letters, digits, - or _") end;
      def checkBucket($name):
        ($name | checkName("bucket name")) as $_
        | ((.provider // $name) | checkName("provider")) as $_
        | if ((.windowDays // 7) | type) == "number" and (.windowDays // 7) > 0 and (.windowDays // 7) <= 366 then .
          else error("bucket \($name): windowDays must be a number of days from 1 to 366") end
        | ([(.snapshots // [])[] | (.source // "owner") | checkName("snapshot source")] | length) as $_
        | if all((.snapshots // [])[]; (.usedPct | type) == "number" and .usedPct >= 0 and .usedPct <= 100) then .
          else error("bucket \($name): every usedPct must be a number from 0 to 100") end;
      def bucketReport($name):
        checkBucket($name)
        | (.windowDays // 7) as $wd
        | (.resetsAt | toEpoch) as $reset
        | ($reset - $wd * 86400) as $start
        | ([(.snapshots // [])[] | {at: (.at | toEpoch), used: .usedPct, source: (.source // "owner")}
            | select(.at >= $start and .at <= $now)] | sort_by(.at)) as $snaps
        | {bucket: $name, provider: (.provider // $name), resetsAt: .resetsAt}
        + if $reset <= $now then
            {status: "window-rolled", stale: false, paceRatio: null, exhausted: false,
             note: "the reset time has passed; record a snapshot with the new --resets-at"}
          elif ($snaps | length) == 0 then
            {status: "no-data", stale: false, paceRatio: null, exhausted: false,
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
            | (($now - $last.at) > $staleS) as $stale
            | {status: (if $stale then "stale" else "ok" end),
               stale: $stale,
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
         ratioComplete: all(.[] | select(.status == "ok"); .paceRatio != null),
         paceRatio: (if all(.[] | select(.status == "ok"); .paceRatio != null)
                     then ([.[] | select(.status == "ok") | .paceRatio] | max)
                     else null end),
         worstBucket: ((map(select(.status == "ok" and .paceRatio != null)) | max_by(.paceRatio) | .bucket) // null),
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
    [[ "$STALE_HOURS" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "QUOTA_STALE_HOURS '$STALE_HOURS' must be a non-negative number of hours"
    quota=$(readQuotaFile) || exit 1
    report=$(reportJson <<<"$quota" 2>&1) || fail "cannot compute the report: $report"
    case "${1:-}" in
      "") reportText "$report" ;;
      --json) printf '%s\n' "$report" ;;
      *) fail "unknown report option '$1'" ;;
    esac
    ;;
  *)
    fail "usage: quota-pace.sh record <bucket> <usedPct> [options] | report [--json]"
    ;;
esac
