#!/usr/bin/env bash
# run-fixture-shards.sh: the one runner behind both fixture suites (R-509,
# IAN-94). It runs the *.test.sh fixtures of one directory in parallel and
# decides which of them a run needs.
#
#   run-fixture-shards.sh <tests-dir> --all
#       every fixture: the parallel batch first, then each `# Shard: serial`
#       fixture alone, because a timing-sensitive fixture measured under the
#       load of its neighbours fails for reasons that are not its subject's.
#       Pre-push and CI use this mode through run-tests.sh.
#   run-fixture-shards.sh <tests-dir> --affected
#       the Stop gate's mode. The fast tier (every fixture with no
#       `# Shard: slow` or `# Shard: serial` header) always runs, so the
#       closure and tree-scanning checks, which are nearly all fast, never
#       wait for pre-push. A slow or serial fixture runs when its text names a changed
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
# A fixture passes on exit 0 with a PASS line and no FAIL line, the verdict
# the sequential runners applied; output is printed in name order once the
# run finishes, so a parallel run reads the same as a sequential one. Exit 0
# when every chosen fixture passed, 1 when one failed, 2 on a usage error.
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

# run_one_fixture <result dir> <fixture>: runs one fixture with stdin closed
# and records its verdict and output. Invoked through xargs as a subcommand,
# which appends the fixture last, hence the argument order.
run_one_fixture() {
  local result_dir="$1" fixture="$2" name output status
  name=$(basename "$fixture")
  output=$(bash "$fixture" </dev/null 2>&1); status=$?
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
# failing fixture followed by its failure lines and last three lines; true
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
      grep -E '^FAIL' "$result_dir/$name.out" 2>/dev/null
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

# usage_error <message>: exits 2 with the message and the usage line.
usage_error() {
  echo "run-fixture-shards.sh: $1" >&2
  echo "usage: run-fixture-shards.sh <tests-dir> --all|--affected [--list] [--changed-from <file>] [--results-dir <dir>] [--jobs <n>] [--settle-seconds <n>] [--settle-max-seconds <n>] [--load-from <file>]" >&2
  exit 2
}

main() {
  local tests_dir="${1:-}" mode="${2:-}" list_only="" changed_from="" kept_dir="" fixtures jobs="" settle_seconds="$SERIAL_SETTLE_DEFAULT_SECONDS" settle_max_seconds="$SERIAL_SETTLE_MAX_DEFAULT_SECONDS" result_dir total count status
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
  tests_dir=$(cd "$tests_dir" && pwd)
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
  [ -n "$jobs" ] || jobs=$(default_job_count)
  echo "fixture-shards: ${mode#--} ran $count of $total fixtures with $jobs jobs${REASON:+ (everything: $REASON)}"
  result_dir="${kept_dir:-$(mktemp -d "${TMPDIR:-/tmp}/fixture-shards.XXXXXX")}"
  export CLAUDE_FIRE_LOG=/dev/null
  run_selected "$SELECTED" "$jobs" "$result_dir" "$settle_seconds" "$settle_max_seconds"
  report_results "$SELECTED" "$result_dir"; status=$?
  [ -n "$kept_dir" ] || rm -rf "$result_dir"
  exit "$status"
}
main "$@"
