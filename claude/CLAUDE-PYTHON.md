# Python Backend Conventions

The Python track. Read on demand for Python API/service work. Mirrors `CLAUDE-BACKEND.md` (the TypeScript/Node track); the universal rules in `CLAUDE.md` still apply, this file carries the Python-specific specifics and the analogs of the `[ts]`-tagged rules.

## Stack

- Framework: FastAPI (async, type-hint native, Pydantic validation)
- Server: uvicorn (ASGI)
- Data: PostgreSQL via SQLAlchemy 2.x (typed, `async` engine), raw SQL allowed in repositories
- Migrations: Alembic
- Validation: Pydantic v2 (request and response models)
- Config: pydantic-settings
- Testing: pytest (+ pytest-asyncio); integration tests hit a real database, not mocks
- Lint/format/types: ruff (lint + import sort), black (format), mypy (strict)
- Package/deps: a single `pyproject.toml` per project

## Directory Structure

```
app/
├── main.py                    # create_app() factory + uvicorn entry
├── core/                      # config, logging, security primitives
│   ├── config.py              # pydantic-settings Settings
│   └── logging.py
├── db/                        # engine + session (below repositories; neither service nor client, per R-306)
│   ├── engine.py
│   └── session.py
├── routers/                   # HTTP routers (thin; validate, delegate, respond)
│   └── jobs.py
├── services/                  # business logic operating on inputs (R-306)
│   └── jobs/
├── clients/                   # stateful wrappers around external SDKs/services (R-306)
│   └── stripe.py
├── repositories/              # data access; all SQL lives here
│   └── jobs.py
├── schemas/                   # Pydantic request/response models (the validation edge)
│   └── jobs.py
└── migrations/                # Alembic env + versions/
tests/                         # pytest, mirrors app/ layout (R-313: tests/ not co-located)
```

## Layer Responsibilities

| Layer | Does | Does NOT |
|---|---|---|
| **Routers** | Validate input (Pydantic), call services/repos, return response models | Contain business logic, run SQL |
| **Services** | Business logic on inputs; orchestrate repos and clients | Know about HTTP request/response objects |
| **Repositories** | Run parameterized SQL / SQLAlchemy queries, return typed results | Know about HTTP, validate input |
| **Clients** | Wrap one external provider's SDK or connection | Hold domain/business logic |

Dependencies flow one direction (R-303): `routers -> services -> repositories -> db`, and `services -> clients`. Lower layers never import higher. No circular imports. Never skip layers in a way that inverts the flow.

## Module and Symbol Naming

- Files and modules: `snake_case.py`, named for their single responsibility (R-315, R-318). Predict contents from the name.
- Functions: verb-noun, `snake_case`: `fetch_user`, `build_resume`, `score_match`. No single-word names.
- Booleans: `is_`/`has_`/`should_` prefix: `is_enabled`, `has_access`, `should_retry`.
- Constants: module-level `UPPER_SNAKE` (the analog of TS `ALL_CAPS`); a single-use literal stays beside its consumer (R-324).
- Classes: `PascalCase`.

## File Layout (analog of R-321 [ts])

Order top to bottom, separated by one blank line:

1. Module docstring (the what+why header).
2. `from __future__ import annotations` (when needed).
3. Imports, grouped and ordered by ruff/isort: standard library, then third-party, then local (`app...`). One import group per blank line.
4. Module-level `UPPER_SNAKE` constants and config.
5. The primary public callable or class.
6. Helper functions, ordered by call sequence (caller above callee); helpers that never call each other sorted alphabetically.

Prefer module-level functions over classes for stateless logic. Use `def`/`async def`, never lambdas assigned to names.

## Entry Point (app factory)

```python
def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(title=settings.app_name)
    register_logging(app)
    register_error_handlers(app)
    register_routers(app)
    register_health(app)  # before everything else that can 500
    return app
```

uvicorn runs `app.main:create_app` (factory mode). No top-level side effects at import time.

## Environment Validation

