#!/usr/bin/env bash
# run-fixture-shards.sh: the one runner behind both fixture suites (R-509,
# IAN-94). It runs the *.test.sh fixtures of one directory in parallel and
# decides which of them a run needs.
#
#   run-fixture-shards.sh <tests-dir> --all
#       every fixture: the parallel batch first, then each `# Shard: serial`
#       fixture alone, because a timing-sensitive fixture measured under the
#       load of its neighbours fails for reasons that are not its subject's.
#       CI and doctor.sh use this mode through run-tests.sh.
#   run-fixture-shards.sh <tests-dir> --affected
#       the Stop gate's mode. The fast tier (every fixture with no
#       `# Shard: slow` or `# Shard: serial` header) always runs, so the
#       closure and tree-scanning checks, which are nearly all fast, never
#       wait for CI. A slow or serial fixture runs when its text names a changed
#       file (the path under claude/, or the basename), when a changed path
#       matches a glob on its `# Watches:` line, or when the fixture itself
#       changed. Everything runs when a changed file is named by no
#       fixture in any tree, is one of the shared files every fixture depends
#       on, or cannot be known because there is no git repository, so a change
#       the selector cannot place is never skipped.
#
# Changed files come from git: the working tree's changes plus the commits
# since the upstream, or since the merge base with origin/main when there is
# no upstream, or since the root commit when there is neither. A git query
# that fails means the change set is unknown, and everything runs.
#
# Two options exist for tests only, and they are arguments rather than
# environment variables so that nothing exported in a caller's shell can
# steer a real run (PR #42 review): run-tests.sh forwards only the mode.
#   --changed-from <file>  read the changed paths (repo relative, one per
#                          line) from a file instead of from git.
#   --list                 print the chosen fixtures' names and run nothing.
# One option exists for callers that need each fixture's own result:
#   --results-dir <dir>    keep <name>.out, <name>.verdict, and <name>.status
#                          (the exit code) for every fixture in an existing
#                          directory instead of a temporary one deleted at
#                          the end. enforce/tdd.sh builds its shell report
#                          from these.
# A tree with no fixtures fails, as the sequential runners did.
# --settle-seconds <n> sets the minimum pause before the serial fixtures
# (default 5), after which the runner also waits for the one-minute load to
# fall below the CPU count, for at most --settle-max-seconds <n> (default 60).
# --jobs <n> sets the parallelism; without it the runner uses the idle CPUs
# (CPU count minus current load), from a quarter of the CPUs to 8, where 8 is where measured wall
# time stopped improving (2026-09-18: 105s at 4 jobs, 62s at 8, 65s at 12 for
# the enforce and hook trees together). --load-from <file> reads the load
# from a file instead of the kernel, for tests. Every control is an argument
# for the same reason as the test options: an exported variable must not be
# able to shorten the quiet period or overload the gate.
#
# Runs queue per worktree and are capped machine-wide (IAN-348, IAN-359,
# IAN-441). Before running anything a run takes two kernel flocks, both on
# file descriptors its workers inherit, so each lasts until the last process
# running a fixture for that run has exited, whatever happens to the runner
# itself: its worktree's lock, ${TMPDIR:-/tmp}/claude-fixture-shards.worktree.
# <cksum of the checkout root>.flock on fd 9, so two runs from one checkout
# never overlap; then one of FIXTURE_SHARDS_MAX_RUNS machine-wide run slots
# (default half the CPUs), ${TMPDIR:-/tmp}/claude-fixture-shards.slot.<n>.flock
# on fd 8, so at most that many worktrees run fixtures at once. A waiting run
# prints one line per holder or one line for full slots, polls, and exits 75
# after FIXTURE_SHARDS_LOCK_WAIT_SECONDS (default 1200) across both waits. The
# runner exports its PID as FIXTURE_SHARDS_LOCK_HELD and its worktree lock's
# path as FIXTURE_SHARDS_LOCK_HELD_FILE, so a fixture that calls the runner
# again takes neither lock and does not wait on its own parent. --list takes
# no lock.
#
# A fixture passes on exit 0 with a PASS line and no FAIL line, the verdict
# the sequential runners applied; output is printed in name order once the
# run finishes, so a parallel run reads the same as a sequential one. Exit 0
# when every chosen fixture passed, 1 when one failed, 2 on a usage error,
# and 75 when the wait for the run lock reached its cap.
set -uo pipefail

