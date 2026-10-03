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

# Trailing burn pairs with the MOST RECENT snapshot at least 12h older: of
# two qualifying snapshots at different rates, the nearer one decides.
rm -f "$CLAUDE_QUOTA_FILE"
export QUOTA_NOW=$NOW_OWNER
bash "$SCRIPT" record codex 0 --resets-at 2026-10-08T10:57:00+07:00 --at $((NOW_OWNER - 48 * HOUR))
bash "$SCRIPT" record codex 10 --at $((NOW_OWNER - 24 * HOUR))
bash "$SCRIPT" record codex 12 --at "$NOW_OWNER"
# Most recent qualifying (24h back): 2 points over 1 day = 2. Oldest would give 6.
[ "$(field '.buckets[0].burn')" = "2" ] || failCase "trailing burn must pair with the most recent snapshot 12h+ older"
# A correction downward clamps burn to 0, never a negative burn.
bash "$SCRIPT" record codex 5 --at $((NOW_OWNER + 13 * HOUR))
export QUOTA_NOW=$((NOW_OWNER + 13 * HOUR))
[ "$(field '.buckets[0].burn')" = "0" ] || failCase "a drop in used percent must clamp burn to 0"
# Under an hour into the window there is no burn to judge: method reads
# insufficient and the ratio is null, never a ratio from a near-zero divisor.
rm -f "$CLAUDE_QUOTA_FILE"
export QUOTA_NOW=$((1791432000 + 30 * 60))
bash "$SCRIPT" record codex 1 --resets-at 2026-10-15T10:57:00+07:00 --at "$QUOTA_NOW"
[ "$(field '.buckets[0].burnMethod')" = "insufficient" ] || failCase "under an hour into the window must read insufficient"
[ "$(field '.buckets[0].paceRatio')" = "null" ] || failCase "an insufficient burn must give a null ratio"
export QUOTA_NOW=$NOW_OWNER

# A provider whose current bucket has no ratio (100% used) must not read as
# the ratio of its other buckets: its paceRatio is null and ratioComplete
# false, so a caller reading the ratio alone cannot see a healthy provider.
rm -f "$CLAUDE_QUOTA_FILE"
bash "$SCRIPT" record claude 100 --resets-at 2026-10-06T23:59:00+07:00 --at "$NOW_OWNER"
bash "$SCRIPT" record claude-fable 10 --provider claude --resets-at 2026-10-06T23:59:00+07:00 --at "$NOW_OWNER"
[ "$(field '.buckets[] | select(.bucket=="claude-fable") | .paceRatio != null')" = "true" ] || failCase "setup: the fable bucket must have a ratio"
[ "$(field '.providers[0].paceRatio')" = "null" ] || failCase "a provider with a 100%-used bucket must not report its other bucket's ratio"
[ "$(field '.providers[0].ratioComplete')" = "false" ] || failCase "the provider must say its ratio is incomplete"
[ "$(field '.providers[0].exhausted')" = "true" ] || failCase "the provider must read exhausted"
rm -f "$CLAUDE_QUOTA_FILE"
cp "$CLAUDE_HARNESS_ROOT/quota.template.json" "$CLAUDE_QUOTA_FILE"
[ "$(field '.providers[] | select(.provider=="claude") | .ratioComplete')" = "true" ] || failCase "a provider with every current bucket rated must read ratioComplete true"

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
[ "$(field '.buckets[0].stale')" = "true" ] || failCase "a stale bucket must carry stale: true"
[ "$(field '.providers[0].paceRatio')" = "null" ] || failCase "a stale bucket must not set the provider ratio"
[ "$(field '.buckets[0].paceRatio != null')" = "true" ] || failCase "setup: the stale bucket itself still shows its ratio"
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
echo '{"buckets":{}}' >"$CLAUDE_QUOTA_FILE"
if bash "$SCRIPT" report >/dev/null 2>&1; then failCase "an empty buckets object must exit nonzero"; fi
rm -f "$CLAUDE_QUOTA_FILE"
if bash "$SCRIPT" record codex 13 >/dev/null 2>&1; then failCase "a new bucket without --resets-at must fail"; fi
[ ! -f "$CLAUDE_QUOTA_FILE" ] || failCase "a failed record must not create the file"
if bash "$SCRIPT" record codex 130 --resets-at 2026-10-08T10:57:00+07:00 >/dev/null 2>&1; then failCase "usedPct over 100 must fail"; fi
if bash "$SCRIPT" record codex 13 --resets-at 'next tuesday' >/dev/null 2>&1; then failCase "an unparseable reset must fail"; fi
if bash "$SCRIPT" record 'Codex!' 13 --resets-at 2026-10-08T10:57:00+07:00 >/dev/null 2>&1; then failCase "a bad bucket name must fail"; fi

