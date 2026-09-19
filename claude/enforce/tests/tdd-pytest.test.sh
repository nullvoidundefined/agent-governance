#!/usr/bin/env bash
# Shard: slow
# Verifies the pytest runner in enforce/tdd.sh (R-412): a *.py test path runs
# the whole pytest suite of the nearest project above it holding
# pyproject.toml, through `uv run python` when uv is on PATH and through the
# project's .venv interpreter with a warning otherwise, in both cases via the
# bootstrap that confines bytecode to a per-run cache, and the JUnit XML
# pytest writes is converted into the report shape red and green already
# read. Red accepts an assertion failure and a missing module and refuses a
# passing test, a skipped test, a syntax error, a file with no tests, and a
# slice that mixes runners; green accepts the fixed implementation and
# refuses a still failing test (also when stale bytecode in the tree holds
# the passing version), a skipped test, and a dropped baseline; the JUnit
# converter runs through the project's .venv interpreter when one exists.
# Test node ids (`path::Class::test`, a bare parametrized name, or one
# parameter set) RED new tests in a file that already holds a passing one:
# red refuses an unknown id, a named test that passes, an unnamed test in the
# file that fails, and a file that no longer collects; green refuses a named
# test still failing and a regression in the file's unnamed test.
# Drives the REAL pytest (the interpreter behind a pytest on PATH, as CI
# installs it pinned with pipx, or uvx at the same pin) behind a stub uv and a
# stub .venv python that record how they were called, so the JUnit parsing is
# exercised against live output and the invocation choice is observed rather
# than assumed.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
TDD="$CLAUDE_HARNESS_ROOT/enforce/tdd.sh"

# PYTEST_PYTHON is an interpreter that can import the real pytest. A pytest on
# PATH is a console script inside its own environment, so the interpreter
# beside the resolved script is that environment's.
# Keep in step with the pytest pin in .github/workflows/enforce.yml.
PYTEST_PIN="9.1.1"
PYTEST_PYTHON=""
if command -v pytest >/dev/null 2>&1; then
  PYTEST_PYTHON="$(dirname "$(readlink -f "$(command -v pytest)")")/python"
  "$PYTEST_PYTHON" -c 'import pytest' >/dev/null 2>&1 || PYTEST_PYTHON=""
fi
if [ -z "$PYTEST_PYTHON" ] && command -v uvx >/dev/null 2>&1; then PYTEST_PYTHON="uvx --quiet --from pytest==$PYTEST_PIN python"; fi
[ -n "$PYTEST_PYTHON" ] || { echo "FAIL: neither pytest nor uvx is on PATH; install pytest==$PYTEST_PIN (CI does it with pipx)"; exit 1; }

P=$(cd "$(mktemp -d)" && pwd -P)
STUBS=$(mktemp -d)
CALLS="$STUBS/calls.log"
trap 'cd / && rm -rf "$P" "$STUBS"' EXIT

# The stub uv accepts only `uv run python ...` and hands the rest of the
# arguments to the real pytest's interpreter, logging its working directory
# and the first arguments (the bootstrap itself spans lines).
cat > "$STUBS/uv" <<STUB
#!/usr/bin/env bash
printf 'uv %s | %s %s %s\n' "\$PWD" "\${1:-}" "\${2:-}" "\${3:-}" >> "$CALLS"
[ "\${1:-}" = run ] && [ "\${2:-}" = python ] || { echo "stub uv: unexpected arguments: \$*" >&2; exit 97; }
shift 2
exec $PYTEST_PYTHON "\$@"
STUB
chmod +x "$STUBS/uv"
export PATH="$STUBS:$PATH"

# The project sits below the repository root, so the pyproject.toml walk is
# exercised: the git root holds none, apps/server does.
git -C "$P" init -q
git -C "$P" config user.email t@t; git -C "$P" config user.name t
SERVER="$P/apps/server"
mkdir -p "$SERVER/app" "$SERVER/tests"
printf '[project]\nname = "fixture"\nversion = "0.0.0"\n\n[tool.pytest.ini_options]\npythonpath = ["."]\ntestpaths = ["tests"]\n' > "$SERVER/pyproject.toml"
: > "$SERVER/app/__init__.py"
printf 'def test_baseline_passes():\n    assert 1 == 1\n' > "$SERVER/tests/test_baseline.py"
printf '.venv\n' > "$P/.gitignore"
git -C "$P" add -A && git -C "$P" commit -qm "chore: init"
cd "$P"

