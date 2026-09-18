#!/usr/bin/env bash
# Shard: slow
# Verifies enforce/run-fixture-shards.sh, the one runner behind both fixture
# suites (R-509, IAN-94). Full mode runs every fixture in parallel and the
# `# Shard: serial` ones alone afterwards. Affected mode always runs the fast
# tier, adds a `# Shard: slow` fixture only when it names a changed file, a
# changed path matches its `# Watches:` globs, or it is itself changed, and
# falls back to everything when a changed file maps to no fixture, is shared
# by all of them, or cannot be listed. A fixture passes only on exit 0 with a
# PASS line and no FAIL line, the verdict the old sequential runners applied.
#
# The fixtures under test are fakes in a sandbox git repository that write
# marker files, so each case asserts which fixtures ran, not what they print.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../harness-root.sh"
RUNNER="$CLAUDE_HARNESS_ROOT/enforce/run-fixture-shards.sh"

fail=0
check() {
  local name="$1"; shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}
not() { ! "$@"; }

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/run-fixture-shards.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT
REPO="$SANDBOX/repo"
TESTS="$REPO/claude/enforce/tests"
MARKS="$SANDBOX/marks"
mkdir -p "$TESTS" "$REPO/claude/hooks" "$MARKS"
export MARKS
# No settle pause except in the cases that test it, so the other full-mode
# cases do not each pay the runner's default. RUN_OPTS reaches every
# run_runner call; the direct calls below pass --settle-seconds themselves.
# The runner reads the machine's load for its settle wait and default job
# count; the fixture feeds it a file instead, so no case depends on how busy
# the machine running it is. LOAD_FILE holds a quiet load unless a case says
# otherwise.
LOAD_FILE="$SANDBOX/load"
echo 0 > "$LOAD_FILE"
RUN_OPTS=(--settle-seconds 0 --load-from "$LOAD_FILE")

# write_fixture <name> <header or ""> <body line>
write_fixture() {
  {
    printf '#!/usr/bin/env bash\n'
    [ -n "$2" ] && printf '%s\n' "$2"
    printf 'touch "$MARKS/%s"\n' "$1"
    printf '%s\n' "$3"
    printf 'echo "%s PASS"\n' "$1"
  } > "$TESTS/$1.test.sh"
}
write_fixture fast-a "" '# exercises hooks/alpha.sh'
write_fixture fast-b "" ': no subject named'
write_fixture slow-c '# Shard: slow' '# exercises hooks/gamma.sh'
# The serial fixture records which markers existed when it started, to prove
# it ran after the whole parallel batch had finished.
write_fixture serial-d '# Shard: serial' 'ls "$MARKS" > "$MARKS/.seen-by-serial"'
: > "$REPO/claude/hooks/alpha.sh"
: > "$REPO/claude/hooks/gamma.sh"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" add -A
git -C "$REPO" commit -q -m seed

