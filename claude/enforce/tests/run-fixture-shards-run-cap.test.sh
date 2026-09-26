#!/usr/bin/env bash
# Shard: slow
# Verifies the per-worktree run lock and the machine-wide run cap in
# enforce/run-fixture-shards.sh (IAN-441, program row 3d). The machine-wide
# lock of IAN-348 and IAN-359 made every worktree on the machine wait for
# every other, so a Stop gate queued for 480 seconds behind a suite from an
# unrelated branch. A run now queues only behind another run from the same
# worktree, and at most FIXTURE_SHARDS_MAX_RUNS runs (default half the CPUs)
# run at once machine-wide. The cases prove that with the cap at 2, two
# worktrees run at once and a third queues until one finishes; that a second
# run in the same worktree queues behind the first; that the default cap is
# derived from the core count; that a bad cap is a usage error; that a nested
# run under a cap of 1 does not wait on its own parent's slot; that a killed
# runner's fixtures keep its slot; that a leaked background process does not;
# that a full cap gives up with 75; and that a forged marker naming a file
# outside the lock directory cannot skip the queue.
#
# Every run points TMPDIR at the sandbox, so the locks under test are never
# the real ones, and clears the markers this fixture inherits from the runner
# that is running it.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../harness-root.sh"
RUNNER="$CLAUDE_HARNESS_ROOT/enforce/run-fixture-shards.sh"

fail=0
check() {
  local name="$1"; shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}
not() { ! "$@"; }

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/run-fixture-shards-run-cap.XXXXXX")
SANDBOX=$(cd "$SANDBOX" && pwd -P)
BACKGROUND_PIDS=""
cleanup_sandbox() {
  local background_pid
  for background_pid in $BACKGROUND_PIDS $(cat "$SANDBOX/leaked-pids" 2>/dev/null); do
    pkill -P "$background_pid" 2>/dev/null
    kill "$background_pid" 2>/dev/null
  done
  rm -rf "$SANDBOX"
}
trap cleanup_sandbox EXIT
LOCK_TMPDIR="$SANDBOX/tmp"
EVENTS="$SANDBOX/events"
LOAD_FILE="$SANDBOX/load"
mkdir -p "$LOCK_TMPDIR"
: > "$EVENTS"
echo 0 > "$LOAD_FILE"
export EVENTS SANDBOX RUNNER LOCK_TMPDIR LOAD_FILE

# write_sleeper <tests dir>: a fixture that appends "start <RUN_NAME>", sleeps,
# and appends "end <RUN_NAME>", so the order of the lines in EVENTS shows which
# runs overlapped.
write_sleeper() {
  mkdir -p "$1"
  cat > "$1/sleeper.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
echo "start $RUN_NAME" >> "$EVENTS"
sleep 4
echo "end $RUN_NAME" >> "$EVENTS"
echo "sleeper PASS"
FIXTURE
}

# One repository and two linked worktrees of it, each with a tests directory,
# plus a second tests directory inside the first worktree, which shares that
# worktree's lock.
REPO="$SANDBOX/repo"
git init -q --initial-branch=main "$REPO"
git -C "$REPO" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m root
git -C "$REPO" worktree add -q "$SANDBOX/wt2" -b wt2
git -C "$REPO" worktree add -q "$SANDBOX/wt3" -b wt3
W1="$REPO"; W2="$SANDBOX/wt2"; W3="$SANDBOX/wt3"
for worktree in "$W1" "$W2" "$W3"; do write_sleeper "$worktree/tests"; done
write_sleeper "$W1/other-tests"

# The nested fixture calls the runner again on a tests directory outside any
# repository, as the runner's own fixtures do, and passes only when that
# inner run passes.
NESTED_INNER="$SANDBOX/nested-inner"
write_sleeper "$NESTED_INNER"
mkdir -p "$W1/nested-tests"
cat > "$W1/nested-tests/outer.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
if RUN_NAME=inner FIXTURE_SHARDS_LOCK_WAIT_SECONDS=4 bash "$RUNNER" "$SANDBOX/nested-inner" --all --jobs 1 --settle-seconds 0 --load-from "$LOAD_FILE" > "$SANDBOX/nested-inner.out" 2>&1; then
  echo "outer PASS"
