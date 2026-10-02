#!/usr/bin/env bash
# Covers: enforce/quota-pace.sh
# quota-pace.test.sh: verifies the quota input and pace calculator behind
# quota-aware routing (IAN-603). Every case writes its own quota file in a
# temp directory through CLAUDE_QUOTA_FILE and pins the clock with QUOTA_NOW,
# so no case reads the live ~/.claude/quota.json or depends on the date. The
# first case is the owner's 2026-10-02 snapshot (Asia/Bangkok), whose ratios
# were worked by hand before the script existed: Claude 1.63, Fable 0.93,
# Codex 0.53.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
SCRIPT="$CLAUDE_HARNESS_ROOT/enforce/quota-pace.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_QUOTA_FILE="$WORK/quota.json"

# 2026-10-03T00:00:00+07:00, the moment of the owner's snapshot.
NOW_OWNER=1790960400
HOUR=3600

failCase() {
  echo "FAIL: $1"
  exit 1
}

# field <jq path>: runs report --json at QUOTA_NOW and prints one value.
field() {
  bash "$SCRIPT" report --json | jq -r "$1"
}

# --- 1. The owner's snapshot reproduces the hand-worked ratios. ---
cp "$CLAUDE_HARNESS_ROOT/quota.template.json" "$CLAUDE_QUOTA_FILE"
export QUOTA_NOW=$NOW_OWNER
[ "$(field '.buckets[] | select(.bucket=="claude") | .paceRatio')" = "1.63" ] || failCase "claude ratio, want 1.63"
[ "$(field '.buckets[] | select(.bucket=="claude-fable") | .paceRatio')" = "0.93" ] || failCase "fable ratio, want 0.93"
[ "$(field '.buckets[] | select(.bucket=="codex") | .paceRatio')" = "0.53" ] || failCase "codex ratio, want 0.53"
[ "$(field '.buckets[] | select(.bucket=="claude") | .dailyBudget')" = "11.25" ] || failCase "claude daily budget, want 11.25"
[ "$(field '.buckets[] | select(.bucket=="claude") | .burnMethod')" = "window-average" ] || failCase "one snapshot must fall back to window-average"
# Provider ratio is the worst bucket's: Claude all-models, not Fable.
[ "$(field '.providers[] | select(.provider=="claude") | .paceRatio')" = "1.63" ] || failCase "claude provider ratio must be its worst bucket"
[ "$(field '.providers[] | select(.provider=="claude") | .worstBucket')" = "claude" ] || failCase "claude worst bucket"
# 45% left at 18.33/day is about 2.46 days: shift-worthy, not exhausted.
[ "$(field '.providers[] | select(.provider=="claude") | .exhausted')" = "false" ] || failCase "claude must not be exhausted at 2.46 days left"
[ "$(field '.providers[] | select(.provider=="codex") | .exhausted')" = "false" ] || failCase "codex must not be exhausted"
# The human table prints both providers.
bash "$SCRIPT" report | grep -q '^provider codex: ratio 0.53' || failCase "text report lacks the codex provider line"

# --- 2. Trailing burn: a pair 12h+ apart wins over the window average. ---
rm -f "$CLAUDE_QUOTA_FILE"
bash "$SCRIPT" record codex 10 --resets-at 2026-10-08T10:57:00+07:00 --at 2026-10-02T00:00:00+07:00
bash "$SCRIPT" record codex 13 --at 2026-10-03T00:00:00+07:00
# 3 points over 1 day: burn 3/day, against a window average of about 8.4.
[ "$(field '.buckets[0].burnMethod')" = "trailing" ] || failCase "two snapshots 24h apart must use trailing burn"
[ "$(field '.buckets[0].burn')" = "3" ] || failCase "trailing burn, want 3"
# A third snapshot only 6h after the second still pairs with the first.
bash "$SCRIPT" record codex 14 --at 2026-10-03T06:00:00+07:00
QUOTA_NOW=$((NOW_OWNER + 6 * HOUR))
export QUOTA_NOW
[ "$(field '.buckets[0].burn')" = "3.2" ] || failCase "trailing burn must pair with the snapshot 12h+ older (4 points over 1.25 days)"
# Snapshots under 12h apart and nothing older: window average.
rm -f "$CLAUDE_QUOTA_FILE"
bash "$SCRIPT" record codex 12 --resets-at 2026-10-08T10:57:00+07:00 --at 2026-10-02T18:00:00+07:00
bash "$SCRIPT" record codex 13 --at 2026-10-03T00:00:00+07:00
export QUOTA_NOW=$NOW_OWNER
[ "$(field '.buckets[0].burnMethod')" = "window-average" ] || failCase "a pair under 12h apart must not count as trailing"

