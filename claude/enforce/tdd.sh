#!/usr/bin/env bash
# tdd.sh: the RED/GREEN evidence for one behavioral slice (R-412), and the
# writer of .claude/tdd-lock.json that hooks/protected-path-guard.sh reads
# (R-410). Four phases, run from anywhere inside the project:
#
#   tdd.sh open "<slice>" [--spec <path>] [--lock <path-or-dir/>]...
#       writes the lock in phase "open": production paths are read-only until
#       the failing test exists and is proven to fail for the right reason.
#   tdd.sh red <test file>...
#       runs the whole suite once and requires: every test in the named files
#       fails for an assertion or a missing-module reason (a syntax error, a
#       file with no tests, a passing test, or a skipped test is refused); no
#       other file fails. Records the pass count outside the named files as the
#       baseline, the sha256 of every named file, and moves to phase "red".
#   tdd.sh green
#       requires the named files to be byte-identical to the lock and, when the
#       lock is committed, to the commit that introduced it (the RED commit);
#       runs the suite and requires every named test to pass, none skipped,
#       no other failure, and the outside-file pass count at or above the
#       baseline. Moves to phase "green". Re-run after every refactor.
#   tdd.sh close
#       removes the lock; refused unless the phase is green.
#   tdd.sh status
#       prints the lock.
#
# Runner: Vitest or Jest resolved from the project's node_modules/.bin, then
# the copy bundled under ~/.claude/enforce/node_modules (with a warning). Both
# emit the same JSON report. pytest, go test, and RSpec arrive with the first
# project on that stack (2026-09-06 decision 1); until then this refuses
# rather than guessing. Exit 1 with the reason on stderr on every refusal.
set -uo pipefail

CLAUDE_DIR="${CLAUDE_TDD_HOME:-$HOME/.claude}"
POLICY="$CLAUDE_DIR/enforce/role-policy.json"
LOCK_RELATIVE=".claude/tdd-lock.json"