# --- 7. Concurrent recorders never lose a snapshot. ---
rm -f "$CLAUDE_QUOTA_FILE"
export QUOTA_NOW=$NOW_OWNER
bash "$SCRIPT" record codex 1 --resets-at 2026-10-08T10:57:00+07:00 --at $((NOW_OWNER - 20 * HOUR))
pids=""
for i in 2 3 4 5 6 7 8 9; do
  bash "$SCRIPT" record codex "$i" --at $((NOW_OWNER - (20 - i) * HOUR)) &
  pids="$pids $!"
done
for p in $pids; do wait "$p" || failCase "a concurrent record failed"; done
[ "$(jq '.buckets.codex.snapshots | length' "$CLAUDE_QUOTA_FILE")" = "9" ] || failCase "concurrent records must all land (want 9 snapshots)"
[ ! -e "$CLAUDE_QUOTA_FILE.lock" ] && [ ! -L "$CLAUDE_QUOTA_FILE.lock" ] || failCase "the writer lock must be released"

# --- 9. Insecure values: the option parser and the lock (R-109 r1). ---
# expectFail <description> <command...>: the command must exit nonzero within
# ten seconds; a hang (timeout's 124) is a failure of its own.
expectFail() {
  local what="$1" rc=0
  shift
  timeout 10 "$@" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 124 ] || failCase "$what: hung"
  [ "$rc" -ne 0 ] || failCase "$what: exited 0"
}
rm -rf "$CLAUDE_QUOTA_FILE" "$CLAUDE_QUOTA_FILE.lock"
export QUOTA_NOW=$NOW_OWNER
for flag in --resets-at --provider --window-days --at --source; do
  expectFail "a dangling $flag" bash "$SCRIPT" record codex 13 "$flag"
