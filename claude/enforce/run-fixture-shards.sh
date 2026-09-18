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
#       wait for pre-push. A slow fixture runs when its text names a changed
#       file (the path under claude/, or the basename), when a changed path
#       matches a glob on its `# Watches:` line, or when the fixture itself
#       changed. Everything runs when a changed file is named by no
#       fixture in any tree, is one of the shared files every fixture depends
#       on, or cannot be known because there is no git repository, so a change
#       the selector cannot place is never skipped.
#
# Changed files come from FIXTURE_CHANGED_FILES (newline separated, repo
# relative) when set, else from git: the working tree's changes plus the
# commits since the upstream, or since the merge base with origin/main when
# there is no upstream, or since the root commit when there is neither.
# FIXTURE_SHARD_LIST_ONLY=1 prints the chosen fixtures' names and runs
# nothing, so selection can be tested against a real tree.
# FIXTURE_SERIAL_SETTLE_SECONDS sets the pause before the serial fixtures
# (default 5). FIXTURE_SHARD_JOBS sets the parallelism; the default is the CPU count
# capped at 8, where measured wall time stopped improving (2026-09-18: 105s
# at 4 jobs, 62s at 8, 65s at 12 for the enforce and hook trees together).
#
# A fixture passes on exit 0 with a PASS line and no FAIL line, the verdict
# the sequential runners applied; output is printed in name order once the
# run finishes, so a parallel run reads the same as a sequential one. Exit 0
# when every chosen fixture passed, 1 when one failed, 2 on a usage error.
set -uo pipefail

SHARED_FILES="enforce/harness-root.sh enforce/run-fixture-shards.sh enforce/tests/run-tests.sh hooks/tests/run-tests.sh"
MAX_DEFAULT_JOBS=8
SERIAL_SETTLE_DEFAULT_SECONDS=5

