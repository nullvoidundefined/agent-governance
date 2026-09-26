#!/usr/bin/env bash
# tdd.sh: the RED/GREEN evidence for one behavioral slice (R-412), and the
# writer of .claude/tdd-lock.json that hooks/protected-path-guard.sh reads
# (R-410). Four phases, run from anywhere inside the project:
#
#   tdd.sh open "<slice>" [--spec <path>] [--lock <path-or-dir/>]...
#       writes the lock in phase "open": production paths are read-only until
#       the failing test exists and is proven to fail for the right reason.
#   tdd.sh open --refactor "<slice>" [--lock <test file>]... [--spec <path>]
#       a behavior-preserving change has no RED to prove, so the green suite is
#       the contract: runs the suite, requires it all green, records the pass
#       count outside the locked test files as the baseline and the sha256 of
#       every locked test file (every test file the suite ran when none is
#       named), and starts in phase "refactor", which locks tests like "red".
#       `tdd.sh green` then works unchanged: hashes, counts, no failures.
#   tdd.sh red <test file | test file::test id>...
#       runs the whole suite once and requires: every named test fails for an
#       assertion or a missing-module reason (a syntax error, a file with no
#       tests, a passing test, or a skipped test is refused); no other test
#       fails. A bare file names every test in it. A test id names tests in a
#       file that already holds passing ones, such as a review fix adding a
#       case: `path::test_x`, `path::TestA::test_x`, or `path::test_x[1-2]`
#       under pytest (a bare parametrized name covers every parameter set, a
#       class every test in it), and `path::<full name>` under Vitest and Jest
#       (describe titles and the test title joined by spaces, the name their
#       -t filter matches). The file's other tests must keep passing and the
#       file must still load, so a new test imports an unwritten unit inside
#       its body. Bash fixtures stay file-level: a fixture is one test, so a
#       test id on a *.test.sh path is refused. Records the pass count outside
#       the named tests as the baseline (the unnamed tests of an id-named file
#       count toward it), the sha256 of every containing file with its ids,
#       and moves to phase "red". A file named both whole and by id is
#       refused, and so is a skipped test anywhere in an id-named file.
#   tdd.sh green
#       requires the containing files to be byte-identical to the lock and,
#       when the lock is committed, to the commit that introduced it (the RED
#       commit); runs the suite and requires every named test to pass, none
#       skipped, no other failure, and the pass count outside the named tests
#       at or above the baseline. Moves to phase "green". Re-run after every
#       refactor.
#   tdd.sh amend <test file>
#       the author's fix to a test it just proved RED: from red, opens a window
#       (phase "amending") in which only that file is writable; run again, it
#       requires the amended test to still fail for a classified reason,
#       re-hashes it, records the amendment, and returns to red. Refused for a
#       test the slice did not lock, outside red, and once the RED is pushed.
#   tdd.sh close
#       removes the lock; refused unless the phase is green, or the phase is
#       open and no test was ever locked (nothing could have been written
#       under the lock, so an abandoned slice need not wait for the user).
#   tdd.sh abandon
#       closes a dead session's lock without the user: refused unless the lock
#       recorded a test, has seen no tdd.sh activity for CLAUDE_TDD_STALE_HOURS
#       (default 4), no live process outside this session works in the tree,
#       and every locked test is committed and passing with the suite green.
#       Logged to CLAUDE_TDD_ABANDON_LOG.
#   tdd.sh status
#       prints the lock.
#   tdd.sh validate <role>
#       the orchestrator's check on a dispatched role's return: phase red
#       after test-author, green after implementer; every modified or
#       untracked path inside the role's role-policy.json boundary (R-411);
#       the implementer's GREEN re-run rather than trusted.
#
# Runner: chosen from the test paths. A `*.test.sh` path is a bash fixture:
# the suite is every `*.test.sh` in the named files' directories, run through
# run-fixture-shards.sh beside this script with that runner's verdict (exit 0,
# a PASS line, no FAIL line), and converted to the JSON report shape below.
# A `*.py` path (test_*.py or *_test.py in practice) is a pytest test: the
# suite is the whole pytest run of the Python project that owns the named
# files, which is the nearest directory above them holding pyproject.toml. It
# runs there in the environment `uv run pytest` would use (`uv run python`)
# when uv is on PATH, and otherwise through the project's .venv interpreter,
# python3, or python, with a warning; either way a short bootstrap starts
# pytest with bytecode confined to a fresh per-run cache, so a stale .pyc in
# the tree can never stand in for the source. pytest writes its built-in
# --junitxml report (the xunit1 family, which names each test's file), and an
# inline Python converter turns it into the JSON report shape below; a
# collection error is a file with
# no tests carrying the error text, so a SyntaxError is refused as a parse
# failure and an ImportError or ModuleNotFoundError is the missing-module RED.
# Any other path, or no path, uses Vitest or Jest resolved from the project's
# node_modules/.bin, then the copy bundled under ~/.claude/enforce/node_modules
# (with a warning). A slice never mixes runners. go test and RSpec arrive with
# the first project on that stack (2026-09-06 decision 1); until then this
# refuses rather than guessing. Exit 1 with the reason on stderr on every
# refusal.
set -uo pipefail

CLAUDE_DIR="${CLAUDE_TDD_HOME:-$HOME/.claude}"
SHARD_RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-fixture-shards.sh"
POLICY="$CLAUDE_DIR/enforce/role-policy.json"
LOCK_RELATIVE=".claude/tdd-lock.json"
# The uv binary the pytest runner prefers; the fixture points it at a name that
# does not exist to exercise the python -m pytest fallback.
UV_BIN="${CLAUDE_TDD_UV:-uv}"
# How the pytest runner starts pytest: `<python> -c "$PYTEST_BOOTSTRAP"
# <bytecode dir> <pytest args>...`. It sets the bytecode cache prefix and
# disables bytecode writes from inside the interpreter, because environment
# variables are not enough: a pytest console script whose shebang carries -E
# (pipx's do) ignores PYTHONPYCACHEPREFIX and PYTHONDONTWRITEBYTECODE. It
# drops the current directory that -c puts at the front of sys.path, so
# imports resolve as they do under the pytest console script, then runs
# pytest's own entry point.
PYTEST_BOOTSTRAP='import sys
if not getattr(sys.flags, "safe_path", False):
    del sys.path[0]
sys.pycache_prefix = sys.argv.pop(1)
sys.dont_write_bytecode = True
import pytest
sys.exit(pytest.console_main())'

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

# resolve_runner [test rel]...: the nearest package's own Vitest or Jest when
# the named tests sit under one (resolve_package_runner), else the root's, else
# the harness-bundled Vitest. RUNNER_DIR is the directory the runner starts in,
# so a package's own config decides what its suite is.
resolve_runner() {
  RUNNER_DIR="$ROOT_PHYSICAL"
  [ "$#" -gt 0 ] && resolve_package_runner "$@" && return 0
  if [ -x "$ROOT/node_modules/.bin/vitest" ]; then RUNNER="$ROOT/node_modules/.bin/vitest"; RUNNER_KIND=vitest
  elif [ -x "$ROOT/node_modules/.bin/jest" ]; then RUNNER="$ROOT/node_modules/.bin/jest"; RUNNER_KIND=jest
  elif [ -x "$CLAUDE_DIR/enforce/node_modules/.bin/vitest" ]; then
    RUNNER="$CLAUDE_DIR/enforce/node_modules/.bin/vitest"; RUNNER_KIND=vitest
    say "warning: no vitest or jest in this project's node_modules; using the harness-bundled vitest" >&2
  else
    die "no supported test runner: Vitest or Jest under node_modules/.bin, *.test.sh fixtures, or *.py pytest tests (go test and RSpec are not wired yet)"
  fi
}

# package_of <test rel>: the nearest directory at or above the test, never above
# the repository root, whose node_modules/.bin holds Vitest or Jest; "." when
# only the root (or nothing) does.
package_of() {
  local dir
  dir=$(dirname "$1")
  while [ "$dir" != "." ] && [ ! -x "$dir/node_modules/.bin/vitest" ] && [ ! -x "$dir/node_modules/.bin/jest" ]; do
    dir=$(dirname "$dir")
  done
  printf '%s' "$dir"
}

