# D: stack files classification (BACKEND, DATABASE, OBSERVABILITY, PYTHON)

Baseline: /home/user/ag-main/claude/ (post-IAN-568 main), 811 / 603 / 282 / 411 lines.
Trim for comparison: /home/user/agent-governance/claude/ (streamline branch), 93 / 70 / 69 / 72 lines.
Class legend: KEEP-INVARIANT, KEEP-INCIDENT, MOVE, REMOVE-TOOLING, REMOVE-OBSOLETE, REMOVE-CEREMONY, REWRITE.
Incident naming: the stack files carry few explicit incident citations. Named ones are: the 2026-09-19 stack audit "corrected" notes (OBSERVABILITY, PYTHON), PL1/PL2/PL15/PL19 (DATABASE, from a 2026-04 debug session, moved in IAN-568), and PL16-18 (billing). Where I infer an incident from the shape of a rule (a "never X, because Y" with a specific Y), I say "inferred".

Cross-file findings that drive the proposals:
1. Broken cross-reference: PYTHON says risky migrations "follow the staged process in CLAUDE-DATABASE.md", but the Neon-branch rehearsal lives in BACKEND and the expand/backfill/contract stages only in PYTHON. DATABASE has neither. Move the staged process into DATABASE.
2. DATABASE is node-pg-migrate/pg specific, yet PYTHON defers "naming, timestamps, access control" to it. Split DATABASE into an engine-neutral PostgreSQL part (everything an agent can't infer) and a short node-pg-migrate part.
3. Python has no N+1 / bounded-read / atomic-RMW / transaction-shape text. It exists only inside the Enforcement section as hook descriptions. The owner wants these in Python. The streamline trim dropped even that, so the trim leaves Python with zero N+1 or transaction guidance. Proposed Python-shaped text is in the PYTHON section below.
4. Envelope contradiction: BACKEND returns `{ error: { message } }`; PYTHON says its `{ code, error }` is "the envelope the Express template returns". They differ. Owner decision needed; recommend `{ error: { code, message } }` in both.
5. TS request-ID sample (OBSERVABILITY) trusts any inbound `X-Request-Id`, the exact defect fixed for Python on 2026-09-19 (log/header injection). Apply the same validation pattern to the TS form.
6. Test-deletion contradiction: PYTHON "fixed or deleted, never skipped" and PROTOCOL "deleted, not deferred" vs global CLAUDE.md "Never skip or delete a failing test to get something green". Rewrite to "fixed, never skipped or deleted to get green".
7. Duplicates across files: Containers (BACKEND and PYTHON), health endpoints (BACKEND, PYTHON, OBSERVABILITY pointers), test runs R-509 (BACKEND, PYTHON), global rules restated (negative-input test, no utils/, assert-behavior-not-mocks, verb+noun names). Collapse to one home each.
8. Possible bug: PYTHON drives API tests via `ASGITransport(app=create_app())` while the engine and Redis are opened in `lifespan`. httpx's ASGITransport does not run lifespan events, so the test client needs `asgi-lifespan` (LifespanManager) or an equivalent fixture. Worth a one-line add (verify against the repo's conftest before asserting).

---

## 1. CLAUDE-BACKEND.md (Express/TypeScript, 811 lines)