done
expectFail "an unknown option" bash "$SCRIPT" record codex 13 --bogus x
expectFail "a provider with control characters" bash "$SCRIPT" record codex 13 --resets-at 2026-10-08T10:57:00+07:00 --provider "$(printf 'co\tdex\nprovider fake')"
expectFail "an offset past 14 hours" bash "$SCRIPT" record codex 13 --resets-at 2026-10-08T10:57:00+99:99
[ ! -f "$CLAUDE_QUOTA_FILE" ] || failCase "a refused record must not create the file"
# The writer lock is a symlink naming its owner's pid (R-109 r4). It is
# broken only when that process is dead; a live owner, however long it has
# been stalled, keeps it, and a waiter fails loudly at its bound.
# deadPid: prints the pid of a process that has exited.
deadPid() {
  sh -c 'exit 0' &
  local p=$!
  wait "$p"
  echo "$p"
}
LOCK="$CLAUDE_QUOTA_FILE.lock"
BRK="$CLAUDE_QUOTA_FILE.lock.break"
resetLock() {
  rm -rf "$CLAUDE_QUOTA_FILE" "$LOCK" "$BRK" "$WORK/shim"
  bash "$SCRIPT" record codex 1 --resets-at 2026-10-08T10:57:00+07:00 --at $((NOW_OWNER - 20 * HOUR))
}
# A live foreign owner: record waits out its bound, fails, and leaves the lock.
resetLock
sleep 60 &
LIVE=$!
ln -s "$LIVE" "$LOCK"
msg=$({ timeout 20 bash "$SCRIPT" record codex 2 2>&1 && echo EXIT0; } || true)
case "$msg" in *EXIT0*) failCase "a live owner's lock must stop the writer" ;; esac
case "$msg" in *"$LIVE"*) ;; *) failCase "the failure must name the live owner pid (got: $msg)" ;; esac
[ "$(readlink "$LOCK")" = "$LIVE" ] || failCase "a refused writer must not remove a live owner's lock"
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null || true
# The same lock, once its owner has died, is broken and the record lands.
timeout 20 bash "$SCRIPT" record codex 2 || failCase "a dead owner's lock must be broken"
[ ! -e "$LOCK" ] && [ ! -L "$LOCK" ] || failCase "the lock must be released after a dead-owner break"
[ "$(jq '.buckets.codex.snapshots | length' "$CLAUDE_QUOTA_FILE")" = "2" ] || failCase "the record past a dead owner must land"
# Anything at the lock path that is not a pid symlink is never deleted.
for kind in dir file badlink; do
  resetLock
  case "$kind" in
    dir) mkdir "$LOCK" && echo keep >"$LOCK/data" ;;
    file) echo keep >"$LOCK" ;;
    badlink) ln -s "/etc/passwd" "$LOCK" ;;
  esac
  touch -h -d '2 hours ago' "$LOCK"
  expectFail "a foreign $kind at the lock path" bash "$SCRIPT" record codex 2
  case "$kind" in
    dir) [ "$(cat "$LOCK/data")" = keep ] || failCase "a foreign directory at the lock path must be left intact" ;;
    file) [ "$(cat "$LOCK")" = keep ] || failCase "a foreign file at the lock path must be left intact" ;;
    badlink) [ "$(readlink "$LOCK")" = /etc/passwd ] || failCase "a foreign symlink at the lock path must be left intact" ;;
  esac
done
# A directory, or a symlink to a directory, at either lock path (R-109 r5):
# `ln -s` would create the link inside it, so every waiter would think it
# held the lock. The writer must fail naming the path and add nothing to it.
for which in lock brk; do
  for kind in dir dirlink; do
    resetLock
    target="$LOCK"; [ "$which" = brk ] && target="$BRK"
    [ "$which" = brk ] && ln -s "$(deadPid)" "$LOCK"
    mkdir -p "$WORK/victim-$which-$kind"
    case "$kind" in
      dir) mkdir "$target" ;;
      dirlink) ln -s "$WORK/victim-$which-$kind" "$target" ;;
    esac
    msg=$({ timeout 20 bash "$SCRIPT" record codex 2 2>&1 && echo EXIT0; } || true)
    case "$msg" in *EXIT0*) failCase "a $kind at the $which path must stop the writer" ;; esac
    case "$msg" in *"$target"*) ;; *) failCase "the failure must name the $which path for a $kind (got: $msg)" ;; esac
    if [ "$kind" = dir ]; then
      [ -z "$(ls -A "$target")" ] || failCase "a $kind at the $which path must gain no entry"
    else
      [ -z "$(ls -A "$WORK/victim-$which-$kind")" ] || failCase "a $kind at the $which path must add nothing to its target"
    fi
    rm -rf "$LOCK" "$BRK"
  done
done
# A live pid this process may not own (init, pid 1) is never treated as dead.
# Only a non-root runner reaches the EPERM branch of isDeadPid this way (CI
# runs as non-root); as root kill -0 succeeds, so say so rather than claim it.
if kill -0 1 2>/dev/null && [ "$(id -u)" = 0 ]; then
  echo "note: running as root, so the pid-1 case exercises kill -0 success, not the EPERM branch (covered on non-root CI runners)"