# run_one_fixture <result dir> <fixture>: runs one fixture with stdin closed
# and records its verdict and output. Invoked through xargs as a subcommand,
# which appends the fixture last, hence the argument order.
run_one_fixture() {
  local result_dir="$1" fixture="$2" name output status
  name=$(basename "$fixture")
  output=$(bash "$fixture" </dev/null 2>&1); status=$?
  printf '%s\n' "$output" > "$result_dir/$name.out"
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

# default_job_count: CPU count capped at MAX_DEFAULT_JOBS.
default_job_count() {
  local cpus
  cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
  [ "$cpus" -gt "$MAX_DEFAULT_JOBS" ] && cpus=$MAX_DEFAULT_JOBS
  echo "$cpus"
}

# changed_files_from_git <repo root>: working-tree changes plus unpushed or
# branch commits, one repo-relative path per line.
changed_files_from_git() {
  local root="$1" base
  git -C "$root" status --porcelain --untracked-files=all 2>/dev/null | sed -E 's/^.. //; s/^.* -> //; s/^"//; s/"$//'
  if base=$(git -C "$root" rev-parse -q --verify '@{u}' 2>/dev/null); then :
  elif base=$(git -C "$root" merge-base HEAD origin/main 2>/dev/null); then :
  else base=$(git -C "$root" rev-list --max-parents=0 HEAD 2>/dev/null | tail -1); fi
  [ -n "$base" ] && git -C "$root" diff --name-only "$base" HEAD 2>/dev/null
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
    for fixture in $corpus; do names_file "$fixture" "$path" && { placed=yes; break; }; done
    [ "$placed" = yes ] || { echo "unmapped: $path"; return; }
  done <<< "$changed"
}

# select_affected <fixtures> <changed files>: the fast tier plus each slow or
# serial fixture that names a changed file.
select_affected() {
  local fixtures="$1" changed="$2" fixture path
  for fixture in $fixtures; do
    if [ "$(shard_of "$fixture")" = fast ]; then echo "$fixture"; continue; fi
    while IFS= read -r path; do
      [ -n "$path" ] && names_file "$fixture" "$path" && { echo "$fixture"; break; }
    done <<< "$changed"
  done
}

# run_selected <fixtures> <jobs> <result dir>: the parallel batch, then a
# settle pause, then each serial fixture alone. The pause exists because a
# timing fixture started the instant the batch ends measures the batch's
# leftover load: on 2026-09-18 hook-latency failed by 2ms straight after the
# batch and passed three times out of three when run alone. The pause changes
# when the measurement is taken, not what it must meet.
run_selected() {
  local fixtures="$1" jobs="$2" result_dir="$3" fixture serial="" batch=""
  for fixture in $fixtures; do
    if [ "$(shard_of "$fixture")" = serial ]; then serial="$serial $fixture"; else batch="$batch $fixture"; fi
  done
  # Guarded because GNU xargs starts the child once even on empty input, with
  # no fixture argument, which a serial-only tree would report as a failure.
  if [ -n "$batch" ]; then
    for fixture in $batch; do echo "$fixture"; done \
      | xargs -P "$jobs" -n 1 bash "$0" --run-one "$result_dir" 2>/dev/null
  fi
  [ -n "$batch" ] && [ -n "$serial" ] && sleep "${FIXTURE_SERIAL_SETTLE_SECONDS:-$SERIAL_SETTLE_DEFAULT_SECONDS}"
  for fixture in $serial; do bash "$0" --run-one "$result_dir" "$fixture"; done
}

# report_results <fixtures> <result dir>: ok/FAIL lines in name order; true
# when all passed.
report_results() {
  local fixtures="$1" result_dir="$2" fixture name all_passed=0
  for fixture in $fixtures; do
    name=$(basename "$fixture")
    if [ "$(cat "$result_dir/$name.verdict" 2>/dev/null)" = ok ]; then
      echo "ok   $name"
    else
      echo "FAIL $name"; tail -3 "$result_dir/$name.out" 2>/dev/null; all_passed=1
    fi
  done
  return "$all_passed"
}

main() {
  local tests_dir="${1:-}" mode="${2:-}" fixtures selected changed corpus reason root jobs result_dir total count status
  [ -d "$tests_dir" ] || { echo "usage: run-fixture-shards.sh <tests-dir> --all|--affected" >&2; exit 2; }
  case "$mode" in --all | --affected) ;; *) echo "run-fixture-shards.sh: unknown mode '$mode'" >&2; exit 2 ;; esac
  tests_dir=$(cd "$tests_dir" && pwd)
  fixtures=$(ls "$tests_dir"/*.test.sh 2>/dev/null | sort)
  total=$(printf '%s\n' "$fixtures" | grep -c .)
  selected="$fixtures"; reason=""
  if [ "$mode" = --affected ]; then
    if [ -n "${FIXTURE_CHANGED_FILES+set}" ]; then changed="$FIXTURE_CHANGED_FILES"
    else
      root=$(git -C "$tests_dir" rev-parse --show-toplevel 2>/dev/null) || root=""
      changed=$([ -n "$root" ] && changed_files_from_git "$root" | sort -u)
    fi
    corpus=$(ls "$tests_dir"/../../*/tests/*.test.sh "$tests_dir"/*.test.sh 2>/dev/null | sort -u)
    # With no injected list and no repository there is no way to know what
    # changed, so nothing may be ruled out.
    if [ -z "${FIXTURE_CHANGED_FILES+set}" ] && [ -z "$root" ]; then
      reason="no git repository to read changes from"
    else
      reason=$(fallback_reason "$changed" "$corpus")
    fi
    [ -n "$reason" ] || selected=$(select_affected "$fixtures" "$changed")
  fi
  if [ -n "${FIXTURE_SHARD_LIST_ONLY:-}" ]; then
    for fixture in $selected; do basename "$fixture"; done
    exit 0
  fi
  count=$(printf '%s\n' "$selected" | grep -c .)
  jobs="${FIXTURE_SHARD_JOBS:-$(default_job_count)}"
  echo "fixture-shards: ${mode#--} ran $count of $total fixtures with $jobs jobs${reason:+ (everything: $reason)}"
  result_dir=$(mktemp -d "${TMPDIR:-/tmp}/fixture-shards.XXXXXX")
  export CLAUDE_FIRE_LOG=/dev/null
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
  run_selected "$selected" "$jobs" "$result_dir"
  report_results "$selected" "$result_dir"; status=$?
  rm -rf "$result_dir"
  exit "$status"
}
main "$@"
