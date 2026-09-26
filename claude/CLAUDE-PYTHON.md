---
paths:
  - "**/*.py"
---

# Python Backend Conventions

The Python track for API services, workers, and scheduled jobs. It mirrors `CLAUDE-BACKEND.md` (the Express track) section for section and restates the parts of `CLAUDE-DATABASE.md` that change shape under SQLAlchemy and Alembic. The universal rules in `CLAUDE.md` still apply; this file carries the Python form of every `[ts]`-tagged rule. Every choice below is the only supported choice: there is one framework, one worker, one package manager, and one logger.

---

## Stack

- **Python 3.13**, pinned in `pyproject.toml` (`requires-python = ">=3.13,<3.14"`) and in `.python-version`
- **FastAPI** on **uvicorn** (ASGI), started in factory mode
- **PostgreSQL** through **SQLAlchemy 2 Core** with the async engine on the **asyncpg** driver; no ORM models, no `Session.add`, tables are `Table` objects on one `MetaData`
- **Alembic** for migrations
- **Pydantic v2** for request and response schemas, **pydantic-settings** for configuration
- **redis.asyncio** for rate limits and the job queue
- **arq** for background jobs and scheduled jobs
- **structlog** for all logging; **asgi-correlation-id** for request IDs
- **Anthropic Python SDK** (`anthropic.AsyncAnthropic`) for LLM calls and **httpx** (`httpx.AsyncClient`) for every other outbound call, both wrapped in `clients/`
- **uv** for environments, dependencies, and the lockfile
- **pytest** with **pytest-asyncio** for tests; **ruff**, **black**, and **mypy --strict** for quality
- **Railway** for hosting, deployed as Docker images (Containers below)

---

## Directory Structure

One service per repository root, or `apps/server/` inside a monorepo. The package is always `app`.

```
app/
├── main.py                    # create_app() factory; uvicorn entry
├── core/                      # settings, logging setup, security primitives
│   ├── settings.py            # pydantic-settings Settings + get_settings()
│   ├── logging.py             # structlog configuration
│   └── security.py            # password hashing, token generation
├── db/                        # engine, connection dependency, table metadata
│   ├── engine.py
│   ├── session.py             # get_connection dependency, run_in_transaction
│   └── tables.py              # MetaData + every Table object
├── middleware/                # ASGI middleware, one class per file (csrf_guard.py, ...)
├── dependencies/              # FastAPI Depends providers (current user, repositories)
│   └── current_user.py
├── routers/                   # HTTP routers: thin; validate, delegate, respond
│   ├── health.py
│   └── trips.py
├── schemas/                   # Pydantic request and response models, one module per domain
│   └── trips.py
├── services/                  # business logic operating on inputs (R-306)
│   └── trips/
│       └── price_trip.py
├── repositories/              # data access; all SQL lives here
│   └── trips.py
├── clients/                   # one thin module per external provider (R-307)
│   └── telemetry.py           # with_client_telemetry wrapper (R-346)
├── constants/                 # error_codes.py, session.py, limits
├── analytics/                 # events.py: the event registry (R-343)
├── prompts/                   # agentic apps: prompt templates as .md package data
├── tools/                     # agentic apps: one module per model-callable tool
└── workers/                   # settings.py (arq WorkerSettings) and jobs/
migrations/                    # env.py (async, target_metadata) and versions/
tests/                         # unit/ and integration/, mirroring app/ (R-313)
docs/openapi.yaml              # exported from the app, diffed in CI
pyproject.toml
uv.lock
alembic.ini
Dockerfile
Dockerfile.worker
docker-compose.yml
```

- Directories appear only when occupied (R-309); the vocabulary is fixed, the set is not mandatory on day one
- `utils/`, `helpers/`, `common/`, `lib/`, and `shared/` never exist (R-306); `core/` is the one allowed exception and holds only settings, logging setup, and security primitives
- `prompts/` and `tools/` exist only in agentic services; a tool module exports one tool definition and its handler

---

## Layer Responsibilities

| Layer | Does | Does NOT |
|---|---|---|
| **Middleware** | Cross-cutting request concerns: request ID, CSRF, timeout, idempotency, rate limit | Touch domain data, call services |
| **Dependencies** | Build per-request values through the `Depends` chain: DB connection, current user, settings | Contain business rules |
| **Routers** | Declare the route, receive validated Pydantic input, call one service or repository, return a response model | Contain business logic, run SQL, build SQL |
| **Services** | Business logic on inputs; orchestrate repositories and clients | Know about `Request`, `Response`, or status codes |
| **Repositories** | Run parameterized SQLAlchemy Core statements, return typed rows | Validate input, know about HTTP |
| **Clients** | Wrap exactly one provider's SDK or HTTP API with telemetry and timeouts | Hold domain logic |
| **Workers** | Receive a job payload, call services, record the outcome | Serve HTTP beyond the health probe |

Dependencies flow one direction (R-303): `routers -> services -> repositories -> db`, and `services -> clients`. Middleware and dependencies sit beside routers and may call repositories for session and idempotency lookups only. Lower layers never import higher ones, and nothing imports from `routers/`.

---

## File and Module Naming

Every module is `snake_case.py`, named for its one responsibility (R-315, R-318). The directory states the layer, so no module carries a layer suffix: `repositories/trips.py`, never `repositories/trips_repository.py`.

| Layer | Convention | Example |
|---|---|---|
| Routers | Plural resource noun | `routers/trips.py` |
| Schemas | The domain noun, matching the router | `schemas/trips.py` |
| Repositories | The table name (R-334) | `repositories/trip_legs.py` |
| Services | Operation, verb plus noun, inside a domain folder | `services/trips/price_trip.py` |
| Clients | Provider name | `clients/stripe.py` |
| Middleware | What it guards or adds | `middleware/csrf_guard.py` |
| Dependencies | What it provides | `dependencies/current_user.py` |
| Worker jobs | Verb plus noun | `workers/jobs/send_digest_email.py` |
| Migrations | Date, sequence, and a slug | `versions/20260918_0001_create_trips.py` |
| Tests | `test_` plus the module under test | `tests/unit/services/trips/test_price_trip.py` |

- Functions: verb plus noun in `snake_case`, the noun mandatory (R-316): `fetch_trip`, `create_user_session`, `score_offer`
- Booleans: `is_`, `has_`, `can_`, or `should_` prefix: `is_expired`, `has_access`
- Constants: module-level `UPPER_SNAKE`; a single-use literal stays beside its consumer (R-324)
- Classes: `PascalCase`; schema classes follow the Validation table below
- Variables: descriptive nouns, plural for collections, no bare adjectives (R-317): `priced_offers`, not `priced`

A feature grows as a folder of operations, not as suffixed files:

```
services/trips/
├── create_trip.py
├── price_trip.py
└── reorder_trip_legs.py
```

---

## File Layout

Order within a module, top to bottom, one blank line between groups (the Python form of R-321):