# Files every fixture of a kind depends on without naming them: the harness
# plumbing, and the ESLint bundle's manifest, lockfile, and config, which
# every lint-driven fixture loads (PR #42 late review: a lockfile change was
# mapped to the one fast fixture that names it and skipped the slow ones).
SHARED_FILES="enforce/harness-root.sh enforce/run-fixture-shards.sh enforce/tests/run-tests.sh hooks/tests/run-tests.sh enforce/package.json enforce/package-lock.json enforce/eslint.config.mjs enforce/eslint-options.mjs enforce/lint.mjs"
MAX_DEFAULT_JOBS=8
SERIAL_SETTLE_DEFAULT_SECONDS=5
SERIAL_SETTLE_MAX_DEFAULT_SECONDS=60
LOAD_FROM=""
# The run locks (IAN-359, IAN-441): kernel flocks taken through perl, because
# macOS ships perl but no flock(1). They replaced an mkdir lock with a
# recorded PID (IAN-348), which a TERM to the runner released while its
# fixtures still ran, and whose dead-holder takeover could admit two runs.
# The worktree lock replaced one machine-wide lock file
# (claude-fixture-shards.flock), which made every worktree wait for every
# other; neither old name is ever mistaken for these locks. RUN_LOCK_FILE is
# set once the tests directory, and so the worktree, is known.
RUN_LOCK_PARENT_DIR="${TMPDIR:-/tmp}"
RUN_LOCK_PREFIX="${RUN_LOCK_PARENT_DIR%/}/claude-fixture-shards"
RUN_LOCK_FILE=""
RUN_SLOT=""
RUN_LOCK_POLL_SECONDS=2
RUN_LOCK_WAIT_DEFAULT_SECONDS=1200
RUN_LOCK_GAVE_UP_STATUS=75

# run_one_fixture <result dir> <fixture>: runs one fixture with stdin closed
# and records its verdict and output. Invoked through xargs as a subcommand,
# which appends the fixture last, hence the argument order.
run_one_fixture() {
  local result_dir="$1" fixture="$2" name output status
  name=$(basename "$fixture")
  # fds 8 and 9 closed: a background process a fixture leaks must not hold
  # the run slot or the worktree lock after the run ends; this process keeps
  # both while the fixture runs.
  output=$(bash "$fixture" </dev/null 8>&- 9>&- 2>&1); status=$?
  printf '%s\n' "$output" > "$result_dir/$name.out"
  echo "$status" > "$result_dir/$name.status"
  # Here-strings, not pipes: under pipefail, `printf | grep -q` fails when grep
  # exits at its first match while printf is still writing, which turned
  # long-output passes into failures (PR #42 CI, 2026-09-18).
  if [ "$status" -eq 0 ] && grep -q PASS <<< "$output" && ! grep -q FAIL <<< "$output"; then
    echo ok > "$result_dir/$name.verdict"
  else
    echo FAIL > "$result_dir/$name.verdict"
  fi
}
if [ "${1:-}" = "--run-one" ]; then
  run_one_fixture "$2" "$3"
  exit 0
fi

# shard_of <fixture>: prints serial, slow, or fast from the fixture's header.
shard_of() {
  if grep -qE '^# Shard: serial$' "$1"; then echo serial
  elif grep -qE '^# Shard: slow$' "$1"; then echo slow
  else echo fast; fi
}

# cpu_count: the online CPU count, 4 when it cannot be read.
cpu_count() {
  getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4
}

