#!/usr/bin/env bash
# Verifies single-file-folder-gate warns (advisory, stderr) when a changed source folder holds
# exactly one source module (R-309), and that .enforce.json exemptions suppress the warning.
set -euo pipefail
HOOK="$HOME/.claude/hooks/single-file-folder-gate.sh"
PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'

REPO=$(mktemp -d); cd "$REPO"; git init -q; git switch -q -c main 2>/dev/null || git checkout -q -b main
git commit -q --allow-empty -m init
mkdir -p src/voices
printf 'export function getVoice() {\n  return "x";\n}\n' > src/voices/voices.ts
git add .; git commit -q -m add

# Folder with exactly one source module -> advisory on stderr naming the folder.
ERR=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK" 2>&1 1>/dev/null)
printf '%s' "$ERR" | grep -q "src/voices" || { echo "FAIL: expected single-file-folder advisory for src/voices"; exit 1; }
# It must NOT block (no deny JSON on stdout).
OUT=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK" 2>/dev/null)
[ -z "$OUT" ] || { echo "FAIL: advisory must not deny"; exit 1; }

# Exemption in .enforce.json -> no warning.
printf '{ "singleFileFolderExemptions": ["src/voices"] }\n' > .enforce.json
printf 'export function getVoice() {\n  return "y";\n}\n' > src/voices/voices.ts
git add .; git commit -q -m exempt
ERR2=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK" 2>&1 1>/dev/null)
printf '%s' "$ERR2" | grep -q "src/voices" && { echo "FAIL: exemption should suppress the advisory"; exit 1; } || true

# Python: a package dir holding one real module warns; __init__.py does not count.
mkdir -p app/scoring
printf '"""Scoring."""\n' > app/scoring/__init__.py
printf 'def score_match():\n    return 1\n' > app/scoring/score_match.py
git add .; git commit -q -m py
ERR3=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK" 2>&1 1>/dev/null)
printf '%s' "$ERR3" | grep -q "app/scoring" || { echo "FAIL: expected advisory for single-module python package"; exit 1; }

# Python: Alembic versions/ dir with one migration is exempt.
mkdir -p migrations/versions
printf 'def upgrade():\n    pass\n' > migrations/versions/a1_init.py
git add .; git commit -q -m mig
ERR4=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK" 2>&1 1>/dev/null)
printf '%s' "$ERR4" | grep -q "migrations/versions" && { echo "FAIL: migrations dirs should be exempt"; exit 1; } || true

# R-305 orders components/Header/Header.tsx; R-309 must not then call that folder
# a single-file folder. Two hooks pointing opposite directions is not enforcement.
mkdir -p src/components/Header
printf 'export function Header() {\n  return null;\n}\n' > src/components/Header/Header.tsx
printf '.header { color: red; }\n' > src/components/Header/Header.module.scss
git add .; git commit -q -m component
ERR5=$(printf '%s' "$PAYLOAD" | CLAUDE_ENFORCE_BASE=HEAD~1 "$HOOK" 2>&1 1>/dev/null)
printf '%s' "$ERR5" | grep -q "src/components/Header" && { echo "FAIL: a paired component folder is the R-305 layout, not an R-309 violation"; exit 1; } || true

echo "single-file-folder-gate.test.sh PASS"
