#!/usr/bin/env bash
# Verifies constant-change-guard.sh: a push whose outgoing diff removes a constant
# value that still appears in test files triggers ask (R-513); clean pushes pass.
set -euo pipefail
HOOK="$HOME/.claude/hooks/constant-change-guard.sh"

decision() {
  OUT=$(jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | "$HOOK")
  if [ -z "$OUT" ]; then echo none; else printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // "none"'; fi
}

TMP=$(mktemp -d)
cd "$TMP"
git init -q
git config user.email t@t && git config user.name t
mkdir -p src/__tests__
printf "export const BRAND_COLOR = '#ff0000';\nexport const STATUS_ACTIVE = 'active';\n" > src/constants.ts
printf "expect(theme.brand).toBe('#ff0000');\n" > src/__tests__/theme.test.ts
git add -A && git commit -qm "chore: init"
BASE=$(git rev-parse HEAD)

# Change a constant WITHOUT updating the stale test assertion -> ask
printf "export const BRAND_COLOR = '#00ff00';\nexport const STATUS_ACTIVE = 'active';\n" > src/constants.ts
git commit -aqm "chore: recolor"
GOT=$(CLAUDE_ENFORCE_BASE=$BASE decision 'git push origin main')
[ "$GOT" = "ask" ] || { echo "FAIL: expected ask for stale assertion, got $GOT"; exit 1; }

# Update the test too -> clean push
printf "expect(theme.brand).toBe('#00ff00');\n" > src/__tests__/theme.test.ts
git commit -aqm "test: update"
GOT=$(CLAUDE_ENFORCE_BASE=$BASE decision 'git push origin main')
[ "$GOT" = "none" ] || { echo "FAIL: expected none after test update, got $GOT"; exit 1; }

# Python: constants.py change with a stale pytest assertion -> ask
mkdir -p app tests
printf "STATUS_ACTIVE = 'enabled'\n" > app/constants.py
printf "def test_status():\n    assert STATUS == 'enabled'\n" > tests/test_status.py
git add -A && git commit -qm "chore: py init"
PYBASE=$(git rev-parse HEAD)
printf "STATUS_ACTIVE = 'running'\n" > app/constants.py
git commit -aqm "chore: py rename"
GOT=$(CLAUDE_ENFORCE_BASE=$PYBASE decision 'git push origin main')
[ "$GOT" = "ask" ] || { echo "FAIL: expected ask for stale python assertion, got $GOT"; exit 1; }
printf "def test_status():\n    assert STATUS == 'running'\n" > tests/test_status.py
git commit -aqm "test: py update"
GOT=$(CLAUDE_ENFORCE_BASE=$PYBASE decision 'git push origin main')
[ "$GOT" = "none" ] || { echo "FAIL: expected none after python test update, got $GOT"; exit 1; }

# Go: constants.go change with a stale co-located test assertion -> ask
mkdir -p internal/config
printf 'package config\n\nconst StatusActive = "live"\n' > internal/config/constants.go
printf 'package config\n\nfunc TestStatus(t *testing.T) {\n\tif StatusActive != "live" {\n\t\tt.Fail()\n\t}\n}\n' > internal/config/constants_test.go
git add -A && git commit -qm "chore: go init"
GOBASE=$(git rev-parse HEAD)
printf 'package config\n\nconst StatusActive = "online"\n' > internal/config/constants.go
git commit -aqm "chore: go rename"
GOT=$(CLAUDE_ENFORCE_BASE=$GOBASE decision 'git push origin main')
[ "$GOT" = "ask" ] || { echo "FAIL: expected ask for stale go assertion, got $GOT"; exit 1; }

# Non-push commands untouched
GOT=$(decision 'git status')
[ "$GOT" = "none" ] || { echo "FAIL: expected none for non-push, got $GOT"; exit 1; }

cd / && rm -rf "$TMP"
echo "constant-change-guard.test.sh PASS"
