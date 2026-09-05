#!/usr/bin/env bash
# Verifies observability-reminder.sh (advisory PostToolUse for R-341, R-345,
# R-346). Six invariants:
#   1. An Express app.ts with routes and no /health reminds R-345.
#   2. The same file with /health, /health/ready, and pino-http is silent.
#   3. An app.ts with middleware and health routes but no request-ID reminds R-341 only.
#   4. A clients/ module calling fetch without a timeout reminds R-346.
#   5. The same client with AbortSignal.timeout is silent.
#   6. A test file and a file outside any server tree are silent whatever they contain.
set -euo pipefail
HOOK="$HOME/.claude/hooks/observability-reminder.sh"
TMP=$(mktemp -d)
mkdir -p "$TMP/apps/server/src/clients/stripe" "$TMP/apps/client/src"

run() { jq -n --arg f "$1" '{hook_event_name:"PostToolUse",tool_name:"Write",tool_input:{file_path:$f}}' | "$HOOK"; }
ctx() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // ""'; }

# 1. Routes, no health.
printf 'import express from "express";\nconst app = express();\napp.use(express.json());\napp.get("/notes", listNotes);\nexport { app };\n' > "$TMP/apps/server/src/app.ts"
OUT=$(run "$TMP/apps/server/src/app.ts")
ctx "$OUT" | grep -q 'R-345' || { echo "FAIL: expected an R-345 reminder for an app with routes and no /health"; exit 1; }

# 2. Complete entry file is silent.
printf 'import express from "express";\nimport { requestLogger } from "./middleware/requestLogger.js";\nconst app = express();\napp.use(requestLogger);\napp.get("/health", liveness);\napp.get("/health/ready", readiness);\napp.get("/notes", listNotes);\nexport { app };\n' > "$TMP/apps/server/src/app.ts"
OUT=$(run "$TMP/apps/server/src/app.ts")
[ -z "$OUT" ] || { echo "FAIL: a complete entry file must be silent, got: $(ctx "$OUT")"; exit 1; }

# 3. Health present, request ID absent.
printf 'import express from "express";\nconst app = express();\napp.use(express.json());\napp.get("/health", liveness);\napp.get("/health/ready", readiness);\napp.get("/notes", listNotes);\nexport { app };\n' > "$TMP/apps/server/src/app.ts"
OUT=$(run "$TMP/apps/server/src/app.ts")
ctx "$OUT" | grep -q 'R-341' || { echo "FAIL: expected an R-341 reminder when middleware is registered without a request ID"; exit 1; }
ctx "$OUT" | grep -q 'R-345' && { echo "FAIL: R-345 must not fire when both health routes exist"; exit 1; } || true

# 4. Client without a timeout.
printf 'export async function createCheckoutSession(input: object) {\n  const response = await fetch("https://api.stripe.com/v1/checkout/sessions", { method: "POST", body: JSON.stringify(input) });\n  return response.json();\n}\n' > "$TMP/apps/server/src/clients/stripe/createCheckoutSession.ts"
OUT=$(run "$TMP/apps/server/src/clients/stripe/createCheckoutSession.ts")
ctx "$OUT" | grep -q 'R-346' || { echo "FAIL: expected an R-346 reminder for a client call with no timeout"; exit 1; }

# 5. Client with a timeout is silent.
printf 'export async function createCheckoutSession(input: object) {\n  const response = await fetch("https://api.stripe.com/v1/checkout/sessions", { method: "POST", body: JSON.stringify(input), signal: AbortSignal.timeout(10_000) });\n  return response.json();\n}\n' > "$TMP/apps/server/src/clients/stripe/createCheckoutSession.ts"
OUT=$(run "$TMP/apps/server/src/clients/stripe/createCheckoutSession.ts")
[ -z "$OUT" ] || { echo "FAIL: a client with a timeout must be silent, got: $(ctx "$OUT")"; exit 1; }

# 6. Out of scope: a test file in the server tree and an app.ts in the client tree.
mkdir -p "$TMP/apps/server/src/__tests__"
printf 'const app = express();\napp.get("/notes", listNotes);\n' > "$TMP/apps/server/src/__tests__/app.ts"
OUT=$(run "$TMP/apps/server/src/__tests__/app.ts"); [ -z "$OUT" ] || { echo "FAIL: test files must be silent"; exit 1; }
printf 'const app = express();\napp.get("/notes", listNotes);\n' > "$TMP/apps/client/src/app.ts"
OUT=$(run "$TMP/apps/client/src/app.ts"); [ -z "$OUT" ] || { echo "FAIL: files outside a server tree must be silent"; exit 1; }

echo "observability-reminder.test.sh PASS"
