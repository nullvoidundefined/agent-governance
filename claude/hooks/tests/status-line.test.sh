#!/usr/bin/env bash
# Verifies status-line.sh (hardening spec B-5): renders the HUD line from the
# documented statusLine stdin JSON, degrades every missing field to a
# placeholder, and exits 0 on every path including broken input. Hermetic:
# fabricated payloads and a mktemp git repo for the branch field.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SL="$SCRIPT_DIR/../../status-line.sh"

fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi; }
rendersAllFields() { # payload-json, expected-grep
  local out; out=$(printf '%s' "$1" | bash "$SL") || return 1
  grep -qE "$2" <<<"$out"
}
exitsZeroOnGarbage() { printf '%s' "$1" | bash "$SL" >/dev/null 2>&1; }
modelSurvivesMalformedField() { # payload-json, expected-placeholder-grep
  local out; out=$(printf '%s' "$1" | bash "$SL") || return 1
  grep -qE '^keepme \|' <<<"$out" && grep -qE "$2" <<<"$out"
}
allNumericFieldsDegradeIndividually() { # payload-json
  local out; out=$(printf '%s' "$1" | bash "$SL") || return 1
  grep -qE '^keepme \|' <<<"$out" && grep -qE 'ctx - ' <<<"$out" \
    && grep -qE '\$- ' <<<"$out" && grep -qE '5h -%' <<<"$out"
}

REPO=$(mktemp -d); trap 'rm -rf "$REPO"' EXIT
git -C "$REPO" init -q -b probe-branch
FULL=$(jq -n --arg cwd "$REPO" '{model:{display_name:"opusplan"},context_window:{used_percentage:42.7},cwd:$cwd,cost:{total_cost_usd:1.2345,total_duration_ms:5400000},rate_limits:{five_hour:{used_percentage:12}}}')
check "full payload renders model" rendersAllFields "$FULL" '^opusplan \|'
check "full payload renders branch" rendersAllFields "$FULL" 'probe-branch'
check "full payload renders ctx percent" rendersAllFields "$FULL" 'ctx 43%'
check "full payload renders cost" rendersAllFields "$FULL" '\$1\.23'
check "full payload renders elapsed" rendersAllFields "$FULL" '1h30m'
check "full payload renders rate limit" rendersAllFields "$FULL" '5h 12%'
: >"$REPO/dirty-file"
check "dirty repo shows the marker" rendersAllFields "$FULL" 'probe-branch\*'
NULLS='{"model":{"display_name":"opusplan"},"context_window":{"used_percentage":null},"cwd":"/nonexistent-dir","cost":{"total_cost_usd":null,"total_duration_ms":0}}'
# Anchored on the payload's model name ("opusplan") at line start (review
# round 1, Minor finding): the bare fallback line ("claude | - | ctx - | $- |
# - | 5h -%") also matches "ctx - ", "$- ", and "| - |" as plain substrings,
# so an un-anchored regex here cannot tell a correctly degraded field apart
# from a regression that collapses the whole line to emit_fallback.
# Anchoring on "^opusplan \|" requires the real per-field degradation path,
# since the fallback line always starts with the literal "claude", never the
# payload's model name.
check "null ctx degrades to placeholder" rendersAllFields "$NULLS" '^opusplan \|.*ctx - '
check "null cost degrades to placeholder" rendersAllFields "$NULLS" '^opusplan \|.*\$- '
check "no-repo cwd degrades branch to placeholder" rendersAllFields "$NULLS" '^opusplan \|.*\| - \|'
check "garbage input still exits 0" exitsZeroOnGarbage 'not json at all'
check "garbage input prints a fallback line" rendersAllFields 'not json at all' 'claude'
check "empty input still exits 0" exitsZeroOnGarbage ''

# Regression (review round 1): a non-numeric value in one numeric field must
# not collapse the whole line to emit_fallback; only that field degrades.
COST_MALFORMED='{"model":{"display_name":"keepme"},"cost":{"total_cost_usd":"not-a-number"}}'
CTX_MALFORMED='{"model":{"display_name":"keepme"},"context_window":{"used_percentage":"not-a-number"}}'
RATE_MALFORMED='{"model":{"display_name":"keepme"},"rate_limits":{"five_hour":{"used_percentage":"not-a-number"}}}'
ALL_MALFORMED='{"model":{"display_name":"keepme"},"context_window":{"used_percentage":"nope"},"cost":{"total_cost_usd":"nope"},"rate_limits":{"five_hour":{"used_percentage":"nope"}}}'
CTX_INFINITE='{"model":{"display_name":"keepme"},"context_window":{"used_percentage":1e400}}'
check "malformed cost degrades alone, model survives" modelSurvivesMalformedField "$COST_MALFORMED" '\$- '
check "malformed ctx degrades alone, model survives" modelSurvivesMalformedField "$CTX_MALFORMED" 'ctx - '
check "malformed rate degrades alone, model survives" modelSurvivesMalformedField "$RATE_MALFORMED" '5h -%'
check "all malformed numeric fields degrade individually, model survives" allNumericFieldsDegradeIndividually "$ALL_MALFORMED"
check "infinite ctx normalizes to placeholder, model survives" modelSurvivesMalformedField "$CTX_INFINITE" 'ctx - '