1. Module docstring: what the module does and why it exists (R-320; ruff `D100`)
2. `from __future__ import annotations` when a forward reference needs it
3. Imports, in the groups under Import Ordering
4. Module-level `UPPER_SNAKE` constants
5. The primary public function or class
6. Private helpers (`_leading_underscore`), ordered by call sequence, caller above callee

- `def` and `async def` only; never a lambda assigned to a name (ruff `E731`)
- Every public function carries a docstring (ruff `D103`) and full type hints

---

## Functions, Classes, and Data Models

Functions for logic, objects for state and boundaries, data models for data. Default to the simplest form and move down the list only when the code demands it:

1. **Functions** for transformations, calculations, validation, orchestration, and stateless business logic
2. **Data models** for structured data: Pydantic `BaseModel` at boundaries, `@dataclass(slots=True, frozen=True)` for internal values, `TypedDict` for typed dict shapes (Python Typing Patterns below)
3. **Classes** only for meaningful mutable state, a lifecycle (start, stop, open, close), interchangeable implementations behind one interface, or an object that owns behavior over time

- Never write a class to group related functions; the module is the grouping. A TypeScript-style `FooService`, `FooManager`, or `FooUtils` class becomes a `foo.py` module of plain functions
- Never write a class whose only state is constructor arguments consumed by one method; pass them as function parameters
- Carve-out: a repository that holds request-scoped state (the `AsyncConnection` and the scoping `user_id`) may be a small class built by a dependency; its methods follow the same naming rules
- Favoring functions is not pure functional programming: use loops, mutation of local state, exceptions, context managers, generators, and closures where they read most plainly; never force `map`/`reduce` chains or monadic patterns onto Python

```python
# A function: the class would add nothing
def calculate_order_total(line_items: list[LineItem], tax_rate: Decimal) -> Decimal:
    """Return the order total including tax."""
    subtotal = sum((item.price * item.quantity for item in line_items), Decimal(0))
    return subtotal * (1 + tax_rate)


# A class: dependencies, mutable state, and a lifecycle
class JobRunner:
    """Pull jobs from a queue until stopped."""

    def __init__(self, job_queue: JobQueue) -> None:
        self._job_queue = job_queue
        self.is_running = False

    def start_runner(self) -> None:
        self.is_running = True

    def stop_runner(self) -> None:
        self.is_running = False
```

---

## Import Ordering

ruff's `I` rules sort imports; the groups are fixed:

```python
"""Prices a trip by summing its selected offers' price lines."""

# 1. Standard library
from decimal import Decimal
from uuid import UUID

# 2. Third-party packages
import structlog
from sqlalchemy.ext.asyncio import AsyncConnection

# 3. Local application imports (absolute, from app)
from app.repositories import trip_offer_price_lines
from app.schemas.trips import TripPriceResponse
```

- Absolute `from app...` imports only; no relative imports (`from ..repositories import`)
- Import a repository or service module and call through it (`trip_offer_price_lines.list_for_trip(...)`), so every call site shows the layer it crosses
- Type-only imports that would create a cycle go under `if TYPE_CHECKING:`

---

## Entry Point (App Factory)

```python
"""Builds the FastAPI application; uvicorn runs this factory."""

from fastapi import FastAPI

from app.core.logging import configure_logging
from app.core.settings import get_settings
from app.routers import health, trips


def create_app() -> FastAPI:
    """Assemble settings, logging, middleware, handlers, and routers in order."""
    settings = get_settings()
    configure_logging(settings)
    app = FastAPI(title=settings.app_name, lifespan=build_lifespan(settings))
    register_middleware(app, settings)
    register_exception_handlers(app)
    app.include_router(health.router)
    app.include_router(trips.router)
    return app
```

- uvicorn starts it with `uvicorn app.main:create_app --factory`
- Nothing runs at import time: settings, the engine, the Redis connection, and every SDK client are built inside `create_app()`, inside the lifespan, or inside a cached dependency, so tests import any module without environment variables
- The `lifespan` async context manager opens the engine and Redis on startup, stores them on `app.state`, and disposes them on shutdown; `@app.on_event` is not used
- The `register_*` functions live in `main.py` beside the factory, and each is an atomic function (R-322)

---

## Build Tool (uv)

- `pyproject.toml` declares the project, its dependencies, the `dev` dependency group, and all tool configuration; `uv.lock` is committed and always current
- `uv sync --frozen` installs exactly the lockfile; CI and Docker never resolve
- `uv run <command>` runs every tool (`uv run pytest`, `uv run alembic upgrade head`); scripts never activate a virtualenv by hand
- `uv add <package>` adds a dependency and updates the lockfile in one step (R-331 applies to every addition)
- `[project.scripts]` names the console entry points (`api`, `worker`); a `justfile` is optional sugar over `uv run`
- No other installer, no `requirements.txt`, no poetry

---

## Health Endpoints

```python
"""Liveness and readiness probes, registered before every application router."""

import asyncio

import structlog
from fastapi import APIRouter, Request, Response, status
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError

READINESS_TIMEOUT_SECONDS = 2
router = APIRouter(tags=["health"])


@router.get("/health")
async def read_liveness() -> dict[str, str]:
    """Answer 200 without touching any dependency."""
    return {"status": "ok"}


@router.get("/health/ready")
async def read_readiness(request: Request, response: Response) -> dict[str, str]:
    """Answer 200 when the database answers, 503 when it does not, including a failed connect."""
    try:
        async with asyncio.timeout(READINESS_TIMEOUT_SECONDS):
            async with request.app.state.engine.connect() as connection:
                await connection.execute(text("SELECT 1"))
    except (OSError, SQLAlchemyError, TimeoutError) as err:
        structlog.get_logger().warning("readiness_db_failed", exc_info=err)
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return {"status": "degraded", "db": "disconnected"}
    return {"status": "ok", "db": "connected"}
```

- `/health` is the Railway healthcheck path and the Docker `HEALTHCHECK` target
- `/health/ready` runs in post-deploy smoke tests. Readiness is bounded by `asyncio.timeout` (corrected 2026-09-19: without a client-side deadline, a hanging connect stalled the probe instead of answering 503)
- The health router is included first and outside the `/v1` prefix (R-345). Router order cannot bypass global middleware, so the rate limiter and the CSRF guard each skip `/health` and `/health/ready` by path, and readiness opens its own connection so a failed connect still answers 503

---

## Worker Pattern (arq)

Workers live in `app/workers/`. `settings.py` holds the `WorkerSettings` class arq reads; each job is one function in `workers/jobs/`.

```python
"""arq worker configuration: queue connection, job registry, lifecycle hooks."""

import structlog
from arq.connections import RedisSettings

from app.core.logging import configure_logging
from app.core.settings import get_settings
from app.db.engine import create_database_engine
from app.workers.context import WorkerContext
from app.workers.jobs.send_digest_email import send_digest_email


async def start_worker_resources(ctx: WorkerContext) -> None:
    """Open the engine once per worker process and log the start."""
    settings = get_settings()
    configure_logging(settings)
    ctx["engine"] = create_database_engine(settings)
    structlog.get_logger().info("worker_started")


async def stop_worker_resources(ctx: WorkerContext) -> None:
    """Dispose the engine on graceful shutdown."""
    await ctx["engine"].dispose()
    structlog.get_logger().info("worker_stopped")


class WorkerSettings:
    functions = [send_digest_email]
    redis_settings = RedisSettings.from_dsn(get_settings().redis_url.get_secret_value())
    on_startup = start_worker_resources
    on_shutdown = stop_worker_resources
    max_jobs = 10
    job_timeout = 300
    max_tries = 3
    health_check_interval = 30
```