fi
resetLock
ln -s 1 "$LOCK"
msg=$({ timeout 20 bash "$SCRIPT" record codex 2 2>&1 && echo EXIT0; } || true)
case "$msg" in *EXIT0*) failCase "a lock naming pid 1 must stop the writer" ;; esac
case "$msg" in *"pid 1,"*) ;; *) failCase "the failure must name pid 1 (got: $msg)" ;; esac
[ "$(readlink "$LOCK")" = 1 ] || failCase "a lock naming pid 1 must be kept"
rm -f "$LOCK"
# With no ps on PATH, a dead owner's lock is still recognized and broken.
resetLock
ln -s "$(deadPid)" "$LOCK"
mkdir -p "$WORK/nops"
for tool in bash jq mktemp mv rm ln readlink dirname mkdir cat date sleep find sort tr head grep sed awk env; do
  p=$(command -v "$tool" 2>/dev/null) && ln -sf "$p" "$WORK/nops/$tool"
done
timeout 20 env PATH="$WORK/nops" bash "$SCRIPT" record codex 2 || failCase "a dead owner must be recognized without ps"
[ "$(jq '.buckets.codex.snapshots | length' "$CLAUDE_QUOTA_FILE")" = "2" ] || failCase "the record without ps must land"
rm -rf "$LOCK"
# On a /proc mounted hidepid, a missing /proc/<pid> proves nothing: with no
# ps either, a dead-looking owner counts as alive and the writer fails.
resetLock
ln -s "$(deadPid)" "$LOCK"
printf 'proc /proc proc rw,relatime,hidepid=2 0 0\n' >"$WORK/mounts-hidepid"
msg=$({ timeout 20 env QUOTA_PROC_MOUNTS="$WORK/mounts-hidepid" PATH="$WORK/nops" bash "$SCRIPT" record codex 2 2>&1 && echo EXIT0; } || true)
case "$msg" in *EXIT0*) failCase "under hidepid with no ps, an owner must count as alive" ;; esac
[ -L "$LOCK" ] || failCase "under hidepid with no ps, the owner's lock must be kept"
# The same mounts file with ps available still finds the dead owner.
timeout 20 env QUOTA_PROC_MOUNTS="$WORK/mounts-hidepid" bash "$SCRIPT" record codex 2 || failCase "under hidepid, ps must still identify a dead owner"
rm -rf "$LOCK"
# Many recorders against one dead owner's lock: exactly one breaks it at a
# time, so every snapshot lands. Probabilistic, so three rounds.
for round in 1 2 3; do
  resetLock
  ln -s "$(deadPid)" "$LOCK"
  pids=""
  for i in 2 3 4 5 6 7 8 9 10 11 12 13; do
    timeout 30 bash "$SCRIPT" record codex "$i" --at $((NOW_OWNER - (20 - i) * HOUR)) &
    pids="$pids $!"
  done
  for p in $pids; do wait "$p" || failCase "a recorder racing a dead owner's lock failed (round $round)"; done
  [ "$(jq '.buckets.codex.snapshots | length' "$CLAUDE_QUOTA_FILE")" = "13" ] ||
    failCase "recorders racing one dead owner's lock lost a snapshot (round $round)"
  [ -z "$(ls -d "$CLAUDE_QUOTA_FILE".lock* 2>/dev/null)" ] || failCase "a lock or break lock was left behind (round $round)"
done
# A break lock left by a dead breaker is cleared; one held by a live process
# stops the writer and is named in the failure.
resetLock
ln -s "$(deadPid)" "$LOCK"
ln -s "$(deadPid)" "$BRK"
timeout 20 bash "$SCRIPT" record codex 2 || failCase "a dead owner behind a dead breaker must be cleared"
[ -z "$(ls -d "$CLAUDE_QUOTA_FILE".lock* 2>/dev/null)" ] || failCase "a cleared break lock must leave no marker"
sleep 60 &
LIVE=$!
ln -s "$(deadPid)" "$LOCK"
ln -s "$LIVE" "$BRK"
msg=$({ timeout 20 bash "$SCRIPT" record codex 3 2>&1 && echo EXIT0; } || true)
case "$msg" in *EXIT0*) failCase "a live breaker must stop the writer" ;; esac
case "$msg" in *lock.break*) ;; *) failCase "the failure must name the break lock (got: $msg)" ;; esac
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null || true
rm -f "$LOCK" "$BRK"
# A live holder stalled inside the locked region (the case rounds 3 and 4
# found) keeps its lock: the waiter fails, the holder's write lands.
resetLock
mkdir -p "$WORK/shim"
REAL_JQ=$(command -v jq)
cat >"$WORK/shim/jq" <<SHIM
#!/usr/bin/env bash
case "\$*" in
  *newReset*)
    if [ -f "$WORK/stall-armed" ]; then
      rm -f "$WORK/stall-armed"
      : >"$WORK/stalled"
      for _ in \$(seq 1 400); do [ -f "$WORK/release" ] && break; sleep 0.05; done
    fi ;;