# resolve_package_runner <test rel>...: in a monorepo whose packages each own
# their runner (pnpm installs Vitest per package, with no root copy), runs that
# package's runner from the package directory (IAN-405). Without this the
# fallback is the harness-bundled Vitest over the whole repository, which
# collects files no package runs, such as Playwright specs, and refuses every
# RED. Tests named from two packages are refused, as one run cannot report
# both. Returns 1 when the tests belong to the root, leaving resolve_runner's
# root lookup in charge.
resolve_package_runner() {
  local rel package="" dir
  for rel in "$@"; do
    dir=$(package_of "$rel")
    if [ -z "$package" ]; then package="$dir"
    elif [ "$package" != "$dir" ]; then die "a slice runs one package's test runner: $rel belongs to $dir, not $package; split them into separate slices"
    fi
  done
  [ "$package" != "." ] || return 1
  RUNNER_DIR="$ROOT_PHYSICAL/$package"
  if [ -x "$RUNNER_DIR/node_modules/.bin/vitest" ]; then RUNNER="$RUNNER_DIR/node_modules/.bin/vitest"; RUNNER_KIND=vitest
  else RUNNER="$RUNNER_DIR/node_modules/.bin/jest"; RUNNER_KIND=jest
  fi
}

# select_runner <test rel>...: shell when every path is a *.test.sh fixture,
# pytest when every path is a *.py file, the JavaScript runner when neither is
# (or none is named), a refusal when mixed.
select_runner() {
  local rel shell=0 python=0 other=0
  for rel in "$@"; do
    case "$rel" in
      *.test.sh) shell=$((shell + 1)) ;;
      *.py) python=$((python + 1)) ;;
      *) other=$((other + 1)) ;;
    esac
  done
  if [ $(( (shell > 0) + (python > 0) + (other > 0) )) -gt 1 ]; then
    die "a slice runs one runner: $shell *.test.sh fixture(s), $python *.py pytest file(s), and $other other test file(s) were named; split them into separate slices"
  fi
  if [ "$shell" -gt 0 ]; then
    [ -f "$SHARD_RUNNER" ] || die "shell fixtures need $SHARD_RUNNER, which is missing"
    RUNNER="$SHARD_RUNNER"; RUNNER_KIND=shell
    MISSING_MODULE="$SHELL_MISSING"; ASSERTION="$SHELL_ASSERTION"
  elif [ "$python" -gt 0 ]; then
    resolve_pytest "$@"
    MISSING_MODULE="$PYTEST_MISSING"; ASSERTION="$PYTEST_ASSERTION"; PARSE_FAILURE="$PYTEST_PARSE_FAILURE"
  else
    resolve_runner "$@"
  fi
}

# resolve_pytest <test rel>...: sets PYTEST_DIR to the physical path of the one
# Python project owning every named file (the nearest directory above each
# that holds pyproject.toml, never above the repository root), and PYTEST_CMD
# to pytest started through PYTEST_BOOTSTRAP under `uv run python` (the
# project environment `uv run pytest` would use), or under project_python with
# a warning when uv is not on PATH. Named files from two projects are refused,
# since one run cannot report both.
resolve_pytest() {
  local rel dir project=""
  for rel in "$@"; do
    dir=$(dirname "$rel")
    while [ "$dir" != "." ] && [ ! -f "$dir/pyproject.toml" ]; do dir=$(dirname "$dir"); done
    [ -f "$dir/pyproject.toml" ] || die "$rel has no pyproject.toml above it inside the repository; pytest runs from the Python project that owns the test"
    if [ -z "$project" ]; then project="$dir"
    elif [ "$project" != "$dir" ]; then die "a slice runs one pytest project: $rel belongs to $dir, not $project; split them into separate slices"
    fi
  done
  if [ "$project" = "." ]; then PYTEST_DIR="$ROOT_PHYSICAL"; else PYTEST_DIR="$ROOT_PHYSICAL/$project"; fi
  RUNNER_KIND=pytest
  if command -v "$UV_BIN" >/dev/null 2>&1; then
    PYTEST_CMD=("$UV_BIN" run python -c "$PYTEST_BOOTSTRAP")
    RUNNER="$UV_BIN run pytest (in $project)"
  else
    local python
    python=$(project_python) || die "pytest needs uv on PATH, a .venv in $project, or python3 or python on PATH, and none was found"
    PYTEST_CMD=("$python" -c "$PYTEST_BOOTSTRAP")
    RUNNER="$python -m pytest (in $project)"
    say "warning: uv is not on PATH; running pytest through '$python' in $project instead of through 'uv run'" >&2
  fi
}

# project_python: prints the project's own .venv interpreter, else python3 or
# python from PATH; returns 1 when none exists. It runs pytest when uv is
# absent and always runs the JUnit converter, so a project that relies on its
# .venv without a global Python still gets a report.
project_python() {
  if [ -x "$PYTEST_DIR/.venv/bin/python" ]; then printf '%s' "$PYTEST_DIR/.venv/bin/python"
  elif command -v python3 >/dev/null 2>&1; then printf 'python3'
  elif command -v python >/dev/null 2>&1; then printf 'python'
  else return 1
  fi
}

# Runs the whole suite for the named tests and leaves the JSON report path in
# REPORT. A non-zero exit is expected whenever a test fails, so only a missing
# report is fatal.
run_suite() {
  select_runner "$@"
  REPORT=$(mktemp)
  case "$RUNNER_KIND" in
    vitest) (cd "$RUNNER_DIR" && "$RUNNER" run --reporter=json --outputFile="$REPORT") >/dev/null 2>&1 || true ;;
    jest) (cd "$RUNNER_DIR" && "$RUNNER" --json --outputFile="$REPORT") >/dev/null 2>&1 || true ;;
    shell) run_shell_suite "$@" > "$REPORT" ;;
    pytest) run_pytest_suite "$@" > "$REPORT" ;;
  esac
  jq -e '.testResults' "$REPORT" >/dev/null 2>&1 || die "the $RUNNER_KIND run produced no JSON report; run '$RUNNER' by hand to see why"
}