Use pydantic-settings; fail fast at startup if a required variable is missing.

```python
class Settings(BaseSettings):
    database_url: str
    anthropic_api_key: str
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")
```

Never read `os.environ` directly in business code; inject `Settings`. Secrets stay off-path (R-102); never log a settings value.

## Router Pattern

```python
router = APIRouter(prefix="/jobs", tags=["jobs"])

@router.get("/{job_id}", response_model=JobResponse)
async def get_job(job_id: int, repo: JobsRepo = Depends(get_jobs_repo)) -> JobResponse:
    job = await repo.get_by_id(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="job not found")
    return JobResponse.model_validate(job)
```

Routers are thin: validate via the typed signature and Pydantic, delegate to a service or repo, map to a `response_model`. Let unexpected errors propagate to the registered exception handlers.

## Validation (Pydantic) (analog of Zod-at-handler)

Validate at the router edge, never in the repository. Request bodies are Pydantic models; responses declare `response_model`. One negative-input test per input handler (R-406): oversized payload, injection attempt, malformed encoding.

## Repository Pattern

```python
async def get_by_id(self, job_id: int) -> Job | None:
    row = await self.session.execute(
        select(jobs_table).where(jobs_table.c.id == job_id, jobs_table.c.user_id == self.user_id)
    )
    return row.mappings().first()
```

All SQL/SQLAlchemy lives in repositories. Parameterized only (never f-string SQL). Every query is `user_id`-scoped where the table is user-owned (access control in the app layer, not the database).

## Database Session

One `async_sessionmaker`. Provide the session and repositories via FastAPI `Depends`. The engine/session module sits below repositories in its own `db/` tree (R-306): it is neither a service nor a client.

## Migrations (Alembic) (analog of R-328 [ts])

- Constant default: a plain string, SQLAlchemy quotes it. `Column(..., server_default="active")`.
- SQL expression default: wrap in `sa.text(...)`. `server_default=sa.text("now()")`, `server_default=sa.text("gen_random_uuid()")`.
- Never nest quotes (`server_default="'active'"` is wrong unless you genuinely need the quotes in the stored value).
- One logical change per migration; comment cross-table dependencies.
- Risky/large changes (column drops, type changes, backfills) follow the same staged approach as the TS track: additive migration, backfill, switch, cleanup; never a destructive one-shot against production (R-101).

## Error Handling

Register exception handlers on the app. Map domain errors to status codes centrally; catch specific DB integrity errors (for example a unique-violation) at the router that can give a useful message, not globally. Do not leak internals in the response body.

## Logging

Structured logging (structlog or stdlib `logging` with a JSON formatter). No secrets or PII in logs (R-102, R-104). One logger per module via `logging.getLogger(__name__)`.

## Testing (pytest) (R-401 in Python form)

- Tests must fail when the implementation is wrong. Assert behavior and returned values, not mock-call counts.
- Integration tests hit a real database (a disposable test DB), not a mocked session. Never mock the thing under test (a repository test that mocks the session is invalid, the analog of mocking the pool).
- LLM consumers include one fixture test against a real captured response.
- `pytest-asyncio` for async paths. Fixtures in `conftest.py`; test files in `tests/` mirroring `app/` (R-313), never co-located.
- No `@pytest.mark.skip` to suppress a failing test; a test that cannot pass is deleted and re-added when the capability exists (R-401 item 9).

## Tooling (analog of Prettier/ESLint)

- `ruff` for lint and import sorting, `black` for formatting, `mypy --strict` for types. Pre-commit runs these on staged files only (R-408); full sweep in pre-push/CI (R-509).
- Trust the pre-commit hooks; do not manually re-run what they already run (R-510).

## Build/Run Assets (analog of R-407 [ts])

Python ships source, not a `dist/` bundle. Runtime-loaded non-code assets (SQL, prompt markdown, JSON) ship as package data (declared in `pyproject.toml`); add a smoke test asserting each required asset resolves at runtime via `importlib.resources`. Assert the package contains no `.env*` or secret files.
