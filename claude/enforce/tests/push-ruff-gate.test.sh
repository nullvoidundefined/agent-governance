#!/usr/bin/env bash
# Verifies push-ruff-gate.sh denies a git push whose outgoing diff adds a Python
# AST-tier violation (R-324/R-326/R-329 analogs), allows clean diffs, scopes to
# added lines only, and honors the test-file per-file-ignores.
set -euo pipefail
HOOK="$HOME/.claude/hooks/push-ruff-gate.sh"
PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'

REPO=$(mktemp -d); cd "$REPO"; git init -q; git switch -q -c main 2>/dev/null || git checkout -q -b main
git config user.email t@t && git config user.name t
git commit -q --allow-empty -m init

# Violating change (lambda assignment, E731 / R-326 analog) -> deny.
printf 'double = lambda value: value * 2\n' > bad.py; git add bad.py; git commit -q -m bad
OUT=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null

# Clean change -> allow (no output).
printf 'def double_value(value):\n    return value * 2\n' > bad.py; git add bad.py; git commit -q -m fix
OUT2=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
[ -z "$OUT2" ]

# Added-line scoping: pre-existing violation on an UNTOUCHED line plus a clean
# added line -> allow; the same file gaining a violating added line -> deny.
printf 'legacy = lambda value: value\n' > debt.py; git add debt.py; git commit -q -m debt
printf 'legacy = lambda value: value\n\n\ndef fresh_value(value):\n    return value\n' > debt.py
git add debt.py; git commit -q -m clean-addition
OUT3=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
[ -z "$OUT3" ]

printf 'legacy = lambda value: value\n\n\ndef fresh_value(value):\n    return value\n\n\nworse = lambda value: value + 1\n' > debt.py
git add debt.py; git commit -q -m violating-addition
OUT4=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
printf '%s' "$OUT4" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null

# Magic value in a test file is exempt (R-324 test-literal exemption).
mkdir -p tests
printf 'def test_ttl():\n    assert 1 > 0 and 86400 == 86400\n' > tests/test_ttl.py
git add tests/test_ttl.py; git commit -q -m test-literals
OUT5=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
[ -z "$OUT5" ]

# Magic value in source (PLR2004 / R-324) -> deny.
printf 'def is_expired(age):\n    return age > 86400\n' > ttl.py; git add ttl.py; git commit -q -m magic
OUT6=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
printf '%s' "$OUT6" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null

echo "push-ruff-gate.test.sh PASS"