ran()     { [ -e "$MARKS/$1" ]; }
reset()   { rm -f "$MARKS"/* "$MARKS"/.seen-by-serial; }
# run_runner <mode> [changed files, newline separated]
run_runner() {
  local mode="$1" changed="${2:-}"
  reset
  if [ -n "$changed" ]; then
    OUT=$(bash "$RUNNER" "$TESTS" "$mode" ${RUN_OPTS[@]+"${RUN_OPTS[@]}"} --changed-from "$(changes_file "$changed")" </dev/null 2>&1); STATUS=$?
  else
    OUT=$(cd "$REPO" && bash "$RUNNER" "$TESTS" "$mode" ${RUN_OPTS[@]+"${RUN_OPTS[@]}"} </dev/null 2>&1); STATUS=$?
  fi
}
out_has() { grep -qF -- "$1" <<< "$OUT"; }
# changes_file <newline-separated paths>: writes them for --changed-from.
changes_file() { printf '%s\n' "$1" > "$SANDBOX/changes.txt"; echo "$SANDBOX/changes.txt"; }

# --- full mode ---
run_runner --all
check "full mode exits 0 when every fixture passes" [ "$STATUS" -eq 0 ]
check "full mode runs the fast fixtures" ran fast-a
check "full mode runs the slow fixture" ran slow-c
check "full mode runs the serial fixture" ran serial-d
check "the serial fixture starts after every parallel fixture finished" \
  grep -qx 'slow-c' "$MARKS/.seen-by-serial"
check "each fixture gets an ok line" out_has "ok   fast-a.test.sh"

# --- affected mode, fast tier always ---
run_runner --affected 'claude/hooks/alpha.sh'
check "a fast-tier change runs the fast tier" ran fast-b
check "a change no slow fixture names skips the slow fixture" not ran slow-c
check "a change the serial fixture does not name skips it" not ran serial-d
check "affected mode says how many fixtures it chose" out_has "ran 2 of 4"

run_runner --affected 'claude/hooks/gamma.sh'
check "a change a slow fixture names runs that slow fixture" ran slow-c
check "the fast tier runs alongside it" ran fast-a

run_runner --affected 'claude/enforce/tests/slow-c.test.sh'
check "editing a slow fixture runs that fixture" ran slow-c

# --- affected mode, fallbacks ---
run_runner --affected 'docs/prs/unrelated-note.md'
check "a change no fixture names runs everything" ran slow-c
check "the unmapped fallback includes the serial fixture" ran serial-d
check "the unmapped fallback says why" out_has "unmapped"

run_runner --affected $'claude/hooks/alpha.sh\nclaude/enforce/harness-root.sh'
check "a shared file runs everything even beside a mapped change" ran slow-c

# --- changed files derived from git when not injected ---
printf 'changed\n' > "$REPO/claude/hooks/gamma.sh"
run_runner --affected
check "an uncommitted edit is detected from git" ran slow-c
git -C "$REPO" checkout -q -- claude/hooks/gamma.sh
printf 'new\n' > "$REPO/claude/hooks/alpha.sh"; git -C "$REPO" commit -qam 'alpha edit'
run_runner --affected
check "a clean tree with no upstream compares against the root commit" not ran slow-c
check "that comparison still sees the committed alpha edit" ran fast-a

# --- verdicts ---
# No case name here spells the failure marker in capitals: the verdict rule
# rejects any output containing it, so this fixture's own passing lines
# would read as failures.
printf '#!/usr/bin/env bash\necho "FAIL: broken"\necho "PASS"\n' > "$TESTS/fast-e.test.sh"
run_runner --all
check "a fixture printing a failure line fails the run" [ "$STATUS" -ne 0 ]
check "the failing fixture is named" out_has "FAIL fast-e.test.sh"
printf '#!/usr/bin/env bash\necho "PASS"\nexit 3\n' > "$TESTS/fast-e.test.sh"
run_runner --all
check "a fixture exiting non-zero fails the run despite PASS" [ "$STATUS" -ne 0 ]
printf '#!/usr/bin/env bash\necho "nothing to say"\n' > "$TESTS/fast-e.test.sh"
run_runner --all
check "a fixture printing no PASS fails the run" [ "$STATUS" -ne 0 ]
# Output far past the 64KB pipe buffer with PASS on the first line: a verdict
# piped into `grep -q` under pipefail sees the writer die of SIGPIPE once grep
# exits early, and reports a passing fixture as failed (PR #42 CI, 2026-09-18).
printf '#!/usr/bin/env bash\necho PASS\nfor _ in $(seq 20000); do echo "line of ordinary fixture output"; done\n' > "$TESTS/fast-e.test.sh"
run_runner --all
check "a passing fixture with very long output passes" [ "$STATUS" -eq 0 ]
rm -f "$TESTS/fast-e.test.sh"

# --- the parallel batch really runs concurrently ---
# Each fixture waits for the other's start marker, so the pair can only both
# pass if they run at the same time; run one after another, the first times out.
for pair in p1 p2; do
  other=$([ "$pair" = p1 ] && echo p2 || echo p1)
  printf '#!/usr/bin/env bash\ntouch "$MARKS/start-%s"\nfor _ in $(seq 50); do [ -e "$MARKS/start-%s" ] && { echo PASS; exit 0; }; sleep 0.1; done\necho "FAIL: ran alone"\n' \
    "$pair" "$other" > "$TESTS/$pair.test.sh"
done
RUN_OPTS=(--settle-seconds 0 --jobs 4 --load-from "$LOAD_FILE")
run_runner --all
check "fixtures in the parallel batch overlap in time" [ "$STATUS" -eq 0 ]
RUN_OPTS=(--settle-seconds 0 --jobs 1 --load-from "$LOAD_FILE")
run_runner --all
check "one job runs them one at a time (the control)" [ "$STATUS" -ne 0 ]
# An inherited job count is ignored: exported as 1 around the default, the
# pair still overlaps (PR #42 late review).
RUN_OPTS=(--settle-seconds 0 --load-from "$LOAD_FILE")
FIXTURE_SHARD_JOBS=1 run_runner --all
check "an inherited FIXTURE_SHARD_JOBS does not change the job count" [ "$STATUS" -eq 0 ]
rm -f "$TESTS/p1.test.sh" "$TESTS/p2.test.sh"

# --- the serial fixtures wait for the batch's load to settle ---
# A timing fixture started the instant the parallel batch ends measures the
# batch's leftover load (2026-09-18: hook-latency failed by 2ms straight after
# the batch and passed three times out of three alone). The fast fixtures
# stamp their finish time, the serial one its start, and the gap must cover
# the settle pause.
write_fixture fast-a "" 'date +%s > "$MARKS/.batch-end-a"'
write_fixture fast-b "" 'date +%s > "$MARKS/.batch-end-b"'
write_fixture serial-d '# Shard: serial' 'date +%s > "$MARKS/.serial-start"'
RUN_OPTS=(--settle-seconds 2 --load-from "$LOAD_FILE")
run_runner --all
settled_before_serial() {
  local batch_end serial_start
  batch_end=$(cat "$MARKS/.batch-end-a" "$MARKS/.batch-end-b" | sort -n | tail -1)
  serial_start=$(cat "$MARKS/.serial-start")
  [ $(( serial_start - batch_end )) -ge "$1" ]
}
check "the serial fixture starts only after the settle pause" settled_before_serial 2
# An inherited zero cannot skip the default pause (PR #42 late review).
RUN_OPTS=(--load-from "$LOAD_FILE")
FIXTURE_SERIAL_SETTLE_SECONDS=0 run_runner --all
check "an inherited FIXTURE_SERIAL_SETTLE_SECONDS cannot skip the default pause" settled_before_serial 5

# The pause before serial fixtures also waits for the machine's load to fall
# below its CPU count, because several sessions sharding at once drove the
# load to 124 and the timing fixture failed after a fixed pause (2026-09-18).
settled_within() {
  local batch_end serial_start
  batch_end=$(cat "$MARKS/.batch-end-a" "$MARKS/.batch-end-b" | sort -n | tail -1)
  serial_start=$(cat "$MARKS/.serial-start")
  [ $(( serial_start - batch_end )) -lt "$1" ]
}
echo 999 > "$LOAD_FILE"
( sleep 3; echo 0 > "$LOAD_FILE" ) &
RUN_OPTS=(--settle-seconds 0 --settle-max-seconds 30 --load-from "$LOAD_FILE")
run_runner --all
wait
check "the serial fixtures wait while the load is high" settled_before_serial 2
check "they start soon after the load falls, well before the cap" settled_within 15
echo 999 > "$LOAD_FILE"
RUN_OPTS=(--settle-seconds 0 --settle-max-seconds 2 --load-from "$LOAD_FILE")
run_runner --all
check "a load that never falls still lets the run finish at the cap" [ "$STATUS" -eq 0 ]
check "the capped wait lasts about the cap" settled_within 10
check "a capped wait is reported" out_has "load still"

# The default job count is the idle CPUs, from a quarter of the CPUs to 8, so
# a second session sharding on a busy machine adds little load of its own and
# still finishes inside the Stop gate's timeout.
CPUS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)
FLOOR=$(( CPUS / 4 )); [ "$FLOOR" -lt 1 ] && FLOOR=1
IDLE=$(( FLOOR + 1 ))
if [ "$IDLE" -le 8 ] && [ "$IDLE" -lt "$CPUS" ]; then
  echo $(( CPUS - IDLE )) > "$LOAD_FILE"
  RUN_OPTS=(--settle-seconds 0 --load-from "$LOAD_FILE")
  run_runner --all
  check "the default job count is the idle CPUs" out_has "with $IDLE jobs"
fi
echo 999 > "$LOAD_FILE"
run_runner --all
check "a saturated machine still gets a quarter of its CPUs" out_has "with $FLOOR jobs"
echo 0 > "$LOAD_FILE"
RUN_OPTS=(--settle-seconds 0 --load-from "$LOAD_FILE")
RUN_OPTS=(--settle-seconds 0 --load-from "$LOAD_FILE")
rm -f "$MARKS"/.batch-end-* "$MARKS/.serial-start"

# --- a tree holding only serial fixtures ---
# An empty parallel batch must not start a child with no fixture argument,
# which xargs does on some platforms when its input is empty (PR #42 review).
SERIAL_ONLY="$SANDBOX/serial-only/claude/enforce/tests"
mkdir -p "$SERIAL_ONLY"
printf '#!/usr/bin/env bash\n# Shard: serial\ntouch "$MARKS/serial-only"\necho PASS\n' > "$SERIAL_ONLY/only.test.sh"
reset
OUT=$(bash "$RUNNER" "$SERIAL_ONLY" --all </dev/null 2>&1); STATUS=$?
check "a serial-only tree passes when its fixture passes" [ "$STATUS" -eq 0 ]
check "the serial-only fixture ran" ran serial-only

# --- affected mode outside a git repository ---
# With no repository there is no way to know what changed, so nothing may be
# ruled out: everything runs (PR #42 review).
NO_GIT="$SANDBOX/no-git/claude/enforce/tests"
mkdir -p "$NO_GIT"
printf '#!/usr/bin/env bash\ntouch "$MARKS/nogit-fast"\necho PASS\n' > "$NO_GIT/fast.test.sh"
printf '#!/usr/bin/env bash\n# Shard: slow\ntouch "$MARKS/nogit-slow"\necho PASS\n' > "$NO_GIT/slow.test.sh"
reset
OUT=$(cd "$SANDBOX" && GIT_CEILING_DIRECTORIES="$SANDBOX" bash "$RUNNER" "$NO_GIT" --affected </dev/null 2>&1); STATUS=$?
check "affected mode outside git runs the slow tier too" ran nogit-slow
check "affected mode outside git says why" out_has "no git repository"

# --- a slow fixture's `# Watches:` globs select it without naming a file ---
# Tree-scanning fixtures depend on files they never name (PR #42 review).
WATCH_TREE="$SANDBOX/watch/claude/enforce/tests"
mkdir -p "$WATCH_TREE"
printf '#!/usr/bin/env bash\n# exercises skills/x/SKILL.md\ntouch "$MARKS/watch-fast"\necho PASS\n' > "$WATCH_TREE/fast.test.sh"
printf '#!/usr/bin/env bash\n# Shard: slow\n# Watches: hooks/*.sh settings.json\ntouch "$MARKS/watch-slow"\necho PASS\n' > "$WATCH_TREE/scanner.test.sh"
reset
OUT=$(bash "$RUNNER" "$WATCH_TREE" --affected --changed-from "$(changes_file 'claude/hooks/zeta.sh')" </dev/null 2>&1)
check "a watched glob selects the slow fixture" ran watch-slow
check "a file matched only by a watch glob is not unmapped" not out_has "unmapped"
reset
OUT=$(bash "$RUNNER" "$WATCH_TREE" --affected --changed-from "$(changes_file 'claude/settings.json')" </dev/null 2>&1)
check "a watched exact path selects the slow fixture" ran watch-slow
reset
OUT=$(bash "$RUNNER" "$WATCH_TREE" --affected --changed-from "$(changes_file 'claude/skills/x/SKILL.md')" </dev/null 2>&1)
check "a change outside the watch globs leaves the slow fixture out" not ran watch-slow

# --- the real tree keeps its whole-tree scanners in reach ---
# List-only selection over this checkout's own fixtures, so the headers that
# carry the guarantee cannot be dropped without this failing.
# Guard first: a runner that ignored --list would run this checkout's real
# suite, this fixture included, recursively. Prove on the sandbox tree that
# list mode runs nothing before pointing it at the real one.
reset
LISTED=$(bash "$RUNNER" "$TESTS" --affected --list --changed-from "$(changes_file 'claude/hooks/gamma.sh')" </dev/null 2>/dev/null)
list_mode_is_inert() { [ -z "$(ls "$MARKS")" ] && grep -qx 'slow-c.test.sh' <<< "$LISTED"; }
check "list mode names the chosen fixtures and runs none of them" list_mode_is_inert
if ! list_mode_is_inert; then
  echo "run-fixture-shards.test.sh: list mode is not inert, so the real-tree cases are not run"
  exit 1
fi
real_selection() {
  bash "$RUNNER" "$CLAUDE_HARNESS_ROOT/enforce/tests" --affected --list --changed-from "$(changes_file "$1")" </dev/null 2>/dev/null
}
selection_has() { grep -qx "$2" <<< "$1"; }
SEL=$(real_selection 'claude/skills/task-start/SKILL.md')
check "an unrelated text edit still runs the credential-shape scan" selection_has "$SEL" credential-shape-scan.test.sh
SEL=$(real_selection 'claude/hooks/secret-scan.sh')
check "a hook edit runs the hook-latency guard" selection_has "$SEL" hook-latency.test.sh
SEL=$(real_selection 'claude/settings.json')
check "a settings edit runs the hook-latency guard" selection_has "$SEL" hook-latency.test.sh
SEL=$(real_selection 'claude/CLAUDE-GO.md')
check "a convention-file edit runs the track invariants" selection_has "$SEL" convention-track-invariants.test.sh
SEL=$(real_selection 'claude/hooks/tests/session-end.test.sh')
check "a fixture edit runs the implementation-root sweep" selection_has "$SEL" fixture-implementation-root.test.sh

# --- inherited environment cannot steer a real run ---
# The test-only inputs are arguments, so a variable exported in the caller's
# shell (the old injection names included) changes nothing (PR #42 review).
printf 'changed\n' > "$REPO/claude/hooks/gamma.sh"
reset
OUT=$(cd "$REPO" && FIXTURE_CHANGED_FILES='claude/hooks/alpha.sh' FIXTURE_SHARD_LIST_ONLY=1 bash "$RUNNER" "$TESTS" --affected </dev/null 2>&1); STATUS=$?
check "an inherited change list does not hide a real change" ran slow-c
check "an inherited list-only flag does not stop the run" ran fast-a
git -C "$REPO" checkout -q -- claude/hooks/gamma.sh

# --- git that cannot list changes ---
# A failing status or diff means the change set is unknown, so nothing may be
# ruled out (PR #42 review).
printf 'changed\n' > "$REPO/claude/hooks/alpha.sh"
chmod 000 "$REPO/.git/index"
reset
OUT=$(cd "$REPO" && bash "$RUNNER" "$TESTS" --affected </dev/null 2>&1); STATUS=$?
chmod 644 "$REPO/.git/index"
git -C "$REPO" checkout -q -- claude/hooks/alpha.sh
check "an unreadable change set runs everything" ran slow-c
check "the git failure is named" out_has "git could not list"

# --- an empty tree is a failure, not a pass ---
EMPTY_TREE="$SANDBOX/empty/claude/enforce/tests"
mkdir -p "$EMPTY_TREE"
OUT=$(bash "$RUNNER" "$EMPTY_TREE" --all </dev/null 2>&1); STATUS=$?
check "a tree with no fixtures fails the run" [ "$STATUS" -ne 0 ]
check "the empty tree is named" out_has "no fixtures"

# --- a checkout path containing spaces ---
# Fixture paths are carried one per line and handed to xargs NUL-delimited,
# so a space in the checkout path never splits one fixture into several
# arguments (PR #42 review round 4).
SPACED="$SANDBOX/with space/claude/enforce/tests"
mkdir -p "$SPACED"
printf '#!/usr/bin/env bash\ntouch "$MARKS/spaced-fast"\n# exercises hooks/alpha.sh\necho PASS\n' > "$SPACED/fast.test.sh"
printf '#!/usr/bin/env bash\n# Shard: slow\n# exercises hooks/gamma.sh\ntouch "$MARKS/spaced-slow"\necho PASS\n' > "$SPACED/slow.test.sh"
printf '#!/usr/bin/env bash\n# Shard: serial\ntouch "$MARKS/spaced-serial"\necho PASS\n' > "$SPACED/serial.test.sh"
reset
OUT=$(bash "$RUNNER" "$SPACED" --all --settle-seconds 0 --load-from "$LOAD_FILE" </dev/null 2>&1); STATUS=$?
check "a spaced checkout path passes in full mode" [ "$STATUS" -eq 0 ]
check "every fixture under a spaced path ran" ran spaced-serial
reset
OUT=$(bash "$RUNNER" "$SPACED" --affected --changed-from "$(changes_file 'claude/hooks/gamma.sh')" </dev/null 2>&1); STATUS=$?
check "affected mode under a spaced path selects the named slow fixture" ran spaced-slow

# --- inherited git context is cleared before selection ---
# A caller exporting GIT_DIR (a linked-worktree hook does) must not make the
# runner read another repository's changes (PR #42 review round 4).
DECOY_REPO="$SANDBOX/decoy"
git init -q "$DECOY_REPO"
git -C "$DECOY_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed
printf 'changed\n' > "$REPO/claude/hooks/gamma.sh"
reset
OUT=$(cd "$REPO" && GIT_DIR="$DECOY_REPO/.git" GIT_WORK_TREE="$DECOY_REPO" bash "$RUNNER" "$TESTS" --affected </dev/null 2>&1); STATUS=$?
git -C "$REPO" checkout -q -- claude/hooks/gamma.sh
check "an inherited GIT_DIR does not redirect change detection" ran slow-c

# --- failure lines survive a long tail ---
# A failing fixture's report carries every failure line, not only its last
# three lines, which on 2026-09-18 were all passing cases and hid the real one
# (main CI after #42).
printf '#!/usr/bin/env bash\necho "FAIL: the early case"\nfor n in 1 2 3 4 5 6; do echo "PASS: later case $n"; done\n' > "$TESTS/fast-e.test.sh"
run_runner --all
check "the report names a failure line buried before the tail" out_has "FAIL: the early case"
rm -f "$TESTS/fast-e.test.sh"

# --- change detection against an upstream and against origin/main ---
# The base is the upstream when one exists, else the merge base with
# origin/main; each must count this branch's own commits and nothing already
# pushed or already on main (PR #42 late review).
BASE_REMOTE="$SANDBOX/remote.git"
BASE_REPO="$SANDBOX/base-repo"
git init -q --bare "$BASE_REMOTE"
cp -R "$REPO" "$BASE_REPO"
# Earlier sections rewrote fast-a so it no longer names hooks/alpha.sh;
# restore the mapping so an alpha change is a mapped fast-tier change here.
printf '#!/usr/bin/env bash\n# exercises hooks/alpha.sh\ntouch "$MARKS/fast-a"\necho PASS\n' > "$BASE_REPO/claude/enforce/tests/fast-a.test.sh"
git -C "$BASE_REPO" commit -qam 'restore fast-a mapping'
git -C "$BASE_REPO" remote add origin "$BASE_REMOTE"
git -C "$BASE_REPO" branch -M main
git -C "$BASE_REPO" push -q -u origin main
BASE_TESTS="$BASE_REPO/claude/enforce/tests"
printf 'pushed\n' > "$BASE_REPO/claude/hooks/gamma.sh"
git -C "$BASE_REPO" commit -qam 'gamma, pushed'
git -C "$BASE_REPO" push -q
printf 'unpushed\n' > "$BASE_REPO/claude/hooks/alpha.sh"
git -C "$BASE_REPO" commit -qam 'alpha, unpushed'
reset
OUT=$(cd "$BASE_REPO" && bash "$RUNNER" "$BASE_TESTS" --affected --settle-seconds 0 --load-from "$LOAD_FILE" </dev/null 2>&1)
check "with an upstream, an already pushed change is not counted" not ran slow-c
check "with an upstream, the unpushed commit is counted" ran fast-a
# The upstream moving ahead must not count its own new files as this
# branch's changes: a two-dot diff against a moved base listed everything main
# had gained and forced a full run at every turn end (2026-09-18).
AHEAD_CLONE="$SANDBOX/ahead-clone"
git clone -q "$BASE_REMOTE" "$AHEAD_CLONE"
mkdir -p "$AHEAD_CLONE/docs"
printf 'new on main\n' > "$AHEAD_CLONE/docs/landed-on-main.md"
git -C "$AHEAD_CLONE" add -A
git -C "$AHEAD_CLONE" -c user.email=t@t -c user.name=t commit -qm 'main moves ahead'
git -C "$AHEAD_CLONE" push -q
git -C "$BASE_REPO" fetch -q
reset
OUT=$(cd "$BASE_REPO" && bash "$RUNNER" "$BASE_TESTS" --affected --settle-seconds 0 --load-from "$LOAD_FILE" </dev/null 2>&1)
check "a file that landed on the upstream after the branch point is not a change" not out_has "unmapped"
git -C "$BASE_REPO" checkout -q -b topic origin/main
git -C "$BASE_REPO" branch -q --unset-upstream 2>/dev/null
printf 'topic\n' > "$BASE_REPO/claude/hooks/gamma.sh"
git -C "$BASE_REPO" commit -qam 'gamma on topic'
reset
OUT=$(cd "$BASE_REPO" && bash "$RUNNER" "$BASE_TESTS" --affected --settle-seconds 0 --load-from "$LOAD_FILE" </dev/null 2>&1)
check "without an upstream, the branch's own commit against origin/main is counted" ran slow-c

# --- toolchain files are shared ---
# A change to the ESLint bundle's manifest or config reaches every lint-driven
# fixture, whether or not one of them names the file (PR #42 late review).
SEL=$(real_selection 'claude/enforce/package-lock.json')
check "a lockfile change runs the slow lint fixtures too" selection_has "$SEL" test-quality-rules.test.sh
SEL=$(real_selection 'claude/enforce/eslint.config.mjs')
check "an ESLint config change runs the slow lint fixtures too" selection_has "$SEL" naming-lexicon.test.sh

# --- per-fixture results kept for a caller ---
# tdd.sh builds its shell-fixture report from these files, so each fixture's
# output, verdict, and exit status survive the run in the directory named.
KEPT="$SANDBOX/kept"
mkdir -p "$KEPT"
printf '#!/usr/bin/env bash\necho "saying hello"\nexit 7\n' > "$TESTS/fast-e.test.sh"
reset
OUT=$(bash "$RUNNER" "$TESTS" --all --results-dir "$KEPT" --settle-seconds 0 --load-from "$LOAD_FILE" </dev/null 2>&1); STATUS=$?
check "a kept results dir holds each fixture's exit status" grep -qx 7 "$KEPT/fast-e.test.sh.status"
check "a kept results dir holds each fixture's output" grep -qx 'saying hello' "$KEPT/fast-e.test.sh.out"
check "a kept results dir holds each fixture's verdict" grep -qx ok "$KEPT/fast-a.test.sh.verdict"
check "a kept results dir survives the run" [ -f "$KEPT/fast-b.test.sh.status" ]
rm -f "$TESTS/fast-e.test.sh"
OUT=$(bash "$RUNNER" "$TESTS" --all --results-dir "$SANDBOX/absent" --settle-seconds 0 --load-from "$LOAD_FILE" 2>&1); STATUS=$?
check "a results dir that does not exist is a usage error" [ "$STATUS" -eq 2 ]

# --- usage ---
OUT=$(bash "$RUNNER" "$TESTS" --bogus 2>&1); STATUS=$?
check "an unknown mode is refused" [ "$STATUS" -eq 2 ]

[ "$fail" -eq 0 ] && echo "run-fixture-shards.test.sh PASS"
exit "$fail"