| excerpt | class | reason | proposed text |
|---|---|---|---|
| Header "apply to all server/ and API packages across every app in this portfolio" | REMOVE-CEREMONY | scope boilerplate; `paths:` frontmatter already scopes | none |
| Stack list (Express 5, Railway, Neon/pg raw SQL no ORM, Zod, Pino, ioredis, Anthropic) | REWRITE | the "no ORM, raw SQL" and "one logger" choices are opinions; the rest is a package list | "Stack: Express 5 + TypeScript, PostgreSQL via `pg` (raw SQL, no ORM), Zod, Pino, ioredis, BullMQ." |
| Directory tree with `(R-306)`, `(R-309)`, `(R-311)` tags | REMOVE-CEREMONY | rule-ID annotations; tree duplicates what structure-conventions skill owns | drop tags; keep one prose line of layer folders |
| Layout rules inside the tree: clients/ = one SDK singleton per provider incl. logger; `database/` never `db/` | KEEP-INVARIANT | house layout an agent cannot infer | "`clients/` one singleton per provider; `database/` (never `db/`) holds the pool and sits below repositories." |
| Layer Responsibilities table (handlers/services/clients/repos/middleware) | KEEP-INVARIANT | durable layering; "services do not hold SDK singletons" is non-obvious | keep as 5 bullets |
| "Never skip layers; repositories never call handlers" | KEEP-INVARIANT | dependency direction (partly in global) | keep one line |
| File Naming table (kebab-case, `.service.ts`, `.tool.ts`, camelCase utils/middleware) | MOVE | to structure-conventions skill; also internally inconsistent (table says `errorHandler/errorHandler.ts` and `.service.ts`, tree shows flat `analyzer.ts`, `errorHandler.ts`) | single source in skill; pick one form |
| "Middleware and handlers are organized in folders by feature" sample | REMOVE-CEREMONY | contradicts tree (flat for single file) | none |
| Import Ordering groups, alphabetical | REMOVE-TOOLING | eslint `import/order` or prettier import-sort | none |
| `import type` for type-only | REMOVE-TOOLING | `verbatimModuleSyntax` / `@typescript-eslint/consistent-type-imports` | none |
| `.js` extension on local imports | REMOVE-TOOLING | tsc `moduleResolution: nodenext` errors without it | none |
| `app/*` alias, never relative beyond one level | REWRITE | tsconfig `paths` + `tsc-alias` is configuration, but the "no deep relative" opinion is useful | fold into Build line below |
| Entry point: `index.ts` loads secrets then `await import("app/app.js")` | KEEP-INVARIANT | non-obvious ordering; static import initializes SDK clients before secrets exist | "`index.ts` loads secrets, then dynamically imports `app.ts`, so no client initializes before `process.env` is complete." |
| `app.ts` sample (`http.createServer`, `listen`, `logger.info`) | REMOVE-CEREMONY | boilerplate | none |
| Build: `tsc && tsc-alias`, "Never use tsup", alias rewriting | KEEP-INVARIANT | explicit tool choice the agent would otherwise change | "Build with `tsc && tsc-alias`; never tsup." |
| Health: `/health` liveness (no DB), `/health/ready` (`SELECT 1`, 503), registered before routes and notFoundHandler | KEEP-INVARIANT | owner wants health conventions; canonical form is shared | MOVE canonical text to OBSERVABILITY "Health"; leave one pointer line here |
| Health: Railway healthcheck path vs smoke test after deploy | KEEP-INVARIANT | explains why two endpoints | folded into OBSERVABILITY health section |
| Worker (BullMQ) code sample | REMOVE-CEREMONY | generic BullMQ boilerplate | none |
| Worker rules inside sample: `maxRetriesPerRequest: null`; log completed/failed/error; health server on PORT; SIGTERM/SIGINT graceful close then exit 0 | KEEP-INVARIANT | each is a real BullMQ/Railway pitfall | 3 bullets (connection option, event logging with `{err}`, health server + graceful shutdown) |
| "`Dockerfile.worker` ... see CLOUD-DEPLOYMENT.md" | REMOVE-CEREMONY | cross-reference | none |
| Containers (R-351): every deployable ships Dockerfile in the commit that creates it; no Nixpacks | KEEP-INVARIANT | owner-level deployment decision | MOVE to one shared Containers block (deployment doc or CLOUD-DEPLOYMENT.md); delete the BACKEND and PYTHON copies |
| Dockerfile sample (node:22-alpine, pnpm deploy) | REMOVE-CEREMONY | generic | none |
| Multi-stage, pinned tag never `latest`, non-root `USER node`, HEALTHCHECK on /health | KEEP-INVARIANT | opinionated, cross-stack | shared Containers block |
| `.dockerignore` list; no secret in image or build arg; env at run time | KEEP-INVARIANT | security invariant; references R-102/R-103/R-104 | shared block, drop IDs |
| `docker-compose.yml` reads `.env.example`, never real `.env` | REMOVE-CEREMONY | local-dev detail, duplicates global secrets rule | none |
| CI builds every image per PR + runs HEALTHCHECK; build-smoke inside builder stage | KEEP-INVARIANT | catches missing `dist/` assets at build, not first request | shared block |
| Session Store: PG-backed, never `MemoryStore` | KEEP-INVARIANT | strong opinion | keep one line |
| Session middleware sample (`createSessionMiddleware`) | REMOVE-CEREMONY | code derivable from express-session docs | none |
| `secure: environment !== "development"`, not `isProduction()` (staging over HTTP) | KEEP-INCIDENT | 2026-09 stack audit; staging cookies sent over plain HTTP | keep as one line with the reason |
| Session test with `X-Forwarded-Proto: https` | KEEP-INCIDENT | express-session withholds Secure cookie on plain HTTP; test must fake the proxy | one line: "build via `createSessionMiddleware(env)` and test with `X-Forwarded-Proto: https`" |
| `sessions` table raw SQL migration | REMOVE-CEREMONY | copy of connect-pg-simple schema | none |
| Env validation: required vars, CORS_ORIGIN required in prod, `validateEnv()` first in app.ts | KEEP-INVARIANT | fail-fast startup | keep 2 lines |
| CORS_ORIGIN shape check in every env: reject `*`, `null` with credentials | KEEP-INCIDENT | 2026-09-19 audit; wildcard + credentials hands session cookie to any site | "Parse `CORS_ORIGIN` in every environment; reject `*`, `null`, lists, paths, userinfo. Blank means no cross-origin caller." |
| 400-char port regex in `corsConfig.ts` | REMOVE-CEREMONY | unreadable, unmaintainable; `new URL(v).origin === v` does the job | none; implementation detail |
| `parseCorsOrigin` test table | REWRITE | negative-input test of a security control is valuable; the code is not | "Test each unsafe value (`*`, `null`, list, path, userinfo) throws." |
| Express middleware order (trust proxy, helmet, CORS, logger, rateLimiter, json 10kb, cookies, CSRF, session, routes, 404, error) | KEEP-INVARIANT | order is load-bearing and non-inferable | keep as a numbered one-line list; reconcile 10kb with Python 100 KB or state both as defaults |
| Router: `import * as` handlers, named export | REMOVE-CEREMONY | style | none |
| Router: apply `requireAuth` at router level not per route | KEEP-INVARIANT | prevents forgotten auth on a new route | keep |
| Handler: return type `Promise<void>`, return early after 400 | REMOVE-CEREMONY | style | none |
| Handler: `safeParse`, never `parse`; unhandled errors propagate to global handler | KEEP-INVARIANT | explicit error behavior | keep |
| Response format `{ data }` / `{ data, meta }` / `{ error: { message } }` | REWRITE | durable but contradicts PYTHON `{ code, error }` | "Success `{ data }` (+ `meta { total, limit, offset }`); errors `{ error: { code, message } }`, same in every stack." Owner to confirm. |
| SSE `data: ${JSON.stringify(...)}\n\n` lines | REMOVE-CEREMONY | protocol boilerplate | none |
| Zod: schemas in `src/schemas/`, `Schema` suffix, PascalCase types | REMOVE-CEREMONY | naming style | none |
| Zod: input schemas separate from data-model schemas; validate at handler layer not repository | KEEP-INVARIANT | layering | keep 1 line |
| Repository: parameterized only; `user_id` scoping | MOVE | duplicate of DATABASE R-365 and Access Control | delete here; DATABASE owns |
| Repository: null for not-found, `RETURNING *`, named exports | REWRITE | null-not-found is durable; the rest is style | "Single-row not-found returns `null`; inserts and updates `RETURNING`; throw if an insert returns no row." |
| Global error handler sample; hide stack traces in production | KEEP-INVARIANT | but a second, different handler sample exists in OBSERVABILITY | keep only the OBSERVABILITY version (logs, reports, then responds) |
| `23505` caught in handlers not globally; cache failures degrade (catch, log, continue) | KEEP-INVARIANT | explicit error behavior | keep 2 bullets |
| "Logging (Pino)" and "Observability (R-341...)" stub sections | REMOVE-CEREMONY | pure pointers | none |
| DB pool sample: max 10, timeouts, `statement_timeout`, SSL `rejectUnauthorized` default true | KEEP-INVARIANT | bounded pool, TLS verify (never disable) | keep as spec: `max`, `connectionTimeoutMillis`, `statement_timeout`, TLS verify on |
| "Query wrapper logs duration in development" | REMOVE-CEREMONY | detail; superseded by query counter in DATABASE | none |
| Risky Migrations: develop locally; validate on Neon branch (row counts, FK, CHECK, test suite); staging; production after a green cycle | KEEP-INVARIANT | migration safety; PYTHON already points at DATABASE for it | MOVE to DATABASE as the shared staged process (see DATABASE proposed shape) |
| "Additive migrations are not risky" | KEEP-INVARIANT | keeps process proportional | MOVE with the above |
| Export Patterns table; "No default exports" | REMOVE-TOOLING | eslint `import/no-default-export` (or Biome `noDefaultExport`) | enable lint rule; delete |
| TS patterns: types vs interfaces; `express.d.ts` extension | REMOVE-TOOLING | `consistent-type-definitions`; declaration merging is standard TS | none |
| RESTful route naming list | REMOVE-CEREMONY | generic REST | one line: "plural nouns, nested sub-resources; PUT full, PATCH partial" or drop |
| Test Runs (R-509): parallel by default, per-worker DB via `VITEST_POOL_ID`, affected-only on commit, full suite in CI, `IAN-98` | MOVE | duplicate of PYTHON R-509; belongs once in global CLAUDE.md testing | global: "Run affected tests locally, full suite in CI; never disable parallelism to hide shared state; isolate state per worker." Drop IAN-98 and R-509 |
| Prettier JSON + table | REMOVE-TOOLING | `.prettierrc` is the source of truth | none |
| "Incident-backed rules: billing apps" header ("Moved ... IAN-568 ... defaults") | REMOVE-CEREMONY | process reference | keep section title "Billing apps" only |
| PL16 confirm dialog with cost preview before charging | KEEP-INCIDENT | billing safety; but it is a UI rule | MOVE to frontend/billing note or keep conditional; incident inferred (charge on first click) |
| PL17 `ai_jobs` table with cost and token columns, aggregated in SQL | KEEP-INVARIANT | domain-specific; only for billing-on-AI-usage apps | keep, conditional on billing |
| PL18 pricing formula carries business-intent comment | REWRITE | good intent | "Comment pricing formulas with the business rule, not just the math." |

Counts (BACKEND, 62 rows): KEEP-INVARIANT 24, KEEP-INCIDENT 4, MOVE 3, REMOVE-TOOLING 6, REMOVE-OBSOLETE 0, REMOVE-CEREMONY 19, REWRITE 6.

### Proposed shape: BACKEND
Target 70-90 lines (baseline 811; the trim reached 93 and is close). Structure: one-line stack; Layers (5 bullets + "never skip"); Startup (secrets-then-import, validateEnv, CORS parse with the incident reason, middleware order list, pointer to health); Routes and handlers (router-level auth, safeParse, envelope, catch 23505 locally, cache degrades); Sessions (pg store, `!== "development"`, testable factory); Workers (3 bullets); Billing (conditional, 3 bullets). Delete: samples, naming tables, import order, export table, Prettier, Test Runs. Move out: Containers (shared), Risky Migrations (to DATABASE), test-run policy (global), file naming (skill). What the trim dropped that was valuable: the explicit two-sentence rationale for `!== "development"` was kept; it dropped nothing important here except the session-cookie test shape (one line, restore) and the `express.json` limit contrast with Python.

---

## 2. CLAUDE-DATABASE.md (603 lines)