# run_shell_suite <test rel>...: runs every *.test.sh in the named files'
# directories through the shard runner and prints the Vitest-shaped report.
# The runner starts in a scratch directory, not the repository root, so a
# fixture that writes a relative path cannot leave files in the slice's tree
# (PR #49 review); fixture paths are absolute, so nothing else changes.
run_shell_suite() {
  local dirs rel dir results scratch fixture records=""
  dirs=$(for rel in "$@"; do dirname "$rel"; done | sort -u)
  while IFS= read -r dir; do
    results=$(mktemp -d); scratch=$(mktemp -d)
    (cd "$scratch" && bash "$SHARD_RUNNER" "$ROOT_PHYSICAL/$dir" --all --results-dir "$results" >/dev/null 2>&1)
    for fixture in "$ROOT_PHYSICAL/$dir"/*.test.sh; do
      [ -f "$fixture" ] && records+=$(shell_record "$fixture" "$results")$'\n'
    done
    rm -rf "$results" "$scratch"
  done <<< "$dirs"
  printf '%s' "$records" | jq -s '{testResults: .}'
}

# run_pytest_suite <test rel>...: runs the whole pytest suite of PYTEST_DIR
# once and prints the Vitest-shaped report. --continue-on-collection-errors
# keeps one unimportable file from hiding every other file's result, which the
# baseline counts. The cache plugin is off, and PYTEST_BOOTSTRAP points the
# bytecode cache at a fresh directory deleted after the run, with writes
# disabled as well: the run leaves nothing untracked for `tdd.sh validate` to
# attribute to a role, and, more importantly, it never reads a .pyc from the
# tree. Python trusts a cached .pyc whose recorded source mtime and size
# match, so bytecode left by an earlier run (the developer's own, or a RED
# run) could otherwise outlive a same-size edit made within the same second
# and turn a failing implementation GREEN. When no report can be built,
# pytest's last output lines go to stderr and nothing is printed, so run_suite
# refuses with the reason in view.
run_pytest_suite() {
  local xml log bytecode rel names=()
  xml=$(mktemp); log=$(mktemp); bytecode=$(mktemp -d)
  for rel in "$@"; do names+=("$(report_name "$rel")"); done
  (cd "$PYTEST_DIR" && "${PYTEST_CMD[@]}" "$bytecode" \
    --rootdir="$PYTEST_DIR" -o junit_family=xunit1 --junitxml="$xml" --continue-on-collection-errors \
    -p no:cacheprovider -q > "$log" 2>&1) || true
  pytest_report "$xml" "$PYTEST_DIR" "${names[@]}" || tail -15 "$log" >&2
  rm -rf "$xml" "$log" "$bytecode"
}

# pytest_report <junit xml> <project dir> <named report name>...: converts
# pytest's JUnit XML into the report shape. Each testcase's file attribute,
# relative to the project, names its record; a collection error (a testcase
# with an empty classname and a "collection failure" error) makes a failed
# record with no tests and the error text as its message; a failure or error
# element is a failed test, and a skipped element (skip or xfail) a skipped
# one. A named file pytest reported nothing for is a record with no tests and
# no message, which red refuses as a file with no tests. The converter runs
# under project_python, the project's .venv interpreter first, and under
# `uv run --no-project python` when no interpreter exists outside uv. Returns
# non-zero when the XML is missing or unreadable, or no interpreter can read it.
pytest_report() {
  local python converter=()
  if python=$(project_python); then converter=("$python")
  elif command -v "$UV_BIN" >/dev/null 2>&1; then converter=("$UV_BIN" run --no-project python)
  else printf 'tdd.sh: no Python interpreter (a .venv in the project, python3, python, or uv) to read the pytest report\n' >&2; return 1
  fi
  "${converter[@]}" -c '
import json
import os
import sys
import xml.etree.ElementTree as ElementTree

xml_path, project_dir, *named_files = sys.argv[1:]
try:
    testcases = list(ElementTree.parse(xml_path).iter("testcase"))
except (OSError, ElementTree.ParseError):
    sys.exit(1)


def node_title(testcase):
    """The test node id inside its file, as pytest would take it after `path::`:
    xunit1 writes the classname as the file path dotted (no .py) followed by any
    class names, and the name as the function plus any parameter set."""
    module = os.path.splitext(testcase.get("file", ""))[0].replace(os.sep, ".").replace("/", ".")
    classname = testcase.get("classname", "")
    classes = classname[len(module) + 1:].split(".") if module and classname.startswith(module + ".") else []
    return "::".join(classes + [testcase.get("name", "")])


records = {}
for testcase in testcases:
    file_name = os.path.normpath(os.path.join(project_dir, testcase.get("file", "")))
    record = records.setdefault(file_name, {"name": file_name, "status": "passed", "message": "", "assertionResults": []})
    problem = next((child for child in testcase if child.tag in ("failure", "error")), None)
    if testcase.get("classname") == "" and problem is not None and problem.get("message") == "collection failure":
        record["status"] = "failed"
        record["message"] = (record["message"] + "\n" + (problem.text or "")).strip()
        continue
    if problem is not None:
        record["status"] = "failed"
        status, failure_messages = "failed", [((problem.get("message") or "") + "\n" + (problem.text or "")).strip()]
    elif testcase.find("skipped") is not None:
        status, failure_messages = "skipped", []
    else:
        status, failure_messages = "passed", []
    record["assertionResults"].append({"title": node_title(testcase), "status": status, "failureMessages": failure_messages})
for file_name in named_files:
    records.setdefault(file_name, {"name": file_name, "status": "passed", "message": "", "assertionResults": []})
print(json.dumps({"testResults": list(records.values())}))
' "$@"
}

# shell_record <fixture> <results dir>: one report record. A fixture that does
# not parse has no tests and a syntax message; one that passed has one passing
# test; one that exited 0 saying neither PASS nor FAIL has no tests and no
# message; any other outcome is one failed test carrying its FAIL lines, or
# its last lines and exit code when it printed none.
shell_record() {
  local fixture="$1" results="$2" name syntax status output failures
  name=$(basename "$fixture")
  if ! syntax=$(bash -n "$fixture" 2>&1); then
    jq -n --arg n "$fixture" --arg m "syntax error: $syntax" '{name:$n, status:"failed", message:$m, assertionResults:[]}'
    return
  fi
  status=$(cat "$results/$name.status" 2>/dev/null || echo 1)
  output=$(cat "$results/$name.out" 2>/dev/null || true)
  if [ "$(cat "$results/$name.verdict" 2>/dev/null)" = ok ]; then
    jq -n --arg n "$fixture" --arg t "$name" '{name:$n, status:"passed", message:"", assertionResults:[{title:$t, status:"passed", failureMessages:[]}]}'
  elif [ "$status" -eq 0 ] && ! grep -q PASS <<< "$output" && ! grep -q FAIL <<< "$output"; then
    jq -n --arg n "$fixture" '{name:$n, status:"failed", message:"", assertionResults:[]}'
  else
    failures=$(grep FAIL <<< "$output" || { tail -5 <<< "$output"; echo "exit $status"; })
    jq -n --arg n "$fixture" --arg t "$name" --arg f "$failures" '{name:$n, status:"failed", message:"", assertionResults:[{title:$t, status:"failed", failureMessages:[$f]}]}'
  fi
}

# Absolute physical path of a root-relative file, as the report names it.
report_name() { printf '%s/%s' "$ROOT_PHYSICAL" "$1"; }

file_record() { jq -c --arg n "$(report_name "$1")" '.testResults[] | select(.name == $n)' "$REPORT"; }

MISSING_MODULE='Cannot find module|Failed to resolve import|does not provide an export|is not a function|is not defined|Cannot read propert'
PARSE_FAILURE='Transform failed|PARSE_ERROR|SyntaxError|Unexpected token|Parse error|syntax error'
# Vitest and Jest: the markers their own assertion failures carry, never a bare
# word a plain Error could say. Vitest writes AssertionError for every chai
# matcher and assert call; the failures it rethrows as a plain Error carry the
# frame of their wrapper (.resolves, .rejects, expect.poll, an expect.extend
# matcher), a snapshot mismatch says so, and expect.assertions and
# expect.hasAssertions fail with their own messages. Jest heads each failure
# with a matcher hint (`expect(received).toBe(expected)`,
# `expect(jest.fn()).lastCalledWith(...expected)`, `expect.assertions(1)`,
# node:assert reformatted as `assert.strictEqual(received, expected)`), where
# the matcher name is any run of characters other than whitespace, `.`, and
# parentheses, so every JavaScript identifier, non-ASCII ones included. A Jest
# expect.extend matcher whose message has no hint is refused: its only trace is
# an `Object.toX` frame, which a plain Error thrown by a helper method of that
# name carries too. Colour is stripped before matching (JQ_FAILURE_RESULT).
ASSERTION='AssertionError|__VITEST_(RESOLVES|REJECTS|POLL_CHAIN|EXTEND_ASSERTION)__|Snapshot `.*` mismatched|expected number of assertions to be|expected any number of assertion|expect\(.*\)(\.(not|resolves|rejects))*\.[^[:space:].()]+\(|expect\.(assertions|hasAssertions)\(|^assert(\.[A-Za-z]+)?\('
# Shell fixtures: bash's own message for a script or command that does not
# exist yet is the missing-module RED; a FAIL line is the assertion RED.
SHELL_MISSING='(: No such file or directory|: command not found)$'
SHELL_ASSERTION='FAIL'
# pytest: an import that cannot resolve (a module or a name not written yet) is
# the missing-module RED, a failed assert or an unmet pytest.raises is the
# assertion RED, and any SyntaxError subclass is a test that does not parse.
PYTEST_MISSING='ModuleNotFoundError|ImportError'
PYTEST_ASSERTION='AssertionError|DID NOT RAISE'
PYTEST_PARSE_FAILURE='SyntaxError|IndentationError|TabError'

# Classifies one RED file from its report record, each of its tests on its own
# (classify_failures). Prints the failure class or dies with the refusal.
classify_red() {
  local rel="$1" record tests message
  record=$(file_record "$rel")
  [ -n "$record" ] || die "$rel was not run by $RUNNER_KIND (is it under a test tree the config includes?)"
  tests=$(printf '%s' "$record" | jq '.assertionResults | length')
  message=$(printf '%s' "$record" | jq -r '.message // ""')
  if [ "$tests" -eq 0 ]; then
    if grep -qE "$PARSE_FAILURE" <<< "$message"; then
      die "$rel does not parse; a broken test is not a RED test. First line: $(printf '%s' "$message" | head -1)"
    elif grep -qE "$MISSING_MODULE" <<< "$message"; then
      printf 'missing-module'
    elif [ -z "$message" ] && [ "$RUNNER_KIND" = pytest ]; then
      die "$rel contains no tests (or pytest did not collect it: check testpaths and python_files in pyproject.toml)"
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
  local results
  results=$(printf '%s' "$record" | jq -c "$JQ_TEST_IDS$JQ_FAILURE_RESULT"'.assertionResults[] | failure_result') || die "$rel: the report's test results could not be read"
  classify_failures "$rel" "$results"
}

# Test node ids. A report test's key is its full name: Vitest's and Jest's
# fullName (describe titles and the test title joined by spaces, the string
# their -t filter matches), or the pytest converter's title (the node id after
# `path::`). A named id matches its key exactly; under pytest it also matches
# every parameter set of a bare function name (`test_x` for `test_x[1]`) and
# every test inside a named class (`TestA` for `TestA::test_y`), as pytest's
# own `path::id` selection does. `in_scope($ids)` is true for every test of a
# file named whole ($ids null) and for the matched tests of a file named by id.
JQ_TEST_IDS='
def test_key: (.fullName // .title);
def matches_id($id; $kind): test_key as $k
  | $k == $id or ($kind == "pytest" and (($k | startswith($id + "[")) or ($k | startswith($id + "::"))));
def named_by($ids; $kind): . as $test | any($ids[]; . as $id | $test | matches_id($id; $kind));
def in_scope($ids; $kind): $ids == null or named_by($ids; $kind);
def entry_for($named): .name as $n | ($named | map(select(.name == $n)) | first);
'

# One {key, failures} object per failing test for classify_failures. A null
# failureMessages becomes an empty message, which is refused by name, instead
# of a jq error that would end the stream early and leave the tests before it
# to classify the file alone (PR #81 review). ANSI colour codes are stripped,
# since a runner under FORCE_COLOR splits a matcher hint with them (IAN-161).
JQ_FAILURE_RESULT='
def failure_result: {key: test_key, failures: ((.failureMessages // []) | map(tostring | gsub("\u001b\\[[0-9;]*m"; "")) | join("\n"))};
'

# classify_failures <rel> <results>: <results> holds one {key, failures} object
# per line, one per failing test in scope; prints the RED class. Each result is
# classified on its own, so one failing for a reason outside both classes
# cannot ride on another's classified message (PR #74 for named tests, IAN-160
# for a file named whole); results are walked one by one, not re-selected by
# name, because Vitest and Jest allow two tests with one full name. The class
# is missing-module when any test is, assertion otherwise. A test with no
# failure message, or no result at all, is refused, never an assertion.
classify_failures() {
  local rel="$1" results="$2" result key failures class=assertion count=0
  while IFS= read -r result; do
    [ -n "$result" ] || continue
    count=$((count + 1))
    key=$(jq -r '.key' <<< "$result")
    failures=$(jq -r '.failures' <<< "$result")
    [ -n "$(tr -d '[:space:]' <<< "$failures")" ] || die "$rel::$key failed with no failure message to classify"
    if grep -qE "$MISSING_MODULE" <<< "$failures"; then class=missing-module
    elif ! grep -qE "$ASSERTION" <<< "$failures"; then
      die "$rel::$key fails for a reason this script does not classify: $(printf '%s' "$failures" | grep -m1 . || true)"
    fi
  done <<< "$results"
  [ "$count" -gt 0 ] || die "$rel has no failing test result to classify"
  printf '%s' "$class"
}

# classify_named <rel> <ids json>: classify_red for a file named by test ids.
# Every id must match a test; the matched tests must each run and fail for an
# assertion or a missing-module reason; every other test in the file must not
# fail (they keep passing beside the new ones), and a file that no longer
# loads is refused, since its other tests stopped running. Prints the class.
classify_named() {
  local rel="$1" ids="$2" record message id listed
  record=$(file_record "$rel")
  [ -n "$record" ] || die "$rel was not run by $RUNNER_KIND (is it under a test tree the config includes?)"
  if [ "$(printf '%s' "$record" | jq '.assertionResults | length')" -eq 0 ]; then
    message=$(printf '%s' "$record" | jq -r '.message // ""' | head -1)
    grep -qE "$PARSE_FAILURE" <<< "$message" && die "$rel does not parse; a broken test is not a RED test. First line: $message"
    die "$rel fails to load, so the tests already in it stopped running${message:+: $message}. With test ids named the file's other tests must keep passing: import what is not written yet inside the new test, or name the whole file"
  fi
  # A suite-level error (a throwing afterAll or teardown) marks the file failed
  # with its own message while the results still look like a clean RED; the
  # tests beside the named ones are then not clean, so it is refused.
  message=$(printf '%s' "$record" | jq -r 'if .status == "failed" then (.message // "") else "" end' | head -1)
  [ -z "$message" ] || die "$rel failed outside its tests: $message. With test ids named the file's other tests must keep passing; fix the suite-level error first"
  while IFS= read -r id; do
    printf '%s' "$record" | jq -e --arg id "$id" --arg kind "$RUNNER_KIND" "$JQ_TEST_IDS"'any(.assertionResults[]; matches_id($id; $kind))' >/dev/null && continue
    listed=$(printf '%s' "$record" | jq -r "$JQ_TEST_IDS"'[.assertionResults[] | test_key] | .[:10] | join(", ")')
    die "no test in $rel matches $id; name a test by $(id_form) as the report lists them: $listed"
  done < <(printf '%s' "$ids" | jq -r '.[]')
  local named_filter="$JQ_TEST_IDS"'[.assertionResults[] | select(named_by($ids; $kind))]'
  local offenders
  # A skip anywhere in the file is refused, as a whole-file red refuses it: a
  # named test must run, and an unnamed one skipped has lost its pass status.
  offenders=$(printf '%s' "$record" | jq -r --arg rel "$rel" "$JQ_TEST_IDS"'[.assertionResults[] | select(.status == "skipped" or .status == "pending" or .status == "todo") | $rel + "::" + test_key] | join(", ")')
  [ -z "$offenders" ] || die "$offenders is skipped; a RED test must run and fail, and the tests beside it must keep running (R-401)"
  offenders=$(printf '%s' "$record" | jq -r --argjson ids "$ids" --arg kind "$RUNNER_KIND" --arg rel "$rel" "$named_filter"' | map(select(.status == "passed") | $rel + "::" + test_key) | join(", ")')
  [ -z "$offenders" ] || die "$offenders already passes. A RED test fails before the implementation exists; remove or sharpen it"
  offenders=$(printf '%s' "$record" | jq -r --argjson ids "$ids" --arg kind "$RUNNER_KIND" --arg rel "$rel" "$JQ_TEST_IDS"'[.assertionResults[] | select(.status == "failed" and (named_by($ids; $kind) | not)) | $rel + "::" + test_key] | join(", ")')
  [ -z "$offenders" ] || die "$offenders fails but was not named; the tests beside the named ones must keep passing. Name it too if it is part of this slice, or fix it first"
  local results
  results=$(printf '%s' "$record" | jq -c --argjson ids "$ids" --arg kind "$RUNNER_KIND" "$JQ_TEST_IDS$JQ_FAILURE_RESULT"'.assertionResults[] | select(named_by($ids; $kind)) | failure_result') || die "$rel: the report's test results could not be read"
  classify_failures "$rel" "$results"
}

# How a test id is written for the current runner, for refusal messages.
id_form() {
  case "$RUNNER_KIND" in
    pytest) printf 'its pytest node id after the path (test_name, Class::test_name, or test_name[params])' ;;
    *) printf 'its full name (describe titles and the test title joined by spaces, as -t matches it)' ;;
  esac
}

# named_count <rel> <ids json>: how many tests the lock records for a file,
# every test when it is named whole ($ids null), the matched ones otherwise.
named_count() {
  file_record "$1" | jq --argjson ids "$2" --arg kind "$RUNNER_KIND" "$JQ_TEST_IDS"'[.assertionResults[] | select(in_scope($ids; $kind))] | length'
}

# CLOSURE_FIXTURE is the one fixture whose failure a red may tolerate, and
# CLOSURE_REVERSE_PATTERN is the wording it uses to name a drifting path. The
# content-drift line it prints alongside names hooks/hook-integrity-check.sh as
# the command to run, which is path-shaped but is not a drifting path, so only
# the reverse-closure wording is read.
CLOSURE_FIXTURE='hook-hashes-closure.test.sh'
CLOSURE_REVERSE_PATTERN='^FAIL: (.+) is covered by the R-203 guard but absent from the manifest'

# drift_is_confined <report entry json> <named json>: true when the entry is
# the manifest-closure fixture and every path it names as drifting is one of
# the test files this red command named.
#
# Writing a slice's own fixture is what puts an unhashed file under
# enforce/tests/, so the closure fixture goes red as a consequence of the test
# the author was asked to write, and outside_pass_count would refuse every RED
# a test author could ever reach in this repository (IAN-156, owner decision
# 2026-09-20). Drift naming any other path still refuses, and so does any other
# failing fixture, including this one failing for a different reason: a run
# with no reverse-closure line at all is content drift this function cannot
# bound to the slice, and is not tolerated.
drift_is_confined() {
  local entry="$1" named="$2" messages path rel matched prefix
  [ "$(basename "$(printf '%s' "$entry" | jq -r '.name')")" = "$CLOSURE_FIXTURE" ] || return 1
  messages=$(printf '%s' "$entry" | jq -r '[.assertionResults[]?.failureMessages[]?] | join("\n")')
  [ -n "$messages" ] || return 1
  local drifting
  drifting=$(sed -nE "s#$CLOSURE_REVERSE_PATTERN.*#\1#p" <<< "$messages")
  [ -n "$drifting" ] || return 1
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    matched=0
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      # Exactly two spellings name the same file: the repository-root one
      # tdd.sh uses, and the harness-relative one the closure fixture prints,
      # which differs by the single directory the harness tree sits in below
      # the repository root. Any shorter trailing run of components is a
      # different file: a bare score.test.sh, or tests/score.test.sh, does not
      # name claude/enforce/tests/score.test.sh (R-517 review of PR #91).
      if [ "$rel" = "$path" ]; then matched=1; break; fi
      prefix="${rel%"/$path"}"
      if [ "$prefix" != "$rel" ] && [ -n "$prefix" ]; then
        case "$prefix" in */*) ;; *) matched=1; break ;; esac
      fi
    done <<< "$(printf '%s' "$named" | jq -r --arg root "$ROOT_PHYSICAL/" '.[].name | ltrimstr($root)')"
    [ "$matched" -eq 1 ] || return 1
  done <<< "$drifting"
  return 0
}

