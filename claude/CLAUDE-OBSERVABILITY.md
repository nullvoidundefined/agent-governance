---
paths:
  - "**/*.py"
  - "**/src/handlers/**"
  - "**/src/repositories/**"
  - "**/src/middleware/**"
  - "**/src/routes/**"
  - "**/src/workers/**"
  - "**/src/dependencyInjection/**"
  - "**/src/schemas/**"
  - "**/src/prompts/**"
  - "**/src/services/**"
  - "**/src/clients/**"
  - "**/*.go"
  - "**/*.rb"
---

# Observability Conventions

Rules that hold in every backend stack, followed by each stack's form.

- One request ID per request: honor `X-Request-Id` from the caller only when it matches `^[A-Za-z0-9._-]{1,64}$` (otherwise mint a UUID), echo it on the response, and bind it to the request context so services and repositories log it without receiving it as a parameter. Workers use the job ID the same way.
- One structured logger. Event name or message first, values as fields, never interpolated into the message. Pass errors as structured fields. No `console.*`, `print`, `fmt.Println` or `puts` in server code. No secrets, tokens, passwords, emails or other PII in any field; log IDs.
- Analytics go through one client module (the only importer of the provider SDK) and an event registry. Event names are `object_action` in past tense, defined as constants, never literals at the call site. A provider failure is logged and never fails the request.
- No swallowed errors. Every catch or rescue names the error, binds it and uses it (log or re-raise). The global error handler logs and reports before responding with a generic 500.
- `/health` (liveness, no dependencies) and `/health/ready` (checks the database) on every service and worker, registered before application routes.
- Wrap every outbound provider call once with a telemetry helper that logs provider, operation, duration and outcome. Every client sets an explicit timeout; a client without one is a defect. Outbound HTTP forwards the request ID.

## TypeScript (Express, Pino)

- Context object first, message second: `logger.info({ event: "register_success", userId: user.id }, "User registered")`. Errors always as `{ err }`. Pretty printing in development, JSON in production.
- Request IDs through `pino-http` with `genReqId` that reads or mints `X-Request-Id` and sets the response header. Register `requestLogger` then `bindRequestContext` (an `AsyncLocalStorage<{ requestId }>`) before every route. Services log through `logger.child(requestContext.getStore() ?? {})`.
- `clients/analytics/trackEvent.ts` wraps the SDK in try/catch with `logger.warn({ err, event }, ...)`; events live in `analytics/events.ts` as an `EVENTS` const object.
- Error handler: `logger.error({ err, requestId }, "Unhandled error")`, report to the error tracker, respond `{ error: { message } }` with the detail hidden in production. An expected failure (a cache read) is caught, logged at `warn` and given a defined fallback.
- `clients/withClientTelemetry.ts` wraps each provider call and logs `{ provider, operation, durationMs }` at `debug` on success and `warn` on failure, then rethrows:

```typescript
export function createCheckoutSession(input: CheckoutInput) {
    return withClientTelemetry("stripe", "createCheckoutSession", () =>
        stripe.checkout.sessions.create(input, { timeout: 10_000, idempotencyKey: input.idempotencyKey }),
    );
}
```

## Python (FastAPI, structlog)

- Configure structlog once per process with `merge_contextvars`, `add_log_level`, ISO UTC `TimeStamper`, and `ExceptionRenderer(ExceptionDictTransformer(show_locals=False))` (frame locals can leak passwords). `ConsoleRenderer` in development, `JSONRenderer` otherwise. Route standard-library records (uvicorn and others) through `ProcessorFormatter` so every production line is JSON.
- `logger = structlog.get_logger()` at module level. Event name first as `snake_case`, values as keywords: `logger.info("trip_created", trip_id=trip.id)`. Errors as `exc_info=err`.
- Use `asgi-correlation-id` for the request ID, with a validator that rejects values outside the pattern. Bind `correlation_id.get()` with `structlog.contextvars.bound_contextvars` in the request middleware (not `clear_contextvars()`). Bind `job_id` in workers.
- Body size limit (100 KB) covers streamed bodies: read the body in the middleware, replay it, and send a 413 directly as ASGI messages.
- Analytics: `AnalyticsEvent(StrEnum)` registry in `analytics/events.py`; `clients/analytics.py` calls the SDK in `asyncio.to_thread` and logs `analytics_capture_failed` on `OSError` or provider errors.
- Never write bare `except:` or `except Exception: pass` (ruff `E722`, `S110`, `BLE001`). The one broad `except Exception` is in `clients/telemetry.py::with_client_telemetry`, which logs `client_call_failed` and re-raises.
- Set timeouts on every client (`httpx.AsyncClient(timeout=10.0)`, `AsyncAnthropic(timeout=60.0, max_retries=2)`); an `httpx` event hook adds `X-Request-Id` from the context vars. Workers answer health on `WORKER_PORT`.

## Go

- Middleware reads or mints `X-Request-Id`, writes it to the response and stores it in `context.Context`; log with `slog` using the ID from the context.
- `slog.Info("note loaded", "note_id", id)`; never `fmt.Println` or `log.Printf` with formatted values in service code.
- `clients/analytics` wraps the provider; event names are constants in `analytics/events.go`.
- Handle every error or wrap it with `%w`. `_ = err` and an empty `if err != nil {}` are defects.
- Every client call uses `context.WithTimeout`, logs provider, operation, duration and outcome, and forwards the request ID.

## Ruby (Rails)

- lograge JSON logs, one line per request in production. `config.log_tags = [:request_id]`; `ActionDispatch::RequestId` honors `X-Request-Id`. Jobs log the job ID the same way.
- Log through lograge's custom payload (`Rails.logger.info(event: "note_loaded", note_id: note.id)`), never interpolated values and never `puts`.
- `app/clients/analytics.rb` wraps the provider; event names are constants in `app/analytics/events.rb`.
- Every `rescue` names the exception and logs or re-raises it; no empty `rescue` bodies.
- Every client call sets a timeout, logs provider, operation, duration and outcome, and forwards the request ID.