esac
exec "$REAL_JQ" "\$@"
SHIM
chmod +x "$WORK/shim/jq"
: >"$WORK/stall-armed"
rm -f "$WORK/stalled" "$WORK/release"
PATH="$WORK/shim:$PATH" bash "$SCRIPT" record codex 2 --at $((NOW_OWNER - 10 * HOUR)) >/dev/null 2>&1 &
holder=$!
for _ in $(seq 1 200); do [ -f "$WORK/stalled" ] && break; sleep 0.05; done
[ -f "$WORK/stalled" ] || failCase "setup: the holder never stalled"
touch -h -d '2 hours ago' "$LOCK"
expectFail "a waiter behind a live stalled holder" bash "$SCRIPT" record codex 4 --at $((NOW_OWNER - 5 * HOUR))
: >"$WORK/release"
wait "$holder" || failCase "a live stalled holder must keep its lock and write"
[ "$(jq -c '[.buckets.codex.snapshots[].usedPct]' "$CLAUDE_QUOTA_FILE")" = "[1,2]" ] || failCase "the stalled holder's snapshot must land and the waiter's must not"
[ ! -e "$LOCK" ] && [ ! -L "$LOCK" ] || failCase "no lock may be left after the stalled-holder case"
# A failure inside the locked region still releases the lock.
echo 'not json' >"$CLAUDE_QUOTA_FILE"
expectFail "a malformed file under the lock" bash "$SCRIPT" record codex 15
for shape in '{"buckets":0}' '{"buckets":null}' '{"buckets":[]}' '{"buckets":""}'; do
  echo "$shape" >"$CLAUDE_QUOTA_FILE"
  expectFail "record over buckets $shape" bash "$SCRIPT" record codex 15 --resets-at 2026-10-08T10:57:00+07:00
  [ "$(cat "$CLAUDE_QUOTA_FILE")" = "$shape" ] || failCase "a wrong-typed buckets file ($shape) must never be overwritten"
done
echo 'not json' >"$CLAUDE_QUOTA_FILE"
[ ! -e "$CLAUDE_QUOTA_FILE.lock" ] && [ ! -L "$CLAUDE_QUOTA_FILE.lock" ] || failCase "a failed record must release the lock"
[ "$(cat "$CLAUDE_QUOTA_FILE")" = "not json" ] || failCase "a malformed file must never be overwritten"

# --- 10. Insecure values: file contents, environment, and targets. ---
# writeBucket <bucket json>: writes a one-bucket quota file named codex.
writeBucket() {
  jq -n --argjson b "$1" '{buckets: {codex: $b}}' >"$CLAUDE_QUOTA_FILE"
}
GOOD='{"provider":"codex","resetsAt":"2026-10-08T10:57:00+07:00","windowDays":7,"snapshots":[{"at":"2026-10-03T00:00:00+07:00","usedPct":13}]}'
writeBucket "$GOOD"
bash "$SCRIPT" report >/dev/null || failCase "setup: the good bucket must report"
for bad in '.snapshots[0].usedPct = -1000' '.snapshots[0].usedPct = 101' '.snapshots[0].usedPct = "55"' \
  '.snapshots[0].usedPct = null' '.resetsAt = null' '.windowDays = 0' '.windowDays = -7' '.windowDays = "7"' \
  '.resetsAt = "2026-10-08T10:57:00+99:99"' '.provider = "co\ndex"' '.snapshots[0].source = "ow\u001b[31mner"'; do
  writeBucket "$(jq -c "$bad" <<<"$GOOD")"
  expectFail "file value $bad" bash "$SCRIPT" report
