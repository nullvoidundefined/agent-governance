#!/usr/bin/env bash
# Covers: enforce/handoff-summary.sh
# handoff-summary.test.sh: verifies the hand-off summary block (status, branch,
# head, failing test names, diff stat) built from a test log and a git repo.
# The recurring rule is that the summary carries names and counts only: every
# failure message in the sample logs holds a SENTINEL_RAW_7f3a string, and no
# case may ever see that string in the output. Diff cases run in a throwaway
# repo; git calls strip GIT_* so a hook's GIT_DIR cannot leak into the real repo.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
SCRIPT="$CLAUDE_HARNESS_ROOT/enforce/handoff-summary.sh"
SAMPLES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/handoff-samples"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cleanenv() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE "$@"; }
g() { (cd "$REPO" && cleanenv git "$@"); }

if ! command -v timeout >/dev/null 2>&1; then
  if command -v gtimeout >/dev/null 2>&1; then
    timeout() { gtimeout "$@"; }
  else
    timeout() { shift; "$@"; }
  fi
fi

# ---- throwaway repo: main plus a feature branch with a known diff ----------
REPO="$WORK/repo"
mkdir -p "$REPO"
g init -q -b main
g config user.email t@example.invalid
g config user.name tester
printf 'one\ntwo\n' >"$REPO/a.txt"
g add a.txt
g commit -q -m base
g checkout -q -b feature/handoff
printf 'one\nSENTINEL_RAW_7f3a_diff_hunk\n' >"$REPO/a.txt"
printf 'x\ny\n' >"$REPO/b.txt"
g add a.txt b.txt
g commit -q -m change
# Net against main: a.txt +1 -1, b.txt +2 -0 => 2 files, +3 -1.
EXPECT_DIFF="diff: 2 files changed, +3 -1"

# run <args...>: runs the script inside the repo, sets OUT, ERR, RC.
run() {
  RC=0
  OUT=$(cd "$REPO" && cleanenv bash "$SCRIPT" "$@" 2>"$WORK/err") || RC=$?
  ERR=$(cat "$WORK/err")
}

assert_ok() {
  [ "$RC" -eq 0 ] || fail "$1: expected exit 0, got $RC (stderr: $ERR)"
}

no_sentinel() {
  case "$OUT$ERR" in
    *SENTINEL_RAW*) fail "$1: raw sentinel text leaked into output" ;;
  esac
}

# failing_names: the "  - name" entries of $OUT, sorted, one per line.
failing_names() {
  printf '%s\n' "$OUT" | sed -n 's/^  - //p' | LC_ALL=C sort
}

# expect_names <label> <name>...: exact set of failing names.
expect_names() {
  local label="$1" want got
  shift
  want=$(printf '%s\n' "$@" | LC_ALL=C sort)
  got=$(failing_names)
  [ "$got" = "$want" ] || fail "$label: failing names differ. want:
$want
got:
$got"
}

# line_of <key>: the single output line starting with "<key>:".
line_of() {
  printf '%s\n' "$OUT" | grep "^$1:" || true
}

# structure: every line is a known key line or a "  - " entry.
assert_structure() {
  local line
  while IFS= read -r line; do
    case "$line" in
      "status: green" | "status: red" | "status: unknown") ;;
      "branch: "* | "head: "* | "failing:" | "  - "* | "diff: "*) ;;
      *) fail "$1: unexpected output line: $line" ;;
    esac
  done <<EOF
$OUT
EOF
  [ "$(printf '%s\n' "$OUT" | grep -c '^failing:$')" -eq 1 ] || fail "$1: expected one 'failing:' line"
  [ "$(printf '%s\n' "$OUT" | grep -c '^status: ')" -eq 1 ] || fail "$1: expected one status line"
}

[ -f "$SCRIPT" ] || fail "script missing: $SCRIPT"