# outside_pass_count <named json>: <named json> lists {name, ids} per named
# file. Everything outside the named tests (whole files outside the list, and
# the unnamed tests of a file named by id) must not fail, and a file named by
# id must still load; dies on a failure, prints the outside pass count.
# The second argument opts one caller into the manifest-drift toleration above.
# Only a caller judging a RED may: `red` and `expected-red` ask for it, while
# `green` and a refactor slice's opening suite must not, because by then the
# drift comes from the production file the implementer edited rather than from
# the slice's own fixture, and tolerating that is the integrity drift on hooks
# that decision 2 of 2026-09-20 refused (R-517 review of PR #91, finding 1).
outside_pass_count() {
  local named="$1" tolerate="${2:-}" failing kept="" report_name
  failing=$(jq -r --argjson named "$named" --arg kind "$RUNNER_KIND" "$JQ_TEST_IDS"'.testResults[] | entry_for($named) as $e
    | if $e == null then select(.status == "failed" or any(.assertionResults[]; .status == "failed"))
      elif $e.ids == null then empty
      else select((.status == "failed" and (.assertionResults | length) == 0) or any(.assertionResults[]; .status == "failed" and (named_by($e.ids; $kind) | not)))
      end | .name' "$REPORT")
  while IFS= read -r report_name; do
    [ -n "$report_name" ] || continue
    if [ "$tolerate" = tolerate ]; then
      drift_is_confined "$(jq -c --arg n "$report_name" '.testResults[] | select(.name == $n)' "$REPORT")" "$named" && continue
    fi
    kept="${kept}${report_name}"$'\n'
  done <<< "$failing"
  failing=$(printf '%s' "$kept" | sed '/^$/d')
  [ -z "$failing" ] || die "the rest of the suite is red, so nothing here is a clean RED: $(printf '%s' "$failing" | sed "s#^$ROOT_PHYSICAL/##" | tr '\n' ' ')"
  jq --argjson named "$named" --arg kind "$RUNNER_KIND" "$JQ_TEST_IDS"'[.testResults[] | entry_for($named) as $e
    | if $e == null then .assertionResults[] elif $e.ids == null then empty else .assertionResults[] | select(named_by($e.ids; $kind) | not) end
    | select(.status == "passed")] | length' "$REPORT"
}

