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

# run_with_deadline <seconds> <output file> <command...>: runs the command
# with its output in the file and kills it and its children after the
# deadline, so a regression that loops forever fails its case instead of
# hanging the whole fixture. The watchdog's output goes nowhere, or its
# orphaned sleep would hold the calling runner's capture pipe open.
run_with_deadline() {
  local deadline_seconds="$1" output_file="$2" command_pid watchdog_pid command_status
  shift 2
  "$@" > "$output_file" 2>&1 &
  command_pid=$!
  ( sleep "$deadline_seconds"; pkill -P "$command_pid"; kill "$command_pid" ) > /dev/null 2>&1 &
  watchdog_pid=$!
  wait "$command_pid"; command_status=$?
  kill "$watchdog_pid" 2>/dev/null; wait "$watchdog_pid" 2>/dev/null
  return "$command_status"
}

# dead_pid_of_finished_process: prints the PID of a process that has exited.
dead_pid_of_finished_process() {
  sh -c 'exit 0' &
  local finished_pid=$!
  wait "$finished_pid"
  echo "$finished_pid"
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
dead_pid=$(dead_pid_of_finished_process)
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
run_with_deadline 30 "$SANDBOX/capped.out" run_locked_runner FIXTURE_SHARDS_LOCK_WAIT_SECONDS=2; capped_status=$?
capped_output=$(cat "$SANDBOX/capped.out")
check "a run past the wait cap exits non-zero" not test "$capped_status" -eq 0
check "a run past the wait cap says it gave up and names the holder" \
  grep -q "gave up after 2s waiting for PID $holder_pid" <<< "$capped_output"
check "a run past the wait cap runs no fixture" test ! -s "$EVENTS"
check "a run past the wait cap leaves the holder's lock in place" test "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$holder_pid"

# Case 5: --list runs nothing, so it takes no lock and does not wait.
list_output=$(run_locked_runner FIXTURE_SHARDS_LOCK_WAIT_SECONDS=2 -- --list); list_status=$?
check "--list does not wait on the lock" test "$list_status" -eq 0
check "--list still lists the fixtures under a held lock" grep -qx "sleeper.test.sh" <<< "$list_output"
kill "$holder_pid" 2>/dev/null
rm -rf "$LOCK_DIR"

# Case 6: a takeover lock left by a waiter that was killed inside it (SIGKILL
# skips the EXIT trap) is cleared, so a dead holder's run lock can still be
# taken over rather than every later run queueing until the cap.
plant_lock "$(dead_pid_of_finished_process)"
mkdir -p "$LOCK_DIR.takeover"
dead_pid_of_finished_process > "$LOCK_DIR.takeover/pid"
: > "$EVENTS"
run_with_deadline 30 "$SANDBOX/orphan.out" run_locked_runner FIXTURE_SHARDS_LOCK_WAIT_SECONDS=6; orphan_status=$?
check "a dead waiter's takeover lock does not block the takeover" test "$orphan_status" -eq 0
check "the run after clearing a dead takeover lock ran its fixture" test "$(tr '\n' ' ' < "$EVENTS")" = "start end "
check "no run lock or takeover lock is left afterwards" not test -e "$LOCK_DIR" -o -e "$LOCK_DIR.takeover"

# Case 7: a lock parent the runner cannot write is reported as that at once,
# not waited on until the cap as if another run held the lock. Skipped as
# root, which can write a read-only directory.
if [ "$(id -u)" -ne 0 ]; then
  READONLY_TMPDIR="$SANDBOX/readonly"
  mkdir -p "$READONLY_TMPDIR"
  chmod 555 "$READONLY_TMPDIR"
  : > "$EVENTS"
  run_with_deadline 30 "$SANDBOX/readonly.out" run_locked_runner TMPDIR="$READONLY_TMPDIR" FIXTURE_SHARDS_LOCK_WAIT_SECONDS=20; readonly_status=$?
  chmod 755 "$READONLY_TMPDIR"
  check "an unwritable lock parent exits non-zero" not test "$readonly_status" -eq 0
  check "an unwritable lock parent is named as the reason" grep -q "cannot create the run lock under $READONLY_TMPDIR" "$SANDBOX/readonly.out"
  check "an unwritable lock parent is not reported as a busy lock" not grep -q "gave up after" "$SANDBOX/readonly.out"
  check "an unwritable lock parent runs no fixture" test ! -s "$EVENTS"
fi

if [ "$fail" -eq 0 ]; then echo "run-fixture-shards-lock: PASS"; else echo "run-fixture-shards-lock: FAIL"; exit 1; fi