# ---- 1. each runner's failure log ------------------------------------------
run --test-log "$SAMPLES/vitest.txt"
assert_ok vitest
[ "$(line_of status)" = "status: red" ] || fail "vitest: status not red"
expect_names vitest \
  "src/x.test.ts > suite > adds numbers" \
  "src/x.test.ts > suite > nested > rejects bad input"
no_sentinel vitest
assert_structure vitest

run --test-log "$SAMPLES/jest.txt"
assert_ok jest
[ "$(line_of status)" = "status: red" ] || fail "jest: status not red"
expect_names jest "math › adds numbers" "math › handles negatives"
no_sentinel jest
assert_structure jest

run --test-log "$SAMPLES/pytest.txt"
assert_ok pytest
[ "$(line_of status)" = "status: red" ] || fail "pytest: status not red"
expect_names pytest \
  "tests/test_x.py::test_name" \
  "tests/test_x.py::TestMath::test_other[case-1]"
no_sentinel pytest
assert_structure pytest

run --test-log "$SAMPLES/bash.txt"
assert_ok bash
[ "$(line_of status)" = "status: red" ] || fail "bash: status not red"
expect_names bash "alpha-guard.test.sh" "beta-guard.test.sh"
no_sentinel bash
assert_structure bash

# ---- 2. green log -----------------------------------------------------------
run --test-log "$SAMPLES/green.txt"
assert_ok green
[ "$(line_of status)" = "status: green" ] || fail "green: status not green"
[ -z "$(failing_names)" ] || fail "green: expected no failing entries"
[ -n "$(line_of failing)" ] || fail "green: missing 'failing:' line"
no_sentinel green
assert_structure green

# ---- 3. no --test-log -------------------------------------------------------
run
assert_ok no-log
[ "$(line_of status)" = "status: unknown" ] || fail "no-log: status not unknown"
[ -z "$(failing_names)" ] || fail "no-log: expected no failing entries"
assert_structure no-log

# ---- 4. mixed log: union across runners -------------------------------------
run --test-log "$SAMPLES/mixed.txt"
assert_ok mixed
[ "$(line_of status)" = "status: red" ] || fail "mixed: status not red"
expect_names mixed \
  "gamma.test.sh" \
  "src/m.test.ts > mixed suite > vitest case" \
  "mixed jest › jest case" \
  "tests/test_m.py::test_mixed"
no_sentinel mixed
assert_structure mixed

# ---- 5. diff line, and no hunk text -----------------------------------------
run --base main --test-log "$SAMPLES/green.txt"
assert_ok diff
[ "$(line_of diff)" = "$EXPECT_DIFF" ] || fail "diff: want '$EXPECT_DIFF', got '$(line_of diff)'"
no_sentinel diff-hunk

run --test-log "$SAMPLES/green.txt"
assert_ok diff-default-base
[ "$(line_of diff)" = "$EXPECT_DIFF" ] || fail "default base main: want '$EXPECT_DIFF', got '$(line_of diff)'"
no_sentinel diff-default-base

# ---- 6. ANSI color codes are stripped before parsing ------------------------
ESC=$(printf '\033')
{
  printf '%s[41m%s[1m FAIL %s[22m%s[49m src/c.test.ts > color suite > color case%s[39m\n' "$ESC" "$ESC" "$ESC" "$ESC" "$ESC"
  printf '%s[31mFAILED%s[0m tests/test_c.py::test_color - AssertionError: SENTINEL_RAW_7f3a_ansi\n' "$ESC" "$ESC"
  printf '%s[31m  ●  color jest › color jest case%s[0m\n' "$ESC" "$ESC"
} >"$WORK/ansi.log"
run --test-log "$WORK/ansi.log"
assert_ok ansi
[ "$(line_of status)" = "status: red" ] || fail "ansi: status not red"
expect_names ansi \
  "src/c.test.ts > color suite > color case" \
  "tests/test_c.py::test_color" \
  "color jest › color jest case"
