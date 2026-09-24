#!/usr/bin/env bash
# Shard: slow
# Verifies the machine-wide run lock in enforce/run-fixture-shards.sh
# (IAN-348, redesigned in IAN-359). Two fixture-suite runs on one machine
# starved each other of CPU until single fixtures passed the 600-second tool
# timeout (2026-09-24), so a second run queues behind the first. The lock is a
# kernel flock held on a file descriptor the runner's workers inherit, so it
# lasts exactly as long as any process running a fixture for that run: a TERM
# or KILL to the runner cannot free it while its fixtures still run, and no
# dead holder ever needs taking over (the PID-and-takeover design this
# replaced let both happen, IAN-359). The cases prove that concurrent runs
# execute one after the other; that a killed runner's fixtures keep the lock
# until they finish; that a lock file naming a dead PID is no obstacle; that a
# background process a fixture leaks does not hold the lock; that a nested run
# skips the lock only for a live holder's PID; and that the wait cap exits 75.
#
# Every run points TMPDIR at the sandbox, so the lock under test is never the
# real one, and clears the marker this fixture inherits from the runner that
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
BACKGROUND_PIDS=""
cleanup_sandbox() {
  local background_pid
  for background_pid in $BACKGROUND_PIDS $(cat "$SANDBOX/leaked-pids" 2>/dev/null); do
    kill "$background_pid" 2>/dev/null
  done
  rm -rf "$SANDBOX"
}
trap cleanup_sandbox EXIT
LOCK_TMPDIR="$SANDBOX/tmp"
LOCK_FILE="$LOCK_TMPDIR/claude-fixture-shards.flock"
TESTS="$SANDBOX/tests"
LEAK_TESTS="$SANDBOX/leak-tests"
EVENTS="$SANDBOX/events"
LOAD_FILE="$SANDBOX/load"
mkdir -p "$LOCK_TMPDIR" "$TESTS" "$LEAK_TESTS"
: > "$EVENTS"
echo 0 > "$LOAD_FILE"
export EVENTS SANDBOX

# The sandbox fixture appends a start line, sleeps, and appends an end line,
# so the order of the lines in EVENTS shows whether two runs overlapped.
cat > "$TESTS/sleeper.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
echo start >> "$EVENTS"
sleep 3
echo end >> "$EVENTS"
echo "sleeper PASS"
FIXTURE
# The leak fixture starts a long-lived background process, as a fixture that
# forgets to stop a server would, records its PID for cleanup, and passes.
cat > "$LEAK_TESTS/leaker.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
sleep 60 > /dev/null 2>&1 &
echo "$!" >> "$SANDBOX/leaked-pids"
echo "leaker PASS"
FIXTURE

# build_runner_argv [VAR=value]... [-- runner option...]: sets RUNNER_ARGV to
# the env-prefixed runner command for the sandbox tests (RUNNER_TESTS when
# set), with the sandbox TMPDIR, the marker cleared, and any extra
# environment and options (after a `--`) given.
build_runner_argv() {
  local environment_assignments=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do environment_assignments+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  RUNNER_ARGV=(env -u FIXTURE_SHARDS_LOCK_HELD TMPDIR="$LOCK_TMPDIR"
    ${environment_assignments[@]+"${environment_assignments[@]}"}
    bash "$RUNNER" "${RUNNER_TESTS:-$TESTS}" --all --jobs 1 --settle-seconds 0 --load-from "$LOAD_FILE" "$@")
}

# run_locked_runner [VAR=value]... [-- runner option...]: runs the runner in
# the foreground with its output on stdout.
run_locked_runner() {
  build_runner_argv "$@"
  "${RUNNER_ARGV[@]}" 2>&1
}