# --- 3. Exhaustion: under one day left at burn, or 90% used. ---
rm -f "$CLAUDE_QUOTA_FILE"
# 85% used, 3 days into the window: burn 28.3/day, 15% left is 0.53 days.
bash "$SCRIPT" record claude 85 --resets-at 2026-10-06T23:59:00+07:00 --at 2026-10-03T00:00:00+07:00
[ "$(field '.buckets[0].exhausted')" = "true" ] || failCase "under one day left at burn must be exhausted"
rm -f "$CLAUDE_QUOTA_FILE"
# 90% used reads exhausted even with a slow burn.
bash "$SCRIPT" record claude 90 --resets-at 2026-10-06T23:59:00+07:00 --window-days 30 --at 2026-10-03T00:00:00+07:00
[ "$(field '.buckets[0].exhausted')" = "true" ] || failCase "90% used must be exhausted"
# The reset-sooner clause, at 89% used so the 90% rule stays out of it.
# Window 2026-09-29T23:59 to 2026-10-06T23:59 +07:00 (epoch below).
RESET_CLAUDE=1791305940
START_CLAUDE=$((RESET_CLAUDE - 7 * 24 * HOUR))
# Six days in: burn 14.83/day, 11% left is 0.74 days, reset 1.0 day away.
rm -f "$CLAUDE_QUOTA_FILE"
export QUOTA_NOW=$((START_CLAUDE + 6 * 24 * HOUR))
bash "$SCRIPT" record claude 89 --resets-at 2026-10-06T23:59:00+07:00 --at "$QUOTA_NOW"
[ "$(field '.buckets[0].exhausted')" = "true" ] || failCase "0.74 days left at burn with the reset 1 day away must be exhausted"
# Three hours before reset: 0.85 days left at burn, but the reset is sooner.
rm -f "$CLAUDE_QUOTA_FILE"
export QUOTA_NOW=$((RESET_CLAUDE - 3 * HOUR))
bash "$SCRIPT" record claude 89 --resets-at 2026-10-06T23:59:00+07:00 --at "$QUOTA_NOW"
[ "$(field '.buckets[0].projectedDaysLeft < 1')" = "true" ] || failCase "setup: projected days left must be under 1"
[ "$(field '.buckets[0].exhausted')" = "false" ] || failCase "a reset that lands before run-out must not read exhausted"
# 100% used: no ratio (no budget left), exhausted, never a division error.
rm -f "$CLAUDE_QUOTA_FILE"
export QUOTA_NOW=$NOW_OWNER
bash "$SCRIPT" record claude 100 --resets-at 2026-10-06T23:59:00+07:00 --at 2026-10-03T00:00:00+07:00
[ "$(field '.buckets[0].paceRatio')" = "null" ] || failCase "100% used must give a null ratio"
[ "$(field '.buckets[0].exhausted')" = "true" ] || failCase "100% used must be exhausted"

