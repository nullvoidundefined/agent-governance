#!/usr/bin/env bash
# enforce-deps-guard.test.sh: verifies the missing-dependency guard at the top
# of enforce/tests/run-tests.sh. Sixteen fixtures in that directory drive the
# ESLint rule bundle out of enforce/node_modules, which is gitignored, so a
# fresh checkout or a new worktree fails all sixteen at once in a way that
# reads like sixteen rules regressing rather than one absent install. The guard
# turns that into a single line naming the install command, and this fixture is
# here because an unproven guard is the same shape as the unproven adapters
# that let two defects reach an external auditor (2026-09-18).
set -uo pipefail

CLAUDE_HARNESS_ROOT="${CLAUDE_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
RUNNER="$CLAUDE_HARNESS_ROOT/enforce/tests/run-tests.sh"

fail=0
# check(name, fn...): runs fn and reports one PASS or FAIL line, the shared
# convention across this suite. Compound assertions go in a named function
# rather than inline, because `check "..." a && b` binds the && outside check.
check() {
  local name="$1"; shift
  if "$@"; then printf 'PASS: %s\n' "$name"; else printf 'FAIL: %s\n' "$name"; fail=1; fi
}

SANDBOX=$(mktemp -d)
mkdir -p "$SANDBOX/enforce/tests"
cp "$RUNNER" "$SANDBOX/enforce/tests/run-tests.sh"
printf '{"name":"sandbox-enforce","private":true}\n' > "$SANDBOX/enforce/package.json"
# One trivially passing fixture, so a run that gets past the guard succeeds and
# the two cases below differ only by the guard, never by fixture content.
printf '#!/usr/bin/env bash\necho "sandbox.test.sh PASS"\n' > "$SANDBOX/enforce/tests/sandbox.test.sh"
chmod +x "$SANDBOX/enforce/tests/sandbox.test.sh"

# Case 1: package.json present, node_modules absent. The guard must refuse.
OUT=$(bash "$SANDBOX/enforce/tests/run-tests.sh" 2>&1); ST=$?
guardRefused() { [ "$ST" -ne 0 ]; }
guardNamedInstall() { grep -q "npm ci --prefix" <<< "$OUT"; }
guardNamedGitignore() { grep -q "gitignored" <<< "$OUT"; }
guardRanNoFixture() { ! grep -q "sandbox.test.sh PASS" <<< "$OUT"; }
check "a missing enforce/node_modules refuses the run" guardRefused
check "the refusal names the install command" guardNamedInstall
check "the refusal explains why every checkout needs it" guardNamedGitignore
check "no fixture runs before the guard refuses" guardRanNoFixture

# Case 2: node_modules present. The guard must stand aside entirely.
mkdir -p "$SANDBOX/enforce/node_modules"
OUT2=$(bash "$SANDBOX/enforce/tests/run-tests.sh" 2>&1); ST2=$?
guardAllowed() { [ "$ST2" -eq 0 ]; }
fixtureRan() { printf '%s' "$OUT2" | grep -q "sandbox.test.sh"; }
check "an installed enforce/node_modules runs the suite" guardAllowed
check "the suite reaches its fixtures once installed" fixtureRan

rm -rf "$SANDBOX"
[ "$fail" -eq 0 ] && echo "enforce-deps-guard.test.sh PASS"
exit "$fail"
