#!/usr/bin/env bash
# Shard: slow
# Verifies the machine-wide lock in enforce/run-fixture-shards.sh (IAN-348).
# Two fixture-suite runs on one machine starved each other of CPU until single
# fixtures passed the 600-second tool timeout (2026-09-24), so a second run now
# queues behind the first instead of overlapping it. The cases prove that two
# concurrent runs execute one after the other, that a second run names the
# holder's PID while it waits, that a lock left by a dead process is taken
# over, that a nested run with the marker exported neither waits nor removes
# its parent's lock, and that the wait cap fails cleanly instead of hanging.
#
# Every run points TMPDIR at the sandbox, so the lock under test is never the
# real one, and unsets the marker this fixture inherits from the runner that
# is running it, or the runs under test would skip the lock altogether.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../harness-root.sh"
RUNNER="$CLAUDE_HARNESS_ROOT/enforce/run-fixture-shards.sh"

fail=0
check() {
  local name="$1"; shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}
not() { ! "$@"; }

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/run-fixture-shards-lock.XXXXXX")
HOLDER_PIDS=""
cleanup_sandbox() {
  local holder_pid
  for holder_pid in $HOLDER_PIDS; do kill "$holder_pid" 2>/dev/null; done
  rm -rf "$SANDBOX"
}
trap cleanup_sandbox EXIT
LOCK_TMPDIR="$SANDBOX/tmp"
LOCK_DIR="$LOCK_TMPDIR/claude-fixture-shards.lock"
TESTS="$SANDBOX/tests"
EVENTS="$SANDBOX/events"
LOAD_FILE="$SANDBOX/load"
mkdir -p "$LOCK_TMPDIR" "$TESTS"
: > "$EVENTS"
echo 0 > "$LOAD_FILE"
export EVENTS

# The one sandbox fixture appends a start line, sleeps, and appends an end
# line, so the order of the lines in EVENTS shows whether two runs overlapped.
cat > "$TESTS/sleeper.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
echo start >> "$EVENTS"
sleep 3
echo end >> "$EVENTS"
echo "sleeper PASS"
FIXTURE

# run_locked_runner [VAR=value]... [-- runner option...]: runs the runner on
# the sandbox tests with the sandbox TMPDIR, the marker cleared, any extra
# environment given, and any extra runner options after a `--`.
run_locked_runner() {
  local environment_assignments=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do environment_assignments+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  env -u FIXTURE_SHARDS_LOCK_HELD TMPDIR="$LOCK_TMPDIR" ${environment_assignments[@]+"${environment_assignments[@]}"} \
    bash "$RUNNER" "$TESTS" --all --jobs 1 --settle-seconds 0 --load-from "$LOAD_FILE" "$@" 2>&1
}

# start_live_holder: starts a process that outlives the case, to stand in for
# a run that holds the lock, and records its PID in LIVE_HOLDER_PID. Not
# called in a command substitution, whose subshell would own the child.
start_live_holder() {
  sleep 60 &
  LIVE_HOLDER_PID=$!
  HOLDER_PIDS="$HOLDER_PIDS $LIVE_HOLDER_PID"
}

# plant_lock <pid>: writes a lock owned by that PID, as a real run would.
plant_lock() {
  mkdir -p "$LOCK_DIR"
  echo "$1" > "$LOCK_DIR/pid"
}

# Case 1: two concurrent runs do not overlap. The first starts, the second
# starts a second later while the first still sleeps; the events must read
# start, end, start, end, and the second must name the first's PID.
run_locked_runner > "$SANDBOX/first.out" &
first_pid=$!
sleep 1
run_locked_runner > "$SANDBOX/second.out" &
second_pid=$!
wait "$first_pid"; first_status=$?
wait "$second_pid"; second_status=$?
events=$(tr '\n' ' ' < "$EVENTS")
check "first concurrent run passes" test "$first_status" -eq 0
check "second concurrent run passes" test "$second_status" -eq 0
check "concurrent runs execute one after the other" test "$events" = "start end start end "
check "second run prints one waiting line naming a holder PID" \
  test "$(grep -c 'waiting for PID [0-9]' "$SANDBOX/second.out")" -eq 1
check "no lock is left after both runs finish" not test -e "$LOCK_DIR"

# Case 2: a lock whose recorded PID is dead is taken over, not waited on.
sh -c 'exit 0' &
dead_pid=$!
wait "$dead_pid"
plant_lock "$dead_pid"
: > "$EVENTS"
stale_output=$(run_locked_runner FIXTURE_SHARDS_LOCK_WAIT_SECONDS=10); stale_status=$?
check "a dead holder's lock is taken over and the run passes" test "$stale_status" -eq 0
check "the run after a takeover ran its fixture" test "$(tr '\n' ' ' < "$EVENTS")" = "start end "
check "the takeover names the dead PID" grep -q "PID $dead_pid" <<< "$stale_output"
check "the taken-over lock is released at exit" not test -e "$LOCK_DIR"

# Case 3: a nested run, the marker exported by the run above it, does not wait
# on the lock that run holds and does not remove it on exit.
start_live_holder
holder_pid="$LIVE_HOLDER_PID"
plant_lock "$holder_pid"
: > "$EVENTS"
nested_output=$(run_locked_runner FIXTURE_SHARDS_LOCK_HELD=1 FIXTURE_SHARDS_LOCK_WAIT_SECONDS=2); nested_status=$?
check "a nested run passes under a live lock" test "$nested_status" -eq 0
check "a nested run ran its fixture" test "$(tr '\n' ' ' < "$EVENTS")" = "start end "
check "a nested run does not wait" not grep -q "waiting for PID" <<< "$nested_output"
check "a nested run leaves its parent's lock in place" test "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$holder_pid"

# Case 4: the wait cap. A live holder never lets go, so the run gives up after
# the cap with a non-zero exit and a message, runs nothing, and leaves the
# holder's lock alone.
: > "$EVENTS"
capped_output=$(run_locked_runner FIXTURE_SHARDS_LOCK_WAIT_SECONDS=2); capped_status=$?
check "a run past the wait cap exits non-zero" not test "$capped_status" -eq 0
check "a run past the wait cap says it gave up and names the holder" \
  grep -q "gave up after 2s waiting for PID $holder_pid" <<< "$capped_output"
check "a run past the wait cap runs no fixture" test ! -s "$EVENTS"
check "a run past the wait cap leaves the holder's lock in place" test "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$holder_pid"

# Case 5: --list runs nothing, so it takes no lock and does not wait.
list_output=$(run_locked_runner FIXTURE_SHARDS_LOCK_WAIT_SECONDS=2 -- --list); list_status=$?
check "--list does not wait on the lock" test "$list_status" -eq 0
check "--list still lists the fixtures under a held lock" grep -qx "sleeper.test.sh" <<< "$list_output"

if [ "$fail" -eq 0 ]; then echo "run-fixture-shards-lock: PASS"; else echo "run-fixture-shards-lock: FAIL"; exit 1; fi