# names_json <rel>...: the named-file list for whole files.
names_json() {
  local rel out='[]'
  for rel in "$@"; do out=$(printf '%s' "$out" | jq -c --arg n "$(report_name "$rel")" '. + [{name: $n, ids: null}]'); done
  printf '%s' "$out"
}

# spec_named <spec json>: the named-file list for a red or lock spec, whose
# entries carry a root-relative path and ids (null for a whole file).
spec_named() { jq -c --arg root "$ROOT_PHYSICAL" 'map({name: ($root + "/" + .path), ids: (.ids // null)})' <<< "$1"; }

# add_named <spec json> <rel> <id or "">: merges one red argument into the
# spec. Ids named for one file collect on one entry, without duplicates. A
# file named both whole and by id is refused, since one of the two forms
# would otherwise be dropped without a word.
add_named() {
  jq -c --arg p "$2" --arg i "$3" '(map(.path) | index($p)) as $at
    | if $at == null then . + [{path: $p, ids: (if $i == "" then null else [$i] end)}]
      elif ($i == "") != (.[$at].ids == null) then error("mixed")
      elif $i == "" or (.[$at].ids | index($i)) != null then .
      else .[$at].ids += [$i] end' <<< "$1" 2>/dev/null \
    || die "$2 is named whole and by test id; name the whole file to RED every test in it, or only the ids of the new tests"
}

# --- subcommands -------------------------------------------------------------

cmd_open() {
  [ -f "$LOCK" ] && die "a slice is already open ($(jq -r '.slice // "?"' "$LOCK" 2>/dev/null), phase $(phase)); finish it with 'tdd.sh green' and 'tdd.sh close', or ask the user to delete $LOCK_RELATIVE"
  local refactor=0
  [ "${1:-}" = "--refactor" ] && { refactor=1; shift; }
  local slice="${1:-}"; shift || true
  [ -n "$slice" ] || die "usage: tdd.sh open [--refactor] \"<slice>\" [--spec <path>] [--lock <path>]..."
  local spec="" locked='[]' lock_tests=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --spec) spec=$(relative "$2"); locked=$(printf '%s' "$locked" | jq -c --arg p "$spec" '. + [$p]'); shift 2 ;;
      --lock)
        if [ "$refactor" -eq 1 ] && grep -qE "$(jq -r '.patterns.tests' "$POLICY")" <<< "$2"; then
          lock_tests+=("$(relative "$2")")
        else
          locked=$(printf '%s' "$locked" | jq -c --arg p "$2" '. + [$p]')
        fi
        shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  mkdir -p "$(dirname "$LOCK")"
  if [ "$refactor" -eq 0 ]; then
    jq -n --arg s "$slice" --arg spec "$spec" --argjson l "$locked" --arg t "$(now)" \
      '{slice:$s, phase:"open", spec:(if $spec=="" then null else $spec end), locked:$l, tests:[], openedAt:$t}' > "$LOCK"
    say "slice open: $slice. Production paths are read-only until 'tdd.sh red <test file>' proves the failing test."
    return
  fi
  open_refactor "$slice" "$spec" "$locked" "${lock_tests[@]+"${lock_tests[@]}"}"
}