# --- Weekly bucket: the 7d figure and the background quota snapshot (IAN-603,
# slice 04 PR 2). Each case uses its own quota file in a temp dir and pins the
# clock with QUOTA_NOW. The record runs in the background, so a write is
# awaited with a bounded poll (about 5 s) and a skip is judged after a fixed
# pause longer than any record takes.
QDIR=$(mktemp -d); trap 'rm -rf "$REPO" "$QDIR"' EXIT
NOW=1790960400            # 2026-10-03T00:00:00+07:00
RESET_EPOCH=1791305940    # 2026-10-06T23:59:00+07:00
waitFor() { # poll a command up to ~5 s (50 x 0.1 s); no reliance on timeout(1)
  local i=0
  while [ "$i" -lt 50 ]; do "$@" && return 0; sleep 0.1; i=$((i + 1)); done
  return 1
}
weekly() { # payload-json, quota-file ; prints the line, preserves exit status
  printf '%s' "$1" | CLAUDE_QUOTA_FILE="$2" QUOTA_NOW="$NOW" bash "$SL"
}
snapshots() { jq -r '[.buckets.claude.snapshots[]?] | length' "$1" 2>/dev/null; }
hasSnapshots() { [ "$(snapshots "$1")" = "$2" ]; }
seven() { jq -n --argjson r "$2" --argjson p "$1" '{model:{display_name:"keepme"},rate_limits:{seven_day:{used_percentage:$p,resets_at:$r}}}'; }
sevenNum() { jq -n --argjson r "$2" --argjson p "$1" '{model:{display_name:"keepme"},rate_limits:{seven_day:{used_percentage:$p,resets_at:$r}}}'; }

# A write: epoch-number resets_at, no quota file yet.
Q="$QDIR/write.json"
out=$(weekly "$(sevenNum 40.4 "$RESET_EPOCH")" "$Q"); rc=$?
check "7d figure shown for a valid weekly bucket" grep -qE '^keepme \|.*\| 5h -% \| 7d 40%$' <<<"$out"
check "valid weekly bucket exits 0" test "$rc" -eq 0
check "valid weekly bucket is recorded in the background" waitFor hasSnapshots "$Q" 1
check "recorded snapshot carries the statusline source, percent and reset" \
  jq -e '.buckets.claude.snapshots[0] | .source == "statusline" and .usedPct == 40.4' "$Q" >/dev/null
check "recorded reset time is the converted epoch" \
  test "$(jq -r '.buckets.claude.resetsAt' "$Q")" = "2026-10-06T16:59:00Z"

# resets_at as a digit string and as an ISO string with an offset.
Q="$QDIR/forms.json"
weekly "$(seven 10 "\"$RESET_EPOCH\"")" "$Q" >/dev/null
check "digit-string resets_at is recorded" waitFor hasSnapshots "$Q" 1
Q="$QDIR/iso.json"
weekly "$(seven 11 '"2026-10-06T23:59:00+07:00"')" "$Q" >/dev/null
check "ISO resets_at is recorded" waitFor hasSnapshots "$Q" 1
check "ISO resets_at keeps its instant" test "$(jq -r '.buckets.claude.resetsAt' "$Q")" = "2026-10-06T16:59:00Z"

# Throttle: a snapshot younger than 30 minutes, from any source, skips the record.
Q="$QDIR/throttle.json"
mkQuota() { # source, minutes-ago
  jq -n --arg s "$1" --argjson at $((NOW - $2 * 60)) \
    '{buckets:{claude:{provider:"claude",resetsAt:"2026-10-06T16:59:00Z",windowDays:7,snapshots:[{at:($at|todate),usedPct:30,source:$s}]}}}' >"$Q"
}
mkQuota owner 10
out=$(weekly "$(sevenNum 40 "$RESET_EPOCH")" "$Q"); rc=$?
check "throttled run still prints the 7d figure" grep -q '7d 40%$' <<<"$out"
check "throttled run exits 0" test "$rc" -eq 0
sleep 1
check "a 10-minute-old owner snapshot throttles the record" hasSnapshots "$Q" 1
mkQuota statusline 10
weekly "$(sevenNum 40 "$RESET_EPOCH")" "$Q" >/dev/null
sleep 1
check "a 10-minute-old statusline snapshot throttles the record" hasSnapshots "$Q" 1
mkQuota owner 31
weekly "$(sevenNum 40 "$RESET_EPOCH")" "$Q" >/dev/null
check "a 31-minute-old snapshot no longer throttles" waitFor hasSnapshots "$Q" 2
mkQuota owner 31
printf '%s' "$(sevenNum 40 "$RESET_EPOCH")" | QUOTA_RECORD_MIN_MINUTES=5 CLAUDE_QUOTA_FILE="$Q" QUOTA_NOW="$NOW" bash "$SL" >/dev/null
check "QUOTA_RECORD_MIN_MINUTES=5 lets a 31-minute-old snapshot through" waitFor hasSnapshots "$Q" 2
mkQuota owner 10
printf '%s' "$(sevenNum 40 "$RESET_EPOCH")" | QUOTA_RECORD_MIN_MINUTES=5 CLAUDE_QUOTA_FILE="$Q" QUOTA_NOW="$NOW" bash "$SL" >/dev/null
check "QUOTA_RECORD_MIN_MINUTES=5 lets a 10-minute-old snapshot through" waitFor hasSnapshots "$Q" 2

