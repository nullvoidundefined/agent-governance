#!/usr/bin/env bash
# Shard: slow
# Verifies the pytest runner in enforce/tdd.sh (R-412): a *.py test path runs
# the whole pytest suite of the nearest project above it holding
# pyproject.toml, as `uv run pytest` when uv is on PATH and as
# `<python> -m pytest` with a warning otherwise, and the JUnit XML pytest
# writes is converted into the report shape red and green already read. Red
# accepts an assertion failure and a missing module and refuses a passing
# test, a skipped test, a syntax error, a file with no tests, and a slice that
# mixes runners; green accepts the fixed implementation and refuses a still
# failing test, a skipped test, and a dropped baseline. Drives the REAL pytest
# (on PATH, as CI installs it pinned, or through uvx at the same pin) behind a
# stub uv and a stub .venv python that record how they were called, so the
# JUnit parsing is exercised against live output and the invocation choice is
# observed rather than assumed.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../enforce/harness-root.sh"
TDD="$CLAUDE_HARNESS_ROOT/enforce/tdd.sh"

# Keep in step with the pytest pin in .github/workflows/enforce.yml.
PYTEST_PIN="9.1.1"
if command -v pytest >/dev/null 2>&1; then PYTEST_COMMAND="pytest"
elif command -v uvx >/dev/null 2>&1; then PYTEST_COMMAND="uvx --quiet --from pytest==$PYTEST_PIN pytest"
else echo "FAIL: neither pytest nor uvx is on PATH; install pytest==$PYTEST_PIN (CI does it with pipx)"; exit 1
fi

P=$(cd "$(mktemp -d)" && pwd -P)
STUBS=$(mktemp -d)
CALLS="$STUBS/calls.log"
trap 'cd / && rm -rf "$P" "$STUBS"' EXIT

# The stub uv accepts only `uv run pytest ...` and hands the rest of the
# arguments to the real pytest, logging its working directory and arguments.
cat > "$STUBS/uv" <<STUB
#!/usr/bin/env bash
printf 'uv %s | %s\n' "\$PWD" "\$*" >> "$CALLS"
[ "\${1:-}" = run ] && [ "\${2:-}" = pytest ] || { echo "stub uv: unexpected arguments: \$*" >&2; exit 97; }
shift 2
exec $PYTEST_COMMAND "\$@"
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
grep -q "^uv $SERVER | run pytest " "$CALLS" || { echo "FAIL: pytest must run as 'uv run pytest' from the pyproject.toml directory; calls: $(cat "$CALLS")"; exit 1; }

# red again: a wrong answer is the assertion RED.
impl 1
bash "$TDD" red "$TEST" >/dev/null
[ "$(lock_field '.tests[0].failureClass')" = "assertion" ] || { echo "FAIL: expected assertion for a failed assert, got $(lock_field '.tests[0].failureClass')"; exit 1; }
[ "$(lock_field '.tests[0].tests')" = "1" ] || { echo "FAIL: the assertion RED must record one test, got $(lock_field '.tests[0].tests')"; exit 1; }

# green: still failing is refused by test name; the phase stays red.
expect_fail "pytest green while failing" bash "$TDD" green | grep -q 'test_scores_a_job_at_2' || { echo "FAIL: a still-failing pytest green must name the failing test"; exit 1; }
[ "$(lock_field .phase)" = "red" ] || { echo "FAIL: a refused pytest green must leave the phase red"; exit 1; }

# green: the fixed implementation passes and the phase becomes green.
git add -A && git commit -qm "test(score): PY-1 score returns 2"
impl 2
bash "$TDD" green >/dev/null || { echo "FAIL: pytest green must pass once score returns 2"; echo "DIAG pyc: $(find "$P" -name '*.pyc' -not -path '*/.venv/*' | tr '\n' ' ')"; echo "DIAG shebang: $(head -1 "$(command -v pytest)" 2>/dev/null || true)"; echo "DIAG cmd: $PYTEST_COMMAND"; echo "DIAG env: $(env | grep -i '^python' | tr '\n' ' ' || true)"; exit 1; }
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
# warning. The stub interpreter hands `-m pytest ...` to the real pytest and
# anything else (the JUnit converter's `-c`) to the real python3, logging
# which, so the converter's use of the project interpreter is observed too
# (PR #72 review).
REAL_PYTHON=$(command -v python3)
mkdir -p apps/server/.venv/bin
cat > apps/server/.venv/bin/python <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = -m ] && [ "\${2:-}" = pytest ]; then
  printf 'python %s | %s\n' "\$PWD" "\$*" >> "$CALLS"
  shift 2
  exec $PYTEST_COMMAND "\$@"
fi
printf 'python-convert %s\n' "\${1:-}" >> "$CALLS"
exec "$REAL_PYTHON" "\$@"
STUB
chmod +x apps/server/.venv/bin/python
: > "$CALLS"
out=$(CLAUDE_TDD_UV=no-such-uv bash "$TDD" open --refactor "PY-2 tidy score" --lock "$TEST" 2>&1) || { echo "FAIL: open --refactor through the python fallback must succeed; output: $out"; exit 1; }
grep -q "uv is not on PATH" <<< "$out" || { echo "FAIL: the python fallback must warn that uv is missing; output: $out"; exit 1; }
grep -q "^python $SERVER | -m pytest " "$CALLS" || { echo "FAIL: without uv pytest must run through the project's .venv python; calls: $(cat "$CALLS")"; exit 1; }
grep -q "^python-convert -c" "$CALLS" || { echo "FAIL: the JUnit converter must run through the project's .venv python; calls: $(cat "$CALLS")"; exit 1; }
[ "$(lock_field '.baseline.runner')" = "pytest" ] || { echo "FAIL: a pytest refactor must record the pytest runner"; exit 1; }
CLAUDE_TDD_UV=no-such-uv bash "$TDD" green >/dev/null 2>&1 && bash "$TDD" close >/dev/null || { echo "FAIL: green and close through the python fallback must succeed"; exit 1; }

# The runs leave nothing untracked: no bytecode, no .pytest_cache.
[ -z "$(git status --porcelain --untracked-files=all)" ] || { echo "FAIL: pytest runs must leave the tree clean; found: $(git status --porcelain --untracked-files=all | tr '\n' ' ')"; exit 1; }

echo "tdd-pytest.test.sh PASS"
