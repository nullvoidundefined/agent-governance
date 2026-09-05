# Backend Observability Rules (R-341 to R-346)

Design doc. Status: approved 2026-09-04 by the maintainer's request ("rules enforcing observability best practices: analytics, request ids, etc."), implemented the same day.

## Motivation

`CLAUDE-BACKEND.md` already describes Pino logging, `pino-http` request IDs, two health endpoints, and a global error handler, and `CLOUD-DEPLOYMENT.md` names `/health` as the Railway healthcheck. None of it was a rule: nothing carried an ID, nothing had a Spec block, and nothing was enforced. A handler that logged with `console.log`, an analytics call with a typo in a string literal, or a `catch {}` that swallowed a provider error all passed every gate. The rules below make the existing conventions load-bearing and mechanize the decidable part.

## Rules (within the R-3xx architecture block, as R-34x)

- **R-341** Request ID: one ID per inbound request, honoring an inbound `X-Request-Id`, generated otherwise, echoed on the response, bound to the request context, carried by every log line, error report, and outbound call for that request. Manual: whether a middleware exists and what it binds is a project-shape question, not an AST question.
- **R-342** Structured logging: the one logger, never `console`, in server code; context object first, message second, values in the object rather than the message. ESLint: `no-console` scoped to the server trees; `structured-log-call` decides the two syntactic defects (interpolated message, object after the message).
- **R-343** Analytics events: one `clients/analytics` module, event names from a checked-in registry, never a string literal at the call site. ESLint: `analytics-event-name` decides the literal-at-call-site half; the single-module half is R-307's `clients/` rule.
- **R-344** No swallowed errors: every `catch` binds the error and uses it (log with `{ err }`, report, return, or rethrow with cause). ESLint: `no-empty` with `allowEmptyCatch: false`; `no-swallowed-catch` decides "bound and referenced".
- **R-345** Health and readiness: `GET /health` (liveness, no dependencies) and `GET /health/ready` (dependency checks, 503 when degraded) on every service and worker, registered before application routes. Manual.
- **R-346** Outbound instrumentation: every `clients/` call logs provider, operation, duration, and outcome, forwards the request ID, and sets a timeout. Manual.

## Components

- `enforce/rules/structured-log-call.mjs` (R-342). Recognizes `<logger>.<level>(...)` where the logger is an identifier named `logger` or `log`, or a member ending in `.log`/`.logger` (`req.log`), and the level is one of trace, debug, info, warn, error, fatal. Reports a template literal with expressions or a `+` concatenation as the message, and a string message followed by an object argument (pino treats that object as an interpolation value and drops it).
- `enforce/rules/analytics-event-name.mjs` (R-343). Reports a string literal or template literal as the first argument of `.track(`, `.capture(`, or `trackEvent(`.
- `enforce/rules/no-swallowed-catch.mjs` (R-344). Reports a `catch` without a binding and a `catch (err)` whose binding is never referenced in the block.
- `enforce/eslint.config.mjs`: one config object scoped to the server trees (`apps/server`, `packages/worker`, `server/src`, and any `src/handlers`, `src/repositories`, `src/middleware`, `src/workers`), tests and scripts exempt, activating the three rules plus `no-console` and `no-empty`.

Not decided mechanically, and said so: whether a logger call carries the request ID (R-341), whether a `catch` that references the error does something useful with it, whether the registry entry an analytics call names exists, and everything in R-345 and R-346. `services/` and `clients/` trees outside a server root are not in scope, because the same directory names exist in the frontend layout and ESLint cannot see the package's dependencies the way `structure-gate.sh` does.

## Wiring and registration (R-516)

Manifest rows: R-342 `eslint:no-console` and `eslint:structured-log-call`; R-343 `eslint:analytics-event-name`; R-344 `eslint:no-empty` and `eslint:no-swallowed-catch`. All `ast` tier, severity `error`, no autofix. The push gate scopes them to added lines and the ratchet grandfathers existing violations, as with every other AST rule.

Lexicon: `log`, `report`, and `track` join the approved verbs so `logRequest`, `reportError`, and `trackEvent` pass R-316 in repos that opt into the lexicon.

## Testing

`enforce/tests/observability-rules.test.sh`: scope (the same `console.log` reports under `apps/server` and passes under `apps/client`), each R-342 defect and its accepted forms (`logger.info({ id }, "msg")`, `logger.info("Worker started")`, `req.log.warn`), R-343 literal versus registry constant, R-344 empty catch, unused binding, unbound catch, and the accepted log-and-rethrow.

## Domain vocabulary

- request ID - the single identifier minted or accepted once per inbound request and carried through every log line, error report, and outbound call it causes - chosen over: correlation ID, trace ID because `X-Request-Id` is the header the stack's middleware already honors, "correlation" implies a multi-service join this rule does not require, and "trace" collides with OpenTelemetry's trace/span model that a project may or may not adopt.
- context object - the first argument of a logger call, the structured fields Pino serializes - chosen over: metadata, payload because Pino's own docs call it the merging object and "payload" names request bodies elsewhere in the conventions.
- analytics event - a product fact recorded through the analytics client, named `object_action` - chosen over: metric, track call because a metric is a number over time and a track call is the transport, not the thing.
- event registry - the one module (`analytics/events.ts`) that declares every analytics event name - chosen over: event catalog, taxonomy because the naming lexicon is already called a registry (`enforce/lexicon.json`) and the two play the same role.
- error report - the record sent to the error tracker for an unexpected failure, tagged with the request ID - chosen over: exception capture because the rule is about what is reported, not the provider verb.
- liveness probe, readiness probe - `GET /health` and `GET /health/ready` - chosen over: healthcheck, status endpoint because Kubernetes and Railway both use the liveness/readiness distinction and the two endpoints answer different questions.
- outbound call instrumentation - the duration, outcome, and request-ID forwarding recorded around every `clients/` call - chosen over: tracing, telemetry because both name whole systems this rule does not mandate.
