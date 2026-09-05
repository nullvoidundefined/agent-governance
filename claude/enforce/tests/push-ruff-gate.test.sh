#!/usr/bin/env bash
# Verifies push-ruff-gate.sh denies a git push whose outgoing diff adds a Python
# AST-tier violation (R-324/R-326/R-329/R-342/R-344 analogs), allows clean
# diffs, scopes to added lines only, and honors the per-file-ignores.
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

# R-344 analogs: a swallowed exception is denied (E722 + S110), a blind
# `except Exception` that does not re-raise is denied (BLE001), and the
# accepted shapes pass: a specific exception that is logged, and a blind one
# that re-raises with cause. The logged-blind-except shape is deliberately
# absent: ruff 0.15 flags it and 0.16 does not.
printf 'def load_note(load):\n    try:\n        return load()\n    except:\n        pass\n' > swallow.py
git add swallow.py; git commit -q -m swallow
OUT6=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
printf '%s' "$OUT6" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
printf 'def load_note(load):\n    try:\n        return load()\n    except Exception:\n        return None\n' > swallow.py
git add swallow.py; git commit -q -m blind
OUT7=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
printf '%s' "$OUT7" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
printf 'import logging\n\nlogger = logging.getLogger(__name__)\n\n\ndef load_note(load):\n    try:\n        return load()\n    except ValueError as err:\n        logger.warning("note_load_failed", exc_info=err)\n        return None\n\n\ndef load_note_strict(load):\n    try:\n        return load()\n    except Exception as err:\n        raise RuntimeError("note load failed") from err\n' > swallow.py
git add swallow.py; git commit -q -m handled
OUT8=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
[ -z "$OUT8" ]

# R-342 analog: print in service code is denied (T201); under scripts/ it passes.
printf 'def show_note(note):\n    print(note)\n' > show.py
git add show.py; git commit -q -m print
OUT9=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
printf '%s' "$OUT9" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
git rm -q show.py; mkdir -p scripts; printf 'print("cli output")\n' > scripts/show.py
git add scripts/show.py; git commit -q -m cli-print
OUT10=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
[ -z "$OUT10" ]

echo "push-ruff-gate.test.sh PASS"