TEST=apps/server/tests/test_score.py
red_test() { printf 'from app.score import score\n\n\ndef test_scores_a_job_at_2():\n    assert score() == 2\n' > "$TEST"; }
impl() { printf 'def score():\n    return %s\n' "$1" > apps/server/app/score.py; }
lock_field() { jq -r "$1" .claude/tdd-lock.json; }
expect_fail() {
  local label="$1"; shift
  if out=$("$@" 2>&1); then echo "FAIL: $label: expected a non-zero exit; output: $out"; exit 1; fi
  printf '%s' "$out"
}

bash "$TDD" open "PY-1 score returns 2" >/dev/null

# red: a passing test, a skipped test, a syntax error, and a file with no
# tests are each refused with the reason, and the phase stays open.
printf 'def test_already_green():\n    assert 1 == 1\n' > "$TEST"
expect_fail "pytest red on a passing test" bash "$TDD" red "$TEST" | grep -q 'already passes' || { echo "FAIL: a passing pytest test must be refused as passing"; exit 1; }
printf 'import pytest\n\n\n@pytest.mark.skip(reason="parked")\ndef test_parked():\n    assert 1 == 2\n' > "$TEST"
expect_fail "pytest red on a skipped test" bash "$TDD" red "$TEST" | grep -qi 'skip' || { echo "FAIL: a skipped pytest test must be refused as skipped"; exit 1; }
printf 'def test_broken(:\n    pass\n' > "$TEST"
expect_fail "pytest red on a syntax error" bash "$TDD" red "$TEST" | grep -q 'does not parse' || { echo "FAIL: a pytest syntax error must be refused as not parsing"; exit 1; }
printf 'NOTHING = 1\n' > "$TEST"
expect_fail "pytest red on a file with no tests" bash "$TDD" red "$TEST" | grep -q 'contains no tests' || { echo "FAIL: a pytest file with no tests must be refused as containing none"; exit 1; }
[ "$(lock_field .phase)" = "open" ] || { echo "FAIL: refused pytest reds must leave the phase open"; exit 1; }

# red: a pytest file named beside a JavaScript test is refused; one runner per slice.
red_test
printf 'it("x", () => {});\n' > apps/server/tests/mixed.test.ts
expect_fail "red mixing pytest and JavaScript" bash "$TDD" red "$TEST" apps/server/tests/mixed.test.ts | grep -q 'pytest file' || { echo "FAIL: mixing pytest and JavaScript tests must be refused naming the pytest kind"; exit 1; }
rm apps/server/tests/mixed.test.ts

# red: a missing module is the missing-module RED, run as uv run pytest from
# the project directory, with the passing baseline counted outside the file.
: > "$CALLS"
bash "$TDD" red "$TEST" >/dev/null || { echo "FAIL: pytest red on a missing module must succeed"; exit 1; }
[ "$(lock_field .phase)" = "red" ] || { echo "FAIL: pytest red must move the phase to red"; exit 1; }
[ "$(lock_field '.tests[0].failureClass')" = "missing-module" ] || { echo "FAIL: expected missing-module for a missing module, got $(lock_field '.tests[0].failureClass')"; exit 1; }
[ "$(lock_field '.tests[0].tests')" = "0" ] || { echo "FAIL: a module that cannot import records no collected tests, got $(lock_field '.tests[0].tests')"; exit 1; }
[ "$(lock_field '.baseline.passed')" = "1" ] || { echo "FAIL: the pytest baseline must count the passing test outside the RED file, got $(lock_field '.baseline.passed')"; exit 1; }
[ "$(lock_field '.baseline.runner')" = "pytest" ] || { echo "FAIL: the pytest runner must be recorded, got $(lock_field '.baseline.runner')"; exit 1; }
[ "$(lock_field '.tests[0].sha256' | wc -c | tr -d ' ')" = "65" ] || { echo "FAIL: pytest red must record a sha256"; exit 1; }
grep -q "^uv $SERVER | run python -c$" "$CALLS" || { echo "FAIL: pytest must run through 'uv run python' from the pyproject.toml directory; calls: $(cat "$CALLS")"; exit 1; }

