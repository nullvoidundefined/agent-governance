#!/usr/bin/env bash
# Verifies the one-export-per-file rule's Next.js App Router exemption (2026-08-04):
# a route.ts under app/api/ may export one function per HTTP method, because the
# framework resolves them by name from that single file and they cannot be split.
# The rule's "**/api/**" glob targets the R-307 fetch-wrapper tree (services/api)
# and swept these in only because both path segments are named "api".
# The exemption is scoped to the route module itself: a sibling helper under
# app/api/ with multiple exports is still flagged.
set -euo pipefail
LINT="$HOME/.claude/enforce/lint.mjs"

DIR=$(mktemp -d); cd "$DIR"; git init -q
mkdir -p src/app/api/tools/batch src/services/api/batch

# App Router route handler exporting two HTTP methods -> allowed.
printf "export async function GET() {\n    return null;\n}\n\nexport async function POST() {\n    return null;\n}\n" > src/app/api/tools/batch/route.ts
node "$LINT" src/app/api/tools/batch/route.ts

# A non-route module under app/api/ is NOT exempt: the carve-out is for the
# framework's route contract, not for the whole directory.
printf "export const a = 1;\nexport const b = 2;\n" > src/app/api/tools/batch/helpers.ts
if node "$LINT" src/app/api/tools/batch/helpers.ts; then
  echo "FAIL: a non-route module under app/api was not flagged" >&2; exit 1
fi

# The R-307 fetch-wrapper tree the glob actually targets is still enforced.
printf "export function saveOne() {}\nexport function loadOne() {}\n" > src/services/api/batch/wrappers.ts
if node "$LINT" src/services/api/batch/wrappers.ts; then
  echo "FAIL: services/api multi-export was not flagged" >&2; exit 1
fi

echo "one-export-app-router.test.sh PASS"