done
jq -n --argjson b "$GOOD" '{buckets: {"co\u001b[31mdex": $b}}' >"$CLAUDE_QUOTA_FILE"
expectFail "a bucket key with an escape byte" bash "$SCRIPT" report
writeBucket "$GOOD"
expectFail "QUOTA_NOW=abc" env QUOTA_NOW=abc bash "$SCRIPT" report
expectFail "QUOTA_NOW=-5" env QUOTA_NOW=-5 bash "$SCRIPT" report
expectFail "QUOTA_STALE_HOURS=abc" env QUOTA_STALE_HOURS=abc bash "$SCRIPT" report
expectFail "QUOTA_STALE_HOURS=-1" env QUOTA_STALE_HOURS=-1 bash "$SCRIPT" report
[ "$(QUOTA_NOW=$((NOW_OWNER + 60)) QUOTA_STALE_HOURS=0 field '.buckets[0].status')" = "stale" ] || failCase "QUOTA_STALE_HOURS=0 must read a minute-old snapshot stale"
# Round 2 (R-109): an absurd window, an unset HOME, a symlinked file, and a
# mistyped report flag all fail loudly instead of reading as healthy.
expectFail "--window-days past 366" bash "$SCRIPT" record codex 13 --window-days 99999999999999999999
expectFail "--window-days 367" bash "$SCRIPT" record codex 13 --window-days 367
writeBucket "$(jq -c '.windowDays = 99999999999999999999' <<<"$GOOD")"
expectFail "file windowDays past 366" bash "$SCRIPT" report
writeBucket "$GOOD"
expectFail "report with an unknown option" bash "$SCRIPT" report --jsno
mkdir -p "$WORK/cwd"
expectFail "HOME unset with no CLAUDE_QUOTA_FILE" sh -c "cd '$WORK/cwd' && env -u HOME -u CLAUDE_QUOTA_FILE bash '$SCRIPT' record codex 13 --resets-at 2026-10-08T10:57:00+07:00"
[ -z "$(ls -A "$WORK/cwd")" ] || failCase "an unset HOME must not create a quota file under the cwd"
expectFail "a relative CLAUDE_QUOTA_FILE" sh -c "cd '$WORK/cwd' && CLAUDE_QUOTA_FILE=quota.json bash '$SCRIPT' record codex 13 --resets-at 2026-10-08T10:57:00+07:00"
for badHome in rel '~'; do
  expectFail "HOME=$badHome" sh -c "cd '$WORK/cwd' && env -u CLAUDE_QUOTA_FILE HOME='$badHome' bash '$SCRIPT' record codex 13 --resets-at 2026-10-08T10:57:00+07:00"
done
[ -z "$(ls -A "$WORK/cwd")" ] || failCase "a relative HOME must not create a quota file under the cwd"
cp "$CLAUDE_QUOTA_FILE" "$WORK/real.json"
ln -s "$WORK/real.json" "$WORK/link.json"
expectFail "a symlinked quota file (record)" env CLAUDE_QUOTA_FILE="$WORK/link.json" bash "$SCRIPT" record codex 14
expectFail "a symlinked quota file (report)" env CLAUDE_QUOTA_FILE="$WORK/link.json" bash "$SCRIPT" report
[ -L "$WORK/link.json" ] || failCase "a refused record must leave the symlink in place"
mkdir -p "$WORK/adir"
expectFail "a quota path naming a directory (record)" env CLAUDE_QUOTA_FILE="$WORK/adir" bash "$SCRIPT" record codex 13 --resets-at 2026-10-08T10:57:00+07:00
expectFail "a quota path naming a directory (report)" env CLAUDE_QUOTA_FILE="$WORK/adir" bash "$SCRIPT" report
[ -z "$(ls -A "$WORK/adir")" ] || failCase "a directory target must receive nothing"

# --- 8. Offsets parse to the same instant as Z. ---
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