# red again: a wrong answer is the assertion RED.
impl 1
bash "$TDD" red "$TEST" >/dev/null
[ "$(lock_field '.tests[0].failureClass')" = "assertion" ] || { echo "FAIL: expected assertion for a failed assert, got $(lock_field '.tests[0].failureClass')"; exit 1; }
[ "$(lock_field '.tests[0].tests')" = "1" ] || { echo "FAIL: the assertion RED must record one test, got $(lock_field '.tests[0].tests')"; exit 1; }

# green: stale bytecode in the tree cannot fake a GREEN. A developer's own
# pytest run leaves __pycache__ behind, and Python trusts a .pyc whose
# recorded source mtime and size match; so the passing implementation is
# compiled in place, then replaced by the failing one with the same size and
# the same mtime. tdd.sh must still run the source on disk and refuse.
impl 2; touch -t 202001010000 apps/server/app/score.py
(cd apps/server && env -u PYTHONDONTWRITEBYTECODE -u PYTHONPYCACHEPREFIX $PYTEST_PYTHON -m pytest -q -p no:cacheprovider >/dev/null 2>&1 || true)
[ -n "$(find apps/server/app -name 'score*.pyc')" ] || { echo "FAIL: setup: the direct pytest run must leave app bytecode in the tree"; exit 1; }
impl 1; touch -t 202001010000 apps/server/app/score.py
expect_fail "pytest green over stale in-tree bytecode" bash "$TDD" green | grep -q 'test_scores_a_job_at_2' || { echo "FAIL: pytest green must run the source on disk, not a stale in-tree .pyc"; exit 1; }
find apps/server -name __pycache__ -type d -prune -exec rm -rf {} +

# green: still failing is refused by test name; the phase stays red.
expect_fail "pytest green while failing" bash "$TDD" green | grep -q 'test_scores_a_job_at_2' || { echo "FAIL: a still-failing pytest green must name the failing test"; exit 1; }
[ "$(lock_field .phase)" = "red" ] || { echo "FAIL: a refused pytest green must leave the phase red"; exit 1; }

# green: the fixed implementation passes and the phase becomes green.
git add -A && git commit -qm "test(score): PY-1 score returns 2"
impl 2
bash "$TDD" green >/dev/null || { echo "FAIL: pytest green must pass once score returns 2"; exit 1; }
[ "$(lock_field .phase)" = "green" ] || { echo "FAIL: pytest green must move the phase to green"; exit 1; }

# green: a skipped RED test is refused. The skip comes from a conftest.py, so
# the locked file is byte-identical and the refusal is the skip, not R-410.
printf 'import pytest\n\n\ndef pytest_collection_modifyitems(items):\n    for item in items:\n        if item.fspath.basename == "test_score.py":\n            item.add_marker(pytest.mark.skip(reason="parked"))\n' > apps/server/tests/conftest.py
expect_fail "pytest green on a skipped RED test" bash "$TDD" green | grep -q 'test_scores_a_job_at_2 (skipped)' || { echo "FAIL: pytest green must refuse a skipped RED test by name"; exit 1; }
rm apps/server/tests/conftest.py

# green: a deleted baseline test drops the outside count and is refused.
rm apps/server/tests/test_baseline.py
expect_fail "pytest green with a deleted baseline test" bash "$TDD" green | grep -q 'baseline' || { echo "FAIL: deleting a pytest baseline test must drop below the baseline"; exit 1; }
git checkout -q -- apps/server/tests/test_baseline.py
bash "$TDD" green >/dev/null && bash "$TDD" close >/dev/null
[ ! -f .claude/tdd-lock.json ] || { echo "FAIL: close after pytest green must remove the lock"; exit 1; }
git add -A && git commit -qm "feat(score): PY-1 score returns 2"

# Without uv the runner falls back to the project's .venv python with a
# warning. The stub interpreter hands everything to the real pytest's
# interpreter and logs whether it was asked to run the pytest bootstrap or the
# JUnit converter, so the converter's use of the project interpreter is
# observed too (PR #72 review).
mkdir -p apps/server/.venv/bin
cat > apps/server/.venv/bin/python <<STUB
#!/usr/bin/env bash
case "\${2:-}" in
  *console_main*) printf 'python %s | pytest\n' "\$PWD" >> "$CALLS" ;;
  *) printf 'python-convert %s\n' "\${1:-}" >> "$CALLS" ;;
