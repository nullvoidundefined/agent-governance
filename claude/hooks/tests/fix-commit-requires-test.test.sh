#!/usr/bin/env bash
# Covers: hook:fix-commit-requires-test
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

# P2-7 (2026-09-17 audit): the same commit written with `-F -` and a heredoc,
# which is the form the agents in this repo actually use. The subject sits in
# the command text, so the guard has everything it needs, and it saw none of it
# while the extractor keyed on -m alone: R-403 was silently inert for every
# commit of the session that found this. Subjects are assembled from pieces so
# this fixture's own text does not trip the live guard on the way in.
FIX_SUBJECT="fix$(printf ':') broken thing"
SCOPED_SUBJECT="fix(scope)$(printf ':') broken thing"
CHORE_SUBJECT="chore$(printf ':') not a fix"
GOT=$(decision "$(printf 'git commit -q -F - <<MSG\n%s\n\nbody line\nMSG' "$FIX_SUBJECT")")
[ "$GOT" = "deny" ] || { echo "FAIL: expected deny for the -F - heredoc form, got $GOT"; exit 1; }
GOT=$(decision "$(printf "git commit -F - <<'EOF'\n%s\nEOF" "$SCOPED_SUBJECT")")
[ "$GOT" = "deny" ] || { echo "FAIL: expected deny for a quoted heredoc delimiter, got $GOT"; exit 1; }
GOT=$(decision "$(printf 'git commit -q -F - <<MSG\n%s\nMSG' "$CHORE_SUBJECT")")
[ "$GOT" = "none" ] || { echo "FAIL: a non-fix subject in the -F - form must pass, got $GOT"; exit 1; }

# PR #8 review (Copilot, claude/hooks/fix-commit-requires-test.sh): the -m
# branch printed the whole message rather than its first line, so any body line
# or trailer beginning with a fix-family prefix made a docs: or chore: commit
# read as a bug fix and deny. R-403 is about the subject; the subject is the
# first non-empty line of the message and nothing below it.
DOCS_SUBJECT="docs(hooks)$(printf ':') describe the guard"
FIX_BODY_LINE="fix$(printf ':') this prefix opens a body line, not the subject"
GOT=$(decision "$(printf 'git commit -m "%s\n\n%s\n\nCo-Authored-By: A B <a@b>"' "$DOCS_SUBJECT" "$FIX_BODY_LINE")")
[ "$GOT" = "none" ] || { echo "FAIL: a fix-family prefix inside the body must not make a docs: commit deny, got $GOT"; exit 1; }

# The extractor reads only from the `git commit` token onward: a `-m "..."`
# string sitting in an earlier command's heredoc payload is not this commit's
# message, and reading it there silently bypassed R-403 for the real commit.
PAYLOAD_HEREDOC='cat > /tmp/fix-commit-requires-test-fixture-out <<PAYLOAD'
GOT=$(decision "$(printf '%s\n-m "%s"\nPAYLOAD\ngit commit -q -F - <<MSG\n%s\nMSG' "$PAYLOAD_HEREDOC" "$CHORE_SUBJECT" "$FIX_SUBJECT")")
[ "$GOT" = "deny" ] || { echo "FAIL: an unrelated -m in a heredoc payload must not stand in for the commit subject, got $GOT"; exit 1; }

# A heredoc delimiter ends the message at its own line; further commands may
# follow it in the same Bash call without hiding the subject.
GOT=$(decision "$(printf 'git commit -q -F - <<MSG\n%s\nMSG\ngit push origin main' "$FIX_SUBJECT")")
[ "$GOT" = "deny" ] || { echo "FAIL: a command after the heredoc delimiter must not hide the subject, got $GOT"; exit 1; }

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
git commit -qm "chore: clear6" >/dev/null

# Chained add+commit bypass (2026-07-31 engineering audit P1): nothing staged
# yet, the add happens inside the same command. Fix without a test -> deny.
printf 'y = 3\n' > chained.py
GOT=$(decision 'git add chained.py && git commit -m "fix: chained no test"')
[ "$GOT" = "deny" ] || { echo "FAIL: expected deny for chained add+commit without test, got $GOT"; exit 1; }

# Chained add+commit including a test file -> allow.
printf 'def test_chained():\n    assert True\n' > tests/test_chained.py
GOT=$(decision 'git add chained.py tests/test_chained.py && git commit -m "fix: chained with test"')
[ "$GOT" = "none" ] || { echo "FAIL: expected allow for chained add+commit with test, got $GOT"; exit 1; }

cd / && rm -rf "$REPO"
echo "fix-commit-requires-test.test.sh PASS"
