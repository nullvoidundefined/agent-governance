#!/usr/bin/env bash
# Verifies single-file-folder-gate warns (advisory, stderr) when a changed source folder holds
# exactly one source module (R-223), and that .enforce.json exemptions suppress the warning.
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

echo "single-file-folder-gate.test.sh PASS"