esac
exec $PYTEST_PYTHON "\$@"
STUB
chmod +x apps/server/.venv/bin/python
: > "$CALLS"
out=$(CLAUDE_TDD_UV=no-such-uv bash "$TDD" open --refactor "PY-2 tidy score" --lock "$TEST" 2>&1) || { echo "FAIL: open --refactor through the python fallback must succeed; output: $out"; exit 1; }
grep -q "uv is not on PATH" <<< "$out" || { echo "FAIL: the python fallback must warn that uv is missing; output: $out"; exit 1; }
grep -q "^python $SERVER | pytest$" "$CALLS" || { echo "FAIL: without uv pytest must run through the project's .venv python; calls: $(cat "$CALLS")"; exit 1; }
grep -q "^python-convert -c" "$CALLS" || { echo "FAIL: the JUnit converter must run through the project's .venv python; calls: $(cat "$CALLS")"; exit 1; }
[ "$(lock_field '.baseline.runner')" = "pytest" ] || { echo "FAIL: a pytest refactor must record the pytest runner"; exit 1; }
CLAUDE_TDD_UV=no-such-uv bash "$TDD" green >/dev/null 2>&1 && bash "$TDD" close >/dev/null || { echo "FAIL: green and close through the python fallback must succeed"; exit 1; }

# --- test node ids: new failing tests in a file that already holds a passing one
# A review fix adds tests to an existing file (template-fastapi-nuxt PR #6), so
# the file as a whole can never be RED. `path::id` names the new tests: a
# class-scoped test and a parametrized one, each importing its unit inside the
# test so the passing test beside them still collects and runs.
cat > "$TEST" <<'PY'
import pytest

from app.score import score


def test_scores_a_job_at_2():
    assert score() == 2


class TestBoost:
    def test_boosted(self):
        from app.boost import boosted_score
        assert boosted_score() == 4


@pytest.mark.parametrize("factor, expected", [(2, 4), (3, 6)])
def test_scales(factor, expected):
    from app.score import scale
    assert scale(factor) == expected
PY
bash "$TDD" open "PY-3 boost and scale" >/dev/null
expect_fail "file-level red on a file with a passing test" bash "$TDD" red "$TEST" | grep -q 'test_scores_a_job_at_2' || { echo "FAIL: file-level red must still refuse a file holding a passing test, naming it"; exit 1; }
expect_fail "node red on an unknown id" bash "$TDD" red "$TEST::test_no_such_test" | grep -q "no test in $TEST matches test_no_such_test" || { echo "FAIL: a node id that matches no test must be refused by name"; exit 1; }
expect_fail "node red on a passing test" bash "$TDD" red "$TEST::test_scores_a_job_at_2" | grep -q "$TEST::test_scores_a_job_at_2 already passes" || { echo "FAIL: a named test that passes must be refused as passing"; exit 1; }
expect_fail "node red leaving a failing test unnamed" bash "$TDD" red "$TEST::TestBoost::test_boosted" "$TEST::test_scales[2-4]" | grep -q 'test_scales\[3-6\]' || { echo "FAIL: an unnamed failing test in a named file must be refused by its id"; exit 1; }
[ "$(lock_field .phase)" = "open" ] || { echo "FAIL: refused node reds must leave the phase open"; exit 1; }
cp "$TEST" "$STUBS/test_score.py.saved"
{ printf 'from app.not_written import thing\n'; cat "$STUBS/test_score.py.saved"; } > "$TEST"
expect_fail "node red on a file that fails to collect" bash "$TDD" red "$TEST::TestBoost::test_boosted" | grep -q 'fails to load' || { echo "FAIL: node red on an uncollectable file must be refused, since its other tests stopped running"; exit 1; }
cp "$STUBS/test_score.py.saved" "$TEST"
# An unnamed test skipped beside the named ones has lost its pass status (PR
# review): refused by id, as a whole-file red refuses any skip.
sed 's/^def test_scores_a_job_at_2/@pytest.mark.skip(reason="parked")\ndef test_scores_a_job_at_2/' "$STUBS/test_score.py.saved" > "$TEST"
expect_fail "node red beside a skipped unnamed test" bash "$TDD" red "$TEST::TestBoost::test_boosted" "$TEST::test_scales" | grep -q "$TEST::test_scores_a_job_at_2 is skipped" || { echo "FAIL: a skipped unnamed test in an id-named file must be refused by its id"; exit 1; }
cp "$STUBS/test_score.py.saved" "$TEST"
# Each named test is classified on its own (PR #74 review): one failing for an
# unclassified reason is refused by id even when another named test's
# missing-module failure would classify the pair.
sed 's/from app.boost import boosted_score/raise RuntimeError("boom")/' "$STUBS/test_score.py.saved" > "$TEST"
expect_fail "node red with one unclassified named failure" bash "$TDD" red "$TEST::TestBoost::test_boosted" "$TEST::test_scales" | grep -q "$TEST::TestBoost::test_boosted fails for a reason this script does not classify" || { echo "FAIL: a named test failing for an unclassified reason must be refused by its id"; exit 1; }
cp "$STUBS/test_score.py.saved" "$TEST"
# The same file named whole and by id is ambiguous and refused, rather than
# the ids being dropped silently (PR review).
expect_fail "red naming a file whole and by id" bash "$TDD" red "$TEST" "$TEST::test_scales" | grep -q 'named whole and by test id' || { echo "FAIL: a file named whole and by id must be refused"; exit 1; }

