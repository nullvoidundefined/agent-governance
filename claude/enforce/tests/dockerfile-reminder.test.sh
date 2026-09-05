#!/usr/bin/env bash
# Verifies dockerfile-reminder.sh (advisory PostToolUse for R-351). Nine invariants:
#   1. A server entry file in a repo with no Dockerfile reminds R-351.
#   2. The same file with a root Dockerfile and .dockerignore is silent.
#   3. A root Dockerfile with no .dockerignore reminds about .dockerignore only.
#   4. A package.json with a start script and no Dockerfile reminds; one
#      without a start script (a library) is silent.
#   5. A platform deploy config (railway.toml) with no Dockerfile reminds.
#   6. A per-app Dockerfile (apps/server/Dockerfile) satisfies the walk-up.
#   7. A written Dockerfile with FROM node:latest and no USER reminds on both;
#      a pinned multi-stage Dockerfile with USER and .dockerignore is silent.
#   8. A stage alias (FROM builder) and a digest-pinned image are not unpinned.
#   9. Test files, node_modules, and an index.ts outside a server tree are silent.
set -euo pipefail
HOOK="$HOME/.claude/hooks/dockerfile-reminder.sh"
TMP=$(mktemp -d)

run() { jq -n --arg f "$1" '{hook_event_name:"PostToolUse",tool_name:"Write",tool_input:{file_path:$f}}' | "$HOOK"; }
ctx() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // ""'; }
new_repo() { local r="$TMP/$1"; mkdir -p "$r/.git"; printf '%s' "$r"; }

# 1. Entry file, no Dockerfile anywhere.
REPO=$(new_repo one); mkdir -p "$REPO/apps/server/src"
printf 'import { app } from "./app.js";\napp.listen(3000);\n' > "$REPO/apps/server/src/index.ts"
OUT=$(run "$REPO/apps/server/src/index.ts")
ctx "$OUT" | grep -q 'R-351.*no Dockerfile exists' || { echo "FAIL: expected an R-351 reminder for a server entry file with no Dockerfile"; exit 1; }

# 2. Root Dockerfile plus .dockerignore: silent.
printf 'FROM node:22-alpine\nUSER node\n' > "$REPO/Dockerfile"; printf 'node_modules\n.env*\n' > "$REPO/.dockerignore"
OUT=$(run "$REPO/apps/server/src/index.ts")
[ -z "$OUT" ] || { echo "FAIL: a repo with a root Dockerfile and .dockerignore must be silent, got: $(ctx "$OUT")"; exit 1; }

# 3. Dockerfile present, .dockerignore missing.
rm "$REPO/.dockerignore"
OUT=$(run "$REPO/apps/server/src/index.ts")
ctx "$OUT" | grep -q 'dockerignore' || { echo "FAIL: expected a .dockerignore reminder"; exit 1; }
ctx "$OUT" | grep -q 'no Dockerfile exists' && { echo "FAIL: the missing-Dockerfile reminder must not fire when one exists"; exit 1; } || true

# 4. package.json with and without a start script.
REPO=$(new_repo two); mkdir -p "$REPO/packages/shared"
printf '{"name":"api","scripts":{"build":"tsc","start":"node dist/index.js"}}\n' > "$REPO/package.json"
OUT=$(run "$REPO/package.json")
ctx "$OUT" | grep -q 'start script' || { echo "FAIL: expected a reminder for a package.json with a start script"; exit 1; }
printf '{"name":"@repo/shared","scripts":{"build":"tsc","test":"vitest"}}\n' > "$REPO/packages/shared/package.json"
OUT=$(run "$REPO/packages/shared/package.json")
[ -z "$OUT" ] || { echo "FAIL: a library package.json must be silent, got: $(ctx "$OUT")"; exit 1; }

# 5. Deploy config with no Dockerfile.
printf '[build]\nbuilder = "NIXPACKS"\n' > "$REPO/railway.toml"
OUT=$(run "$REPO/railway.toml")
ctx "$OUT" | grep -q 'platform deploy config' || { echo "FAIL: expected a reminder for a deploy config with no Dockerfile"; exit 1; }