# --- 4. Stale snapshots and rolled windows are flagged, never trusted. ---
rm -f "$CLAUDE_QUOTA_FILE"
bash "$SCRIPT" record codex 13 --resets-at 2026-10-08T10:57:00+07:00 --at 2026-10-03T00:00:00+07:00
QUOTA_NOW=$((NOW_OWNER + 25 * HOUR))
export QUOTA_NOW
[ "$(field '.buckets[0].status')" = "stale" ] || failCase "a 25h-old snapshot must read stale"
[ "$(QUOTA_STALE_HOURS=48 field '.buckets[0].status')" = "ok" ] || failCase "QUOTA_STALE_HOURS must widen the stale window"
# 2026-10-08T11:00:00+07:00, three minutes after the codex reset.
export QUOTA_NOW=1791432000
[ "$(field '.buckets[0].status')" = "window-rolled" ] || failCase "a passed reset must read window-rolled"
[ "$(field '.buckets[0].paceRatio')" = "null" ] || failCase "a rolled window must give no ratio"
[ "$(field '.providers[0].status')" = "no-usable-data" ] || failCase "a provider with only a rolled bucket has no usable data"

# --- 5. A new reset time drops the previous window's snapshots. ---
bash "$SCRIPT" record codex 2 --resets-at 2026-10-15T10:57:00+07:00 --at 2026-10-08T11:00:00+07:00
[ "$(jq '.buckets.codex.snapshots | length' "$CLAUDE_QUOTA_FILE")" = "1" ] || failCase "a new window must drop the old window's snapshots"
[ "$(field '.buckets[0].status')" = "ok" ] || failCase "the new window must report ok"

# --- 6. Bad input fails loudly; nothing reads as zero usage. ---
rm -f "$CLAUDE_QUOTA_FILE"
if bash "$SCRIPT" report >/dev/null 2>&1; then failCase "a missing quota file must exit nonzero"; fi
{ bash "$SCRIPT" report 2>&1 || true; } | grep -q "no quota file" || failCase "a missing file must say so"
echo '{"nope":1}' >"$CLAUDE_QUOTA_FILE"
if bash "$SCRIPT" report >/dev/null 2>&1; then failCase "a file without buckets must exit nonzero"; fi
rm -f "$CLAUDE_QUOTA_FILE"
if bash "$SCRIPT" record codex 13 >/dev/null 2>&1; then failCase "a new bucket without --resets-at must fail"; fi
[ ! -f "$CLAUDE_QUOTA_FILE" ] || failCase "a failed record must not create the file"
if bash "$SCRIPT" record codex 130 --resets-at 2026-10-08T10:57:00+07:00 >/dev/null 2>&1; then failCase "usedPct over 100 must fail"; fi
if bash "$SCRIPT" record codex 13 --resets-at 'next tuesday' >/dev/null 2>&1; then failCase "an unparseable reset must fail"; fi
if bash "$SCRIPT" record 'Codex!' 13 --resets-at 2026-10-08T10:57:00+07:00 >/dev/null 2>&1; then failCase "a bad bucket name must fail"; fi

# --- 7. Offsets parse to the same instant as Z. ---
# A snapshot two hours into the window survives re-recording the same reset
# in another offset form. Were an offset ignored, the reset would read as a
# different instant, the window start would move by hours, and the snapshot
# would be dropped as belonging to an older window.
rm -f "$CLAUDE_QUOTA_FILE"
export QUOTA_NOW=$((START_CLAUDE + 3 * HOUR))
bash "$SCRIPT" record claude 1 --resets-at 2026-10-06T16:59:00Z --at $((START_CLAUDE + 2 * HOUR))
bash "$SCRIPT" record claude 2 --resets-at 2026-10-06T23:59:00+07:00 --at "$QUOTA_NOW"
bash "$SCRIPT" record claude 2 --resets-at 2026-10-06T11:59:00-05:00 --at "$QUOTA_NOW"
bash "$SCRIPT" record claude 2 --resets-at 2026-10-06T23:59+0700 --at "$QUOTA_NOW"
[ "$(jq '.buckets.claude.snapshots | length' "$CLAUDE_QUOTA_FILE")" = "4" ] || failCase "the same reset in Z, +07:00, -05:00 and +0700 (no seconds) must not open a new window"
[ "$(field '.buckets[0].status')" = "ok" ] || failCase "offset forms must keep the window current"

echo "PASS: quota-pace"