# A refactor slice: the whole suite must be green now, and the locked test
# files (the named ones, or every test file the suite ran) become the contract.
open_refactor() {
  local slice="$1" spec="$2" locked="$3"; shift 3
  local rels=("$@")
  run_suite "${rels[@]+"${rels[@]}"}"
  local failing
  failing=$(jq -r '.testResults[] | select(.status == "failed" or ([.assertionResults[] | select(.status == "failed")] | length > 0)) | .name' "$REPORT" | sed "s#^$ROOT_PHYSICAL/##")
  [ -z "$failing" ] || { rm -f "$REPORT"; die "a refactor starts from a green suite and this one is red: $(printf '%s' "$failing" | tr '\n' ' '). Fix or RED-slice the failure first."; }
  if [ ${#rels[@]} -eq 0 ]; then
    while IFS= read -r name; do
      [ -n "$name" ] && rels+=("${name#"$ROOT_PHYSICAL"/}")
    done < <(jq -r '.testResults[].name' "$REPORT")
  fi
  local entries='[]' rel
  for rel in "${rels[@]}"; do
    [ -f "$rel" ] || die "no such test file: $rel"
    entries=$(printf '%s' "$entries" | jq -c --arg p "$rel" --arg h "$(sha "$rel")" \
      --argjson n "$(file_record "$rel" | jq '.assertionResults | length')" '. + [{path:$p, sha256:$h, failureClass:"refactor", tests:$n}]')
  done
  local baseline
  baseline=$(outside_pass_count "$(names_json "${rels[@]}")") || exit 1
  jq -n --arg s "$slice" --arg spec "$spec" --argjson l "$locked" --argjson t "$entries" --argjson b "$baseline" --arg k "$RUNNER_KIND" --arg at "$(now)" \
    '{slice:$s, phase:"refactor", spec:(if $spec=="" then null else $spec end), locked:$l, tests:$t, baseline:{passed:$b, runner:$k}, openedAt:$at}' > "$LOCK"
  rm -f "$REPORT"
  say "REFACTOR: ${#rels[@]} test file(s) locked, $baseline passing outside. Restructure, then 'tdd.sh green'; the same tests must pass unchanged."
}

cmd_red() {
  require_lock
  case "$(phase)" in open | red) ;; amending) die "an amendment of $(jq -r '.amending.path' "$LOCK") is open; finish it with 'tdd.sh amend $(jq -r '.amending.path' "$LOCK")' first" ;; refactor) die "this is a refactor slice; a new behavior is a new slice: 'tdd.sh green', 'tdd.sh close', then 'tdd.sh open'" ;; *) die "phase is $(phase); red is only valid from open or red. Close this slice and open the next." ;;
  esac
  [ $# -gt 0 ] || die "usage: tdd.sh red <test file | test file::test id>..."
  local tests_pattern spec='[]' rels=() rel file id
  tests_pattern=$(jq -r '.patterns.tests' "$POLICY")
  for f in "$@"; do
    file="$f"; id=""
    case "$f" in *::*) file="${f%%::*}"; id="${f#*::}"; [ -n "$id" ] || die "$f names an empty test id" ;; esac
    case "$file" in *.test.sh) [ -z "$id" ] || die "$file is a bash fixture, which is one test: name the fixture file, not a test inside it (test ids apply to pytest, Vitest, and Jest)" ;; esac
    rel=$(relative "$file")
    grep -qE "$tests_pattern" <<< "$rel" || die "$rel is not under a test tree (enforce/role-policy.json patterns.tests)"
    spec=$(add_named "$spec" "$rel" "$id") || exit 1
  done
  while IFS= read -r rel; do rels+=("$rel"); done < <(jq -r '.[].path' <<< "$spec")
  run_suite "${rels[@]}"
  local entries='[]' class ids
  for rel in "${rels[@]}"; do
    ids=$(jq -c --arg p "$rel" '.[] | select(.path == $p) | .ids' <<< "$spec")
    if [ "$ids" = null ]; then class=$(classify_red "$rel") || exit 1
    else class=$(classify_named "$rel" "$ids") || exit 1
    fi
    entries=$(printf '%s' "$entries" | jq -c --arg p "$rel" --arg h "$(sha "$rel")" --arg c "$class" --argjson ids "$ids" \
      --argjson n "$(named_count "$rel" "$ids")" '. + [{path:$p, sha256:$h, failureClass:$c, tests:$n} + (if $ids == null then {} else {ids:$ids} end)]')
  done
  local baseline
  baseline=$(outside_pass_count "$(spec_named "$spec")" tolerate) || exit 1
  jq --argjson t "$entries" --argjson b "$baseline" --arg k "$RUNNER_KIND" --arg at "$(now)" \
    '.phase = "red" | .tests = $t | .baseline = {passed: $b, runner: $k} | .redAt = $at' "$LOCK" > "$LOCK.tmp" && mv "$LOCK.tmp" "$LOCK"
  rm -f "$REPORT"
  local summary
  summary=$(printf '%s' "$entries" | jq -r '[.[] | .path + (if .ids then "::{" + (.ids | join(", ")) + "}" else "" end) + " [" + .failureClass + ", " + (.tests | tostring) + " test(s)]"] | join(", ")')
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
  if [ -n "$red_commit" ] && git show "$red_commit:$LOCK_RELATIVE" 2>/dev/null | jq -e '.phase == "red" or .phase == "green" or .phase == "refactor"' >/dev/null 2>&1; then
    changed=$(git show "$red_commit:$LOCK_RELATIVE" | jq -r '.tests[] | "\(.path) \(.sha256)"' | while read -r path recorded; do
      committed=$(git show "$red_commit:$path" 2>/dev/null | shasum -a 256 | awk '{print $1}')
      [ "$committed" = "$recorded" ] && [ -f "$path" ] && [ "$(sha "$path")" = "$committed" ] || printf '%s\n' "$path"
    done)
    [ -z "$changed" ] || die "locked test file(s) differ from the RED commit ${red_commit:0:7} (R-410): $(printf '%s' "$changed" | tr '\n' ' ')"
  else
    [ "$(phase)" = "refactor" ] || say "note: the lock is not committed yet, so the hash check ran against the lock only; commit the RED test before the implementation (R-412)" >&2
  fi
}

cmd_green() {
  require_lock
  case "$(phase)" in
    red | green | refactor) ;;
    amending) die "an amendment of $(jq -r '.amending.path' "$LOCK") is open; finish it with 'tdd.sh amend $(jq -r '.amending.path' "$LOCK")' before green" ;;
    *) die "phase is $(phase); run 'tdd.sh red <test file>' first" ;;
  esac
  check_hashes
  local rels names rel record locked_rels=()
  rels=$(jq -r '.tests[].path' "$LOCK")
  while IFS= read -r rel; do [ -n "$rel" ] && locked_rels+=("$rel"); done <<< "$rels"
  run_suite "${locked_rels[@]+"${locked_rels[@]}"}"
  names=$(spec_named "$(jq -c '.tests' "$LOCK")")
  local ids id
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    ids=$(jq -c --arg p "$rel" '.tests[] | select(.path == $p) | .ids // null' "$LOCK")
    record=$(file_record "$rel")
    [ -n "$record" ] || die "$rel was not run"
    # A file with no test results failed to load; one with results failed a
    # named test (every test of a file named whole), and the refusal names it
    # with the first line of its failure; one whose tests all passed but is
    # still marked failed hit a suite-level error (a throwing afterAll), and
    # the refusal carries the file message. A failing unnamed test in a file
    # named by id is left to outside_pass_count, which names the file.
    printf '%s' "$record" | jq -e '.status == "failed" and (.assertionResults | length) == 0' >/dev/null && die "$rel failed to run: $(printf '%s' "$record" | jq -r '.message' | head -1)"
    if [ "$ids" != null ]; then
      while IFS= read -r id; do
        printf '%s' "$record" | jq -e --arg id "$id" --arg kind "$RUNNER_KIND" "$JQ_TEST_IDS"'any(.assertionResults[]; matches_id($id; $kind))' >/dev/null \
          || die "$rel::$id did not run; RED recorded it (R-401)"
      done < <(jq -r '.[]' <<< "$ids")
    fi
    printf '%s' "$record" | jq -e --argjson ids "$ids" --arg kind "$RUNNER_KIND" "$JQ_TEST_IDS"'[.assertionResults[] | select(in_scope($ids; $kind)) | select(.status != "passed")] | length == 0' >/dev/null \
      || die "$rel is not green: $(printf '%s' "$record" | jq -r --argjson ids "$ids" --arg kind "$RUNNER_KIND" "$JQ_TEST_IDS"'[.assertionResults[] | select(in_scope($ids; $kind)) | select(.status != "passed") | "\(test_key) (\(.status))" + (((.failureMessages // [])[0] // "") | split("\n") | map(select(test("\\S"))) | if length > 0 then ": " + .[0] else "" end)] | join(", ")')"
    printf '%s' "$record" | jq -e '.status == "failed" and all(.assertionResults[]; .status != "failed")' >/dev/null && die "$rel failed outside its tests: $(printf '%s' "$record" | jq -r '.message' | head -1)"
    local expected
    expected=$(jq -r --arg p "$rel" '.tests[] | select(.path == $p) | .tests' "$LOCK")
    [ "$(named_count "$rel" "$ids")" -ge "$expected" ] || die "$rel ran fewer named tests than RED recorded ($expected)"
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
  if [ "$(phase)" = "open" ] && jq -e '(.tests // []) | length == 0' "$LOCK" >/dev/null; then :
  else
    [ "$(phase)" = "green" ] || die "phase is $(phase); a slice closes only from green, or from open before any test is locked. Make it green, or ask the user to delete $LOCK_RELATIVE"
  fi
  say "closed: $(jq -r '.slice' "$LOCK")"
  rm -f "$LOCK"
}

