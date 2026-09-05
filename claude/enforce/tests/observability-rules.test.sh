#!/usr/bin/env bash
# Verifies the observability rules (R-342, R-343, R-344) added 2026-09-04.
#
# Scope:
#   1. console.log under apps/server reports (no-console); the same file under
#      apps/client passes, because the block is scoped to the server trees.
# R-342 structured-log-call:
#   2. An interpolated message reports.
#   3. A string message followed by a context object reports (Pino drops it).
#   4. Context first, message second passes; a bare message passes.
#   5. req.log.<level> with an interpolated message reports.
# R-343 analytics-event-name:
#   6. A literal event name at .track( reports; a registry constant passes.
#   7. A template literal at .capture( reports.
# R-344 no-swallowed-catch and no-empty:
#   8. An empty catch reports.
#   9. A bound error never referenced reports.
#  10. An unbound catch with a body reports.
#  11. Log-with-err then rethrow passes.
set -euo pipefail
E="$HOME/.claude/enforce"

TMP=$(mktemp -d)
mkdir -p "$TMP/apps/server/src/services" "$TMP/apps/server/src/handlers" "$TMP/apps/client/src/services"

reports() {
  local report
  report=$(node "$E/lint.mjs" "$TMP/$1" 2>&1 || true)
  printf '%s' "$report" | grep -q "$2"
}
passes() { node "$E/lint.mjs" "$TMP/$1" >/dev/null 2>&1; }

# 1. Scope.
printf 'export function getNote() {\n  console.log("x");\n}\n' > apps-console.ts
cp apps-console.ts "$TMP/apps/server/src/services/getNote.ts"
cp apps-console.ts "$TMP/apps/client/src/services/getNote.ts"
reports apps/server/src/services/getNote.ts "no-console" || { echo "FAIL: console.log under apps/server must report (R-342)"; exit 1; }
passes apps/client/src/services/getNote.ts || { echo "FAIL: console.log under apps/client must not be in the server-scoped block"; exit 1; }

# 2. Interpolated message.
printf 'declare const logger: { info: (...args: unknown[]) => void };\nexport function getNote(id: string) {\n  logger.info(`note ${id}`);\n}\n' > "$TMP/apps/server/src/services/interpolated.ts"
reports apps/server/src/services/interpolated.ts "R-342: put values in the context object" || { echo "FAIL: interpolated log message must report"; exit 1; }

# 3. Object after the message.
printf 'declare const logger: { info: (...args: unknown[]) => void };\nexport function getNote(id: string) {\n  logger.info("note loaded", { id });\n}\n' > "$TMP/apps/server/src/services/objectAfter.ts"
reports apps/server/src/services/objectAfter.ts "context object comes first" || { echo "FAIL: object after the message must report"; exit 1; }

# 4. Accepted shapes.
printf 'declare const logger: { info: (...args: unknown[]) => void };\nexport function getNote(id: string) {\n  logger.info({ id }, "note loaded");\n  logger.info("worker started");\n}\n' > "$TMP/apps/server/src/services/accepted.ts"
passes apps/server/src/services/accepted.ts || { echo "FAIL: context-first and bare-message calls must pass"; node "$E/lint.mjs" "$TMP/apps/server/src/services/accepted.ts" || true; exit 1; }

# 5. req.log.
printf 'export function handleNote(req: { log: { warn: (...args: unknown[]) => void } }, id: string) {\n  req.log.warn(`missing ${id}`);\n}\n' > "$TMP/apps/server/src/handlers/reqLog.ts"
reports apps/server/src/handlers/reqLog.ts "R-342" || { echo "FAIL: req.log with an interpolated message must report"; exit 1; }

# 6. Analytics literal vs registry.
printf 'declare const analytics: { track: (name: string, props: object) => void };\nexport function trackSignup(userId: string) {\n  analytics.track("signup_completed", { userId });\n}\n' > "$TMP/apps/server/src/services/trackLiteral.ts"
reports apps/server/src/services/trackLiteral.ts "R-343" || { echo "FAIL: literal event name must report"; exit 1; }
printf 'declare const analytics: { track: (name: string, props: object) => void };\ndeclare const EVENTS: { signupCompleted: string };\nexport function trackSignup(userId: string) {\n  analytics.track(EVENTS.signupCompleted, { userId });\n}\n' > "$TMP/apps/server/src/services/trackRegistry.ts"
passes apps/server/src/services/trackRegistry.ts || { echo "FAIL: registry constant must pass"; node "$E/lint.mjs" "$TMP/apps/server/src/services/trackRegistry.ts" || true; exit 1; }

# 7. Template literal at .capture(.
printf 'declare const posthog: { capture: (name: string) => void };\nexport function trackView(page: string) {\n  posthog.capture(`viewed_${page}`);\n}\n' > "$TMP/apps/server/src/services/captureTemplate.ts"
reports apps/server/src/services/captureTemplate.ts "R-343" || { echo "FAIL: template literal event name must report"; exit 1; }

# 8. Empty catch.
printf 'export async function getNote(load: () => Promise<string>) {\n  try {\n    return await load();\n  } catch {}\n  return "";\n}\n' > "$TMP/apps/server/src/services/emptyCatch.ts"
reports apps/server/src/services/emptyCatch.ts "R-344\|no-empty" || { echo "FAIL: empty catch must report"; exit 1; }

# 9. Bound but unused.
printf 'export async function getNote(load: () => Promise<string>) {\n  try {\n    return await load();\n  } catch (err) {\n    return "";\n  }\n}\n' > "$TMP/apps/server/src/services/unusedCatch.ts"
reports apps/server/src/services/unusedCatch.ts "never used" || { echo "FAIL: unreferenced catch binding must report"; exit 1; }

# 10. Unbound catch with a body.
printf 'export async function getNote(load: () => Promise<string>) {\n  try {\n    return await load();\n  } catch {\n    return "";\n  }\n}\n' > "$TMP/apps/server/src/services/unboundCatch.ts"
reports apps/server/src/services/unboundCatch.ts "bind the error" || { echo "FAIL: unbound catch must report"; exit 1; }

# 11. Log and rethrow passes.
printf 'declare const logger: { error: (...args: unknown[]) => void };\nexport async function getNote(load: () => Promise<string>) {\n  try {\n    return await load();\n  } catch (err) {\n    logger.error({ err }, "note load failed");\n    throw err;\n  }\n}\n' > "$TMP/apps/server/src/services/handledCatch.ts"
passes apps/server/src/services/handledCatch.ts || { echo "FAIL: log-and-rethrow must pass"; node "$E/lint.mjs" "$TMP/apps/server/src/services/handledCatch.ts" || true; exit 1; }

rm -f apps-console.ts
echo "observability-rules.test.sh PASS"