- `WorkerSettings` is the one place a module-level read of settings is allowed, because arq imports the class to start the process; nothing else imports `workers/settings.py`
- `WorkerContext` is a `TypedDict` (`engine: AsyncEngine`, `job_id: str`, plus arq's keys), so `mypy --strict` types every `ctx[...]` read. A job function takes `ctx: WorkerContext` first, receives only IDs and small values, and loads everything else from the database; a payload never carries a model object
- Every job binds `job_id=ctx["job_id"]` into the structlog context on entry, so every line and every outbound call carries it (R-341)
- Jobs are idempotent: a retried job checks its own completion marker before it acts
- The API enqueues through one `clients/queue.py` (`await queue.enqueue_job("send_digest_email", user_id)`), and the job name string lives only there, derived from `send_digest_email.__name__`
- Health (R-345): `start_worker_resources` also starts a minimal Starlette app on `WORKER_PORT` (default 3002) as a background `uvicorn.Server` task, serving `/health` and `/health/ready` (a `SELECT 1` and a Redis `PING`), and the container's `HEALTHCHECK` hits it; `arq --check` stays a CI smoke of the queue, not the probe
- arq handles `SIGTERM` by letting running jobs finish up to `job_timeout`; Railway's drain window is set at least that long
- The worker ships as `Dockerfile.worker`: the API image with `CMD ["arq", "app.workers.settings.WorkerSettings"]` and a `HEALTHCHECK` on port 3002

---

## Containers (R-351)

Every deployable artifact (API, worker, scheduled job) ships its Dockerfile in the commit that creates it. The image is the deploy unit on every platform; buildpacks are never the deploy path.

```dockerfile
# Dockerfile (API)
FROM python:3.13-slim AS builder
COPY --from=ghcr.io/astral-sh/uv:0.8 /uv /usr/local/bin/uv
WORKDIR /app
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project
COPY app/ app/
COPY migrations/ migrations/
COPY alembic.ini ./
RUN uv sync --frozen --no-dev

FROM python:3.13-slim
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PATH="/app/.venv/bin:$PATH"
RUN useradd --create-home --uid 10001 app
COPY --from=builder --chown=app:app /app /app
USER app
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" || exit 1
CMD ["uvicorn", "app.main:create_app", "--factory", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers"]
```

- `--proxy-headers` trusts `X-Forwarded-For` only from the addresses in `FORWARDED_ALLOW_IPS` (uvicorn's `--forwarded-allow-ips` read from the environment), set at run time to the reverse proxy's private network as a CIDR, so a redeploy that changes the proxy's address still matches; Rate Limiting below depends on it. Never `*`, which makes uvicorn take the first, client-forgeable entry, and settings refuse to start production without it, because a missing value keys every proxied request on the proxy's address and puts the whole site in one bucket. The right-to-left walk past trusted addresses needs uvicorn 0.53 or later, the pinned floor

- **Multi-stage**, with base images pinned to a version tag, never `latest`
- **Non-root** `app` user in the runtime stage
- **`.dockerignore`**: `.git`, `.venv`, `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.env*`, `tests/`, `docs/`
- Configuration arrives as environment variables at run time through pydantic-settings, never as a build argument and never as a baked file (R-102, R-104)
- **`docker-compose.yml`** runs the API, the worker, Postgres 17, and Redis 7 for local development and integration tests, reading `.env.example` values, never a real `.env` (R-103)
- Migrations run as a release step (`alembic upgrade head`) before the new image takes traffic, never inside the app's startup
- **`railway.toml`** sets `dockerfilePath` per service, and CI builds both images on every pull request and runs each `HEALTHCHECK` target once

---

## Session Store

Cookie sessions backed by Postgres, the same design as the Express template. The cookie carries a random token; the database stores only its SHA-256 hash.

```python
"""Creates and verifies session tokens and passwords; the cookie holds the only raw token."""

import asyncio
import hashlib
import secrets
from datetime import timedelta

import bcrypt

SESSION_COOKIE_NAME = "sid"
SESSION_TTL = timedelta(days=7)
BCRYPT_ROUNDS = 12
_DUMMY_PASSWORD_HASH = bcrypt.hashpw(b"timing-equalizer", bcrypt.gensalt(BCRYPT_ROUNDS))


def generate_session_token() -> tuple[str, str]:
    """Return the raw token for the cookie and its SHA-256 hash for the database."""
    raw_token = secrets.token_urlsafe(32)
    return raw_token, hashlib.sha256(raw_token.encode()).hexdigest()


async def verify_password(candidate: str, stored_hash: str | None) -> bool:
    """Check a password off the event loop, against a dummy hash when the user is unknown."""
    target_hash = stored_hash.encode() if stored_hash else _DUMMY_PASSWORD_HASH
    is_match = await asyncio.to_thread(bcrypt.checkpw, candidate.encode(), target_hash)
    return is_match and stored_hash is not None
```

- **Table** `user_sessions` (R-334): `id uuid PK`, `user_id uuid FK -> users ON DELETE CASCADE`, `token_hash text UNIQUE NOT NULL`, `expires_at timestamptz NOT NULL`, `created_at`, `last_seen_at`, and an index on `expires_at`
- **Cookie**: `httponly=True`, `secure` tied to every non-development environment, `samesite="lax"`, `max_age` from `SESSION_TTL`, `path="/"`, set with `response.set_cookie`. A staging cookie without `secure` travels over plain HTTP, so the check names development and nothing else:

```python
def set_session_cookie(response: Response, raw_token: str, settings: Settings) -> None:
    """Write the session cookie; the login route passes the settings it got from Depends(get_settings)."""
    response.set_cookie(
        SESSION_COOKIE_NAME,
        raw_token,
        httponly=True,
        secure=settings.environment != "development",
        samesite="lax",
        max_age=int(SESSION_TTL.total_seconds()),
        path="/",
    )
```

```python
async def test_session_cookie_is_secure_in_staging(app, client, registered_user):
    """A cookie without Secure in staging would travel over plain HTTP."""
    staging_settings = Settings(_env_file=None, environment="staging", database_url="postgresql://localhost/app_test")
    app.dependency_overrides[get_settings] = lambda: staging_settings
    try:
        response = await client.post("/v1/auth/login", json={"email": registered_user.email, "password": "changeme"})
    finally:
        app.dependency_overrides.pop(get_settings, None)
    set_cookie_header = response.headers["set-cookie"]
    assert "Secure" in set_cookie_header
    assert "HttpOnly" in set_cookie_header
```

- **Email** is trimmed and lowercased before every insert and lookup, and `users` carries a unique index on `lower(email)` (added 2026-09-19: without both, `A@x.com` and `a@x.com` register as two accounts and login depends on case)
- **Login** looks up the user, runs `verify_password` even when the user is missing (the dummy hash equalizes timing), and answers `AUTH_INVALID_CREDENTIALS` in both cases
- **Password reset** (`user_password_resets`, token stored as its SHA-256 hash): 1-hour expiry; issuing a reset deletes the user's earlier unused resets; consumption is one atomic `UPDATE ... SET used_at = now() WHERE token_hash = :hash AND used_at IS NULL AND expires_at > now() RETURNING user_id`, and success deletes every session of the user (added 2026-09-19: a select-then-update lets two concurrent submissions of one token both succeed)
- **Resolution**: the `get_current_user` dependency hashes the cookie value, selects the session joined to its user where `expires_at > now()`, raises `AUTH_REQUIRED` or `AUTH_SESSION_EXPIRED`, and binds `user_id` into the structlog context
- **Admin**: `require_admin` depends on `get_current_user` and raises `AUTH_ADMIN_REQUIRED` unless `user.role == "admin"`
- **Logout** deletes the session row and clears the cookie; a password change deletes every other session of that user
- **Cleanup**: expired rows are deleted hourly by the arq cron job (pg_cron Cleanup Jobs below)
- bcrypt always runs inside `asyncio.to_thread`, for verification as above and for hashing at registration, so it never blocks the event loop

---

## CSRF

Cookie sessions need a CSRF guard. The API requires a custom header that a browser will not send cross-origin without a CORS preflight:

- `middleware/csrf_guard.py` rejects `POST`, `PUT`, `PATCH`, and `DELETE` requests that lack `X-Requested-With: XMLHttpRequest` with 403 and `CSRF_HEADER_MISSING`
- Exempt: the Stripe webhook route (verified by signature instead) and the health routes
- CORS allows only `settings.cors_origin`, with `allow_credentials=True`, so a foreign origin cannot pass the preflight that the header forces
- No token endpoint and no double-submit cookie

---

## Rate Limiting

- A Redis-backed fixed-window limiter in `middleware/rate_limit.py`, keyed on `scope["client"]` (`request.client.host`), the client IP uvicorn resolved through the trusted-proxy chain (Containers above); the limiter never parses `X-Forwarded-For` itself
- The trust chain: the edge (Railway) appends the connecting address as the last `X-Forwarded-For` entry, and every earlier entry is client-supplied; the reverse proxy in front of the API (the Nitro proxy in a Nuxt stack) forwards only that last entry, and uvicorn honors it only from the proxy's private address, so a direct request is keyed on its peer address (corrected 2026-09-19: the first `X-Forwarded-For` hop is client-forgeable, so keying on it let one client rotate buckets at will)
- Global limit: 100 requests per 15 minutes; auth routes, matched on the full `/v1` path the middleware sees (`/v1/auth/login`, `/v1/auth/register`, `/v1/auth/forgot-password`, `/v1/auth/reset-password`): 10 per 15 minutes (corrected 2026-09-19: the list names every limited path in full, because a pattern written without the `/v1` mount prefix never matches and leaves the route on the global limit)
- Over the limit: 429 with `RATE_LIMIT_EXCEEDED` and a `Retry-After` header
- Without `REDIS_URL` the limiter falls back to an in-process counter and logs one `rate_limiter_in_memory` warning, in development and test only: settings refuse to start production without `REDIS_URL`, because per-process counters let an attacker rotate across instances past the auth limit
- Skipped when `settings.environment == "test"`; the rate-limit tests turn it back on explicitly

---

## Idempotency Keys

- `middleware/idempotency.py` handles `POST` and `PUT` requests that carry an `Idempotency-Key` header from an authenticated user; everything else passes through
- A new key claims a row in `request_idempotency_keys` (`key`, `user_id`, `request_method`, `request_path`, `request_body_hash`, `state` in `in_progress` or `completed`, `locked_until`, `claim_token uuid`, `status_code` and `response_body jsonb` null until completed, `created_at`, unique on `(key, user_id)`), runs the handler, and stores the status and body with `state = 'completed'`
- A `completed` key seen within 24 hours replays the stored status code and body without running the handler, but only when method, path, and SHA-256 body hash all match; any mismatch answers 422 `IDEMPOTENCY_KEY_REUSED` and runs nothing (corrected 2026-09-19: scoping by `(key, user_id)` alone let a key sent to one endpoint replay its response into another)
- A claim takes a 60-second lease (`locked_until`). A second request that meets an `in_progress` claim inside its lease answers 409; one that meets an expired lease takes the claim over with one `UPDATE ... SET locked_until = now() + interval '60 seconds', claim_token = :mine WHERE key = :key AND user_id = :user_id AND state = 'in_progress' AND locked_until < now() RETURNING key`, so two takeovers cannot both win, and runs the handler (corrected 2026-09-19: a process that crashed between claim and completion stranded the key until cleanup). The completion `UPDATE` and the `finally` `DELETE` that releases a claim after a raise or a 5xx both carry `AND claim_token = :mine`, so a slow original process can neither overwrite nor delete the claim that took it over, and the client's retry runs again
- Rows older than 24 hours are deleted by the hourly cleanup job

---

## Request Timeout

`middleware/request_timeout.py` wraps the downstream call in `asyncio.timeout(30)` and answers 408 with `SERVER_REQUEST_TIMEOUT` when it fires. Streaming routes (SSE) are exempt and enforce their own idle timeout.

---

## Environment Validation

```python
"""Typed settings read from the environment once and validated at startup."""

import re
from functools import lru_cache
from typing import Literal

from pydantic import SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

UNSAFE_CORS_ORIGINS = frozenset({"*", "null"})  # CORSMiddleware allow-all, and the iframe origin
# Accepts scheme://host[:port] for the two browser schemes; the host must start with a
# letter or digit, and the port alternatives exclude each scheme's default (443, 80) and
# cap at 65535, since a browser never sends a default port or an out-of-range one.
BROWSER_ORIGIN_PATTERN = re.compile(r"^(https://[a-z0-9][a-z0-9.-]*(:(?:[1-9][0-9]?|[1-35-9][0-9]{2}|4[0-35-9][0-9]|44[0-24-9]|[1-9][0-9]{3}|6553[0-5]|655[0-2][0-9]|65[0-4][0-9]{2}|6[0-4][0-9]{3}|[1-5][0-9]{4}))?|http://[a-z0-9][a-z0-9.-]*(:(?:[1-9]|[1-79][0-9]|8[1-9]|[1-9][0-9]{2}|[1-9][0-9]{3}|6553[0-5]|655[0-2][0-9]|65[0-4][0-9]{2}|6[0-4][0-9]{3}|[1-5][0-9]{4}))?)$")


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore", hide_input_in_errors=True)

    app_name: str = "api"
    environment: Literal["development", "test", "staging", "production"] = "development"
    database_url: SecretStr
    redis_url: SecretStr | None = None
    cors_origin: str | None = None
    database_ca_cert: str | None = None
    forwarded_allow_ips: str | None = None

    @field_validator("cors_origin")
    @classmethod
    def refuse_unsafe_cors_origin(cls, value: str | None) -> str | None:
        origin = (value or "").strip()
        if origin and (origin.lower() in UNSAFE_CORS_ORIGINS or not BROWSER_ORIGIN_PATTERN.fullmatch(origin)):
            raise ValueError("CORS_ORIGIN must be one concrete scheme://host[:port] origin")
        return origin or None

    @model_validator(mode="after")
    def require_production_values(self) -> "Settings":
        """Refuse to start in production without the values production needs."""
        required_values = (self.cors_origin, self.redis_url, self.forwarded_allow_ips)
        if self.environment == "production" and not all(required_values):
            raise ValueError("CORS_ORIGIN, REDIS_URL, and FORWARDED_ALLOW_IPS are required in production")
        return self


@lru_cache
def get_settings() -> Settings:
    """Build the settings once per process."""
    return Settings()
```

`CORS_ORIGIN` is validated in every environment, not only production: with `allow_credentials=True`, Starlette reads `*` as allow-all and echoes each caller's `Origin`, and `null` is the origin every sandboxed iframe sends, so either value hands the session cookie to any site. The negative test feeds each value a browser could never send:

```python
def test_settings_refuses_unsafe_cors_origin(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DATABASE_URL", "postgresql://localhost/app_test")
    unsafe_origins = ("*", "null", "https://a.example,https://b.example", "https://client.example/path", "https://name@client.example")
    for unsafe_origin in unsafe_origins:
        monkeypatch.setenv("CORS_ORIGIN", unsafe_origin)
        with pytest.raises(ValidationError) as exc_info:
            Settings(_env_file=None)
        assert exc_info.value.errors()[0]["loc"] == ("cors_origin",)


def test_settings_accepts_real_cors_origin(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DATABASE_URL", "postgresql://localhost/app_test")
    monkeypatch.setenv("CORS_ORIGIN", "https://app.example.com")
    settings = Settings(_env_file=None)
    assert settings.cors_origin == "https://app.example.com"
```

- Business code receives `Settings` through `Depends(get_settings)` or a parameter; nothing reads `os.environ`
- Secrets are `SecretStr` fields, never logged and never echoed in an error (R-102)
- `.env.example` lists every variable with a placeholder value (`changeme`), never a real one (R-108)

---

## FastAPI App Structure

Starlette wraps middleware outside-in: the middleware added last runs first on the request. Register in reverse of the order the request should see them:

```python
def register_middleware(app: FastAPI, settings: Settings) -> None:
    """Add middleware last to first so requests pass them in the documented order."""
    app.add_middleware(IdempotencyMiddleware)                    # 7
    app.add_middleware(CsrfGuardMiddleware)                      # 6
    app.add_middleware(RequestTimeoutMiddleware, seconds=30)     # 5
    app.add_middleware(RateLimitMiddleware, settings=settings)   # 4
    cors_origins = [settings.cors_origin] if settings.cors_origin else []  # already validated
    app.add_middleware(
        CORSMiddleware,
        allow_origins=cors_origins,
        allow_credentials=True,
        allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE"],
        allow_headers=["Content-Type", "X-Requested-With", "Idempotency-Key", "X-Request-Id"],
    )                                                            # 3
    app.add_middleware(SecurityHeadersMiddleware)                # 2
    app.add_middleware(RequestContextMiddleware)                 # 1b
    app.add_middleware(CorrelationIdMiddleware, header_name="X-Request-Id", validator=is_valid_request_id)  # 1a
```

The request passes them in this order:

1. **Request ID and body limit**: asgi-correlation-id (1a, outermost, so every response carries the ID, 413s included) keeps a valid inbound `X-Request-Id` or mints one; `RequestContextMiddleware` (1b) binds it into structlog and rejects a body over 100 KB with 413 `INPUT_PAYLOAD_TOO_LARGE` unless the route is on the upload allowlist
2. **Security headers**: the Helmet equivalents (`X-Content-Type-Options`, `Referrer-Policy`, and `Strict-Transport-Security` in production)
3. **CORS**, so preflights answer before anything else can reject them
4. **Rate limit**
5. **Request timeout**
6. **CSRF guard**
7. **Idempotency**, innermost, because it needs the resolved user and must capture the final response

- Session resolution is a dependency, not middleware, so each route declares whether it needs a user; idempotency reads the user by resolving the session cookie itself through the same repository function
- Every middleware is a pure ASGI class (`async def __call__(self, scope, receive, send)`), never `BaseHTTPMiddleware`, because the latter breaks streaming responses and context propagation
- Exception handlers are registered after middleware, and the health router is included before every application router

---

## Router Pattern

```python
"""HTTP routes for trips: validate, delegate to services, shape the response."""

from uuid import UUID

from fastapi import APIRouter, Depends, status

from app.dependencies.current_user import get_current_user
from app.dependencies.repositories import get_trips_repository
from app.errors import NotFoundError
from app.repositories.trips import TripsRepository
from app.schemas.trips import TripCreate, TripResponse

router = APIRouter(prefix="/v1/trips", tags=["trips"], dependencies=[Depends(get_current_user)])


@router.post("", response_model=TripResponse, status_code=status.HTTP_201_CREATED)
async def create_trip(
    body: TripCreate, trips: TripsRepository = Depends(get_trips_repository)
) -> TripResponse:
    """Create a trip owned by the signed-in user."""
    return TripResponse(data=await trips.insert_trip(body))


@router.get("/{trip_id}", response_model=TripResponse)
async def get_trip(trip_id: UUID, trips: TripsRepository = Depends(get_trips_repository)) -> TripResponse:
    """Return one trip, or TRIPS_NOT_FOUND when it is missing or not the user's."""
    trip_row = await trips.fetch_trip(trip_id)
    if trip_row is None:
        raise NotFoundError("TRIPS_NOT_FOUND", "Trip not found")
    return TripResponse(data=trip_row)
```

- One router per resource, prefixed `/v1/<resource>`, with the auth dependency on the router rather than on each route
- Route functions stay under the atomic-function ceiling (R-322): one call into a service or repository, one response
- A list route returns `{ data, meta: { total, limit, offset } }` through a `ModelListResponse`; `response_model` on every route; `status_code` declared for anything other than 200
- Domain errors raise the app's own `AppError` subclasses (Error Handling below), never `HTTPException` with a free-form `detail`

---

## Validation (Pydantic)

FastAPI validates every declared body, path, and query parameter against its Pydantic type before the route runs and answers 422 on failure; the exception handler rewrites that to the envelope with `INPUT_VALIDATION_ERROR`. There is no explicit parse step in the route.

| Schema | Purpose | Example |
|---|---|---|
| `Model` | The row shape a repository returns | `Trip` |
| `ModelCreate` | Request body for create | `TripCreate` |
| `ModelUpdate` | Request body for a partial update, every field optional | `TripUpdate` |
| `ModelResponse` | The `{ data }` envelope around one resource | `TripResponse` |
| `ModelListResponse` | The `{ data, meta }` envelope around a page | `TripListResponse` |

- All schemas for a domain live in `schemas/<domain>.py`
- Request schemas set `model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)` and bound every string and list (`Field(max_length=...)`)
- Response schemas never include secrets or hashes; a `Model` that has one is never returned directly
- One negative-input test per handler (R-406): oversized payload, injection string, malformed encoding

---

## Repository Pattern

```python
"""Data access for the trips table; every query is scoped to the owning user."""

from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncConnection

from app.db.tables import trips_table
from app.schemas.trips import Trip


class TripsRepository:
    def __init__(self, connection: AsyncConnection, user_id: UUID) -> None:
        self._connection = connection
        self._user_id = user_id

    async def fetch_trip(self, trip_id: UUID) -> Trip | None:
        """Return the trip when it exists and belongs to the user, else None."""
        statement = select(trips_table).where(
            trips_table.c.id == trip_id, trips_table.c.user_id == self._user_id
        )
        row = (await self._connection.execute(statement)).mappings().first()
        return Trip.model_validate(row) if row else None
```

- SQLAlchemy Core expressions only; raw SQL through `text()` with bound parameters when Core cannot say it; never string formatting into SQL
- Every query on a user-owned table carries `user_id` in its `WHERE` clause (access control in the app, `CLAUDE-DATABASE.md`)
- Inserts and updates use `.returning(...)` so the caller gets the stored row in one round trip
- Not found is `None` (or `False` for a delete), never an exception; the router decides the status
- Repositories never commit; the transaction belongs to the dependency that opened the connection

---

## Database Session and Engine

```python
"""Engine construction and the per-request connection dependency."""

from collections.abc import AsyncIterator

from fastapi import Request
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine, create_async_engine

from app.core.settings import Settings


def create_database_engine(settings: Settings) -> AsyncEngine:
    """Build the one engine per process with bounded pool and query time."""
    return create_async_engine(
        settings.database_url.get_secret_value(),
        pool_size=10,
        max_overflow=5,
        pool_timeout=5,
        pool_recycle=1800,
        pool_pre_ping=True,
        connect_args=build_connect_args(settings),
    )


async def get_connection(request: Request) -> AsyncIterator[AsyncConnection]:
    """Yield one connection inside one transaction per request; commit on success."""
    async with request.app.state.engine.begin() as connection:
        yield connection
```

- One engine per process, created in the lifespan and stored on `app.state`; the URL uses the `postgresql+asyncpg` scheme, built from `DATABASE_URL`
- One connection and one transaction per request through `get_connection`, always declared as `Depends(get_connection, scope="function")`: FastAPI's default request scope runs the exit code after the response is sent, so a failed commit would follow a 201 the client already received. With function scope, `engine.begin()` commits before the response and rolls back when the route raises
- A service that needs its own transaction boundary inside a request uses `async with connection.begin_nested():`
- A connection is never shared across `asyncio` tasks; `asyncio.gather` over repository calls opens one connection per task
- Workers and scripts open connections from the engine in `ctx` the same way, one transaction per job
- `build_connect_args` returns the connect `timeout` and `server_settings` (`statement_timeout` 10000 ms) always, plus the `ssl` context in staging and production. TLS with certificate verification, the `sslmode=verify-full` semantics: `ssl.create_default_context(cafile=settings.database_ca_cert)` passed as asyncpg's `ssl` connect argument checks the chain and the hostname, and the optional `DATABASE_CA_CERT` names a private CA's file (corrected 2026-09-19: `require` encrypts without verifying the server, so a man in the middle passes)

---

## Migrations (Alembic)

- Revisions live in `migrations/versions/`; `migrations/env.py` imports `metadata` from `app/db/tables.py` as `target_metadata` and runs through the async engine
- Every revision has `revision`, `down_revision`, a working `upgrade()`, and a working `downgrade()`; the chain is linear, and a branch is merged with `alembic merge` before it lands
- `alembic revision --autogenerate` is a starting draft; every generated file is read and edited before it is committed
- One logical change per revision; a comment names any cross-table dependency

```python
"""Create trips with its route-shape enum."""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "20260918_0002"
down_revision = "20260918_0001"

trip_route_shape = postgresql.ENUM("one_way", "round_trip", "multi_city", name="trip_route_shape", create_type=False)


def upgrade() -> None:
    """Create the enum explicitly, then the table that uses it."""
    trip_route_shape.create(op.get_bind(), checkfirst=False)
    op.create_table(
        "trips",
        sa.Column("id", sa.Uuid(), primary_key=True, server_default=sa.text("gen_random_uuid()")),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("route_shape", trip_route_shape, nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
    )
    op.create_index("ix_trips_user_id", "trips", ["user_id"])


def downgrade() -> None:
    """Drop the table, then the enum."""
    op.drop_table("trips")
    trip_route_shape.drop(op.get_bind(), checkfirst=False)
```

- `MetaData(naming_convention=...)` in `tables.py` names every index, unique, check, foreign key, and primary key constraint (`ix_%(table_name)s_%(column_0_name)s` and so on), so autogenerate and hand-written revisions agree
- Enums are created and dropped explicitly with `create_type=False` on the column type; autogenerate does not manage enum lifecycles
- Constant defaults are plain strings, which SQLAlchemy quotes (`server_default="draft"`); expression defaults are wrapped in `sa.text()` (`server_default=sa.text("now()")`); never nested quotes (`server_default="'draft'"`) (R-328)
- Table, column, and constraint naming, timestamps, and access-control rules come from `CLAUDE-DATABASE.md` and R-334, cited here rather than copied

---

## Risky Migrations

A revision that renames or drops a table or column, moves data between tables, renames a foreign key column, or tightens a CHECK constraint on populated data is risky. It follows the staged process in `CLAUDE-DATABASE.md`, with each stage as its own Alembic revision and its own deploy:

1. **Expand**: add the new column or table, nullable or defaulted
2. **Backfill**: a data revision (or an arq job for large tables) fills it in batches
3. **Switch**: the application reads and writes the new shape
4. **Contract**: drop the old shape in a later revision

Each stage is validated on a Neon branch before staging, and staging before production. A destructive one-shot revision against production is never written (R-101).

---

## Error Handling and Response Envelope

Every success is `{ "data": ... }` (with `"meta"` for pages). Every error is `{ "code": "...", "error": "..." }`, the envelope the Express template's code returns, so one frontend `apiFetch` handles both backends. `CLAUDE-BACKEND.md` still documents an older `{ error: { message } }` shape, and correcting it is tracked separately.

```python
"""Machine-readable error codes; clients switch on these, never on the message. Excerpt."""

from enum import StrEnum


class ErrorCode(StrEnum):
    AUTH_ADMIN_REQUIRED = "AUTH_ADMIN_REQUIRED"
    AUTH_INVALID_CREDENTIALS = "AUTH_INVALID_CREDENTIALS"
    AUTH_REQUIRED = "AUTH_REQUIRED"
    AUTH_SESSION_EXPIRED = "AUTH_SESSION_EXPIRED"
    CSRF_HEADER_MISSING = "CSRF_HEADER_MISSING"
    IDEMPOTENCY_KEY_REUSED = "IDEMPOTENCY_KEY_REUSED"
    INPUT_PAYLOAD_TOO_LARGE = "INPUT_PAYLOAD_TOO_LARGE"
    INPUT_VALIDATION_ERROR = "INPUT_VALIDATION_ERROR"
    RATE_LIMIT_EXCEEDED = "RATE_LIMIT_EXCEEDED"
    ROUTING_METHOD_NOT_ALLOWED = "ROUTING_METHOD_NOT_ALLOWED"
    ROUTING_NOT_FOUND = "ROUTING_NOT_FOUND"
    SERVER_DATABASE_UNAVAILABLE = "SERVER_DATABASE_UNAVAILABLE"
    SERVER_INTERNAL_ERROR = "SERVER_INTERNAL_ERROR"
    SERVER_REQUEST_TIMEOUT = "SERVER_REQUEST_TIMEOUT"
```

- Codes live in `constants/error_codes.py`, namespaced `DOMAIN_REASON`, each with a one-line comment saying when it fires; the excerpt above omits domain codes, and the real registry holds every code the app raises (`TRIPS_NOT_FOUND`, `AUTH_EMAIL_ALREADY_REGISTERED`, the `BILLING_WEBHOOK_*` codes), because an unregistered code is a type error
- `app/errors.py` defines `AppError(status_code, code, message)` and its subclasses (`NotFoundError`, `ConflictError`, `ForbiddenError`); routes and services raise these
- `register_exception_handlers` installs five handlers: `AppError` to its own status and code; Starlette's `HTTPException` (unknown path, wrong method) to `ROUTING_NOT_FOUND` or `ROUTING_METHOD_NOT_ALLOWED`, so no response ever uses FastAPI's default `{ detail }`; `RequestValidationError` to 400 `INPUT_VALIDATION_ERROR` with field errors; the connection-class `OperationalError` and `asyncpg` connection errors to 503 `SERVER_DATABASE_UNAVAILABLE`; and bare `Exception` to 500 `SERVER_INTERNAL_ERROR`
- The 500 handler logs with `exc_info`, reports to Sentry with the request ID, and returns `"Internal server error"` in production; outside production it returns the exception message, never a traceback
- A unique violation is caught where a useful message exists (`IntegrityError` whose `orig.sqlstate == "23505"` on register becomes 409 `AUTH_EMAIL_ALREADY_REGISTERED`), never mapped globally
- Cache and analytics failures degrade: catch the specific exception, log it, continue without the value; they never fail the request (R-344)

---

## Stripe Webhook

- `POST /v1/billing/webhook` reads `await request.body()` as raw bytes before anything parses it, and verifies with `stripe.Webhook.construct_event(raw_body, signature_header, settings.stripe_webhook_secret)`
- A missing signature or secret answers 400 `BILLING_WEBHOOK_MISCONFIGURED`; a failed verification answers 400 `BILLING_WEBHOOK_INVALID_SIGNATURE`
- Only allowlisted event types are handled; the rest are acknowledged with 200 and ignored
- The ledger table `billing_webhook_events` (R-334; `id uuid PK`, `stripe_event_id` unique, `event_type`, `status` in `claimed`, `processed`, `failed`, `attempted_at`) makes delivery idempotent: claim with `INSERT ... ON CONFLICT (stripe_event_id) DO UPDATE SET status = 'claimed', attempted_at = now() WHERE billing_webhook_events.status = 'failed' OR (billing_webhook_events.status = 'claimed' AND billing_webhook_events.attempted_at < now() - interval '10 minutes') RETURNING id`, skip when no row returns (already `processed`, or claimed within 10 minutes), and mark `processed` or `failed` in the same transaction as the side effect (corrected 2026-09-19: `ON CONFLICT DO NOTHING` never reclaimed a `failed` event or a claim left by a crash, so Stripe's redelivery was skipped and the event lost for good)
- A failed handler answers 500 with `BILLING_WEBHOOK_PROCESSING_FAILED` so Stripe retries
- The route is exempt from CSRF and rate limiting and carries no session dependency

---

## Email (Resend)

- `clients/resend.py` builds the client lazily on first send from `settings.resend_api_key`
- Without a key the client logs one `email_disabled` warning and each send becomes a logged no-op, so development and tests run without the provider
- Templates are functions in `services/email/` that return subject, HTML, and text; the client only sends
- Sends from request handlers go through an arq job, so a slow provider never holds a request open

---

## Object Storage (Cloudflare R2)

- `clients/r2.py` wraps a boto3 S3 client pointed at the account's R2 endpoint, built lazily, with `connect_timeout` and `read_timeout` set; calls run in `asyncio.to_thread`
- Object keys are generated by the server (`{user_id}/{uuid4()}.{extension}`) and validated against `^[0-9a-f-]+/[0-9a-f-]+\.[a-z0-9]{1,5}$` before any operation; a client-supplied key is never used as-is
- Uploads and downloads use presigned URLs with a 15-minute expiry; the API never proxies file bytes
- The extension and content type come from an allowlist per upload purpose

---

## Error Tracking (Sentry)

- `sentry_sdk.init(dsn=..., environment=..., traces_sample_rate=...)` runs in `create_app()` only when `settings.sentry_dsn` is set, with the FastAPI and asyncpg integrations
- The `get_current_user` dependency calls `sentry_sdk.set_user({"id": str(user.id)})`; no email, no name (R-104)
- The request-context middleware sets the `request_id` tag, so every event joins the logs for its request
- `before_send` scrubs cookies, the `Authorization` header, and any field named like a secret

---

## Circuit Breaker

- Optional, not part of the default stack (owner decision, 2026-09-19 stack audit: a breaker no provider needs is unused code, R-309); add one only when a provider's failures are shown to cascade. `services/circuit_breaker.py` opens after 5 failures inside 60 seconds for 30 seconds, failing fast with a typed `CircuitOpenError`; state lives in Redis under `circuit:{provider}` so every instance shares it, without Redis it fails open, and it wraps the client call inside `with_client_telemetry` so an open circuit still logs its outcome

---

## Logging (structlog)

This section lives in `CLAUDE-OBSERVABILITY.md`, which loads on every backend file in every stack alongside this one.

---

## Observability (R-341 to R-346)

This section lives in `CLAUDE-OBSERVABILITY.md`, which loads on every backend file in every stack alongside this one.

---

## pg_cron Cleanup Jobs

- The scheduled cleanup is one arq cron job, `cron(delete_expired_rows, minute=0)` in `WorkerSettings.cron_jobs`: hourly, it deletes expired `user_sessions`, `request_idempotency_keys` older than 24 hours, and `billing_webhook_events` older than 30 days, in batches of 1000 so a large backlog never holds a long lock. No pg_cron extension and no migration-scheduled job (owner decision, 2026-09-19 stack audit: one code path replaces the pg_cron migration and its arq fallback, and the worker exists anyway; the heading keeps its name for the invariant test). While the worker is down, rows accumulate until it returns, and nothing else is affected

---

## OpenAPI and /v1 Versioning

- Every application router is mounted under `/v1`; a breaking change adds `/v2` routes beside the old ones and retires `/v1` only after clients move
- FastAPI generates the OpenAPI document from the routes and schemas; `docs/openapi.yaml` is exported from it by `uv run python -m app.export_openapi` and committed
- CI regenerates the file and fails when it differs from the committed copy, so the document and the code cannot drift
- The frontend's generated API types come from the committed file, never from a running server

---

## Python Typing Patterns

- Pydantic `BaseModel` at every boundary: request bodies, responses, job payloads, provider responses after parsing
- `@dataclass(slots=True, frozen=True)` for internal value objects that never cross a boundary
- `get_current_user` returns a typed `CurrentUser` model; routes receive it through `Annotated[CurrentUser, Depends(get_current_user)]`, never by reading `request.state`
- `typing.Any` is banned (ruff `ANN401`); `object` plus narrowing, or a `TypedDict`, takes its place
- `mypy --strict` runs over `app/` and `tests/`; `# type: ignore` requires an error code and a reason

| Postgres | Python | SQLAlchemy column | Pydantic field |
|---|---|---|---|
| `uuid` | `UUID` | `sa.Uuid()` | `UUID` |
| `text` | `str` | `sa.Text()` | `str = Field(max_length=...)` |
| `integer` | `int` | `sa.Integer()` | `int` |
| `numeric(12,2)` | `Decimal` | `sa.Numeric(12, 2)` | `Decimal` (never `float` for money) |
| `boolean` | `bool` | `sa.Boolean()` | `bool` |
| `timestamptz` | `datetime` (aware, UTC) | `sa.DateTime(timezone=True)` | `AwareDatetime` |
| `jsonb` | `dict[str, object]` | `postgresql.JSONB()` | a nested `BaseModel` |
| enum type | `StrEnum` | `postgresql.ENUM(..., name=...)` | the same `StrEnum` |

---

## RESTful Route Naming

Resource paths follow the table in `CLAUDE-BACKEND.md` (RESTful Route Naming), with every application path under `/v1`:

```
GET    /v1/trips                    list (paginated)
POST   /v1/trips                    create
GET    /v1/trips/{trip_id}          get one
PATCH  /v1/trips/{trip_id}          partial update
DELETE /v1/trips/{trip_id}          delete
POST   /v1/trips/{trip_id}/price    action on one resource
```

Path parameters are `snake_case` and named for the resource (`trip_id`, never `id`).

---

## Testing (pytest)

- Tests fail when the implementation is wrong: assert returned values and stored rows, never mock-call counts (R-401)
- Integration tests run against a real Postgres (the compose service locally, a service container in CI), never a mocked connection; the schema is built once per session with `alembic upgrade head`, and each test runs inside a transaction that rolls back, or truncates the touched tables in a fixture when a test commits
- API tests drive the app through `httpx.AsyncClient(transport=ASGITransport(app=create_app()))`
- Each input handler has one negative-input test (R-406): an oversized body, an injection string, and malformed encoding, each asserting the envelope code
- Provider clients are replaced at the client boundary with recorded responses; an LLM consumer has one fixture test against a real captured response
- `pytest-asyncio` in `asyncio_mode = "auto"`; fixtures live in `conftest.py`; tests mirror `app/` under `tests/unit` and `tests/integration` (R-313)
- `@pytest.mark.skip` never suppresses a failing test; a test that cannot pass yet is deleted and re-added with the capability (R-401)
- Coverage floor: 60 percent on `app/`, measured with `pytest-cov`
- Test runs (R-509): run in parallel with `pytest -n auto` (`pytest-xdist`), adding `--dist loadfile` when tests in one file share an expensive fixture, and give each worker its own database named from the `worker_id` fixture so the rolled-back transactions of two workers never meet; turn ends, commits, and branch-level merges run only the affected tests (the changed test files plus the tests mirroring changed `app/` modules, or `pytest-testmon` once the project adopts it), and the full `pytest -n auto` runs as the required CI check before any merge to `main`, not at pre-push (IAN-98); either plugin is a new dependency and needs its R-331 justification

---

## Tooling

- **ruff** for lint and import sorting (`select` includes `E`, `F`, `I`, `B`, `UP`, `S`, `D`, `ANN`, `PL`), **black** for formatting at `line-length = 100` to match the portfolio-wide Prettier width, and **mypy --strict**
- Pre-commit runs ruff, black, and mypy on staged files only (R-408); the full sweep runs at pre-push and in CI (R-509)
- Trust the pre-commit hooks and do not re-run what they already ran (R-510)
- All tool configuration lives in `pyproject.toml`; no `setup.cfg`, no `.flake8`

---

## Enforcement

Mechanical enforcers cover the Python analogs of the AST-tier rules; `~/.claude/enforce/manifest.json` carries each entry.

- `hook:push-ruff-gate` runs the bundled `~/.claude/enforce/ruff-enforce.toml` over the added lines of the outgoing Python diff on `git push`: `PLR2004` (R-324 magic values), `ANN401` with `PGH003` and `PGH004` (no `typing.Any`, no blanket suppressions), `E731` (no lambda assigned to a name), `T201` (no `print`, R-342), and `E722`, `S110`, `BLE001` (R-344); repos in `enforce/exempt-repos.txt` skip it, and it fails open without ruff or uv. The same gate runs `~/.claude/enforce/data-access/python_data_access.py` (standard-library `ast`) over the changed Python files, added lines only: R-361, a repository- or `db`-imported call or an `execute`/`scalar(s)`/`stream` call inside a `for`, `async for`, or `while` body or a comprehension element; R-362, inside an explicit `begin()`/`begin_nested()` block, an `httpx`/`requests`/`aiohttp` or `clients` call, or a data-access call not given the transaction's connection. A deliberately bounded loop carries `# data-access-allow: <the bound>` on the line or the line above; the checker runs even when ruff is missing, and fails open without `python3`
- The same gate adds `D100` and `D103` (module and public-function docstrings, the R-320 analog) when the repo's `.enforce.json` sets `fileHeaders: true`, the switch that also turns on the ESLint header rule
- `ci:llm-rule-judge` (the `rule-judge` CI check) judges `*.py` in each pull request's diff against the naming and responsibility rules (R-315, R-316, R-317, R-325, R-334, the manifest's llm-judge tier)
- `hook:structure-gate` allows `snake_case` package directories plus `db/`, `core/`, `middleware/`, and `dependencies/` in Python trees; catch-all directories, kebab-case, and co-located tests are denied
- `hook:migration-defaults-guard` checks the Alembic default forms in Migrations above

---

## Build/Run Assets (R-407)

Python ships source, not a bundle. Runtime-loaded non-code assets (SQL files, prompt markdown in `prompts/`, JSON fixtures the app reads) ship as package data declared in `pyproject.toml`. A smoke test asserts that each required asset resolves at run time through `importlib.resources.files("app")`, and the image build runs that test in the builder stage, so a missing asset fails the build rather than the first request. The package contains no `.env*` file and no secret.