# cmd_expected_red: answers, without writing anything, whether the suite's
# current failures are exactly the RED this slice already recorded.
#
# hooks/verification-gate.sh refuses to let a turn or a subagent end on a red
# suite (R-509), which blocks a test author on the one outcome its role exists
# to produce. The gate cannot judge that for itself without parsing four test
# runners, and this file already normalizes all four into one report, so the
# gate asks here instead (IAN-156, owner decision 2026-09-20). Only a slice
# that reached `red` has an expected red suite: `open` has recorded no test
# yet, and `green` and `refactor` are past the point where failing is correct.
#
# Read-only is the contract, not a convenience. The caller runs this on a tree
# it is about to block or release, so it must not move the phase, rewrite the
# lock, or leave a file behind; run_suite reports into a mktemp outside the
# repository and the shard runner starts in a scratch directory.
cmd_expected_red() {
  require_lock
  local current rel locked_rels=()
  current=$(phase)
  [ "$current" = red ] || [ "$current" = amending ] || die "phase is $current; only a slice that recorded its RED has an expected red suite, so there is nothing here to excuse"
  while IFS= read -r rel; do [ -n "$rel" ] && locked_rels+=("$rel"); done <<< "$(jq -r '.tests[].path' "$LOCK")"
  [ "${#locked_rels[@]}" -gt 0 ] || die "phase is red but the lock records no test file; repair or delete $LOCK_RELATIVE outside the session"
  run_suite "${locked_rels[@]}"
  outside_pass_count "$(spec_named "$(jq -c '.tests' "$LOCK")")" tolerate >/dev/null
  rm -f "$REPORT"
  say "EXPECTED RED: every failure is one of the ${#locked_rels[@]} locked test file(s)"
}

# cmd_amend <test file>: the author's own fix to a test it just proved RED,
# without the user deleting the lock (2026-09-24). Run twice. From phase red
# the first run opens a window, phase "amending", in which the guard lets
# exactly that file be written and nothing else, production included. From
# "amending" the second run re-runs the suite, requires the amended test to
# still fail for a classified reason with nothing outside the locked tests
# failing, re-hashes it, appends the change to .amendments with git blobs of
# the file before and after (`git diff <fromBlob> <toBlob>` shows what the
# author changed; the blobs are unreferenced, so a gc prunes them after its
# expiry), and returns to
# red. Refused for a test this slice did not lock (an earlier slice's test
# stays under R-410), in every phase but red and amending (after green above
# all), and once the RED version of the test, or a committed red lock, is
# reachable from a remote-tracking ref: pushed history is shared, and a
# changed test there goes through `DISPUTE:` and the user.
cmd_amend() {
  require_lock
  [ $# -eq 1 ] || die "usage: tdd.sh amend <test file>"
  local rel
  rel=$(relative "$1")
  case "$(phase)" in
    red) start_amendment "$rel" ;;
    amending) finish_amendment "$rel" ;;
    *) die "phase is $(phase); a test is amended only while its slice is red, before any GREEN. After that the test is the contract (R-410): return 'DISPUTE: <test id>: <why>' to the user" ;;
  esac
}

start_amendment() {
  local rel="$1"
  jq -e --arg p "$rel" 'any(.tests[]; .path == $p)' "$LOCK" >/dev/null \
    || die "$rel is not a test this slice locked at RED; a test from an earlier slice stays read-only (R-410). If it is wrong, return 'DISPUTE: <test id>: <why>' to the user"
  red_is_pushed "$rel" && die "the RED version of $rel has been pushed, so it is shared history and no longer the author's to amend (R-410). Return 'DISPUTE: <test id>: <why>' to the user"
  local from_blob
  from_blob=$(git hash-object -w -- "$rel") || die "could not store $rel in the git object database"
  jq --arg p "$rel" --arg b "$from_blob" --arg at "$(now)" '.phase = "amending" | .amending = {path: $p, fromBlob: $b, startedAt: $at}' "$LOCK" > "$LOCK.tmp" && mv "$LOCK.tmp" "$LOCK"
  say "AMENDING: $rel is writable, and nothing else is. Fix the test, then run 'tdd.sh amend $rel' again to re-prove the RED."
}

