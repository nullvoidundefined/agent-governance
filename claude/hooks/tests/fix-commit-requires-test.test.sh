#!/usr/bin/env bash
# Verifies fix-commit-requires-test.sh (R-403): a fix-family commit with no staged
# test file denies; staged TS or Python test files allow. The tests/ tree and
# pytest filename conventions (test_*.py, *_test.py) count as test files.
set -euo pipefail
HOOK="$HOME/.claude/hooks/fix-commit-requires-test.sh"

payload() { jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }
decision() {
  OUT=$(payload "$1" | "$HOOK")
  if [ -z "$OUT" ]; then echo none; else printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // "none"'; fi
}

REPO=$(mktemp -d); cd "$REPO"; git init -q
git config user.email t@t && git config user.name t
git commit -q --allow-empty -m init

# fix: with no staged test -> deny
printf 'export const x = 1;\n' > fixOnly.ts; git add fixOnly.ts
GOT=$(decision 'git commit -m "fix: broken thing"')
[ "$GOT" = "deny" ] || { echo "FAIL: expected deny with no staged test, got $GOT"; exit 1; }
git commit -qm "chore: clear" >/dev/null

# fix: with a staged TS test -> allow
mkdir -p src/__tests__
printf 'test("x", () => {});\n' > src/__tests__/fix.test.ts; git add src/__tests__/fix.test.ts
GOT=$(decision 'git commit -m "fix: with ts test"')
[ "$GOT" = "none" ] || { echo "FAIL: expected allow with staged TS test, got $GOT"; exit 1; }
git commit -qm "chore: clear2" >/dev/null

# fix: with a staged Python test under tests/ -> allow (the R-403 Python glob)
mkdir -p tests
printf 'def test_fix():\n    assert True\n' > tests/test_fix.py; git add tests/test_fix.py
GOT=$(decision 'git commit -m "fix: with python test"')
[ "$GOT" = "none" ] || { echo "FAIL: expected allow with staged python test, got $GOT"; exit 1; }
git commit -qm "chore: clear3" >/dev/null

# fix: with a staged RSpec file under spec/ -> allow (the R-403 Ruby glob)
mkdir -p spec/models
printf "RSpec.describe Job do\nend\n" > spec/models/job_spec.rb; git add spec/models/job_spec.rb
GOT=$(decision 'git commit -m "fix: with rspec"')
[ "$GOT" = "none" ] || { echo "FAIL: expected allow with staged rspec, got $GOT"; exit 1; }
git commit -qm "chore: clear4" >/dev/null

# fix: with a staged co-located Go test -> allow (the R-403 Go glob)
mkdir -p internal/services
printf 'package services\n\nfunc TestFix(t *testing.T) {}\n' > internal/services/fix_test.go; git add internal/services/fix_test.go
GOT=$(decision 'git commit -m "fix: with go test"')
[ "$GOT" = "none" ] || { echo "FAIL: expected allow with staged go test, got $GOT"; exit 1; }
git commit -qm "chore: clear5" >/dev/null

# non-fix subject untouched even with no test
printf 'x = 2\n' > module.py; git add module.py
GOT=$(decision 'git commit -m "feat: no test needed"')
[ "$GOT" = "none" ] || { echo "FAIL: expected allow for non-fix subject, got $GOT"; exit 1; }

cd / && rm -rf "$REPO"
echo "fix-commit-requires-test.test.sh PASS"