# current_load: the one-minute load average as a whole number, read from
# --load-from when given (tests), else from the kernel; 0 when unreadable, so
# an unknown load never stalls a run.
current_load() {
  local raw
  if [ -n "$LOAD_FROM" ]; then raw=$(head -1 "$LOAD_FROM" 2>/dev/null)
  elif [ -r /proc/loadavg ]; then raw=$(cut -d' ' -f1 /proc/loadavg)
  else raw=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}'); fi
  raw="${raw%%.*}"
  [[ "$raw" =~ ^[0-9]+$ ]] && echo "$raw" || echo 0
}

# default_job_count: the idle CPUs (CPU count minus the current load), from a
# quarter of the CPUs to MAX_DEFAULT_JOBS. A fixed 8 let several sessions
# sharding at once drive the load to 124 on a 14-CPU machine; a floor of 1
# then ran a full suite one fixture at a time past the Stop gate's 600-second
# timeout (2026-09-18).
default_job_count() {
  local jobs cpus floor
  cpus=$(cpu_count)
  floor=$(( cpus / 4 )); [ "$floor" -lt 1 ] && floor=1
  jobs=$(( cpus - $(current_load) ))
  [ "$jobs" -lt "$floor" ] && jobs=$floor
  [ "$jobs" -gt "$MAX_DEFAULT_JOBS" ] && jobs=$MAX_DEFAULT_JOBS
  echo "$jobs"
}

# settle_before_serial <min seconds> <max seconds>: waits at least the minimum,
# then until the load falls below the CPU count or the maximum is reached. A
# fixed pause was not enough once other sessions kept the machine loaded: the
# timing fixture then measured their load, not the chain it guards.
settle_before_serial() {
  local min_seconds="$1" max_seconds="$2" waited cpus
  sleep "$min_seconds"; waited="$min_seconds"; cpus=$(cpu_count)
  while [ "$(current_load)" -ge "$cpus" ] && [ "$waited" -lt "$max_seconds" ]; do
    sleep 1; waited=$(( waited + 1 ))
  done
  if [ "$(current_load)" -ge "$cpus" ]; then
    echo "fixture-shards: load still $(current_load) on $cpus CPUs after ${waited}s; running the serial fixtures anyway"
  fi
}

# changed_files_from_git <repo root>: working-tree changes plus unpushed or
# branch commits, one repo-relative path per line; non-zero when git cannot
# produce the list, so a failure is never read as "nothing changed".
changed_files_from_git() {
  local root="$1" base status_lines diff_lines
  status_lines=$(git -C "$root" status --porcelain --untracked-files=all 2>/dev/null) || return 1
  if base=$(git -C "$root" rev-parse -q --verify '@{u}' 2>/dev/null); then :
  elif base=$(git -C "$root" merge-base HEAD origin/main 2>/dev/null); then :
  else base=$(git -C "$root" rev-list --max-parents=0 HEAD 2>/dev/null | tail -1); fi
  [ -n "$base" ] || return 1
  # Three dots: the changes since the branch point only. A two-dot diff
  # against an upstream that had moved ahead also listed every file main had
  # gained, and forced a full run at each turn end (2026-09-18).
  diff_lines=$(git -C "$root" diff --name-only "$base...HEAD" 2>/dev/null) || return 1
  sed -E 's/^.. //; s/^.* -> //; s/^"//; s/"$//' <<< "$status_lines"
  printf '%s\n' "$diff_lines"
}

# names_file <fixture> <repo-relative path>: true when the fixture is that
# path, its text names the path under claude/ or the file's basename, or the
# path matches one of the globs on its `# Watches:` line. A whole-tree scanner
# declares what it reads there, because it never names those files itself
# (PR #42 review: hook-latency times every registered hook without naming one).
names_file() {
  local fixture="$1" path="$2" relative glob
  relative="${path#claude/}"
  case "$fixture" in *"/$relative") return 0 ;; esac
  grep -qF -- "$relative" "$fixture" || grep -qF -- "$(basename "$path")" "$fixture" && return 0
  # Word-split the globs with filename expansion off, or `hooks/*.sh` would
  # expand against the current directory before it is ever matched.
  local globs matched=1
  globs=$(sed -n 's/^# Watches: //p' "$fixture")
  set -f
  for glob in $globs; do
    # shellcheck disable=SC2053  # the right side is a glob on purpose
    [[ "$relative" == $glob ]] && { matched=0; break; }
  done
  set +f
  return "$matched"
}