finish_amendment() {
  local rel="$1" open_path
  open_path=$(jq -r '.amending.path // ""' "$LOCK")
  [ "$rel" = "$open_path" ] || die "the open amendment is for $open_path; finish it with 'tdd.sh amend $open_path' first"
  local before ids locked_rels=() path class
  before=$(jq -r --arg p "$rel" '.tests[] | select(.path == $p) | .sha256' "$LOCK")
  ids=$(jq -c --arg p "$rel" '.tests[] | select(.path == $p) | .ids // null' "$LOCK")
  while IFS= read -r path; do [ -n "$path" ] && locked_rels+=("$path"); done <<< "$(jq -r '.tests[].path' "$LOCK")"
  run_suite "${locked_rels[@]}"
  if [ "$ids" = null ]; then class=$(classify_red "$rel") || exit 1
  else class=$(classify_named "$rel" "$ids") || exit 1
  fi
  outside_pass_count "$(spec_named "$(jq -c '.tests' "$LOCK")")" tolerate >/dev/null || exit 1
  local after count from_blob to_blob
  after=$(sha "$rel")
  from_blob=$(jq -r '.amending.fromBlob // ""' "$LOCK")
  to_blob=$(git hash-object -w -- "$rel") || die "could not store $rel in the git object database"
  count=$(named_count "$rel" "$ids")
  rm -f "$REPORT"
  jq --arg p "$rel" --arg from "$before" --arg to "$after" --arg fb "$from_blob" --arg tb "$to_blob" --arg c "$class" --argjson n "$count" --arg at "$(now)" '
    .tests |= map(if .path == $p then .sha256 = $to | .failureClass = $c | .tests = $n else . end)
    | .amendments = ((.amendments // []) + [{path: $p, fromSha256: $from, toSha256: $to, fromBlob: $fb, toBlob: $tb, failureClass: $c, at: $at}])
    | .phase = "red" | del(.amending)' "$LOCK" > "$LOCK.tmp" && mv "$LOCK.tmp" "$LOCK"
  say "RED (amended): $rel [$class, $count test(s)]; the amendment is recorded in the lock ('git diff $from_blob $to_blob' shows it). Commit the amended test before the implementation, then 'tdd.sh green'."
}

# red_is_pushed <rel>: true when a remote-tracking ref reaches a commit holding
# <rel> with the content the lock recorded at RED, or the last commit of a
# committed lock that records <rel> at that hash. A lock some earlier slice
# committed and pushed is not this RED: a repository that once tracked the
# lock and then ignored it would otherwise refuse every amendment.
red_is_pushed() {
  local rel="$1" recorded commit
  recorded=$(jq -r --arg p "$rel" '.tests[] | select(.path == $p) | .sha256' "$LOCK")
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    [ "$(git show "$commit:$rel" 2>/dev/null | shasum -a 256 | awk '{print $1}')" = "$recorded" ] && return 0
  done <<< "$(git log --remotes --format=%H -- "$rel" 2>/dev/null)"
  commit=$(git log -1 --format=%H -- "$LOCK_RELATIVE" 2>/dev/null || true)
  [ -n "$commit" ] || return 1
  git show "$commit:$LOCK_RELATIVE" 2>/dev/null | jq -e --arg p "$rel" --arg h "$recorded" 'any(.tests[]?; .path == $p and .sha256 == $h)' >/dev/null 2>&1 || return 1
  [ -n "$(git branch -r --contains "$commit" 2>/dev/null)" ]
}

# cmd_abandon: closes a lock whose session is dead, without the user, when
# closing it loses nothing (2026-09-24: a dead session's lock blocked the next
# one). Refused unless all of these hold: the lock recorded a test (a lock
# that never did is `close`'s case); no tdd.sh activity for
# CLAUDE_TDD_STALE_HOURS (default 4), read from the lock's own timestamps and
# its mtime; no live process outside the caller's own session has its working
# directory in this tree (skipped with a warning where lsof is absent); every
# locked test is committed, identical to HEAD and to the lock's hash; and the
# suite passes, the locked tests included. The close is appended as one JSON
# line to CLAUDE_TDD_ABANDON_LOG (default telemetry/tdd-abandon.jsonl under the
# Claude home).
cmd_abandon() {
  require_lock
  jq -e '(.tests // []) | length > 0' "$LOCK" >/dev/null \
    || die "this lock never recorded a test; end it with 'tdd.sh close', which needs no staleness check"
  local hours="${CLAUDE_TDD_STALE_HOURS:-4}" last_activity age_hours
  last_activity=$(lock_last_activity)
  age_hours=$(( ($(date -u +%s) - last_activity) / 3600 ))
  [ "$age_hours" -ge "$hours" ] \
    || die "the lock saw tdd.sh activity ${age_hours}h ago, and a lock is stale only after ${hours} hours without any (CLAUDE_TDD_STALE_HOURS); its session may still be working. Ask the user, or wait"
  local holders
  if holders=$(live_holders); then
    [ -z "$holders" ] || die "a live process outside this session is working in this tree, so the lock's session may not be dead: $(printf '%s' "$holders" | tr '\n' ';' | sed 's/;$//'). Ask the user"
  else
    say "warning: lsof is not on PATH, so live processes in this tree were not checked; staleness rests on the lock's age alone" >&2
  fi
  local rel recorded locked_rels=()
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    locked_rels+=("$rel")
    recorded=$(jq -r --arg p "$rel" '.tests[] | select(.path == $p) | .sha256' "$LOCK")
    git ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 && git diff --quiet HEAD -- "$rel" 2>/dev/null && [ "$(sha "$rel")" = "$recorded" ] \
      || die "$rel is not committed as the lock recorded it (untracked, changed since HEAD, or changed since RED); abandoning would lose that work. Ask the user"
  done <<< "$(jq -r '.tests[].path' "$LOCK")"
  run_suite "${locked_rels[@]}"
  local ids record
  for rel in "${locked_rels[@]}"; do
    ids=$(jq -c --arg p "$rel" '.tests[] | select(.path == $p) | .ids // null' "$LOCK")
    record=$(file_record "$rel")
    printf '%s' "$record" | jq -e --argjson ids "$ids" --arg kind "$RUNNER_KIND" "$JQ_TEST_IDS"'.status != "failed" and ([.assertionResults[] | select(in_scope($ids; $kind))] | length > 0 and all(.status == "passed"))' >/dev/null 2>&1 \
      || die "$rel is not passing, so the slice's behavior is unfinished; resume it ('tdd.sh green' once it passes) or ask the user"
  done
  outside_pass_count "$(spec_named "$(jq -c '.tests' "$LOCK")")" >/dev/null || exit 1
  rm -f "$REPORT"
  local log="${CLAUDE_TDD_ABANDON_LOG:-$CLAUDE_DIR/telemetry/tdd-abandon.jsonl}" last_iso
  last_iso=$(date -u -r "$last_activity" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$last_activity" +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$(dirname "$log")"
  jq -c --arg at "$(now)" --arg repo "$(basename "$ROOT_PHYSICAL")" --arg last "$last_iso" \
    '{at: $at, repo: $repo, slice: .slice, phase: .phase, lastActivity: $last, tests: [.tests[].path]}' "$LOCK" >> "$log"
  say "abandoned: $(jq -r '.slice' "$LOCK") (phase $(phase), idle ${age_hours}h); its tests are committed and passing. Logged to $log."
  rm -f "$LOCK"
}

# lock_last_activity: epoch seconds of the newest tdd.sh write to the lock,
# the later of its mtime and every timestamp it records.
lock_last_activity() {
  local mtime recorded
  # GNU first: GNU `stat -f` is file-system status and exits 0, so trying the
  # BSD form first reads garbage on Linux. A non-number falls back to BSD.
  mtime=$(stat -c %Y "$LOCK" 2>/dev/null) || mtime=""
  [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=$(stat -f %m "$LOCK" 2>/dev/null) || mtime=0
  [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
  recorded=$(jq -r '[.openedAt, .redAt, .greenAt, (.amendments // [] | .[].at), .amending.startedAt] | map(select(. != null) | fromdateiso8601) | max // 0' "$LOCK")
  if [ "$recorded" -gt "$mtime" ]; then printf '%s' "$recorded"; else printf '%s' "$mtime"; fi
}

# live_holders: prints "<pid> <command>" for every live process whose working
# directory lies in this tree and that does not belong to the caller's own
# session: the topmost ancestor of this script working in the tree, and
# everything below it (its shell, subagents, MCP servers). Returns 1 when lsof
# is absent.
live_holders() {
  command -v lsof >/dev/null 2>&1 || return 1
  ps -Ao pid=,ppid=,comm= | awk -v self="$$" -v root="$ROOT_PHYSICAL" '
    FNR == NR {
      if ($0 ~ /^p/) pid = substr($0, 2)
      else if ($0 ~ /^n/) { dir = substr($0, 2); if (dir == root || index(dir, root "/") == 1) inroot[pid] = 1 }
      next
    }
    { parent[$1] = $2; name = $0; sub(/^ *[0-9]+ +[0-9]+ +/, "", name); command[$1] = name }
    END {
      session = self
      for (p = self; p != "" && p + 0 > 1; p = parent[p]) { ancestor[p] = 1; if (p in inroot) session = p }
      for (pid in inroot) {
        if (pid in ancestor || !(pid in parent)) continue
        mine = 0
        for (p = pid; p != "" && p + 0 > 1; p = parent[p]) if (p == session) { mine = 1; break }
        if (!mine) print pid " " command[pid]
      }
    }' <(lsof -d cwd -Fpn 2>/dev/null || true) -
}

cmd_status() {
  if [ -f "$LOCK" ]; then jq . "$LOCK"; else say "no slice open"; fi
}

# validate <role>: the orchestrator's check on a dispatched role's return
# (2026-09-17 skills audit, S-9), decided here instead of read off porcelain
# output by hand. The lock phase is the one the role leaves behind (red after
# the test author, green after the implementer; a read-only role leaves it
# untouched and is not judged on it), every modified or untracked path lies
# inside the role's write boundary from role-policy.json (R-411; the lock
# itself is excepted because this script writes it), and for the implementer
# the GREEN is re-run rather than taken from the report.
cmd_validate() {
  local role="${1:-}"
  [ -n "$role" ] || die "usage: tdd.sh validate <role>"
  jq -e --arg r "$role" '.roles[$r]' "$POLICY" >/dev/null 2>&1 \
    || die "unknown role '$role'; role-policy.json knows $(jq -r '.roles | keys | join(", ")' "$POLICY")"
  require_lock
  local expected=""
  case "$role" in
    test-author) expected=red ;;
    implementer) expected=green ;;
  esac
  if [ -n "$expected" ] && [ "$(phase)" != "$expected" ]; then
    die "phase is $(phase) after $role; expected $expected (the role did not finish: test-author runs 'tdd.sh red', implementer runs 'tdd.sh green')"
  fi
  local mode pattern violations changed
  mode=$(jq -r --arg r "$role" '.roles[$r] | if .allow then "allow" else "deny" end' "$POLICY")
  pattern=$(jq -r --arg r "$role" --arg m "$mode" '.roles[$r][$m][] as $n | .patterns[$n]' "$POLICY" | paste -sd'|' -)
  changed=$(git status --porcelain --untracked-files=all | sed -E 's/^.{3}//; s/^.* -> //; s/^"(.*)"$/\1/' | grep -vx "$LOCK_RELATIVE" || true)
  violations=$(printf '%s\n' "$changed" | while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ "$mode" = allow ]; then
      grep -qE "$pattern" <<< "$p" || printf '%s\n' "$p"
    else
      grep -qE "$pattern" <<< "$p" && printf '%s\n' "$p"
    fi
  done)
  [ -z "$violations" ] || die "$role wrote outside its boundary (R-411): $(printf '%s' "$violations" | tr '\n' ' '). Discard those writes (git checkout/rm) and re-dispatch; the role file states the boundary, protected-path-guard enforces it in subagent context."
  if [ "$role" = implementer ]; then cmd_green; fi
  local count
  count=$(printf '%s\n' "$changed" | grep -c . || true)
  say "VALID: $role return; phase $(phase); $count changed path(s), all inside the $role boundary"
}

case "${1:-}" in
  open) shift; cmd_open "$@" ;;
  red) shift; cmd_red "$@" ;;
  green) cmd_green ;;
  expected-red) cmd_expected_red ;;
  amend) shift; cmd_amend "$@" ;;
  abandon) cmd_abandon ;;
  close) cmd_close ;;
  status) cmd_status ;;
  validate) shift; cmd_validate "$@" ;;
  *) die "usage: tdd.sh open [--refactor] \"<slice>\" [--spec <path>] [--lock <path>]... | red <test file>... | green | amend <test file> | expected-red | close | abandon | status | validate <role>" ;;
esac