case "$OUT" in *"$ESC"*) fail "ansi: escape byte present in output" ;; esac
no_sentinel ansi

# ---- 7. branch and head match git -------------------------------------------
run --test-log "$SAMPLES/green.txt"
assert_ok branch-head
want_branch=$(g branch --show-current)
want_head=$(g rev-parse --short HEAD)
[ "$(line_of branch)" = "branch: $want_branch" ] || fail "branch: want '$want_branch', got '$(line_of branch)'"
[ "$(line_of head)" = "head: $want_head" ] || fail "head: want '$want_head', got '$(line_of head)'"

# ---- 8. negative input: exit 2 with a message on stderr ---------------------
expect_usage_error() {
  local label="$1"
  shift
  run "$@"
  [ "$RC" -eq 2 ] || fail "$label: expected exit 2, got $RC"
  [ -n "$ERR" ] || fail "$label: expected a message on stderr"
}

expect_usage_error "missing log" --test-log "$WORK/does-not-exist.log"
expect_usage_error "missing base ref" --base no-such-ref-7f3a --test-log "$SAMPLES/green.txt"
expect_usage_error "unknown option" --bogus
expect_usage_error "unknown option with log" --test-log "$SAMPLES/green.txt" --frobnicate

# Oversized log (5 MB of failure-looking lines): still exits 0 within the
# time limit, and no raw line reaches the output.
BIG="$WORK/big.log"
awk 'BEGIN{while(n<5242880){print "FAIL: SENTINEL_RAW_7f3a_oversized padding padding padding padding padding"; n+=76}}' >"$BIG"
RC=0
OUT=$(cd "$REPO" && cleanenv timeout 60 bash "$SCRIPT" --test-log "$BIG" 2>"$WORK/err") || RC=$?
ERR=$(cat "$WORK/err")
[ "$RC" -eq 0 ] || fail "oversized: expected exit 0 within 60s, got $RC"
no_sentinel oversized
case "$OUT" in *padding*) fail "oversized: raw line text leaked" ;; esac
assert_structure oversized

# ---- 9. PR 4 review cases ----------------------------------------------------
# Console noise shaped like a vitest line must not pass through as a name.
printf '  FAIL  retry a > b: token=SENTINEL_RAW_7f3a_console\n' >"$WORK/console.log"
run --test-log "$WORK/console.log"
assert_ok console
no_sentinel console
# A pytest collection error is a failure, not a green run.
printf 'ERROR tests/test_e.py - ImportError: SENTINEL_RAW_7f3a_collect\n=== 1 error in 0.10s ===\n' >"$WORK/collect.log"
run --test-log "$WORK/collect.log"
assert_ok collect
[ "$(line_of status)" = "status: red" ] || fail "collect: a pytest ERROR must read red"
expect_names collect "tests/test_e.py"
no_sentinel collect
# A parametrized pytest id with a space keeps its whole id.
printf 'FAILED tests/t.py::test_x[a b] - AssertionError: SENTINEL_RAW_7f3a_space\n' >"$WORK/space.log"
run --test-log "$WORK/space.log"
assert_ok space
expect_names space "tests/t.py::test_x[a b]"
no_sentinel space
# CRLF logs parse, and no carriage return reaches the output.
printf ' FAIL  src/r.test.ts > s > crlf case\r\nFAIL crlf.test.sh\r\n' >"$WORK/crlf.log"
run --test-log "$WORK/crlf.log"
assert_ok crlf
expect_names crlf "src/r.test.ts > s > crlf case" "crlf.test.sh"
case "$OUT" in *$'\r'*) fail "crlf: carriage return in output" ;; esac
# A private-mode ANSI sequence is stripped too.
printf '%s[?25l FAIL  src/p.test.ts > s > private%s[?25h\n' "$ESC" "$ESC" >"$WORK/private.log"
run --test-log "$WORK/private.log"
assert_ok private
expect_names private "src/p.test.ts > s > private"

echo "PASS: handoff-summary"