# fallback_reason <changed files> <mapping corpus>: prints why every fixture
# must run, or nothing when each changed file is placed.
fallback_reason() {
  local changed="$1" corpus="$2" path relative fixture placed
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    relative="${path#claude/}"
    case " $SHARED_FILES " in *" $relative "*) echo "shared: $path"; return ;; esac
    placed=no
    while IFS= read -r fixture; do
      [ -n "$fixture" ] && names_file "$fixture" "$path" && { placed=yes; break; }
    done <<< "$corpus"
    [ "$placed" = yes ] || { echo "unmapped: $path"; return; }
  done <<< "$changed"
}

# select_affected <fixtures> <changed files>: the fast tier plus each slow or
# serial fixture that names a changed file.
select_affected() {
  local fixtures="$1" changed="$2" fixture path
  while IFS= read -r fixture; do
    [ -n "$fixture" ] || continue
    if [ "$(shard_of "$fixture")" = fast ]; then echo "$fixture"; continue; fi
    while IFS= read -r path; do
      [ -n "$path" ] && names_file "$fixture" "$path" && { echo "$fixture"; break; }
    done <<< "$changed"
  done <<< "$fixtures"
}

# run_selected <fixtures> <jobs> <result dir> <settle seconds> <settle max>: the parallel batch, then a
# settle pause, then each serial fixture alone. The pause exists because a
# timing fixture started the instant the batch ends measures the batch's
# leftover load: on 2026-09-18 hook-latency failed by 2ms straight after the
# batch and passed three times out of three when run alone. The pause changes
# when the measurement is taken, not what it must meet.
#
# Fixture paths travel one per line and reach xargs NUL-delimited, so a space
# in the checkout path never splits one fixture into several arguments (PR #42
# review round 4).
run_selected() {
  local fixtures="$1" jobs="$2" result_dir="$3" settle_seconds="$4" settle_max_seconds="$5" fixture serial="" batch=""
  while IFS= read -r fixture; do
    [ -n "$fixture" ] || continue
    if [ "$(shard_of "$fixture")" = serial ]; then serial+="$fixture"$'\n'; else batch+="$fixture"$'\n'; fi
  done <<< "$fixtures"
  # Guarded because GNU xargs starts the child once even on empty input, with
  # no fixture argument, which a serial-only tree would report as a failure.
  if [ -n "$batch" ]; then
    printf '%s' "$batch" | tr '\n' '\0' \
      | xargs -0 -P "$jobs" -n 1 bash "$0" --run-one "$result_dir" 2>/dev/null
  fi
  [ -n "$batch" ] && [ -n "$serial" ] && settle_before_serial "$settle_seconds" "$settle_max_seconds"
  while IFS= read -r fixture; do
    [ -n "$fixture" ] && bash "$0" --run-one "$result_dir" "$fixture"
  done <<< "$serial"
}

# report_results <fixtures> <result dir>: ok/FAIL lines in name order, each
# failing fixture followed by every line carrying the failure marker and its
# last three lines; true
# when all passed.
report_results() {
  local fixtures="$1" result_dir="$2" fixture name all_passed=0
  while IFS= read -r fixture; do
    [ -n "$fixture" ] || continue
    name=$(basename "$fixture")
    if [ "$(cat "$result_dir/$name.verdict" 2>/dev/null)" = ok ]; then
      echo "ok   $name"
    else
      # Every failure line, then the tail: the last three lines alone were
      # all passing cases when fixture-implementation-root failed on main
      # after #42, which left the failure unreadable from the CI log.
      echo "FAIL $name"
      # The verdict's own marker test, so every line that failed the fixture is
      # shown, including ones with the marker mid-line (PR #59 review).
      grep -F 'FAIL' "$result_dir/$name.out" 2>/dev/null
      tail -3 "$result_dir/$name.out" 2>/dev/null
      all_passed=1
    fi
  done <<< "$fixtures"
  return "$all_passed"
}

