#!/usr/bin/env bash
# Shard: slow
# Verifies enforce/run-fixture-shards.sh, the one runner behind both fixture
# suites (R-509, IAN-94). Full mode runs every fixture in parallel and the
# `# Shard: serial` ones alone afterwards. Affected mode always runs the fast
# tier, adds a `# Shard: slow` fixture only when it names a changed file or is
# itself changed, and falls back to everything when a changed file maps to no
# fixture or is shared by all of them. A fixture passes only on exit 0 with a
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
# No settle pause except in the one case that tests it, so the other full-mode
# cases do not each pay the runner's default.
export FIXTURE_SERIAL_SETTLE_SECONDS=0

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
    OUT=$(FIXTURE_CHANGED_FILES="$changed" bash "$RUNNER" "$TESTS" "$mode" </dev/null 2>&1); STATUS=$?
  else
    OUT=$(cd "$REPO" && bash "$RUNNER" "$TESTS" "$mode" </dev/null 2>&1); STATUS=$?
  fi
}
out_has() { printf '%s' "$OUT" | grep -qF -- "$1"; }

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
rm -f "$TESTS/fast-e.test.sh"

# --- the parallel batch really runs concurrently ---
# Each fixture waits for the other's start marker, so the pair can only both
# pass if they run at the same time; run one after another, the first times out.
for pair in p1 p2; do
  other=$([ "$pair" = p1 ] && echo p2 || echo p1)
  printf '#!/usr/bin/env bash\ntouch "$MARKS/start-%s"\nfor _ in $(seq 50); do [ -e "$MARKS/start-%s" ] && { echo PASS; exit 0; }; sleep 0.1; done\necho "FAIL: ran alone"\n' \
    "$pair" "$other" > "$TESTS/$pair.test.sh"
done
FIXTURE_SHARD_JOBS=4 run_runner --all
check "fixtures in the parallel batch overlap in time" [ "$STATUS" -eq 0 ]
FIXTURE_SHARD_JOBS=1 run_runner --all
check "one job runs them one at a time (the control)" [ "$STATUS" -ne 0 ]
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
FIXTURE_SERIAL_SETTLE_SECONDS=2 run_runner --all
settled_before_serial() {
  local batch_end serial_start
  batch_end=$(cat "$MARKS/.batch-end-a" "$MARKS/.batch-end-b" | sort -n | tail -1)
  serial_start=$(cat "$MARKS/.serial-start")
  [ $(( serial_start - batch_end )) -ge 2 ]
}
check "the serial fixture starts only after the settle pause" settled_before_serial
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
OUT=$(cd "$SANDBOX" && env -u FIXTURE_CHANGED_FILES GIT_CEILING_DIRECTORIES="$SANDBOX" bash "$RUNNER" "$NO_GIT" --affected </dev/null 2>&1); STATUS=$?
check "affected mode outside git runs the slow tier too" ran nogit-slow
check "affected mode outside git says why" out_has "no git repository"

# --- usage ---
OUT=$(bash "$RUNNER" "$TESTS" --bogus 2>&1); STATUS=$?
check "an unknown mode is refused" [ "$STATUS" -eq 2 ]

[ "$fail" -eq 0 ] && echo "run-fixture-shards.test.sh PASS"
exit "$fail"