die() { printf 'tdd.sh: %s\n' "$*" >&2; exit 1; }
say() { printf 'tdd.sh: %s\n' "$*"; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
cd "$ROOT" || die "cannot enter $ROOT"
ROOT_PHYSICAL=$(pwd -P)
LOCK="$ROOT/$LOCK_RELATIVE"

phase() { [ -f "$LOCK" ] && jq -r '.phase // ""' "$LOCK" 2>/dev/null || printf ''; }
require_lock() {
  [ -f "$LOCK" ] || die "no slice is open: run 'tdd.sh open \"<slice>\"' first"
  jq -e . "$LOCK" >/dev/null 2>&1 || die "$LOCK_RELATIVE is not JSON; ask the user to repair or delete it outside the session"
}

# A path relative to the repo root, whatever form the caller used.
relative() {
  local target="$1" physical
  case "$target" in /*) ;; *) target="$OLDPWD/$target" ;; esac
  [ -e "$target" ] || die "no such file: $1"
  physical=$(cd "$(dirname "$target")" && pwd -P)/$(basename "$target")
  case "$physical" in
    "$ROOT_PHYSICAL"/*) printf '%s' "${physical#"$ROOT_PHYSICAL"/}" ;;
    *) die "$1 is outside the repository" ;;
  esac
}

# --- runner ------------------------------------------------------------------

resolve_runner() {
  if [ -x "$ROOT/node_modules/.bin/vitest" ]; then RUNNER="$ROOT/node_modules/.bin/vitest"; RUNNER_KIND=vitest
  elif [ -x "$ROOT/node_modules/.bin/jest" ]; then RUNNER="$ROOT/node_modules/.bin/jest"; RUNNER_KIND=jest
  elif [ -x "$CLAUDE_DIR/enforce/node_modules/.bin/vitest" ]; then
    RUNNER="$CLAUDE_DIR/enforce/node_modules/.bin/vitest"; RUNNER_KIND=vitest
    say "warning: no vitest or jest in this project's node_modules; using the harness-bundled vitest" >&2
  else
    die "no supported test runner: Vitest or Jest under node_modules/.bin (pytest, go test, and RSpec are not wired yet)"
  fi
}

# Runs the whole suite and leaves the JSON report path in REPORT. A non-zero
# exit is expected whenever a test fails, so only a missing report is fatal.
run_suite() {
  resolve_runner
  REPORT=$(mktemp)
  case "$RUNNER_KIND" in
    vitest) "$RUNNER" run --reporter=json --outputFile="$REPORT" >/dev/null 2>&1 || true ;;
    jest) "$RUNNER" --json --outputFile="$REPORT" >/dev/null 2>&1 || true ;;
  esac
  jq -e '.testResults' "$REPORT" >/dev/null 2>&1 || die "the $RUNNER_KIND run produced no JSON report; run '$RUNNER' by hand to see why"
}

# Absolute physical path of a root-relative file, as the report names it.
report_name() { printf '%s/%s' "$ROOT_PHYSICAL" "$1"; }

file_record() { jq -c --arg n "$(report_name "$1")" '.testResults[] | select(.name == $n)' "$REPORT"; }

MISSING_MODULE='Cannot find module|Failed to resolve import|does not provide an export|is not a function|is not defined|Cannot read propert'
PARSE_FAILURE='Transform failed|PARSE_ERROR|SyntaxError|Unexpected token|Parse error'
ASSERTION='AssertionError|expected|toBe|toEqual|toMatch|toThrow|toHaveBeen'

# Classifies one RED file from its report record. Prints the failure class or
# dies with the refusal.
classify_red() {
  local rel="$1" record tests message
  record=$(file_record "$rel")
  [ -n "$record" ] || die "$rel was not run by $RUNNER_KIND (is it under a test tree the config includes?)"
  tests=$(printf '%s' "$record" | jq '.assertionResults | length')
  message=$(printf '%s' "$record" | jq -r '.message // ""')
  if [ "$tests" -eq 0 ]; then
    if printf '%s' "$message" | grep -qE "$PARSE_FAILURE"; then
      die "$rel does not parse; a broken test is not a RED test. First line: $(printf '%s' "$message" | head -1)"
    elif printf '%s' "$message" | grep -qE "$MISSING_MODULE"; then
      printf 'missing-module'
    elif [ -z "$message" ]; then
      die "$rel contains no tests"
    else
      die "$rel failed to run for a reason this script does not classify: $(printf '%s' "$message" | head -1)"
    fi
    return
  fi
  if printf '%s' "$record" | jq -e '[.assertionResults[] | select(.status == "skipped" or .status == "pending" or .status == "todo")] | length > 0' >/dev/null; then
    die "$rel contains a skipped test; a RED test must run and fail (R-401)"
  fi
  if printf '%s' "$record" | jq -e '[.assertionResults[] | select(.status == "passed")] | length > 0' >/dev/null; then
    die "$rel has a test that already passes: $(printf '%s' "$record" | jq -r '[.assertionResults[] | select(.status == "passed") | .title] | join(", ")'). A RED test fails before the implementation exists; remove or sharpen it"
  fi
  local failures
  failures=$(printf '%s' "$record" | jq -r '[.assertionResults[].failureMessages[]] | join("\n")')
  if printf '%s' "$failures" | grep -qE "$MISSING_MODULE"; then printf 'missing-module'
  elif printf '%s' "$failures" | grep -qE "$ASSERTION"; then printf 'assertion'
  else die "$rel fails for a reason this script does not classify: $(printf '%s' "$failures" | head -1)"
  fi
}

# Files in the report other than the named ones: dies on any failure, prints
# the pass count.
outside_pass_count() {
  local names="$1" failing
  failing=$(jq -r --argjson names "$names" '.testResults[] | select((.name as $n | $names | index($n)) == null) | select(.status == "failed" or ([.assertionResults[] | select(.status == "failed")] | length > 0)) | .name' "$REPORT")
  [ -z "$failing" ] || die "the rest of the suite is red, so nothing here is a clean RED: $(printf '%s' "$failing" | sed "s#^$ROOT_PHYSICAL/##" | tr '\n' ' ')"
  jq --argjson names "$names" '[.testResults[] | select((.name as $n | $names | index($n)) == null) | .assertionResults[] | select(.status == "passed")] | length' "$REPORT"
}

names_json() {
  local rel out='[]'
  for rel in "$@"; do out=$(printf '%s' "$out" | jq -c --arg n "$(report_name "$rel")" '. + [$n]'); done
  printf '%s' "$out"
}

# --- subcommands -------------------------------------------------------------

cmd_open() {
  [ -f "$LOCK" ] && die "a slice is already open ($(jq -r '.slice // "?"' "$LOCK" 2>/dev/null), phase $(phase)); finish it with 'tdd.sh green' and 'tdd.sh close', or ask the user to delete $LOCK_RELATIVE"
  local slice="${1:-}"; shift || true
  [ -n "$slice" ] || die "usage: tdd.sh open \"<slice>\" [--spec <path>] [--lock <path>]..."
  local spec="" locked='[]'
  while [ $# -gt 0 ]; do
    case "$1" in
      --spec) spec=$(relative "$2"); locked=$(printf '%s' "$locked" | jq -c --arg p "$spec" '. + [$p]'); shift 2 ;;
      --lock) locked=$(printf '%s' "$locked" | jq -c --arg p "$2" '. + [$p]'); shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  mkdir -p "$(dirname "$LOCK")"
  jq -n --arg s "$slice" --arg spec "$spec" --argjson l "$locked" --arg t "$(now)" \
    '{slice:$s, phase:"open", spec:(if $spec=="" then null else $spec end), locked:$l, tests:[], openedAt:$t}' > "$LOCK"
  say "slice open: $slice. Production paths are read-only until 'tdd.sh red <test file>' proves the failing test."
}

cmd_red() {
  require_lock
  case "$(phase)" in open | red) ;; *) die "phase is $(phase); red is only valid from open or red. Close this slice and open the next." ;;
  esac
  [ $# -gt 0 ] || die "usage: tdd.sh red <test file>..."
  local tests_pattern rels=() rel
  tests_pattern=$(jq -r '.patterns.tests' "$POLICY")
  for f in "$@"; do
    rel=$(relative "$f")
    printf '%s' "$rel" | grep -qE "$tests_pattern" || die "$rel is not under a test tree (enforce/role-policy.json patterns.tests)"
    rels+=("$rel")
  done
  run_suite
  local entries='[]' class
  for rel in "${rels[@]}"; do
    class=$(classify_red "$rel") || exit 1
    entries=$(printf '%s' "$entries" | jq -c --arg p "$rel" --arg h "$(sha "$rel")" --arg c "$class" \
      --argjson n "$(file_record "$rel" | jq '.assertionResults | length')" '. + [{path:$p, sha256:$h, failureClass:$c, tests:$n}]')
  done
  local baseline
  baseline=$(outside_pass_count "$(names_json "${rels[@]}")") || exit 1
  jq --argjson t "$entries" --argjson b "$baseline" --arg k "$RUNNER_KIND" --arg at "$(now)" \
    '.phase = "red" | .tests = $t | .baseline = {passed: $b, runner: $k} | .redAt = $at' "$LOCK" > "$LOCK.tmp" && mv "$LOCK.tmp" "$LOCK"
  rm -f "$REPORT"
  local summary
  summary=$(printf '%s' "$entries" | jq -r '[.[] | .path + " [" + .failureClass + ", " + (.tests | tostring) + " test(s)]"] | join(", ")')
  say "RED: $summary; baseline $baseline passing outside. Tests are locked; implement, then 'tdd.sh green'."
}

check_hashes() {
  local changed
  changed=$(jq -r '.tests[] | "\(.path) \(.sha256)"' "$LOCK" | while read -r path recorded; do
    [ -f "$path" ] || { printf '%s deleted\n' "$path"; continue; }
    [ "$(sha "$path")" = "$recorded" ] || printf '%s\n' "$path"
  done)
  [ -z "$changed" ] || die "locked test file(s) changed since RED (R-410): $(printf '%s' "$changed" | tr '\n' ' '). The tests are the contract; if one is wrong, return 'DISPUTE: <test id>: <why>' and stop."
  local red_commit
  red_commit=$(git log -1 --format=%H -- "$LOCK_RELATIVE" 2>/dev/null || true)
  if [ -n "$red_commit" ] && git show "$red_commit:$LOCK_RELATIVE" 2>/dev/null | jq -e '.phase == "red" or .phase == "green"' >/dev/null 2>&1; then
    changed=$(git show "$red_commit:$LOCK_RELATIVE" | jq -r '.tests[] | "\(.path) \(.sha256)"' | while read -r path recorded; do
      committed=$(git show "$red_commit:$path" 2>/dev/null | shasum -a 256 | awk '{print $1}')
      [ "$committed" = "$recorded" ] && [ -f "$path" ] && [ "$(sha "$path")" = "$committed" ] || printf '%s\n' "$path"
    done)
    [ -z "$changed" ] || die "locked test file(s) differ from the RED commit ${red_commit:0:7} (R-410): $(printf '%s' "$changed" | tr '\n' ' ')"
  else
    say "note: the lock is not committed yet, so the hash check ran against the lock only; commit the RED test before the implementation (R-412)" >&2
  fi
}

cmd_green() {
  require_lock
  case "$(phase)" in red | green) ;; *) die "phase is $(phase); run 'tdd.sh red <test file>' first" ;; esac
  check_hashes
  run_suite
  local rels names rel record
  rels=$(jq -r '.tests[].path' "$LOCK")
  names='[]'
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    names=$(printf '%s' "$names" | jq -c --arg n "$(report_name "$rel")" '. + [$n]')
    record=$(file_record "$rel")
    [ -n "$record" ] || die "$rel was not run"
    printf '%s' "$record" | jq -e '.status == "failed"' >/dev/null && die "$rel failed to run: $(printf '%s' "$record" | jq -r '.message' | head -1)"
    printf '%s' "$record" | jq -e '[.assertionResults[] | select(.status != "passed")] | length == 0' >/dev/null \
      || die "$rel is not green: $(printf '%s' "$record" | jq -r '[.assertionResults[] | select(.status != "passed") | "\(.title) (\(.status))"] | join(", ")')"
    local expected
    expected=$(jq -r --arg p "$rel" '.tests[] | select(.path == $p) | .tests' "$LOCK")
    [ "$(printf '%s' "$record" | jq '.assertionResults | length')" -ge "$expected" ] || die "$rel ran fewer tests than RED recorded ($expected)"
  done <<< "$rels"
  local baseline passed
  baseline=$(jq -r '.baseline.passed // 0' "$LOCK")
  passed=$(outside_pass_count "$names") || exit 1
  [ "$passed" -ge "$baseline" ] || die "the suite outside the RED files dropped below the baseline ($passed < $baseline): a test was deleted or skipped (R-401)"
  jq --arg at "$(now)" '.phase = "green" | .greenAt = $at' "$LOCK" > "$LOCK.tmp" && mv "$LOCK.tmp" "$LOCK"
  rm -f "$REPORT"
  say "GREEN: $(printf '%s' "$rels" | tr '\n' ' ')pass; $passed passing outside (baseline $baseline). Refactor under the lock, re-run green, commit, then 'tdd.sh close'."
}

cmd_close() {
  require_lock
  [ "$(phase)" = "green" ] || die "phase is $(phase); a slice closes only from green. Make it green, or ask the user to delete $LOCK_RELATIVE"
  say "closed: $(jq -r '.slice' "$LOCK")"
  rm -f "$LOCK"
}

cmd_status() {
  if [ -f "$LOCK" ]; then jq . "$LOCK"; else say "no slice open"; fi
}

case "${1:-}" in
  open) shift; cmd_open "$@" ;;
  red) shift; cmd_red "$@" ;;
  green) cmd_green ;;
  close) cmd_close ;;
  status) cmd_status ;;
  *) die "usage: tdd.sh open \"<slice>\" [--spec <path>] | red <test file>... | green | close | status" ;;
esac