# 6. Per-app Dockerfile found on the walk up.
REPO=$(new_repo three); mkdir -p "$REPO/apps/server/src"
printf 'FROM node:22-alpine\nUSER node\n' > "$REPO/apps/server/Dockerfile"; : > "$REPO/apps/server/.dockerignore"
printf 'app.listen(3000);\n' > "$REPO/apps/server/src/index.ts"
OUT=$(run "$REPO/apps/server/src/index.ts")
[ -z "$OUT" ] || { echo "FAIL: a per-app Dockerfile must satisfy the walk-up, got: $(ctx "$OUT")"; exit 1; }

# 7. Dockerfile content: unpinned and root, then a clean multi-stage file.
REPO=$(new_repo four)
printf 'FROM node:latest\nCOPY . .\nCMD ["node","dist/index.js"]\n' > "$REPO/Dockerfile"
OUT=$(run "$REPO/Dockerfile")
ctx "$OUT" | grep -q 'non-root user' || { echo "FAIL: expected a USER reminder for a root Dockerfile"; exit 1; }
ctx "$OUT" | grep -q 'unpinned base image (node:latest)' || { echo "FAIL: expected an unpinned-image reminder for node:latest, got: $(ctx "$OUT")"; exit 1; }
ctx "$OUT" | grep -q 'dockerignore' || { echo "FAIL: expected a .dockerignore reminder beside a new Dockerfile"; exit 1; }
printf 'FROM node:22-alpine AS builder\nWORKDIR /app\nCOPY . .\nRUN npm ci && npm run build\n\nFROM node:22-alpine\nWORKDIR /app\nCOPY --from=builder /app/dist ./dist\nUSER node\nHEALTHCHECK CMD wget -qO- http://localhost:3000/health || exit 1\nCMD ["node","dist/index.js"]\n' > "$REPO/Dockerfile"
: > "$REPO/.dockerignore"
OUT=$(run "$REPO/Dockerfile")
[ -z "$OUT" ] || { echo "FAIL: a pinned multi-stage Dockerfile with USER must be silent, got: $(ctx "$OUT")"; exit 1; }

# 8. Stage aliases, digests, and untagged images.
printf 'FROM golang:1.23 AS Builder\nRUN go build -o /out/app .\nFROM gcr.io/distroless/static@sha256:0123456789abcdef\nCOPY --from=Builder /out/app /app\nUSER nonroot\nFROM builder AS test\n' > "$REPO/Dockerfile"
OUT=$(run "$REPO/Dockerfile")
[ -z "$OUT" ] || { echo "FAIL: stage aliases and digest pins must not count as unpinned, got: $(ctx "$OUT")"; exit 1; }
printf 'FROM python\nUSER app\n' > "$REPO/Dockerfile"
OUT=$(run "$REPO/Dockerfile")
ctx "$OUT" | grep -q 'unpinned base image (python)' || { echo "FAIL: an untagged image must count as unpinned, got: $(ctx "$OUT")"; exit 1; }

# 9. Out of scope.
REPO=$(new_repo five); mkdir -p "$REPO/apps/server/src/__tests__" "$REPO/node_modules/express" "$REPO/apps/client/src/components"
printf 'app.listen(3000);\n' > "$REPO/apps/server/src/__tests__/index.ts"
OUT=$(run "$REPO/apps/server/src/__tests__/index.ts"); [ -z "$OUT" ] || { echo "FAIL: test files must be silent"; exit 1; }
printf '{"name":"express","scripts":{"start":"node index.js"}}\n' > "$REPO/node_modules/express/package.json"
OUT=$(run "$REPO/node_modules/express/package.json"); [ -z "$OUT" ] || { echo "FAIL: node_modules must be silent"; exit 1; }
printf 'export { Button } from "./Button";\n' > "$REPO/apps/client/src/components/index.ts"
OUT=$(run "$REPO/apps/client/src/components/index.ts"); [ -z "$OUT" ] || { echo "FAIL: an index.ts outside a server tree must be silent"; exit 1; }

echo "dockerfile-reminder.test.sh PASS"