| excerpt | class | reason | proposed text |
|---|---|---|---|
| Intro: "follows data-access rules R-361 to R-365 (rulebook/reference.md)... checklist to run before finishing" | REMOVE-CEREMONY | rule IDs and process pointer | "Applies to all PostgreSQL schemas, migrations and query code." |
| Stack: Neon, node-pg-migrate builder, pg, no ORM | REWRITE | stack facts plus one opinion | one line; note Python uses SQLAlchemy Core + Alembic (no ORM models) |
| Migration location tree and `{TS_MS}_{kebab}.js` naming; one logical change per file | MOVE | structure-conventions skill already claims migrations layout | keep only "one logical change per migration" |
| ESM `export const up/down`, never `exports.up` ("type": "module") | KEEP-INVARIANT | silent failure otherwise; agents default to CommonJS | keep one line |
| Migration structure code sample | REMOVE-CEREMONY | node-pg-migrate docs | none |
| Always provide `up` and `down` | KEEP-INVARIANT | reversibility | keep |
| Use `pgm` builder, raw SQL only for triggers/complex DDL | REWRITE | weak as written | "Prefer the `pgm` builder; raw `pgm.sql` for triggers and DDL it cannot express." |
| JSDoc types for `pgm`; "Comment dependencies" | REMOVE-CEREMONY | editor sugar / comment ritual | none |
| Drop in reverse order; enums created before tables, dropped after | KEEP-INVARIANT | down-migration correctness | keep one line |
| Table naming plural snake_case; junction table naming | KEEP-INVARIANT | house convention | merge: "Plural snake_case tables; junction `a_b` (`link_tags`)" |
| Columns snake_case only; FK `{singular}_id`; booleans `is_`/`has_` | KEEP-INVARIANT | house convention | keep, 1 line |
| PK `uuid` default `gen_random_uuid()`, no serial/bigint | KEEP-INVARIANT | strong opinion | keep |
| `created_at`/`updated_at` timestamptz default NOW(); `set_updated_at()` trigger created once and attached per table | KEEP-INVARIANT | opinionated pattern; samples are boilerplate | keep one bullet, drop SQL sample; say "first migration" not "users table migration" |
| FK `notNull` unless optional; CASCADE for user-owned, SET NULL for loose refs | KEEP-INVARIANT | data-deletion semantics | keep |
| CHECK constraint sample; composite unique via `addConstraint` | REWRITE | closed value sets should be CHECK/enum; sample is docs | "Closed value sets use a CHECK or enum; composite uniqueness via a named constraint." |
| Arrays `text[]` default `'{}'`; JSONB not json, default `'{}'`, `_json` suffix for API payloads | KEEP-INVARIANT | house conventions; never `json` | one bullet |
| Custom ENUM sample | REMOVE-CEREMONY | duplicated by drop-order rule | none |
| Indexes: single/multi-column code | REMOVE-CEREMONY | builder docs | none |
| Auto-generated index names | KEEP-INVARIANT | conflicts with Python's `naming_convention` | state per stack, or unify on a naming_convention |
| Index every FK and every WHERE/ORDER BY/JOIN column; `= ANY($1)` filter columns indexed | KEEP-INVARIANT | N+1 prevention companion | keep |
| "Create indexes in same migration as table" (stated twice) | REMOVE-CEREMONY | duplicate statement | keep one |
| Connection: pool wrapper `query(text, values, client?)`, `withTransaction`, `countQueries` with AsyncLocalStorage | KEEP-INVARIANT | the mechanism that makes transaction and N+1 rules testable | spec in prose: wrapper takes optional client; counts per async context; `withTransaction` commits/rolls back/releases |
| `withTransaction` code sample | REWRITE | note: a throwing `ROLLBACK` masks the original error and releases a broken client | state "release with the error if ROLLBACK fails" |
| "Inside a transaction use `query(sql, values, client)`, only wrapper is counted" | KEEP-INVARIANT | keeps counter honest | keep |
| Request-ID middleware wraps request in `queryCounter.run`; completion log carries `queryCount`; warn above `QUERY_COUNT_WARN_THRESHOLD` | KEEP-INVARIANT | observability of hidden N+1 in production; trim dropped it | keep; cross-link to OBSERVABILITY request context |
| SQL formatting: UPPERCASE keywords, lowercase names, multi-line | REMOVE-CEREMONY | style; no linter enforces but low value | one phrase or drop |
| Placeholders `$n`, never interpolation | KEEP-INVARIANT | injection | keep (merged with R-365) |
| Common patterns: single row null; insert RETURNING + throw; upsert; `= ANY`; parallel list+count | REWRITE | mostly samples; `RETURNING *` conflicts with "name columns on wide tables" | "RETURNING the needed columns; list and count may run in parallel (not on one transaction client)." |
| Dynamic updates through constant allowlist; never interpolate a key | KEEP-INVARIANT | injection via identifiers; the `satisfies Record<keyof Input,string>` trick is non-obvious | keep as 2 lines + 5-line sample |
| Query Discipline checklist (6 items, "check the diff against every item") | REMOVE-CEREMONY | duplicates the R-361..365 sections below; process checklist | delete; sections carry the rules |
| R-361 no query per element: parents then children via `= ANY`, JOIN, lateral `json_agg`; plural repository function; never loop the singular | KEEP-INVARIANT | owner: N+1; strongest content | keep ~8 lines with the 3-line wrong/right |
| R-361 write sets with `unnest` (`INSERT ... SELECT FROM unnest`, `UPDATE ... FROM unnest(...)`) | KEEP-INVARIANT | non-obvious, high value | keep both patterns compactly |
| R-361 loop that repeats a query on purpose carries disable comment with its bound (`eslint-disable-next-line dataAccess/no-query-in-loop`, `# data-access-allow:`) | REWRITE | enforcer-tag mechanics are ceremony, the "state the bound" intent is good | "A deliberate loop (keyset backfill) states its bound in a comment." |
| R-362 one transaction for writes that belong together; every statement on `client` | KEEP-INVARIANT | owner: transaction boundaries | keep with the 3 wrong cases condensed |
| R-362 no network call inside a transaction (send email after commit) | KEEP-INVARIANT | locks and pool held across a round trip | keep |
| R-362 repository functions take `client?` as trailing parameter | KEEP-INVARIANT | how the above is achievable | keep |
| R-362 single statement already atomic; data-modifying CTE | KEEP-INVARIANT | avoids needless transactions | keep 1 line |
| R-362 `await` in turn, never `Promise.all` over one client | KEEP-INVARIANT | trim kept; one client is a serial channel | keep |
| R-362 outbox row for side effects tied to commit | KEEP-INVARIANT | strong opinion | keep |
| R-362 lock several rows in primary-key order | KEEP-INVARIANT | deadlock avoidance | keep |
| R-363 no unguarded read-modify-write; compute in SQL with guard, zero rows means failure | KEEP-INVARIANT | owner: atomic RMW | keep with the credits example |
| R-363 `FOR UPDATE` in tx, or `version` column; 409 on zero rows | KEEP-INVARIANT | optimistic concurrency | keep |
| R-363 select-then-insert is a race: unique constraint + `ON CONFLICT` | KEEP-INVARIANT | classic bug | keep |
| R-363 idempotency keys under a unique constraint, same transaction as effect | KEEP-INVARIANT | trim dropped this line | restore |
| R-364 every list `LIMIT` capped by `MAX_PAGE_SIZE`, clamp input | KEEP-INVARIANT | owner: bounded reads | keep |
| R-364 keyset pagination on unbounded tables, `OFFSET` on small/admin only; `ORDER BY ... id` | KEEP-INVARIANT | deterministic pages | keep with 4-line SQL |
| R-364 aggregate in SQL, `EXISTS` for existence | KEEP-INVARIANT | common agent mistake (`rows.length`) | keep |
| R-364 name columns on tables with large jsonb/text not returned | KEEP-INVARIANT | payload bound | keep |
| R-364 index every new filter/join/sort; `EXPLAIN ANALYZE` when table "can grow past a few thousand rows" | REWRITE | arbitrary threshold | "EXPLAIN a new query on a table that will grow and confirm it uses an index." |
| R-365 every value a placeholder incl. `LIMIT`/`OFFSET`/`ANY` arrays | KEEP-INVARIANT | injection | keep |
| R-365 sort column/direction from request via allowlist; unknown key is 400 | KEEP-INVARIANT | identifier injection | keep |
| Query budget tests: test every collection read compares query count at two sizes; real test DB | KEEP-INVARIANT | only thing that catches N+1 hidden behind helpers; compare sizes, not absolute number | keep rule and one 8-line sample |
| "ESLint `dataAccess/no-query-in-loop` catches loops; only this test catches hidden ones" | REWRITE | enforcer name is ceremony; the rationale is the valuable part | "A linter sees only a visible loop; the count test catches N+1 hidden behind helpers or services." |
| Type Mapping table (uuid, varchar, text, text[], integer, boolean, jsonb, timestamptz, enum) | REWRITE | mostly derivable; misses that `numeric` and `bigint`/`COUNT` return strings from `pg` | compact: keep boolean list and add "`numeric`, `bigint`, `COUNT(*)` arrive as strings; cast or parse" (the doc already uses `COUNT(*)::text`) |
| Access control: no RLS, API enforces, every repository query scoped by `user_id`, no direct DB connections, API is only client | KEEP-INVARIANT | tenant-isolation model | keep; add "cross-tenant access test" only if owner wants |
| "Incident-backed rules ... Moved from global-memory PL list 2026-10-02 (IAN-568)" header and PL ids | REMOVE-CEREMONY | process reference and rule ids | rename section "Lessons from production incidents" without IDs |
| PL1 every DB-touching handler gets a real-Postgres integration test | KEEP-INCIDENT | subscription lookup referenced a removed column; mocked unit test passed; first prod request 500 | keep with the incident as the reason |
| PL2 after a destructive migration grep the codebase for column, type, repository functions; delete dead code in the same commit | KEEP-INCIDENT | destructive-migration sweep | keep |
| PL15 after a deploy with a migration, exercise every endpoint touching changed tables by hand | KEEP-INCIDENT | post-migration verification | keep; trim kept it |
| PL19 removing a subscription/tier/plan system is a whole-codebase sweep | KEEP-INCIDENT | subscription removal incident | REWRITE generic: "Removing a feature or system deletes every column, type, handler, constant, UI string for it in the same PR." |