# affected_selection <tests dir> <fixtures> <changed-from file or "">: sets
# SELECTED and REASON for --affected. REASON non-empty means everything runs.
affected_selection() {
  local tests_dir="$1" fixtures="$2" changed_from="$3" changed root corpus
  SELECTED="$fixtures"; REASON=""
  if [ -n "$changed_from" ]; then
    changed=$(cat "$changed_from")
  else
    root=$(git -C "$tests_dir" rev-parse --show-toplevel 2>/dev/null) || { REASON="no git repository to read changes from"; return; }
    changed=$(changed_files_from_git "$root") || { REASON="git could not list the changes"; return; }
    changed=$(sort -u <<< "$changed")
  fi
  corpus=$(ls "$tests_dir"/../../*/tests/*.test.sh "$tests_dir"/*.test.sh 2>/dev/null | sort -u)
  REASON=$(fallback_reason "$changed" "$corpus")
  [ -n "$REASON" ] || SELECTED=$(select_affected "$fixtures" "$changed")
}

# worktree_root <tests dir>: the top of the checkout holding the tests
# directory, or the resolved directory itself outside any repository.
worktree_root() {
  git -C "$1" rev-parse --show-toplevel 2>/dev/null || (cd "$1" && pwd -P)
}

# worktree_lock_path <tests dir>: the run lock of the checkout holding the
# tests directory. One per checkout, so a linked worktree and the main
# checkout queue separately, while the enforce and hook trees of one checkout
# share a lock and never run at once.
worktree_lock_path() {
  echo "$RUN_LOCK_PREFIX.worktree.$(printf '%s' "$(worktree_root "$1")" | cksum | awk '{print $1}').flock"
}

# run_slot_path <n>: the lock file of machine-wide run slot n.
run_slot_path() {
  echo "$RUN_LOCK_PREFIX.slot.$1.flock"
}

# max_concurrent_runs: how many worktrees may run fixtures at once machine-wide:
# FIXTURE_SHARDS_MAX_RUNS when set, else half the CPUs, at least 1. Exits 2
# on a value that is not a positive whole number. An environment variable by
# the owner's decision (IAN-441), because raising it adds load but can never
# skip or shorten a fixture.
max_concurrent_runs() {
  local configured="${FIXTURE_SHARDS_MAX_RUNS:-}" half_cpus
  if [ -n "$configured" ]; then
    [[ "$configured" =~ ^[1-9][0-9]*$ ]] || usage_error "FIXTURE_SHARDS_MAX_RUNS needs a positive whole number, not '$configured'"
    echo "$configured"; return
  fi
  half_cpus=$(( $(cpu_count) / 2 )); [ "$half_cpus" -lt 1 ] && half_cpus=1
  echo "$half_cpus"
}

# lock_holder_pid <lock file>: prints the PID of the run that last took the
# lock, as it recorded in the file; nothing when no run has.
lock_holder_pid() {
  head -1 "$1" 2>/dev/null
}

# is_file_locked <lock file>: true while some process holds the lock. Probes
# on a fresh open of the file, so the probe's own momentary lock is released
# as soon as perl exits.
is_file_locked() {
  perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or exit 1; flock($f, LOCK_EX|LOCK_NB) ? exit 1 : exit 0' "$1"
}

# is_nested_run: true when FIXTURE_SHARDS_LOCK_HELD_FILE names a worktree lock
# under this run's lock directory, FIXTURE_SHARDS_LOCK_HELD names the run that
# file records as holder, and that lock is held right now, that is, this
# runner was started by one of that run's fixtures and must not wait on its
# own ancestors' worktree lock or run slot. The holder need not be alive: a
# killed runner's orphaned workers still hold its locks, and their fixtures'
# nested runs must not queue behind them. A marker naming another PID, a
# holder whose run has finished, or a file outside the lock directory is
# stale or forged and is ignored, so it can never switch queueing off
# (IAN-359 review, IAN-441).
is_nested_run() {
  local marker="${FIXTURE_SHARDS_LOCK_HELD:-}" held_file="${FIXTURE_SHARDS_LOCK_HELD_FILE:-}" worktree_key
  [ -n "$marker" ] && [ -n "$held_file" ] || return 1
  worktree_key="${held_file#"$RUN_LOCK_PREFIX.worktree."}"
  [ "$worktree_key" != "$held_file" ] && [[ "$worktree_key" =~ ^[0-9]+\.flock$ ]] || return 1
  [ "$marker" = "$(lock_holder_pid "$held_file")" ] && is_file_locked "$held_file"
}

# open_run_lock_file: opens the worktree lock file on fd 9 for the rest of
# the run. The xargs workers inherit it, which is what keeps the lock held
# while any of them is still running a fixture.
open_run_lock_file() {
  { exec 9>>"$RUN_LOCK_FILE"; } 2>/dev/null && return 0
  echo "fixture-shards: cannot open the run lock $RUN_LOCK_FILE; point TMPDIR at a writable directory" >&2
  exit 1
}

# try_lock_fd <fd>: true when this run now holds the lock on the file open on
# that fd. perl locks the runner's own fd (fdopen shares its open file
# description), so the lock outlives perl and is released only when every
# process holding the fd has exited.
try_lock_fd() {
  perl -MFcntl=:flock -e 'open(my $f, ">&=", $ARGV[0]) or exit 2; flock($f, LOCK_EX|LOCK_NB) ? exit 0 : exit 1' "$1"
}

# try_run_slot <cap>: true when this run now holds one of the cap's run
# slots, left open and locked on fd 8 for the workers to inherit, with its
# number in RUN_SLOT and this PID recorded in its file.
try_run_slot() {
  local slot slot_file
  for (( slot = 1; slot <= $1; slot++ )); do
    slot_file=$(run_slot_path "$slot")
    { exec 8>>"$slot_file"; } 2>/dev/null || continue
    if try_lock_fd 8; then
      RUN_SLOT="$slot"; echo "$$" > "$slot_file"
      return 0
    fi
    exec 8>&-
  done
  return 1
}

# give_up_waiting <wait cap> <holder pid>: the wait cap's clean failure, so a
# queued run ends the turn with a reason instead of hanging it. Exits 75
# (EX_TEMPFAIL) rather than 1, so verification-gate.sh can tell a queue that
# never cleared from a failing fixture and skip its retry, which would wait a
# second full cap past the Stop hook's budget (IAN-351).
give_up_waiting() {
  echo "fixture-shards: gave up after ${1}s waiting for PID ${2:-unknown} (or the fixtures it started) to release $RUN_LOCK_FILE; rerun once that run finishes" >&2
  exit "$RUN_LOCK_GAVE_UP_STATUS"
}

# give_up_waiting_for_slot <wait cap> <run cap>: the same failure when every
# machine-wide run slot stayed busy. Exiting releases the worktree lock, since
# no fixture has started to inherit it.
give_up_waiting_for_slot() {
  echo "fixture-shards: gave up after ${1}s waiting for one of the $2 run slots under $RUN_LOCK_PARENT_DIR (FIXTURE_SHARDS_MAX_RUNS); rerun once another worktree's run finishes" >&2
  exit "$RUN_LOCK_GAVE_UP_STATUS"
}

# require_lock_parent_dir: exits 1 when the lock's parent directory cannot be
# created or written, which would otherwise read as a busy lock (PR #129
# review).
require_lock_parent_dir() {
  mkdir -p "$RUN_LOCK_PARENT_DIR" 2>/dev/null
  if [ ! -d "$RUN_LOCK_PARENT_DIR" ] || [ ! -w "$RUN_LOCK_PARENT_DIR" ]; then
    echo "fixture-shards: cannot create the run lock under $RUN_LOCK_PARENT_DIR, which is missing or not writable; point TMPDIR at a writable directory" >&2
    exit 1
  fi
}

# wait_for_worktree_lock <wait cap> <started>: takes this worktree's run lock
# on fd 9, printing one line per holder it waits on, and gives up once
# SECONDS passes started plus the cap. Records this PID in the file and
# exports both nesting markers.
wait_for_worktree_lock() {
  local wait_cap="$1" started="$2" holder announced=""
  open_run_lock_file
  until try_lock_fd 9; do
    holder=$(lock_holder_pid "$RUN_LOCK_FILE")
    if [ -n "$holder" ] && [ "$holder" != "$announced" ]; then
      echo "fixture-shards: another fixture run from this worktree holds $RUN_LOCK_FILE; waiting for PID $holder (or the fixtures it started, up to ${wait_cap}s)"
      announced="$holder"
    fi
    [ $(( SECONDS - started )) -ge "$wait_cap" ] && give_up_waiting "$wait_cap" "$holder"
    sleep "$RUN_LOCK_POLL_SECONDS"
  done
  echo "$$" > "$RUN_LOCK_FILE"
  export FIXTURE_SHARDS_LOCK_HELD="$$" FIXTURE_SHARDS_LOCK_HELD_FILE="$RUN_LOCK_FILE"
}

# wait_for_run_slot <wait cap> <started> <run cap>: takes a machine-wide run
# slot on fd 8, printing one line when all are busy, and gives up once
# SECONDS passes started plus the cap.
wait_for_run_slot() {
  local wait_cap="$1" started="$2" run_cap="$3" announced=""
  until try_run_slot "$run_cap"; do
    if [ -z "$announced" ]; then
      echo "fixture-shards: all $run_cap run slots are busy (FIXTURE_SHARDS_MAX_RUNS, default half the CPUs); waiting for another worktree's run to finish (up to ${wait_cap}s)"
      announced=1
    fi
    [ $(( SECONDS - started )) -ge "$wait_cap" ] && give_up_waiting_for_slot "$wait_cap" "$run_cap"
    sleep "$RUN_LOCK_POLL_SECONDS"
  done
}

# acquire_run_lock <run cap>: takes this worktree's run lock, then one of the
# machine-wide run slots (IAN-348, IAN-359, IAN-441), always in that order so
# two runs can never each hold what the other waits for. Two suites from one
# checkout at once starved each other past the 600-second tool timeout
# (2026-09-24), and one machine-wide lock made every worktree wait for every
# other, so runs queue per worktree and the slots cap the load. Gives up
# after FIXTURE_SHARDS_LOCK_WAIT_SECONDS (default 1200) across both waits. A
# nested run returns at once and takes neither. The wait and the markers are
# environment variables, unlike the other controls, because none can make a
# run shorter: the markers count only while the run they name holds its lock,
# and the wait only decides how long to queue. Without a working perl the run
# goes ahead unqueued, with a warning, as it did before IAN-348.
acquire_run_lock() {
  local run_cap="$1" wait_cap="${FIXTURE_SHARDS_LOCK_WAIT_SECONDS:-$RUN_LOCK_WAIT_DEFAULT_SECONDS}" started="$SECONDS"
  [[ "$wait_cap" =~ ^[0-9]+$ ]] || usage_error "FIXTURE_SHARDS_LOCK_WAIT_SECONDS needs a whole number"
  command -v perl >/dev/null 2>&1 || { echo "fixture-shards: perl not found, so this run is not queued behind other runs" >&2; return 0; }
  # A perl that cannot load Fcntl (a bad PERL5OPT or PERL5LIB) would make every
  # try below fail and read as a busy lock until the cap (PR #136 review).
  perl -MFcntl=:flock -e 1 >/dev/null 2>&1 || { echo "fixture-shards: perl cannot take the run lock (it fails to load Fcntl), so this run is not queued behind other runs" >&2; return 0; }
  is_nested_run && return 0
  require_lock_parent_dir
  wait_for_worktree_lock "$wait_cap" "$started"
  wait_for_run_slot "$wait_cap" "$started" "$run_cap"
}

# usage_error <message>: exits 2 with the message and the usage line.
usage_error() {
  echo "run-fixture-shards.sh: $1" >&2
  echo "usage: run-fixture-shards.sh <tests-dir> --all|--affected [--list] [--changed-from <file>] [--results-dir <dir>] [--jobs <n>] [--settle-seconds <n>] [--settle-max-seconds <n>] [--load-from <file>]" >&2
  exit 2
}

main() {
  local tests_dir="${1:-}" mode="${2:-}" list_only="" changed_from="" kept_dir="" fixtures jobs="" settle_seconds="$SERIAL_SETTLE_DEFAULT_SECONDS" settle_max_seconds="$SERIAL_SETTLE_MAX_DEFAULT_SECONDS" result_dir total count status run_cap
  [ -d "$tests_dir" ] || usage_error "no tests directory '$tests_dir'"
  case "$mode" in --all | --affected) ;; *) usage_error "unknown mode '$mode'" ;; esac
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --list) list_only=1; shift ;;
      --changed-from) [ -r "${2:-}" ] || usage_error "--changed-from needs a readable file"; changed_from="$2"; shift 2 ;;
      --jobs) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || usage_error "--jobs needs a positive integer"; jobs="$2"; shift 2 ;;
      --settle-seconds) [[ "${2:-}" =~ ^[0-9]+$ ]] || usage_error "--settle-seconds needs a whole number"; settle_seconds="$2"; shift 2 ;;
      --settle-max-seconds) [[ "${2:-}" =~ ^[0-9]+$ ]] || usage_error "--settle-max-seconds needs a whole number"; settle_max_seconds="$2"; shift 2 ;;
      --load-from) [ -r "${2:-}" ] || usage_error "--load-from needs a readable file"; LOAD_FROM="$2"; shift 2 ;;
      --results-dir) [ -d "${2:-}" ] || usage_error "--results-dir needs an existing directory"; kept_dir="$2"; shift 2 ;;
      *) usage_error "unknown option '$1'" ;;
    esac
  done
  # Cleared before any git query, not only before the fixtures run: an
  # inherited GIT_DIR (a linked-worktree hook exports one) would otherwise
  # make change detection read another repository (PR #42 review round 4).
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
  [ "$settle_max_seconds" -ge "$settle_seconds" ] || usage_error "--settle-max-seconds ($settle_max_seconds) is below --settle-seconds ($settle_seconds)"
  tests_dir=$(cd "$tests_dir" && pwd)
  run_cap=$(max_concurrent_runs) || exit 2
  RUN_LOCK_FILE=$(worktree_lock_path "$tests_dir")
  fixtures=$(ls "$tests_dir"/*.test.sh 2>/dev/null | sort)
  [ -n "$fixtures" ] || { echo "fixture-shards: no fixtures in $tests_dir, which is a broken checkout, not a pass"; exit 1; }
  total=$(grep -c . <<< "$fixtures")
  SELECTED="$fixtures"; REASON=""
  [ "$mode" = --affected ] && affected_selection "$tests_dir" "$fixtures" "$changed_from"
  if [ -n "$list_only" ]; then
    while IFS= read -r fixture; do [ -n "$fixture" ] && basename "$fixture"; done <<< "$SELECTED"
    exit 0
  fi
  count=$(grep -c . <<< "$SELECTED")
  # After --list, which runs nothing, and before the job count, which should
  # read the load once the run ahead has finished.
  acquire_run_lock "$run_cap"
  [ -n "$jobs" ] || jobs=$(default_job_count)
  echo "fixture-shards: ${mode#--} ran $count of $total fixtures with $jobs jobs${REASON:+ (everything: $REASON)}"
  [ -z "$RUN_SLOT" ] || echo "fixture-shards: run slot $RUN_SLOT of $run_cap (FIXTURE_SHARDS_MAX_RUNS, default half the CPUs)"
  result_dir="${kept_dir:-$(mktemp -d "${TMPDIR:-/tmp}/fixture-shards.XXXXXX")}"
  export CLAUDE_FIRE_LOG=/dev/null
  run_selected "$SELECTED" "$jobs" "$result_dir" "$settle_seconds" "$settle_max_seconds"
  report_results "$SELECTED" "$result_dir"; status=$?
  [ -n "$kept_dir" ] || rm -rf "$result_dir"
  exit "$status"
}
main "$@"