# start_runner_in_background <output file> [VAR=value]...: starts the runner
# so that $! is the runner's own PID (the subshell execs env, which execs
# bash), and records it in STARTED_RUNNER_PID.
start_runner_in_background() {
  local output_file="$1"; shift
  build_runner_argv "$@"
  ( exec "${RUNNER_ARGV[@]}" > "$output_file" 2>&1 ) &
  STARTED_RUNNER_PID=$!
  BACKGROUND_PIDS="$BACKGROUND_PIDS $STARTED_RUNNER_PID"
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

# wait_for_line <seconds> <pattern> <file>: true once the file holds a line
# matching the pattern, false when the seconds pass first.
wait_for_line() {
  local waited=0
  until grep -q "$2" "$3" 2>/dev/null; do
    [ "$waited" -ge "$(( $1 * 10 ))" ] && return 1
    sleep 0.1; waited=$(( waited + 1 ))
  done
}

# is_lock_free: true when a fresh process can take the run lock at once.
is_lock_free() {
  perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or exit 2; flock($f, LOCK_EX|LOCK_NB) ? exit 0 : exit 1' "$LOCK_FILE"
}

# start_lock_holder: starts a process that takes the run lock and keeps it,
# writing its PID into the lock file as a real run does, and records the PID
# in LOCK_HOLDER_PID once the lock is held.
start_lock_holder() {
  perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or die; flock($f, LOCK_EX) or die; open(my $p, ">", $ARGV[0]) or die; print $p "$$\n"; close $p; sleep 60' "$LOCK_FILE" &
  LOCK_HOLDER_PID=$!
  BACKGROUND_PIDS="$BACKGROUND_PIDS $LOCK_HOLDER_PID"
  wait_for_line 5 "^$LOCK_HOLDER_PID\$" "$LOCK_FILE"
}

# dead_pid_of_finished_process: prints the PID of a process that has exited.
dead_pid_of_finished_process() {
  sh -c 'exit 0' &
  local finished_pid=$!
  wait "$finished_pid"
  echo "$finished_pid"
}

# Case 1: two concurrent runs do not overlap. The second starts once the
# first's fixture has started; the events must read start, end, start, end,
# and the second prints exactly one waiting line.
start_runner_in_background "$SANDBOX/first.out"
first_pid=$STARTED_RUNNER_PID
wait_for_line 10 start "$EVENTS"
run_with_deadline 60 "$SANDBOX/second.out" run_locked_runner; second_status=$?
wait "$first_pid"; first_status=$?
check "first concurrent run passes" test "$first_status" -eq 0
check "second concurrent run passes" test "$second_status" -eq 0
check "concurrent runs execute one after the other" test "$(tr '\n' ' ' < "$EVENTS")" = "start end start end "
check "second run prints one waiting line naming the first run's PID" \
  test "$(grep -c "waiting for PID $first_pid" "$SANDBOX/second.out")" -eq 1
check "the lock is free once both runs finish" is_lock_free

# Case 2: a runner killed with TERM mid-run keeps the lock until its fixture
# finishes, so the next run cannot start its fixture alongside the orphan.
for kill_signal in TERM KILL; do
  : > "$EVENTS"
  start_runner_in_background "$SANDBOX/killed-$kill_signal.out"
  killed_pid=$STARTED_RUNNER_PID
  wait_for_line 10 start "$EVENTS"
  kill "-$kill_signal" "$killed_pid"
  run_with_deadline 60 "$SANDBOX/after-$kill_signal.out" run_locked_runner; after_status=$?
  check "a run after a $kill_signal-killed runner passes" test "$after_status" -eq 0
  check "a $kill_signal-killed runner's fixture finishes before the next run's starts" \
    test "$(tr '\n' ' ' < "$EVENTS")" = "start end start end "
done

# Case 3: a lock file naming a dead PID, with no process holding the lock, is
# no obstacle: the run starts at once and prints no waiting line.
dead_pid_of_finished_process > "$LOCK_FILE"
: > "$EVENTS"
run_with_deadline 30 "$SANDBOX/stale.out" run_locked_runner FIXTURE_SHARDS_LOCK_WAIT_SECONDS=10; stale_status=$?
check "a lock file naming a dead PID does not stop the run" test "$stale_status" -eq 0
check "a lock file naming a dead PID causes no wait" not grep -q "waiting for PID" "$SANDBOX/stale.out"
check "the run after a stale lock file ran its fixture" test "$(tr '\n' ' ' < "$EVENTS")" = "start end "

# Case 4: a background process a fixture leaks does not hold the lock once
# the run that started it has finished.
RUNNER_TESTS="$LEAK_TESTS" run_with_deadline 30 "$SANDBOX/leak.out" run_locked_runner; leak_status=$?
check "the leaking fixture's run passes" test "$leak_status" -eq 0
check "a fixture's leaked background process does not hold the lock" is_lock_free

# Case 5: a nested run whose marker names the live holder skips the lock and
# leaves it held; a marker naming a dead PID is stale and does not.
start_lock_holder
holder_pid="$LOCK_HOLDER_PID"
: > "$EVENTS"
run_with_deadline 30 "$SANDBOX/nested.out" run_locked_runner FIXTURE_SHARDS_LOCK_HELD="$holder_pid" FIXTURE_SHARDS_LOCK_WAIT_SECONDS=2; nested_status=$?
check "a nested run naming the live holder passes" test "$nested_status" -eq 0
check "a nested run naming the live holder ran its fixture" test "$(tr '\n' ' ' < "$EVENTS")" = "start end "
check "a nested run naming the live holder does not wait" not grep -q "waiting for PID" "$SANDBOX/nested.out"
check "a nested run leaves its parent's lock held" not is_lock_free
: > "$EVENTS"
run_with_deadline 30 "$SANDBOX/stale-marker.out" run_locked_runner FIXTURE_SHARDS_LOCK_HELD="$(dead_pid_of_finished_process)" FIXTURE_SHARDS_LOCK_WAIT_SECONDS=2; stale_marker_status=$?
check "a stale marker does not skip the lock: the run queues and gives up with 75" test "$stale_marker_status" -eq 75
check "a run with a stale marker runs no fixture while the lock is held" test ! -s "$EVENTS"

# Case 6: the wait cap. A live holder never lets go, so the run gives up after
# the cap with exit 75, the code the gate does not retry (IAN-351), a message
# naming the holder, and no fixture run; the holder keeps the lock.
: > "$EVENTS"
run_with_deadline 30 "$SANDBOX/capped.out" run_locked_runner FIXTURE_SHARDS_LOCK_WAIT_SECONDS=2; capped_status=$?
check "a run past the wait cap exits 75" test "$capped_status" -eq 75
check "a run past the wait cap says it gave up and names the holder" \
  grep -q "gave up after 2s waiting for PID $holder_pid" "$SANDBOX/capped.out"
check "a run past the wait cap runs no fixture" test ! -s "$EVENTS"
check "a run past the wait cap leaves the holder's lock held" not is_lock_free

# Case 7: --list runs nothing, so it takes no lock and does not wait.
list_output=$(run_locked_runner FIXTURE_SHARDS_LOCK_WAIT_SECONDS=2 -- --list); list_status=$?
check "--list does not wait on the lock" test "$list_status" -eq 0
check "--list still lists the fixtures under a held lock" grep -qx "sleeper.test.sh" <<< "$list_output"
kill "$holder_pid" 2>/dev/null; wait "$holder_pid" 2>/dev/null

# Case 8: a lock directory left at the old IAN-348 path is not this lock.
mkdir -p "$LOCK_TMPDIR/claude-fixture-shards.lock"
echo "$$" > "$LOCK_TMPDIR/claude-fixture-shards.lock/pid"
: > "$EVENTS"
run_with_deadline 30 "$SANDBOX/old-dir.out" run_locked_runner FIXTURE_SHARDS_LOCK_WAIT_SECONDS=2; old_dir_status=$?
check "an old-style lock directory does not block a run" test "$old_dir_status" -eq 0
check "an old-style lock directory causes no wait" not grep -q "waiting for PID" "$SANDBOX/old-dir.out"

# Case 9: a lock parent the runner cannot write is reported as that at once,
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