# Malformed weekly fields: the line prints, exits 0, shows no 7d, records nothing.
malformedOk() { [ "$1" -eq 0 ] && [ ! -e "$2" ] && grep -qE '^keepme \|.*\| 5h -%$' <<<"$3"; }
malformed() { # name, payload
  local q="$QDIR/malformed.json" o r
  rm -f "$q"
  o=$(weekly "$2" "$q"); r=$?
  sleep 1
  check "malformed weekly ($1): line prints, exit 0, no 7d, no record" \
    malformedOk "$r" "$q" "$o"
}
malformed "percent is text" "$(seven '"abc"' "\"$RESET_EPOCH\"")"
malformed "percent above 100" "$(sevenNum 101 "$RESET_EPOCH")"
malformed "percent negative" "$(sevenNum -1 "$RESET_EPOCH")"
malformed "reset is text" "$(seven 40 '"soon"')"
malformed "reset is an ISO date with no zone" "$(seven 40 '"2026-10-06T23:59:00"')"
malformed "reset is missing" '{"model":{"display_name":"keepme"},"rate_limits":{"seven_day":{"used_percentage":40}}}'
malformed "percent is missing" "$(jq -n --arg r "$RESET_EPOCH" '{model:{display_name:"keepme"},rate_limits:{seven_day:{resets_at:$r}}}')"
malformed "seven_day is not an object" '{"model":{"display_name":"keepme"},"rate_limits":{"seven_day":"x"}}'

# An unwritable quota file (its parent is a regular file): the line prints and
# exits 0 whatever the background record does.
: >"$QDIR/afile"
out=$(weekly "$(sevenNum 40 "$RESET_EPOCH")" "$QDIR/afile/quota.json"); rc=$?
sleep 1
check "unwritable quota file: line prints with the 7d figure" grep -qE '^keepme \|.*\| 7d 40%$' <<<"$out"
check "unwritable quota file: exit 0" test "$rc" -eq 0
check "unwritable quota file: nothing is created" test ! -e "$QDIR/afile/quota.json"
# A quota file that is not JSON also never breaks the line.
printf 'not json' >"$QDIR/garbage.json"
out=$(weekly "$(sevenNum 40 "$RESET_EPOCH")" "$QDIR/garbage.json"); rc=$?
sleep 1
check "corrupt quota file: line prints, exit 0" test "$rc" -eq 0 -a -n "$out"
check "corrupt quota file is left untouched" test "$(cat "$QDIR/garbage.json")" = "not json"

# A quota file the recorder cannot use starts no recorder. Without this check
# every render would start one doomed process, since an unreadable file has no
# snapshot to throttle on (PR 185 review). A stub recorder counts the starts;
# the first case is the control: a missing file in a writable directory starts one.
STUB="$QDIR/stub"; mkdir -p "$STUB/enforce"; cp "$SL" "$STUB/status-line.sh"
printf '#!/usr/bin/env bash\necho started >>"%s/starts"\n' "$STUB" >"$STUB/enforce/quota-pace.sh"; chmod +x "$STUB/enforce/quota-pace.sh"
recorderStarts() { # quota-file ; renders twice, prints how many recorders started
  rm -f "$STUB/starts"
  for _ in 1 2; do printf '%s' "$(sevenNum 40 "$RESET_EPOCH")" | CLAUDE_QUOTA_FILE="$1" QUOTA_NOW="$NOW" bash "$STUB/status-line.sh" >/dev/null 2>&1; done
  sleep 1; if [ -f "$STUB/starts" ]; then wc -l <"$STUB/starts" | tr -d ' '; else echo 0; fi
}
check "missing quota file in a writable dir: the recorder starts" test "$(recorderStarts "$QDIR/fresh/quota.json")" = "2"
check "corrupt quota file: no recorder starts" test "$(recorderStarts "$QDIR/garbage.json")" = "0"
check "quota file under a regular file: no recorder starts" test "$(recorderStarts "$QDIR/afile/quota.json")" = "0"

[ "$fail" -eq 0 ] && echo "status-line.test.sh PASS" || exit 1