else
  echo "outer FAIL"
fi
FIXTURE
mkdir -p "$W2/leak-tests"
cat > "$W2/leak-tests/leaker.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
sleep 60 > /dev/null 2>&1 &
echo "$!" >> "$SANDBOX/leaked-pids"
echo "leaker PASS"
FIXTURE

# build_runner_argv <tests dir> <run name> [VAR=value]...: sets RUNNER_ARGV to
# the env-prefixed runner command, with the sandbox TMPDIR and the markers and
# cap cleared unless given.
build_runner_argv() {
  local tests_dir="$1" run_name="$2"; shift 2
  RUNNER_ARGV=(env -u FIXTURE_SHARDS_LOCK_HELD -u FIXTURE_SHARDS_LOCK_HELD_FILE -u FIXTURE_SHARDS_MAX_RUNS
    TMPDIR="$LOCK_TMPDIR" RUN_NAME="$run_name" "$@"
    bash "$RUNNER" "$tests_dir" --all --jobs 1 --settle-seconds 0 --load-from "$LOAD_FILE")
}

# start_runner_in_background <output file> <tests dir> <run name> [VAR=value]...:
# starts the runner so that $! is the runner's own PID, recorded in
# STARTED_RUNNER_PID.
start_runner_in_background() {
  local output_file="$1"; shift
  build_runner_argv "$@"
  ( exec "${RUNNER_ARGV[@]}" > "$output_file" 2>&1 ) &
  STARTED_RUNNER_PID=$!
  BACKGROUND_PIDS="$BACKGROUND_PIDS $STARTED_RUNNER_PID"
}