Counts (DATABASE, 60 rows): KEEP-INVARIANT 37, KEEP-INCIDENT 4, MOVE 1, REMOVE-TOOLING 0, REMOVE-OBSOLETE 0, REMOVE-CEREMONY 9, REWRITE 9.

### Proposed shape: DATABASE
Target 110-130 lines (trim: 70; baseline: 603). Restructure into three parts so PYTHON can honestly depend on it:
1. PostgreSQL conventions (engine-neutral): schema/naming, uuid PK, timestamptz and `set_updated_at`, FK/delete semantics, indexes, tenant scoping, type pitfalls.
2. Query discipline (engine-neutral rules, one short TS example each, SQL as the common denominator): N+1 (`= ANY`, JOIN, lateral json_agg, `unnest` writes), transaction boundaries (no network in tx, outbox, lock order, one connection serial), atomic RMW, bounded reads, parameters and identifier allowlists, query-budget tests.
3. Migration safety: staged expand/backfill/contract, Neon-branch rehearsal and what to verify (row counts, FK, CHECK, suite), "never a destructive one-shot against production", additive migrations exempt, post-deploy endpoint verification, destructive-migration code sweep (PL2, PL19 generalized), plus a three-line node-pg-migrate section (ESM exports, up/down, builder).
Optional additions not in the source, for the owner to accept or reject (all are standard Postgres migration hazards): `CREATE INDEX CONCURRENTLY` on populated tables, a `lock_timeout` for DDL, adding NOT NULL to a populated column in stages. Labelled as additions, not preserved rules.
What the trim dropped that is valuable: the idempotency-key-under-unique-constraint line; the `queryCount` request log and warn threshold; the "linter sees loops, test sees hidden N+1" rationale; the "bound the deliberate loop" requirement; the two incident narratives (PL1's specific failure); the Neon-branch staged process (it lives in BACKEND, which the trim kept only as one line); the PL2 "same commit" detail survived. The trim also lost the explicit PL15 detail "do not trust CI alone".

---

## 3. CLAUDE-OBSERVABILITY.md (282 lines)

| excerpt | class | reason | proposed text |
|---|---|---|---|
| Intro: "Logging and observability ... (IAN-381) ... live in CLAUDE.md as R-341 to R-346 ... track files keep their section headings and point here" | REMOVE-CEREMONY | ticket id, rule ids, file-wiring narrative | "Rules shared by every backend stack, then each stack's form." |
| Python: structlog config code (`SHARED_PROCESSORS`, `configure_logging`) | REWRITE | boilerplate, but carries two hard-won details (show_locals off, stdlib routing) | keep a trimmed ~15-line sample or a spec list of processors |
| `logger = structlog.get_logger()` at module level | REMOVE-CEREMONY | idiomatic structlog | fold into event-name bullet |
| Event name first as snake_case, values as keyword fields, never an f-string | KEEP-INVARIANT | structured logging convention | keep |
| Errors as `exc_info=err`, rendered via `ExceptionRenderer(ExceptionDictTransformer(show_locals=False))`; `dict_tracebacks` renders locals and wrote the DB password into a readiness log | KEEP-INCIDENT | 2026-09-19 probe: asyncpg connect-frame locals leaked the database password | keep exactly, drop "(corrected 2026-09-19 ...)" parenthetical but keep the leak as the reason |
| stdlib records (uvicorn, asgi-correlation-id, SQLAlchemy) routed via `ProcessorFormatter`; clear uvicorn handlers so every production line is JSON | KEEP-INCIDENT | 2026-09-19: those records printed as plain text; trim kept it | keep |
| No secrets, tokens, passwords, emails, PII in any field; log IDs | KEEP-INVARIANT | security; R-104 tag only | keep, drop R-104 |
| R-341 Request ID: asgi-correlation-id honors/mints/echoes; "owner decision, 2026-09-19 stack audit: replaces about 40 hand-written lines" | REWRITE | the decision is useful, the audit narrative is ceremony | "Use asgi-correlation-id; do not hand-write request-ID middleware." |
| `REQUEST_ID_PATTERN` + `is_valid_request_id` code | KEEP-INCIDENT | the hand-written middleware echoed any inbound value, enabling newline/megabyte injection into logs and headers | keep rule: inbound IDs accepted only if `^[A-Za-z0-9._-]{1,64}$`, else a fresh UUID; pass as the library's `validator`; drop the sample if the library covers it |
| `RequestContextMiddleware` binds `correlation_id.get()` via `bound_contextvars`; `clear_contextvars()` would wipe an outer binding | KEEP-INVARIANT | subtle correctness; trim kept | keep |
| Body limit covers streamed bodies: read to 100 KB, replay, send 413 as raw ASGI so app never runs | KEEP-INCIDENT | 2026-09-19: raising from `receive` becomes a 400, counting as the app reads misses routes that never read the body | keep one sentence; belongs with Python middleware rather than observability, so MOVE to PYTHON if the owner prefers topical purity |
| Services/repositories inherit `request_id` from context; workers bind `job_id` | KEEP-INVARIANT | trace correlation without parameter threading | keep |
| R-343 analytics: one client, one registry, `object_action` past tense, no literal at call site; sample with `AnalyticsEvent(StrEnum)` and `track_event` | KEEP-INVARIANT | house convention; only the client imports the SDK | keep rule once for all stacks, drop per-language samples |
| `track_event` provider failure logged, never fails the request | KEEP-INVARIANT | explicit failure behavior | keep in shared rules |
| R-344 every `except` names the class, binds and uses it; bare `except:` and `except Exception: pass` never; ruff `E722`, `S110`, `BLE001` | REMOVE-TOOLING | ruff E722/S110/BLE001 catch the syntactic cases; `F841` catches unused bound names | keep only the behavioral half below |
| R-344 the 500 handler logs and reports before it responds | KEEP-INVARIANT | explicit failure logging | keep |
| R-346 outbound wrapper `with_client_telemetry` (provider, operation, duration; warn on failure, debug on success, re-raise) | KEEP-INVARIANT | owner: useful error context | spec in two lines; code optional |
| "The one broad `except Exception` is here and it re-raises" | KEEP-INVARIANT | prevents swallowed failures | keep |
| Every client sets explicit timeout (`httpx.AsyncClient(timeout=10.0)`, `AsyncAnthropic(timeout=60.0, max_retries=2)`); a client without one is a defect | KEEP-INVARIANT | strong opinion | keep |
| Outbound HTTP forwards `X-Request-Id` via httpx event hook | KEEP-INVARIANT | trace correlation | keep |
| "Health endpoints (R-345) are the two under Health Endpoints in CLAUDE-PYTHON.md; workers on WORKER_PORT" | REWRITE | pointer, but health conventions belong here | become the canonical "Health and readiness" section (below) |
| TS Pino: context object first, message second (sample lines) | KEEP-INVARIANT | structured logging | keep one example |
| TS: pretty in development, JSON in production | REMOVE-CEREMONY | default pino-pretty setup; also stated for Python | one shared line |
| TS: errors always `{ err }` | KEEP-INVARIANT | serializer relies on key `err` | keep |
| TS: never `console.*`; values in object not message (ESLint-enforced) | REMOVE-TOOLING for `console.*` (eslint `no-console`); KEEP-INVARIANT for values-in-object | split | keep second half in shared rules |
| TS: request IDs via `pino-http` `genReqId` sample | REWRITE | sample trusts any inbound `X-Request-Id` and casts an array header to string, i.e. the defect fixed for Python | "Accept inbound `X-Request-Id` only if it matches the same pattern; otherwise `randomUUID()`; echo on response." |
| TS: `AsyncLocalStorage` `bindRequestContext`; register `requestLogger` then `bindRequestContext` before every route; `req.log` | KEEP-INVARIANT | trace correlation | keep 3 lines |
| TS: services log through `logger.child(requestContext.getStore())` or a helper; never a logger lacking the ID | KEEP-INVARIANT | correlation | keep |
| TS: workers use `{ jobId }` on every line and forward it | KEEP-INVARIANT | correlation | merged with shared worker rule |
| TS analytics registry sample (`EVENTS`, `trackEvent`) | REMOVE-CEREMONY | duplicate of the shared analytics rule | none |
| TS errorHandler sample (log, `reportError`, respond generic in production) | KEEP-INVARIANT | but differs from BACKEND's handler | single canonical handler here; BACKEND drops its copy |
| TS expected-failure `try/catch` with `logger.warn` and null fallback | KEEP-INVARIANT | degrade explicitly, never silently | keep |
| TS `withClientTelemetry` + Stripe `createCheckoutSession` sample (timeout, idempotencyKey), "(R-307)" | REWRITE | one idea (wrap every provider call once); sample is long | spec line; drop R-307 |
| TS: forward `X-Request-Id` outbound; every client call sets a timeout; health pointer | KEEP-INVARIANT | duplicates of shared rules | merge into shared |
| Go R-341 (middleware reads or mints X-Request-Id, context, `slog.With`) | KEEP-INVARIANT | stack form | keep short; drop "R-341:" prefix |
| Go R-342 slog attrs, no `fmt.Println`/`log.Printf` "manual, no golangci linter is bundled" | REWRITE | enforcer note is ceremony | "slog with structured attributes; no printf logging in service code." |
| Go R-343 analytics package and constants | KEEP-INVARIANT | stack form | keep |
| Go R-344 handle or wrap with `%w`; `errcheck`, `errorlint` | REMOVE-TOOLING for the unhandled/wrapping halves | errcheck/errorlint | keep "no `_ = err`" only if not lint-covered |
| Go R-345 health endpoints registered first | KEEP-INVARIANT | merged into shared Health | keep |
| Go R-346 `context.WithTimeout`, logs provider/op/duration/outcome, forwards request ID | KEEP-INVARIANT | stack form | keep |
| Ruby lograge JSON, request ID tags, one line per request | KEEP-INVARIANT | stack form | keep |
| Ruby R-341 `ActionDispatch::RequestId`, `config.log_tags` | KEEP-INVARIANT | stack form | keep |
| Ruby R-342 lograge custom payload, no interpolation, no `puts`; "manual, since Rails/Output needs rubocop-rails the gate does not bundle" | REWRITE | enforcer rationale is ceremony | drop the parenthetical |
| Ruby R-343 analytics client and constants | KEEP-INVARIANT | stack form | keep |
| Ruby R-344 `rescue` names exception, logs or re-raises; `Lint/SuppressedException`; bound-but-unused stays manual | REMOVE-TOOLING for empty rescue (RuboCop `Lint/SuppressedException`); rest KEEP-INVARIANT | split | keep behavioral half |
| Ruby R-345 health endpoints; R-346 client calls timeout/log/forward | KEEP-INVARIANT | stack form | keep |
| Frontmatter `paths:` includes `**/*.go`, `**/*.rb` | KEEP-INVARIANT | loads for all backend stacks | keep |

Counts (OBSERVABILITY, 49 rows): KEEP-INVARIANT 28 (+3 split rows counted as REMOVE-TOOLING for the lint-covered half), KEEP-INCIDENT 4, MOVE 0, REMOVE-TOOLING 4, REMOVE-OBSOLETE 0, REMOVE-CEREMONY 4, REWRITE 7.

### Proposed shape: OBSERVABILITY
Target 80-100 lines (trim 69; baseline 282). Structure: (1) Shared rules: request ID (pattern, mint, echo, bind), one structured logger and field conventions, no secrets/PII, error logging (name, bind, use; 500 handler logs and reports; expected failures logged at warn with a defined fallback), analytics registry, outbound wrapper with timeout and request-ID forwarding. (2) Health and readiness, the canonical home: `/health` liveness with no dependencies, `/health/ready` checks the database (and Redis for workers) with a short timeout and returns 503 with a stable body, both registered before application routes and exempt from rate-limit and CSRF, workers serve them on their own port, container HEALTHCHECK targets `/health`. (3) Stack forms: Python (processor chain, the two 2026-09-19 corrections, library choice, streamed-body limit), TypeScript (pino-http with the validated ID, ALS binding), Go and Ruby as 4-5 bullets each. Optional additions for owner approval (not in source): forward W3C `traceparent` when an OTel SDK is present; level policy (4xx at info/warn, 5xx at error); log an error once at the boundary that handles it rather than at every layer, to avoid duplicate lines. What the trim dropped: the validated-ID pattern for TS (it dropped the TS correction path, though the pattern text is kept for the shared rule); the explicit `except Exception` single-place rule survived. The trim's health collapse to one shared bullet is acceptable but loses the readiness timeout and 503 body, which live only in PYTHON.

---

## 4. CLAUDE-PYTHON.md (411 lines)

| excerpt | class | reason | proposed text |
|---|---|---|---|
| Intro: "mirrors CLAUDE-BACKEND.md and restates parts of CLAUDE-DATABASE.md ... only supported choice" | REWRITE | the "one choice per concern" stance is a strong opinion; the mirroring narrative is not | "Python backend conventions. One choice per concern. Covers what ruff, the formatter and mypy cannot check." |
| Stack list (3.13, uv, FastAPI/uvicorn factory, Pydantic v2, pydantic-settings, SQLAlchemy 2 Core asyncpg no ORM, Alembic, redis.asyncio, arq, structlog, asgi-correlation-id, AsyncAnthropic, httpx, pytest-asyncio, ruff, mypy --strict, Railway/Docker) | KEEP-INVARIANT | opinionated stack decisions an agent would otherwise vary | keep as one dense paragraph |
| Directory tree with `(R-306)`, `(R-307)`, `(R-313)`, `(R-343)` tags | REWRITE | layout is durable, tags are ceremony | one prose line of folders; drop IDs |
| "Directories appear only when occupied (R-309)"; "utils/, helpers/, common/, lib/, shared/ never exist (R-306)"; core/ the one exception | REMOVE-CEREMONY | global CLAUDE.md already bans catch-all dirs | keep only "`core/` holds only settings, logging, security" |
| Layer table (middleware, dependencies, routers, services, repositories, clients, workers) | KEEP-INVARIANT | durable layering | 5 bullets |
| Dependency direction `routers -> services -> repositories -> db`, `services -> clients`; middleware may call repositories only for session/idempotency | KEEP-INVARIANT | dependency flow | keep, drop R-303 |
| Naming: `snake_case.py`, no layer suffix, plural resource nouns, repository = table name, service verb+noun in domain folder | KEEP-INVARIANT | house convention | keep 2 lines, drop R-315/318/334 |
| Functions verb+noun; booleans `is_`/`has_`/`can_`/`should_`; no bare adjectives; single-use literal beside consumer | REMOVE-CEREMONY | R-316/317/324; verb+noun is already global | none |
| Absolute `from app...` imports only | REMOVE-TOOLING | ruff `TID252` (ban relative imports) | enable in ruff config |
| Call through the imported module so each call site shows its layer | REWRITE | stylistic but a real house choice | keep as 1 line or drop |
| Module order: docstring, imports, constants, public function, private helpers caller above callee (R-320, R-321) | REMOVE-CEREMONY | arbitrary heuristic; docstring half is ruff `D100` | none |
| Functions for logic, Pydantic at boundaries, frozen slots dataclasses internally; no `FooService` classes; class only for state, lifecycle, or interchangeable impls | KEEP-INVARIANT | strong opinion | keep 1-2 lines |
| App factory: `create_app()` assembles settings, logging, middleware, handlers, routers; `uvicorn app.main:create_app --factory` | KEEP-INVARIANT | structure | keep |
| Nothing at import time: settings, engine, Redis, SDK clients built in factory/lifespan/cached dependency | KEEP-INVARIANT | testability | keep |
| `lifespan` opens and disposes engine and Redis; no `@app.on_event` | KEEP-INVARIANT | deprecated API opinion | keep one line |
| Health: `/health` no dependencies; `/health/ready` `SELECT 1` in `asyncio.timeout(2)`, 503 `{"status":"degraded","db":"disconnected"}` on `OSError`/`SQLAlchemyError`/`TimeoutError` | KEEP-INVARIANT | owner: health conventions; the timeout so a hanging connect cannot stall the probe is non-obvious | MOVE to OBSERVABILITY canonical Health section |
| Worker: `WorkerSettings` in `workers/settings.py`, one job per function | KEEP-INVARIANT | arq structure | keep |
| `WorkerSettings` the one allowed module-level settings read; `on_startup` opens one engine into `ctx` | KEEP-INVARIANT | exception to "nothing at import time" | keep |
| `WorkerContext` TypedDict; job takes `ctx` first; IDs and small values only, load from DB; bind `job_id` | KEEP-INVARIANT | queue payload hygiene, correlation | keep |
| Jobs idempotent via completion marker | KEEP-INVARIANT | retry safety | keep |
| One `clients/queue.py` holds the job name string derived from `__name__` | KEEP-INVARIANT | prevents name drift | keep |
| Worker health server on `WORKER_PORT` as background `uvicorn.Server`; `arq --check` only CI smoke | REWRITE | health is shared; `arq --check` note is detail | pointer to shared Health; drop `--check` sentence |
| `Dockerfile.worker` = API image with different CMD; Railway drain >= `job_timeout` | KEEP-INVARIANT | graceful shutdown | shared Containers block |
| Containers R-351 first bullet: multi-stage, pinned `python:3.13-slim`, `uv sync --frozen --no-dev`, non-root, HEALTHCHECK, uvicorn CMD | MOVE | duplicate of BACKEND Containers | shared Containers block with a 2-line Python variant |
| `--proxy-headers` trusts XFF only from `FORWARDED_ALLOW_IPS` (CIDR); never `*`; settings refuse production start without it | KEEP-INVARIANT | rate limiter depends on it; `*` takes the first, client-forgeable entry | keep as Python-specific security bullet |
| `.dockerignore`; config via runtime env, never build arg (R-102/R-104) | MOVE | duplicates BACKEND and global secrets rule | shared block |
| compose runs API, worker, Postgres 17, Redis 7 from `.env.example` (R-103) | REMOVE-CEREMONY | local dev setup | none |
| Migrations run as a release step (`alembic upgrade head`) before new image takes traffic, never at app startup | KEEP-INVARIANT | migration safety | keep (trim kept) |
| CI builds both images per PR and runs each HEALTHCHECK | MOVE | shared with BACKEND | shared block |
| Session store: cookie token `secrets.token_urlsafe(32)`, 7-day TTL; DB stores only SHA-256 hash | KEEP-INVARIANT | auth design, an agent would otherwise store the raw token | keep |
| bcrypt 12 rounds inside `asyncio.to_thread`; dummy-hash verify for unknown user | KEEP-INVARIANT | async correctness (blocking hash off the loop), timing equalization | keep |
| `user_sessions` column listing | REMOVE-CEREMONY | schema is derivable; R-334 | none |
| Cookie flags: httponly, `secure` on every non-development env, samesite lax, path "/" | KEEP-INCIDENT | staging cookie travelled over plain HTTP (2026-09 audit, same as BACKEND) | keep one line |
| `set_session_cookie` and staging-Secure test code | REWRITE | the test idea (feed the insecure value) is valuable, the code is not | "Test that a staging login sets `Secure` and `HttpOnly`." |
| Email trimmed and lowercased, unique index on `lower(email)` | KEEP-INVARIANT | duplicate-account bug | keep |
| Login: verify password even when user missing; same code either way | KEEP-INVARIANT | duplicate of the bullet above | merge |
| Password reset: hashed token, 1-hour expiry, delete earlier unused, single atomic `UPDATE ... WHERE used_at IS NULL AND expires_at > now() RETURNING user_id` | KEEP-INVARIANT | atomic read-modify-write; select-then-update lets two submissions succeed | keep with the reason |
| Resolution: `get_current_user` hashes cookie, joins session and user, raises AUTH_REQUIRED/AUTH_SESSION_EXPIRED, binds `user_id`; `require_admin` | REMOVE-CEREMONY | derivable once the design is stated | keep "binds `user_id` into log context" only |
| Logout deletes row and clears cookie; password change deletes other sessions; hourly cleanup | KEEP-INVARIANT | session hygiene; cleanup listed again in Provider section | keep, dedupe |
| CSRF: reject POST/PUT/PATCH/DELETE without `X-Requested-With: XMLHttpRequest` (403 `CSRF_HEADER_MISSING`); Stripe webhook and health exempt; CORS only `settings.cors_origin`; no token endpoint | KEEP-INVARIANT | strong, non-default design | keep |
| Rate limit: Redis fixed window keyed on `request.client.host`, never parse `X-Forwarded-For` | KEEP-INCIDENT | inferred: every entry but the last is client-supplied, so keying the first hop lets one client rotate buckets | keep with the reason |
| Rate limit numbers (100/15 min global, 10/15 min auth) | REWRITE | defaults, not rules | "Global and stricter auth limits live in settings." |
| Auth routes listed by full `/v1` path; pattern without mount prefix never matches | KEEP-INCIDENT | inferred: a limiter that silently never applied | keep one line |
| 429 `RATE_LIMIT_EXCEEDED` with `Retry-After` | KEEP-INVARIANT | contract | keep |
| No `REDIS_URL`: in-process counter with one warning in dev/test only; production refuses to start | KEEP-INVARIANT | per-process counters let an attacker rotate instances | keep |
| Rate limit skipped when `environment == "test"`; tests turn it back on | REMOVE-CEREMONY | detail | none |
| Idempotency keys: row layout, claim token, 24h replay only on matching method/path/body hash, 422 mismatch, 60s lease, single guarded `UPDATE` takeover, `finally` release guarded by claim token, hourly cleanup | MOVE | a feature spec of ~12 clauses auto-loaded on every `*.py` | move to a reference doc or skill; keep a 3-line invariant here: "claim atomically, replay only on identical request, lease takeover is a single guarded UPDATE" |
| Request timeout `asyncio.timeout(30)` -> 408; SSE exempt | REWRITE | numbers are defaults | "Request timeout middleware (default 30s) answers 408 `SERVER_REQUEST_TIMEOUT`; SSE routes enforce idle timeout themselves." |
| Env validation `Settings` code (SecretStr, `Literal` env, validators) | REWRITE | code is derivable; the rules are not | spec bullets (below) |
| CORS_ORIGIN regex in Python (copy of the TS regex) and validator | REMOVE-CEREMONY | unmaintainable regex; `urllib.parse` check suffices | keep rule: reject `*`, `null`, lists, paths, userinfo in every env |
| `CORS_ORIGIN` validated in every environment (credentials + `*`/`null`) | KEEP-INCIDENT | 2026-09-19 audit | keep (merge with TS) |
| Negative tests for unsafe CORS origins | REWRITE | the idea is the valuable part | one line |
| `require_production_values`: refuse production start without CORS_ORIGIN, REDIS_URL, FORWARDED_ALLOW_IPS | KEEP-INVARIANT | fail-fast | keep |
| Business code gets `Settings` through `Depends(get_settings)`; nothing reads `os.environ` | KEEP-INVARIANT | testability | keep |
| Secrets are `SecretStr`, never logged or echoed (R-102); `.env.example` placeholders such as `changeme` (R-108) | REWRITE | SecretStr and `hide_input_in_errors` are non-default; `.env.example` is global | keep "SecretStr and `hide_input_in_errors=True`"; drop IDs |
| App structure: `add_middleware` registers outside-in, last-added runs first; register in reverse | KEEP-INVARIANT | classic Starlette trap | keep |
| CORS `add_middleware` code sample | REMOVE-CEREMONY | boilerplate | none |
| Request order: correlation id outermost, request context (100 KB body limit, 413 unless upload allowlist), then the remaining middleware | KEEP-INVARIANT | order is load-bearing | one numbered line (trim has it) |
| Session resolution is a dependency, not middleware | KEEP-INVARIANT | per-route declaration | keep |
| Middleware are pure ASGI, never `BaseHTTPMiddleware` | KEEP-INVARIANT | streaming and contextvar propagation | keep |
| Exception handlers after middleware; health router included before every application router | KEEP-INVARIANT | ordering | keep |
| Router: one per resource under `/v1/<resource>`, auth dependency on the router | KEEP-INVARIANT | prevents forgotten auth | keep |
| Route is one service/repository call + one response; `response_model` on every route; list envelope | KEEP-INVARIANT | thin routers | keep |
| Domain errors raise `AppError` subclasses, never `HTTPException` free-form `detail` | KEEP-INVARIANT | explicit error behavior | keep |
| `get_current_user` returns typed `CurrentUser` via `Annotated[..., Depends]`, never from `request.state` | KEEP-INVARIANT | typing at boundaries | keep |
| Pydantic validation rewritten into 400 `INPUT_VALIDATION_ERROR` envelope | KEEP-INVARIANT | contract | keep |
| Schemas `Model`/`ModelCreate`/`ModelUpdate`/`ModelResponse`/`ModelListResponse` | REMOVE-CEREMONY | naming convention | optional one line |
| Request schemas `extra="forbid"`, `str_strip_whitespace`, bounded strings and lists | KEEP-INVARIANT | input hardening | keep |
| Response schemas never include secrets/hashes | KEEP-INVARIANT | security | keep |
| "One negative-input test per handler (R-406)" | REMOVE-CEREMONY | duplicate of global rule | none (global has it) |
| Repository: SQLAlchemy Core only; `text()` with bound params; never format into SQL | KEEP-INVARIANT | injection | keep |
| Every user-owned query carries `user_id` | KEEP-INVARIANT | tenant isolation | keep |
| `.returning(...)`; not found is `None`/`False`; repositories never commit | KEEP-INVARIANT | explicit error behavior, transaction ownership | keep |
| DB session: one engine per process in lifespan on `app.state`, `postgresql+asyncpg`, bounded pool (size 10, overflow 5, timeout 5, recycle 1800, pre_ping) | KEEP-INVARIANT | bounded resources | keep as spec |
| One connection and transaction per request via `Depends(get_connection, scope="function")` so a failed commit happens before the 201 is sent; nested boundary uses `begin_nested()` | KEEP-INVARIANT | non-obvious FastAPI dependency-scope behavior; owner: DB transactions | keep with reason |
| A connection never shared across `asyncio` tasks (`asyncio.gather` over repository calls opens one per task) | KEEP-INVARIANT | async correctness; trim dropped it | restore |
| `build_connect_args`: timeout, `statement_timeout` 10000, `ssl.create_default_context(cafile=...)` in staging/production (verify-full semantics; `require` does not verify) | KEEP-INVARIANT | TLS verification stays on (global never-rule) | keep |
| Alembic: `migrations/versions`, async `env.py` importing `metadata` | REMOVE-CEREMONY | setup detail | none |
| Alembic: `upgrade()` and `downgrade()`, linear chain, one change per revision, autogenerate output is a draft | KEEP-INVARIANT | migration safety | keep |
| `MetaData(naming_convention=...)` | KEEP-INVARIANT | stable constraint names | keep |
| Enums created and dropped explicitly (`ENUM(create_type=False)`, create in upgrade, drop after table in downgrade) | KEEP-INVARIANT | Alembic enum gotcha | keep |
| Defaults: constant `server_default="draft"`, expression `sa.text("now()")`, never nested quotes (R-328; `hook:migration-defaults-guard`) | REWRITE | durable rule, enforcer tag is ceremony | keep rule, drop R-328 and hook name |
| "Naming, timestamps, access control come from CLAUDE-DATABASE.md and R-334" | REWRITE | DATABASE is node-pg-migrate specific; reference is broken | point to the engine-neutral DATABASE part |
| Risky migrations: staged expand/backfill/switch/contract, each its own revision and deploy; validated on Neon branch, staging, production; no destructive one-shot against production (R-101) | KEEP-INVARIANT | owner: migration safety | MOVE to DATABASE (single copy) |
| Error envelope `{ code, error }` "the envelope the Express template returns" | REWRITE | contradicts BACKEND `{ error: { message } }` | unify, see cross-file finding 4 |
| Codes in `constants/error_codes.py` `StrEnum` `DOMAIN_REASON`, each commented with when it fires; clients switch on code | KEEP-INVARIANT | typed error codes; the per-entry comment is ceremony | keep, drop "one-line comment" requirement |
| `AppError(status_code, code, message)` and subclasses; five registered handlers (AppError, HTTPException->ROUTING_*, RequestValidationError->400, ... ) | KEEP-INVARIANT | no FastAPI default `{ detail }` leaks | keep |
| 500 handler logs with `exc_info`, reports to Sentry with request ID, generic message in production, never a traceback | KEEP-INVARIANT | explicit failure logging | keep |
| Unique violation caught where a useful message exists (`IntegrityError`, sqlstate 23505, register -> 409); never globally; cache/analytics failures degrade (R-344) | KEEP-INVARIANT | explicit error behavior | keep, drop R-344 |
| Stripe webhook: raw bytes before parsing, `construct_event`, 400 codes for misconfigured/invalid signature | KEEP-INVARIANT | money; signature verification | keep |
| Webhook ledger `billing_webhook_events` with claim/processed/failed, guarded `INSERT ... ON CONFLICT DO UPDATE ... WHERE status='failed' OR stale`; failed handler answers 500 so Stripe retries | KEEP-INVARIANT | idempotent delivery; atomic claim | keep as 3 lines |
| Email (Resend): lazy client; without API key each send is a logged no-op | REWRITE | silent no-op in production hides lost mail | "No-op only in development/test; in production a missing key fails startup." (owner to confirm) |
| Email sends from request handlers go through an arq job | KEEP-INVARIANT | no network in request path / retries | keep |
| Object storage (R2): `asyncio.to_thread` boto3, server-generated keys validated by regex, 15-minute presigned URLs, API never proxies bytes | KEEP-INVARIANT | security | keep |
| Sentry: init only when DSN set; `set_user` ID only; `request_id` tag; `before_send` scrubs cookies, Authorization, secret-named fields | KEEP-INVARIANT | PII control | keep |
| Circuit breaker not in default stack (owner decision 2026-09-19); add only when failures shown to cascade; state in Redis, fail open | REWRITE | decision log, but a useful anti-gold-plating line | "No circuit breaker by default; add one only when provider failures are shown to cascade." |
| Cleanup: one hourly arq cron deletes expired sessions, idempotency keys > 24h, webhook events > 30d, batches of 1000; no pg_cron | KEEP-INVARIANT | operational pattern | keep once |
| OpenAPI: routers under `/v1`; `docs/openapi.yaml` exported via `app.export_openapi`, committed, CI diffs; frontend types generated from it | KEEP-INVARIANT | contract drift guard | keep |
| Path params named for the resource (`trip_id`) | REMOVE-CEREMONY | naming | none |
| "Logging, observability, route naming: see ..." pointer | REMOVE-CEREMONY | cross-reference | none |
| Typing: Pydantic `BaseModel` at every boundary (bodies, responses, job payloads, parsed provider responses) | KEEP-INVARIANT | owner: typing at boundaries | keep |
| Typing map: `Decimal` for money never `float`; aware UTC `datetime`/`AwareDatetime`; `StrEnum`; `UUID` | KEEP-INVARIANT | correctness; the rest of the mapping is derivable | keep Decimal-for-money and aware-datetime only; drop `uuid`/`text`/`jsonb` mappings (mypy and the column types state them) |
| Testing: assert returned values and stored rows, never mock-call counts (R-401) | REMOVE-CEREMONY | global CLAUDE.md already says it | none |
| "A failing test is fixed or deleted, never skipped" | REWRITE | contradicts global "never skip or delete a failing test to get green" | "A failing test is fixed; never skipped, and not deleted to get green." |
| Integration tests on real Postgres (compose/service container), schema once per session via `alembic upgrade head`, per-test rollback or truncation | KEEP-INVARIANT | owner: real PostgreSQL | keep |
| API tests via `httpx.AsyncClient(ASGITransport(app=create_app()))`, `asyncio_mode="auto"`; tests mirror `app/` (R-313) | KEEP-INVARIANT | owner: async correctness; add lifespan handling (finding 8) | keep; add "ASGITransport does not run lifespan; wrap with asgi-lifespan or a fixture" after verifying |
| Negative-input test per handler asserting the envelope code (R-406) | REMOVE-CEREMONY | global duplicate | keep only "assert the envelope code" |
| Provider clients replaced at the client boundary with recorded responses; LLM consumer has one fixture test against a real captured response | KEEP-INVARIANT | third-party interface mocking, cheap LLM test | keep |
| Coverage floor 60 percent on `app/` | REMOVE-CEREMONY | arbitrary heuristic; config in `pyproject.toml` (`--cov-fail-under`) if wanted | none |
| Runs (R-509): `pytest -n auto`, `--dist loadfile`, one DB per worker via `worker_id`, affected-only, "R-331 justification" | MOVE | duplicate of BACKEND test runs | global testing rule; keep only "one database per xdist worker" here |
| Tooling: ruff one linter/formatter, `line-length = 100`, one formatter per repo, mypy --strict on `app/` and `tests/` | REMOVE-TOOLING | `pyproject.toml` is the source of truth | none |
| Ruff `select` includes E,F,I,B,UP,S,D,ANN,PL | REMOVE-TOOLING | config belongs in `pyproject.toml` | none |
| Pre-commit on staged files; full sweep at pre-push and CI (R-509); do not re-run what hooks ran | REMOVE-CEREMONY | process; duplicates global lesson L4 | none |
| Enforcement: `hook:push-ruff-gate`, `~/.claude/enforce/...`, `ci:llm-rule-judge`, `hook:structure-gate`, `hook:migration-defaults-guard`, `.enforce.json` | REMOVE-CEREMONY | enforcer tags and harness wiring; belongs in PROTOCOL/enforce docs | none |
| Enforcement content: R-361 no repository/`execute`/`scalar`/`stream` call inside a loop or comprehension | REWRITE | the only Python statement of N+1 | restore as a real rule (below); drop the hook description |
| Enforcement content: R-362 inside `begin()`/`begin_nested()` no `httpx`/`requests`/`aiohttp`/client call, every data-access call given the transaction's connection | REWRITE | the only Python statement of the transaction rules | restore as real rule (below) |
| "A deliberately bounded loop carries `# data-access-allow: <the bound>`" | REWRITE | enforcer tag; keep the "state the bound" idea | "A deliberate loop states its bound." |
| Build/Run Assets (R-407): runtime-loaded assets as package data, smoke test via `importlib.resources.files("app")`, run in builder stage, no `.env*` in package | KEEP-INVARIANT | missing asset fails the build not the first request | keep 2 lines, drop R-407 |

Counts (PYTHON, 118 rows): KEEP-INVARIANT 68, KEEP-INCIDENT 4, MOVE 5, REMOVE-TOOLING 3, REMOVE-OBSOLETE 0, REMOVE-CEREMONY 19, REWRITE 19.

### Proposed shape: PYTHON
Target 130-160 lines (trim: 72; baseline 411). Larger than the trim because the owner wants Python's database discipline preserved and the trim left Python without it. Structure: Stack (1 paragraph); Layout and layers (tree as one line, 7 layer bullets, dependency direction, naming); App factory and middleware (nothing at import time, lifespan, reverse registration order, pure ASGI, ordered list); Routers, validation, errors (envelope, AppError, handlers, typed CurrentUser, `extra="forbid"`); Settings (SecretStr, CORS parse, production-required values, nothing reads `os.environ`); Database (engine, request-scoped transaction with `scope="function"`, never share a connection across tasks, repositories never commit, `user_id` scoping, TLS verify and timeouts, Alembic pitfalls, pointer to DATABASE for the staged process); **Python data-access discipline** (new, restoring the dropped guidance in SQLAlchemy Core form, below); Auth and security (session hash, bcrypt in a thread, atomic reset, CSRF header, rate limit keyed on `client.host`, proxy headers, idempotency invariant); Workers (arq); Provider clients, Stripe webhook ledger, Sentry; Testing (real Postgres, ASGITransport plus lifespan note, recorded provider responses, one DB per worker); Typing (Pydantic at boundaries, Decimal money, aware datetimes). Remove: tooling section, enforcement section, R-IDs, session code samples, Containers (shared), idempotency full spec (to reference).

Proposed new Python data-access text (the largest gap):
- No query per element. No repository call, `execute`, `scalar(s)`, or `stream` inside a loop, comprehension, or `asyncio.gather(*[... for x in xs])`. Load sets with `column.in_(ids)` or `= ANY(:ids)`, a JOIN, or a lateral `json_agg`; write sets with a multi-row `insert().values([...])` or `unnest`. Add a plural repository function the first time a caller needs more than one row.
- One transaction for writes that belong together: inside `engine.begin()` or the request's `get_connection`, every statement uses the same connection, awaited in sequence; no `httpx`/client call inside the block (send after commit; use an outbox row for effects tied to commit).
- No unguarded read-modify-write. Compute in SQL with a guard (`update(...).where(credits >= 1).returning(...)`, zero rows means failure), or `select(...).with_for_update()`, or a version column; "select then insert" becomes a unique constraint plus `on_conflict_do_nothing/update`.
- Every read bounded: capped `limit`, `order_by` ending in `id`, keyset on unbounded tables, aggregate in SQL.
- A query-count test per collection read: count statements with a SQLAlchemy `before_cursor_execute` listener at two data sizes and assert equality, against real Postgres.
What the trim dropped that is valuable: all of the above Python data-access content (it existed only in the Enforcement section); "never share a connection across asyncio tasks"; the `begin_nested()` note; the `scope="function"` reason (kept the phrase, lost "failed commit after a 201"); the streamed-body 413 detail (kept in OBSERVABILITY); the circuit-breaker anti-gold-plating line; the rate-limit full-`/v1`-path pitfall is kept; the Resend no-op risk is not addressed in either version; the xdist per-worker DB sentence survived.
