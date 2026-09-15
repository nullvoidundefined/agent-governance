#!/usr/bin/env bash
# observability-reminder.sh: PostToolUse(Write|Edit) advisory for the three
# observability rules ESLint cannot see, because they are about project shape
# rather than one file's syntax (2026-09-04 observability rules, hooks question):
#   R-345  an app entry file registers routes but no /health and /health/ready
#   R-341  an Express app registers middleware but nothing that mints or honors
#          X-Request-Id (pino-http, requestLogger, a request-id middleware)
#   R-346  a clients/ module makes an outbound call with no timeout
# Reads the written file from disk, matches by path and content with cheap
# regexes, and emits a non-blocking reminder (additionalContext). Every check
# is a heuristic, so this never blocks; the push gates and the ratchet are the
# hard guarantees for what they can decide, and these three stay [manual] in
# spirit with a nudge at the moment the file is written. Silent for tests,
# fixtures, scripts, and anything outside a server tree.
file_path=$(jq -rc '.tool_input.file_path // ""' 2>/dev/null)
[ -z "$file_path" ] && exit 0
[ -f "$file_path" ] || exit 0

case "$file_path" in
  *.test.* | *.spec.* | *__tests__* | *__fixtures__* | */tests/* | */test_* | *_test.py | *_test.go | */spec/* | *_spec.rb | */scripts/* | */bin/* | */vendor/* | */node_modules/*) exit 0 ;;
esac

# Server trees only: the R-304 backend names plus the monorepo server roots,
# and the Python, Go, and Rails entry-point conventions.
case "$file_path" in
  */apps/server/* | */packages/worker/* | */server/src/* | */src/handlers/* | */src/repositories/* | */src/middleware/* | */src/workers/* | */clients/* | */app/main.py | */main.py | */app.py | */main.go | */config/routes.rb | */app/*.rb) : ;;
  *) exit 0 ;;
esac

base=$(basename "$file_path")
content=$(cat "$file_path" 2>/dev/null) || exit 0
reminders=""
add() { reminders="${reminders}- $1"$'\n'; }

# R-345 and R-341: entry files that register routes or middleware.
case "$base" in
  app.ts | app.js | app.mjs | server.ts | server.js | index.ts | main.py | app.py | main.go | routes.rb)
    if printf '%s' "$content" | grep -qE 'app\.(get|use|post)\(|router\.|@app\.(route|get)|include_router\(|app\.add_api_route|http\.HandleFunc|mux\.Handle|r\.(Get|Post|Handle)\(|Rails\.application\.routes'; then
      if ! printf '%s' "$content" | grep -q '/health'; then
        add "R-345: this entry file registers routes but no \`GET /health\` (liveness, no dependencies) or \`GET /health/ready\` (dependency checks, 503 when degraded). Register both before the application routes."
      elif ! printf '%s' "$content" | grep -qE '/health/ready|/ready'; then
        add "R-345: \`/health\` is registered but no readiness probe (\`/health/ready\`) checks the dependencies; the post-deploy smoke target needs one."
      fi
      if printf '%s' "$content" | grep -qE 'app\.use\(|include_router\(|app\.add_middleware|Rails\.application' && ! printf '%s' "$content" | grep -qiE 'x-request-id|request[-_]?id|pino-?http|requestLogger|RequestId|ActionDispatch::RequestId|log_tags'; then
        add "R-341: middleware is registered here but nothing mints or honors \`X-Request-Id\`. Add the request-ID middleware (pino-http genReqId plus the response header; structlog contextvars; slog with the ID from context; log_tags in Rails) before the routes."
      fi
    fi
    ;;
esac

# R-346: a clients/ module with an outbound call and no timeout.
case "$file_path" in
  */clients/*)
    if printf '%s' "$content" | grep -qE '\bfetch\(|axios|\bgot\(|undici|httpx\.|requests\.(get|post|put|delete|request)|http\.Client|http\.Get\(|Net::HTTP|Faraday|new [A-Z][A-Za-z]*Client\('; then
      if ! printf '%s' "$content" | grep -qiE 'timeout|AbortSignal|signal:|deadline|context\.WithTimeout|read_timeout|open_timeout'; then
        add "R-346: this client makes an outbound call with no timeout. Set one explicitly (fetch \`signal: AbortSignal.timeout(ms)\`, SDK \`timeout\`, httpx \`timeout=\`, \`context.WithTimeout\`, Faraday \`timeout\`) and wrap the call in \`withClientTelemetry\` so duration, outcome, and the request ID are logged."
      fi
    fi
    ;;
esac

[ -z "$reminders" ] && exit 0
jq -n --arg f "$file_path" --arg r "$reminders" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: ("Observability reminder for " + $f + " (advisory; these are project-shape checks ESLint cannot make):\n" + $r + "Patterns in ~/.claude/CLAUDE-BACKEND.md under Observability. If the file is deliberately exempt, say so and move on.")
  }
}'
exit 0