# run_with_deadline <seconds> <output file> <tests dir> <run name> [VAR=value]...:
# runs the runner in the foreground and kills it and its children after the
# deadline, so a regression that loops forever fails its case instead of
# hanging the fixture.
run_with_deadline() {
  local deadline_seconds="$1" output_file="$2" command_pid watchdog_pid command_status
  shift 2
  build_runner_argv "$@"
  "${RUNNER_ARGV[@]}" > "$output_file" 2>&1 &
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

# line_number <pattern>: the number of the first EVENTS line matching the
# pattern, 0 when none does.
line_number() {
  local found
  found=$(grep -n "$1" "$EVENTS" | head -1 | cut -d: -f1)
  echo "${found:-0}"
}

# is_before <first pattern> <second pattern>: true when both lines exist and
# the first comes earlier in EVENTS.
is_before() {
  local first second
  first=$(line_number "$1"); second=$(line_number "$2")
  [ "$first" -gt 0 ] && [ "$second" -gt 0 ] && [ "$first" -lt "$second" ]
}

# slot_file <n>: the path of machine-wide run slot n in the sandbox.
slot_file() {
  echo "$LOCK_TMPDIR/claude-fixture-shards.slot.$1.flock"
}

# is_file_lock_free <file>: true when a fresh process can lock the file at once.
is_file_lock_free() {
  perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or exit 2; flock($f, LOCK_EX|LOCK_NB) ? exit 0 : exit 1' "$1"
}

# start_file_holder <file>: starts a process that locks the file, writes its
# PID into it, and keeps it; records the PID in FILE_HOLDER_PID once held.
start_file_holder() {
  perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or die; flock($f, LOCK_EX) or die; open(my $p, ">", $ARGV[0]) or die; print $p "$$\n"; close $p; sleep 60' "$1" &
  FILE_HOLDER_PID=$!
  BACKGROUND_PIDS="$BACKGROUND_PIDS $FILE_HOLDER_PID"
  wait_for_line 5 "^$FILE_HOLDER_PID\$" "$1"
}

# Case 1: with the cap at 2, two worktrees run at once and a third queues
# until one of them finishes.
start_runner_in_background "$SANDBOX/w1.out" "$W1/tests" w1 FIXTURE_SHARDS_MAX_RUNS=2
w1_pid=$STARTED_RUNNER_PID
start_runner_in_background "$SANDBOX/w2.out" "$W2/tests" w2 FIXTURE_SHARDS_MAX_RUNS=2
w2_pid=$STARTED_RUNNER_PID
wait_for_line 15 "start w1" "$EVENTS"; wait_for_line 15 "start w2" "$EVENTS"
run_with_deadline 60 "$SANDBOX/w3.out" "$W3/tests" w3 FIXTURE_SHARDS_MAX_RUNS=2; w3_status=$?
wait "$w1_pid"; w1_status=$?
wait "$w2_pid"; w2_status=$?
check "cap 2: the first worktree's run passes" test "$w1_status" -eq 0
check "cap 2: the second worktree's run passes" test "$w2_status" -eq 0
check "cap 2: the third worktree's run passes" test "$w3_status" -eq 0
check "cap 2: two worktrees run at once" is_before "start w2" "end w1"
check "cap 2: two worktrees run at once (other order)" is_before "start w1" "end w2"
check "cap 2: the third worktree starts only after one of the first two ends" is_before "end w" "start w3"
check "cap 2: the third worktree says it waits for a run slot" grep -q "run slots are busy" "$SANDBOX/w3.out"
check "cap 2: the third worktree does not wait on a worktree lock" not grep -q "waiting for PID" "$SANDBOX/w3.out"

# Case 2: a second run in the same worktree, from another tests directory of
# it, queues behind the first even with free slots.
: > "$EVENTS"
start_runner_in_background "$SANDBOX/same-first.out" "$W1/tests" w1a FIXTURE_SHARDS_MAX_RUNS=2
same_first_pid=$STARTED_RUNNER_PID
wait_for_line 15 "start w1a" "$EVENTS"
run_with_deadline 60 "$SANDBOX/same-second.out" "$W1/other-tests" w1b FIXTURE_SHARDS_MAX_RUNS=2; same_second_status=$?
wait "$same_first_pid"; same_first_status=$?
check "same worktree: both runs pass" test "$same_first_status" -eq 0 -a "$same_second_status" -eq 0
check "same worktree: the second run starts after the first ends" \
  test "$(tr '\n' ' ' < "$EVENTS")" = "start w1a end w1a start w1b end w1b "
check "same worktree: the second run names the first run's PID" \
  grep -q "waiting for PID $same_first_pid" "$SANDBOX/same-second.out"

# Case 3: the default cap is half the online CPUs, at least 1, and the run
# names its slot and the cap.
cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
expected_cap=$(( cpus / 2 )); [ "$expected_cap" -lt 1 ] && expected_cap=1
: > "$EVENTS"
run_with_deadline 30 "$SANDBOX/default.out" "$W2/tests" default; default_status=$?
check "default cap: the run passes" test "$default_status" -eq 0
check "default cap: the run reports a cap of half the $cpus CPUs ($expected_cap)" \
  grep -q "run slot [0-9]* of $expected_cap (" "$SANDBOX/default.out"

# Case 4: a cap that is not a positive whole number is a usage error.
for bad_cap in 0 abc -1; do
  run_with_deadline 30 "$SANDBOX/bad-cap.out" "$W2/tests" bad FIXTURE_SHARDS_MAX_RUNS="$bad_cap"; bad_status=$?
  check "cap '$bad_cap' exits 2" test "$bad_status" -eq 2
  check "cap '$bad_cap' names FIXTURE_SHARDS_MAX_RUNS" grep -q "FIXTURE_SHARDS_MAX_RUNS" "$SANDBOX/bad-cap.out"
done

# Case 5: under a cap of 1, a nested run started by one of the run's own
# fixtures takes neither lock, so it does not wait on its parent's slot.
: > "$EVENTS"
run_with_deadline 60 "$SANDBOX/nested.out" "$W1/nested-tests" outer FIXTURE_SHARDS_MAX_RUNS=1; nested_status=$?
check "nested run under cap 1: the outer run passes" test "$nested_status" -eq 0
check "nested run under cap 1: the inner run ran its fixture" grep -q "start inner" "$EVENTS"
check "nested run under cap 1: the inner run did not wait" not grep -q "busy\|waiting for PID" "$SANDBOX/nested-inner.out"

# Case 6: a KILL to a runner does not free its slot while its fixture runs.
: > "$EVENTS"
start_runner_in_background "$SANDBOX/killed.out" "$W1/tests" killed FIXTURE_SHARDS_MAX_RUNS=1
killed_pid=$STARTED_RUNNER_PID
wait_for_line 15 "start killed" "$EVENTS"
kill -KILL "$killed_pid"
run_with_deadline 60 "$SANDBOX/after-kill.out" "$W2/tests" after FIXTURE_SHARDS_MAX_RUNS=1; after_kill_status=$?
check "after a killed runner: the next run passes" test "$after_kill_status" -eq 0
check "after a killed runner: its fixture ends before the next run's starts" \
  test "$(tr '\n' ' ' < "$EVENTS")" = "start killed end killed start after end after "

# Case 7: a background process a fixture leaks does not hold the slot once
# its run has finished.
run_with_deadline 30 "$SANDBOX/leak.out" "$W2/leak-tests" leak FIXTURE_SHARDS_MAX_RUNS=1; leak_status=$?
check "leak: the leaking fixture's run passes" test "$leak_status" -eq 0
check "leak: a leaked background process does not hold the run slot" is_file_lock_free "$(slot_file 1)"

# Case 8: with every slot held, a run gives up after the wait cap with 75 and
# a message naming the cap, and runs no fixture.
start_file_holder "$(slot_file 1)"
slot_holder_pid=$FILE_HOLDER_PID
: > "$EVENTS"
run_with_deadline 30 "$SANDBOX/full.out" "$W3/tests" full FIXTURE_SHARDS_MAX_RUNS=1 FIXTURE_SHARDS_LOCK_WAIT_SECONDS=2; full_status=$?
check "full cap: the run exits 75" test "$full_status" -eq 75
check "full cap: the message says it gave up waiting for one of the 1 run slots" \
  grep -q "gave up after 2s waiting for one of the 1 run slots" "$SANDBOX/full.out"
check "full cap: no fixture ran" test ! -s "$EVENTS"
check "full cap: the run released its worktree lock on giving up" \
  is_file_lock_free "$LOCK_TMPDIR/claude-fixture-shards.worktree.$(printf '%s' "$W3" | cksum | awk '{print $1}').flock"

# Case 9: a marker naming a live lock holder on a file outside the lock
# directory is forged and does not skip the queue.
start_file_holder "$SANDBOX/forged.flock"
forger_pid=$FILE_HOLDER_PID
: > "$EVENTS"
run_with_deadline 30 "$SANDBOX/forged.out" "$W3/tests" forged FIXTURE_SHARDS_MAX_RUNS=1 FIXTURE_SHARDS_LOCK_WAIT_SECONDS=2 \
  FIXTURE_SHARDS_LOCK_HELD="$forger_pid" FIXTURE_SHARDS_LOCK_HELD_FILE="$SANDBOX/forged.flock"; forged_status=$?
check "forged marker: the run still queues and gives up with 75" test "$forged_status" -eq 75
check "forged marker: no fixture ran" test ! -s "$EVENTS"
kill "$slot_holder_pid" "$forger_pid" 2>/dev/null; wait "$slot_holder_pid" "$forger_pid" 2>/dev/null

if [ "$fail" -eq 0 ]; then echo "run-fixture-shards-run-cap: PASS"; else echo "run-fixture-shards-run-cap: FAIL"; exit 1; fi
