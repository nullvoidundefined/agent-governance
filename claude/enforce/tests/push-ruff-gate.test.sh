#!/usr/bin/env bash
# Covers: ruff:ANN401, ruff:BLE001, ruff:E722, ruff:E731, ruff:PGH003, ruff:PLR2004, ruff:S110, ruff:T201
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

# P2-3 (2026-09-17 audit): ANN401, PGH003 and S110 were selected in
# ruff-enforce.toml and named in the manifest with no case driving them, and
# the CI workflow's comment claimed this fixture checked ANN401. S110 was
# reachable only together with E722 above, so it never proved itself either.
# Each is now driven alone, on its own file, so a code dropped from the select
# list fails here rather than silently stopping enforcement.
printf 'from typing import Any\n\n\ndef handle(payload: Any) -> None:\n    return None\n' > anytype.py
git add anytype.py; git commit -qm "test: anytype"
OUT_ANN=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
printf '%s' "$OUT_ANN" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || { echo "FAIL: ANN401 (a typing.Any parameter) must deny"; exit 1; }
printf '%s' "$OUT_ANN" | grep -q "ANN401" \
  || { echo "FAIL: the ANN401 denial must name the code; got: $OUT_ANN"; exit 1; }

printf 'def total(items):\n    return sum(items)  # type: ignore\n' > blanket.py
git add blanket.py; git commit -qm "test: blanket ignore"
OUT_PGH=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
printf '%s' "$OUT_PGH" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || { echo "FAIL: PGH003 (a blanket type ignore) must deny"; exit 1; }
printf '%s' "$OUT_PGH" | grep -q "PGH003" \
  || { echo "FAIL: the PGH003 denial must name the code; got: $OUT_PGH"; exit 1; }
printf 'def total(items):\n    return sum(items)  # type: ignore[arg-type]\n' > blanket.py
git add blanket.py; git commit -qm "test: coded ignore"
OUT_PGH_OK=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
[ -z "$OUT_PGH_OK" ] || { echo "FAIL: a type-ignore carrying its code must pass; got: $OUT_PGH_OK"; exit 1; }

# S110 cannot be isolated: ruff 0.15.8 raises it only for a BROAD handler
# swallowed by pass, and that same shape always raises BLE001 too, while a
# specific handler (`except ValueError: pass`) raises neither (verified against
# the pinned ruff). So the honest assertion is that the denial NAMES S110,
# which proves the code is selected and reported rather than merely listed in
# ruff-enforce.toml; the earlier swallow case asserted only that something
# denied, which S110 could have stopped contributing to unnoticed.
printf 'def load(read):\n    try:\n        read()\n    except Exception:\n        pass\n' > s110.py
git add s110.py; git commit -qm "test: s110"
OUT_S110=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
printf '%s' "$OUT_S110" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || { echo "FAIL: a broad handler swallowed by pass must deny"; exit 1; }
printf '%s' "$OUT_S110" | grep -q "S110" \
  || { echo "FAIL: the denial must name S110, not only its BLE001 companion; got: $OUT_S110"; exit 1; }
printf 'def load(read):\n    try:\n        read()\n    except ValueError:\n        pass\n' > s110.py
git add s110.py; git commit -qm "test: specific handler"
OUT_S110_OK=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK")
[ -z "$OUT_S110_OK" ] \
  || { echo "FAIL: a specific handler is out of S110's scope in the pinned ruff and must pass; got: $OUT_S110_OK"; exit 1; }

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
