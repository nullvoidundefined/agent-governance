#!/usr/bin/env bash
# Verifies lint.mjs enforces per-repo import-direction zones from a repo's .enforce.json
# (R-224): a lower layer importing a higher one is flagged only when .enforce.json declares it.
set -euo pipefail
LINT="$HOME/.claude/enforce/lint.mjs"
REPO=$(mktemp -d); cd "$REPO"
mkdir -p src/services src/handlers
printf 'export function handleAuth() {\n  return true;\n}\n' > src/handlers/authHandler.ts
printf 'import { handleAuth } from "../handlers/authHandler";\n\nexport function runAuth() {\n  return handleAuth();\n}\n' > src/services/authService.ts

# Without .enforce.json: the import-direction rule is inactive -> file passes.
node "$LINT" src/services/authService.ts >/dev/null 2>&1 || { echo "FAIL: should pass with no .enforce.json"; exit 1; }

# With a zone forbidding services -> handlers: the cross-layer import is flagged.
cat > .enforce.json <<'JSON'
{ "importZones": [ { "target": "src/services", "from": "src/handlers", "message": "services must not import handlers (R-224)" } ] }
JSON
node "$LINT" src/services/authService.ts >/dev/null 2>&1 && { echo "FAIL: expected R-224 import-direction violation"; exit 1; } || true

echo "import-direction.test.sh PASS"