# A class id and a bare parametrized name (every parameter set) are RED
# together: missing-module, three named tests, and the passing test in the
# same file counts in the baseline beside test_baseline.
out=$(bash "$TDD" red "$TEST::TestBoost::test_boosted" "$TEST::test_scales" 2>&1) || { echo "FAIL: node red on the new failing tests must succeed; output: $out"; exit 1; }
[ "$(lock_field .phase)" = "red" ] || { echo "FAIL: node red must move the phase to red"; exit 1; }
[ "$(lock_field '.tests | length')" = "1" ] || { echo "FAIL: two ids in one file must lock one file entry, got $(lock_field '.tests | length')"; exit 1; }
[ "$(lock_field '.tests[0].path')" = "$TEST" ] || { echo "FAIL: the lock entry must carry the containing file, got $(lock_field '.tests[0].path')"; exit 1; }
[ "$(lock_field '.tests[0].ids | join(",")')" = "TestBoost::test_boosted,test_scales" ] || { echo "FAIL: the lock entry must record the named ids, got $(lock_field '.tests[0].ids')"; exit 1; }
[ "$(lock_field '.tests[0].failureClass')" = "missing-module" ] || { echo "FAIL: an import inside the test must be the missing-module RED, got $(lock_field '.tests[0].failureClass')"; exit 1; }
[ "$(lock_field '.tests[0].tests')" = "3" ] || { echo "FAIL: node red must count the named tests (1 + 2 parameter sets), got $(lock_field '.tests[0].tests')"; exit 1; }
[ "$(lock_field '.baseline.passed')" = "2" ] || { echo "FAIL: the baseline must count the passing test beside the named ones, got $(lock_field '.baseline.passed')"; exit 1; }
git add -A && git commit -qm "test(score): PY-3 boost and scale"

# green: a named test still failing is refused by id; a regression in the
# unnamed test of the same file is refused; all named passing is GREEN.
printf 'def boosted_score():\n    return 4\n' > apps/server/app/boost.py
expect_fail "node green with a named test failing" bash "$TDD" green | grep -q 'test_scales' || { echo "FAIL: node green must name the still-failing named test"; exit 1; }
printf 'def score():\n    return 1\n\n\ndef scale(factor):\n    return 2 * factor\n' > apps/server/app/score.py
expect_fail "node green with the unnamed test regressed" bash "$TDD" green | grep -q "the rest of the suite is red.*$TEST" || { echo "FAIL: node green must refuse a regression in the named file's other tests"; exit 1; }
printf 'def score():\n    return 2\n\n\ndef scale(factor):\n    return 2 * factor\n' > apps/server/app/score.py
out=$(bash "$TDD" green 2>&1) || { echo "FAIL: node green must pass once the named tests pass; output: $out"; exit 1; }
bash "$TDD" close >/dev/null
git add -A && git commit -qm "feat(score): PY-3 boost and scale"

# The runs leave nothing untracked: no bytecode, no .pytest_cache.
[ -z "$(git status --porcelain --untracked-files=all)" ] || { echo "FAIL: pytest runs must leave the tree clean; found: $(git status --porcelain --untracked-files=all | tr '\n' ' ')"; exit 1; }

echo "tdd-pytest.test.sh PASS"
