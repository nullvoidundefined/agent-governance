# Python and Vue Convention Tracks: Design

Date: 2026-09-17
Status: draft, awaiting owner review
Workstream: 1 of 3 (conventions, then the FastAPI + Nuxt template, then Voyager 2.0)

## Summary

The Claude Code convention stack today has a deep TypeScript track (`CLAUDE-BACKEND.md` at 810 lines, `CLAUDE-FRONTEND.md` plus `CLAUDE-FRONTEND-NEXT.md` at 417 lines, `CLAUDE-DATABASE.md` at 336 lines) and a shallow Python track (`CLAUDE-PYTHON.md` at 199 lines) with no Vue track at all. The next two workstreams build a FastAPI + Nuxt 4 template and then rebuild Voyager on it, so both tracks must reach the depth of the TypeScript track first, and the mechanical enforcers that back the TypeScript rules must gain Python and Vue analogs where one exists.

This spec covers four deliverables in the agent-governance repo: a four-file split of the frontend conventions so a Vue project never loads React rules, a rewrite of the Python file to Express-track depth, the enforcement additions that make the new tracks mechanical rather than recall-based, and an `add-stack-track` skill plus an invariant test so the fifth stack track is added by procedure rather than from memory.

## Domain vocabulary

| Term | Meaning in this spec |
|---|---|
| Convention file | A `claude/CLAUDE-<TRACK>.md` file with a `paths:` frontmatter block that Claude Code auto-loads when work touches a matching path. |
| Track | One stack's set of convention files. The TypeScript track is `CLAUDE-BACKEND.md`, `CLAUDE-FRONTEND*.md`, `CLAUDE-DATABASE.md`, `CLAUDE-STYLING.md`. The Python track is `CLAUDE-PYTHON.md`. The Vue track is the new `CLAUDE-FRONTEND-VUE.md` and `CLAUDE-FRONTEND-NUXT.md`. |
| Core file | `CLAUDE-FRONTEND.md`, the framework-agnostic frontend file every framework file is read together with. |
| Framework file | A file scoped to one framework (`-NEXT`, `-VITE`, `-REACT`, `-VUE`, `-NUXT`) that is read alongside the core file. |
| Rules symlink | A git-tracked symlink `claude/rules/<name>.md -> ../CLAUDE-<TRACK>.md`. Claude Code reads the `paths:` frontmatter through the symlink to decide when to auto-load the file. |
| Parity target | The TypeScript-track section a Python or Vue section must match in depth and specificity. |
| Enforcer | The hook, ESLint rule, or ruff rule registered in `enforce/manifest.json` that fires mechanically on a rule (R-516). |
| Fixture test | The shell test under `enforce/tests/` or `hooks/tests/` that proves an enforcer fires on a violating input and stays silent on a compliant one. |
| Stack track procedure | The ordered steps that add a new track: convention file, rules symlink, session-types row, `CLAUDE.md` read-on-demand row, enforcer analogs, manifest entries, fixture tests, sync. |
| SFC | A Vue single-file component, a `.vue` file with `<template>`, `<script setup lang="ts">`, and optional `<style>` blocks. |
| Composable | A Vue function named `useX` that encapsulates reactive state or behavior. The Vue analog of a React hook. |
| Nitro | Nuxt's server engine. `server/api/` and `server/middleware/` files run in Nitro, not in the browser. |

## Goals

1. A Vue or Nuxt session auto-loads only Vue and Nuxt conventions, never React ones.
2. `CLAUDE-PYTHON.md` specifies every pattern the FastAPI template needs at the depth `CLAUDE-BACKEND.md` specifies the Express equivalent, and contradicts nothing decided for the template.
3. Every TypeScript-track enforcer that has a feasible Python or Vue analog gains it in this slice, each with a manifest entry and a fixture test.
4. Adding a sixth stack track is a checklist run, not a recall exercise.

## Non-goals

- Writing any template code. The template is workstream 2 and has its own spec.
- Changing `CLAUDE-DATABASE.md`. Its stack-agnostic rules stay where they are; the Python file carries the Alembic and SQLAlchemy restatements.
- A Python naming-lexicon AST enforcer (R-316, R-317). The LLM judge covers Python naming today; an AST script is a later slice.
- SFC-aware brace counting in `clean-code-scan.mjs` (R-322). Deferred to the Later list.
- Touching the Go or Ruby tracks.

## Decisions already made

These were settled with the owner before this spec and are inputs, not open questions.

| Decision | Choice |
|---|---|
| Vue SSR framework | Nuxt 4 (`app/` directory root, Nitro server, SSR on by default) |
| Python data layer | SQLAlchemy 2 Core, async engine, asyncpg driver, Alembic migrations |
| Python worker | arq (asyncio, Redis-backed) |
| Python packaging | uv, committed `uv.lock` |
| Python logging | structlog, no stdlib alternative |
| Frontend file plan | Four-file split: agnostic core, `-REACT`, `-VUE`, `-NUXT` |
| Enforcement scope | Parser wiring, glob and hook extensions, structure-gate Nuxt trigger; Python naming AST and SFC brace counting deferred |
| Spec and PR home | This repo, `docs/superpowers/specs/` and `docs/slices/` |

## Current state (findings)

### Frontend

`CLAUDE-FRONTEND.md` declares `paths:` globs that include `**/src/components/**` and `**/src/state/**`, not only `**/*.tsx`. A Vue project with a `components/` directory matches those globs and auto-loads React 19 rules, `useCallback` guidance, and the State Management section's explicit ban on Zustand and other state libraries. Pinia, which the Vue track requires, contradicts that ban directly. Roughly 40 percent of the core file is truly framework-agnostic (directory shape, the API wrapper pattern, error handling, most of the Prettier config, and the entire Playwright E2E layout section); the rest is React-coupled.

### Python

`CLAUDE-PYTHON.md` is missing, relative to `CLAUDE-BACKEND.md`: a worker pattern, a session store, a middleware-order section, a response-envelope section, a build-tool section, typing patterns, and RESTful route naming. It also lacks everything `CLAUDE-BACKEND.md` itself never wrote down but the Express template implements: bcrypt and SHA-256 hashed session tokens, the `X-Requested-With` CSRF check, Redis-backed rate limiting with a memory fallback, idempotency keys, the 30 second request timeout, the `{ code, error }` envelope with namespaced codes, the Stripe webhook with a raw body and an event-idempotency ledger, Resend, PostHog server events, Cloudflare R2, Sentry, a Redis circuit breaker, pg_cron cleanup jobs, a checked-in OpenAPI file, and a `/v1` versioned router.

The file also contradicts the decisions above in four places: it offers Django as an alternative framework (lines 160, 169, 171), Celery or RQ as the worker (line 169), `pip install --require-hashes` as an alternative to uv (line 170), and stdlib logging as an alternative to structlog (line 156). The Repository Pattern example is class-based while the File Layout section prefers module-level functions, and the carve-out for request-scoped repositories is never stated.

### Enforcement

- `enforce/eslint.config.mjs` and `enforce/eslint-options.mjs` hardcode `**/*.ts` and `**/*.tsx` in every `files:` array. No `.vue` file is ever parsed, and neither `vue-eslint-parser` nor `eslint-plugin-vue` is installed.
- The server-tree glob list that scopes R-342, R-343, and R-344 (`apps/server/**`, `server/src/**`, and similar) does not match Nitro's `server/api/**` or `server/middleware/**`.
- `hooks/structure-gate.sh` roots its segment walk on `src` for any file and on `app` only when the file is Python. A `.vue` or Nitro `.ts` file under Nuxt's `app/` or `server/` never triggers the walk, so R-304, R-305, R-311, and R-312 are silently inert on Nuxt paths. The per-component-folder check (R-305) is hardcoded to `.tsx` plus a React dependency.
- The FastAPI vocabulary (`app/routers`, `app/schemas`, `app/repositories`, `app/core`, `app/db`) is already accepted by structure-gate; no change is needed there.
- `ruff-enforce.toml` covers eight rules (PLR2004, E731, T201, E722, S110, BLE001, ANN401, PGH003). It does not include pydocstyle `D100`/`D103`, the natural AST analog of the R-320 file-header rule.

## Design

### 1. Frontend four-file split

`CLAUDE-FRONTEND.md` is refactored into a framework-agnostic core. React-specific content moves to a new `CLAUDE-FRONTEND-REACT.md`. Two new files carry the Vue track. `CLAUDE-FRONTEND-NEXT.md` and `CLAUDE-FRONTEND-VITE.md` change only where they cross-reference the core.

| File | Target lines | `paths:` globs | Contents |
|---|---|---|---|
| `CLAUDE-FRONTEND.md` (refactored core) | ~140 | `**/src/components/**`, `**/src/features/**`, `**/src/state/**`, `**/src/api/**`, `**/app/components/**`, `**/app/composables/**`, `**/app/stores/**` | Framework Files dispatch table (adds a `nuxt.config.ts` marker row), generic Directory Vocabulary, generic File Naming rows, API Calls pattern, Error Handling, Prettier config minus `jsxSingleQuote`, the full E2E Test Layout section moved verbatim. |
| `CLAUDE-FRONTEND-REACT.md` (new) | ~170 | `**/*.tsx`, `**/*.jsx` | React 19 Framework and Stack, TSX Component Patterns (props interface, `useCallback`, default exports, no `React.FC`), React Import Ordering, State Management (TanStack Query, Context, `useState`, `useRef`, the state-library ban), `'use client'` pointer to the Next file, JSX Prettier row, React ESLint rules. |
| `CLAUDE-FRONTEND-VUE.md` (new) | ~190 | `**/*.vue`, `**/app/components/**`, `**/app/composables/**`, `**/app/stores/**` | Vue 3 Framework and Stack (Composition API, `<script setup lang="ts">` only, TanStack Query for Vue, Pinia, Reka UI, SCSS modules, no Tailwind), Directory Vocabulary (`composables/` replaces `state/`, `stores/` for Pinia), File Naming (`PascalCase.vue`, `useX.ts`), SFC Component Patterns (`defineProps<Props>()`, `defineEmits<Emits>()`, `ref`/`computed`, block order, sibling `.module.scss` via `import styles`), Vue Import Ordering (`vue`, `vue-router`, `#imports` first), State Management (TanStack Query for Vue for server state, Pinia `defineStore` for app state, `ref`/`reactive` for local state), Vue ESLint rules (`eslint-plugin-vue` recommended set, block order, `vue/multi-word-component-names` exceptions for pages and layouts), SCSS module usage in templates (`:class="[styles.chip, isSelected && styles.chipSelected]"`), `displayName` and `data-test-id` rule, Storybook for Vue. |
| `CLAUDE-FRONTEND-NUXT.md` (new) | ~120 | `**/app/pages/**`, `**/app/layouts/**`, `**/app/middleware/**`, `**/app/plugins/**`, `**/server/**/*.ts`, `**/nuxt.config.*` | Framework (Nuxt 4, `app/` root, SSR default), Directory Structure (`app/pages`, `app/layouts`, `app/middleware`, `app/plugins`, `server/api`, `server/middleware`, `app/assets/css/main.scss`), Route groups translated to named layouts plus `definePageMeta({ layout, middleware })`, Auth gating (a `server/middleware` cookie-presence check for the redirect plus a protected layout that re-verifies the session against the backend), Proxies (`server/api/[...path].ts` to the backend, `server/api/ingest/[...path].ts` to PostHog), Metadata and Fonts (`useSeoMeta`, `useHead`, `@nuxt/fonts`), Environment Variables (`runtimeConfig.public` from `NUXT_PUBLIC_*` at runtime, read via `useRuntimeConfig()`), Theme (Pinia store persisted to `localStorage`, `data-theme` attribute, inline anti-FOUC script via `useHead`), Sentry (`@sentry/nuxt`), File Naming rows, Containers (Nitro `node-server` preset, `.output/`, `HEALTHCHECK` against `server/api/health.get.ts`, `CMD ["node", ".output/server/index.mjs"]`). |

Design rules for the split:

- The core keeps only prose that reads correctly for both React and Vue without a framework name in it. Any sentence naming a hook, a directive, or a state library moves to a framework file.
- The Framework Files dispatch table in the core gains a row: `nuxt.config.ts` in the project root reads `CLAUDE-FRONTEND-VUE.md` and `CLAUDE-FRONTEND-NUXT.md`.
- `CLAUDE-STYLING.md` stays unchanged except for the two sections that show TSX syntax (Applying Variants, SCSS Module Import in TSX). Each gains a short Vue subsection showing the `:class` array form and the `import styles from './X.module.scss'` line inside `<script setup>`; the sibling-file convention is kept for parity with the per-component-folder rule.

### 2. `CLAUDE-PYTHON.md` rewrite

The file is rewritten to the outline below, about 900 lines, in the macro order the Express file uses (stack, structure, naming, app wiring, data layer, cross-cutting, tooling). Sections the current file has and the Express file lacks (Module and Symbol Naming, File Layout, Testing, Enforcement, Build/Run Assets) are preserved.

| # | Section | ~Lines | Notes |
|---|---|---|---|
| 1 | Stack | 20 | FastAPI, uvicorn, SQLAlchemy 2 Core async on asyncpg, Alembic, Pydantic v2, pydantic-settings, `redis.asyncio`, arq, structlog, Anthropic Python SDK, uv, Railway. No alternatives listed. |
| 2 | Directory Structure | 60 | Adds `prompts/` and `tools/` for agentic apps, `workers/` for arq, `migrations/versions/`. |
| 3 | Layer Responsibilities | 15 | Adds a Middleware and Dependencies row for Starlette middleware and the `Depends` chain. |
| 4 | File and Module Naming | 35 | Per-layer `snake_case.py` table; no suffixes, the directory disambiguates; feature-folder example. |
| 5 | File Layout | 15 | Existing content, plus the stated carve-out: repositories holding request-scoped state may be classes. |
| 6 | Import Ordering | 20 | Worked example; absolute `from app...` imports only. |
| 7 | Entry Point (app factory) | 20 | Settings and clients constructed inside `create_app()` or a cached dependency, never at import time. |
| 8 | Build Tool (uv) | 12 | `uv sync --frozen`, `uv run`, `[project.scripts]`, committed lockfile, no pip or poetry. |
| 9 | Health Endpoints | 20 | Route code for `/health` and `/health/ready` with `SELECT 1` via `Depends(get_session)`. |
| 10 | Worker Pattern (arq) | 50 | `WorkerSettings`, `RedisSettings.from_dsn`, `functions` list, `on_startup`/`on_shutdown`, `arq --check` for the health probe, `Dockerfile.worker`, graceful shutdown. |
| 11 | Containers (R-351) | 35 | Multi-stage `python:3.13-slim`, uv in the builder, non-root `app` user, `HEALTHCHECK`, compose with API, worker, Postgres, Redis, `railway.toml`, CI builds the image. |
| 12 | Session Store | 55 | bcrypt 12 rounds, 32-byte token, SHA-256 hash stored, 7-day httpOnly `sameSite=lax` cookie, timing-equalized login against a fixed dummy hash, `sessions` table shape, admin role via `require_admin` dependency, hourly cleanup. |
| 13 | CSRF | 12 | Middleware rejecting state-changing requests without `X-Requested-With`; no token endpoint. |
| 14 | Rate Limiting | 20 | Redis-backed limiter with an in-memory fallback and a startup warning; global and auth-route limits; skipped under test. |
| 15 | Idempotency Keys | 18 | `Idempotency-Key` on POST and PUT for authenticated users, stored status and body, 24 hour TTL. |
| 16 | Request Timeout | 8 | 30 second middleware returning 408. |
| 17 | Environment Validation | 15 | pydantic-settings with a validator requiring `cors_origin` in production. |
| 18 | FastAPI App Structure | 30 | Middleware precedence stated for Starlette's outside-in wrapping, with the resulting request-path order listed explicitly. |
| 19 | Router Pattern | 25 | `APIRouter(prefix="/v1/...", dependencies=[Depends(require_session)])`, full CRUD example. |
| 20 | Validation (Pydantic) | 20 | Schema naming table: `Model`, `ModelCreate`, `ModelUpdate`, `ModelResponse`, all in `schemas/<domain>.py`; note that FastAPI validates automatically, so no `safeParse` analog. |
| 21 | Repository Pattern | 30 | Core `select`/`insert` with `RETURNING`, `user_id` scoping, `None` for not found. |
| 22 | Database Session and Engine | 25 | `create_async_engine` pool settings and `statement_timeout`, `async_sessionmaker`, transaction helper, one session per request, never shared across tasks. |
| 23 | Migrations (Alembic) | 30 | Location, `revision`/`down_revision` chain, `upgrade()`/`downgrade()` both required, worked create-table example, `MetaData(naming_convention=...)` for autogenerate, explicit `CREATE TYPE` and `DROP TYPE` for enums, `sa.text()` for expression defaults. |
| 24 | Risky Migrations | 12 | Cross-reference to the database file's staged process, restated as separate Alembic revisions. |
| 25 | Error Handling and Response Envelope | 35 | `{ code, error }` envelope, namespaced codes in `constants/error_codes.py`, `@app.exception_handler` code, DB-unavailable to 503, internals hidden in production, cache reads degrade and never raise. |
| 26 | Stripe Webhook | 28 | Raw body route before JSON parsing, signature verification, event allowlist, `stripe_events` ledger with claim, processed, and failed states. |
| 27 | Email (Resend) | 12 | Lazy client, no-op with a warning when the key is absent. |
| 28 | Object Storage (Cloudflare R2) | 12 | boto3 S3 client, key validation, presigned URLs. |
| 29 | Error Tracking (Sentry) | 12 | `sentry_sdk` init gated on DSN, user context set in the session dependency. |
| 30 | Circuit Breaker | 18 | Redis-backed state, fails open when Redis is absent. |
| 31 | Logging (structlog) | 18 | `ConsoleRenderer` in development, `JSONRenderer` elsewhere, `{ err }` shape via `exc_info`. |
| 32 | Observability (R-341 to R-346) | 60 | Code for the request-ID middleware, `clients/analytics.py`, `clients/telemetry.py` with a `with_client_telemetry` wrapper. |
| 33 | pg_cron Cleanup Jobs | 12 | Migration installs the extension when available and schedules hourly cleanup; in-process fallback. |
| 34 | OpenAPI and `/v1` Versioning | 15 | FastAPI generates the document; a checked-in `docs/openapi.yaml` is exported from it in CI and diffed, so the file and the code cannot drift. |
| 35 | Python Typing Patterns | 18 | `BaseModel` at boundaries, `@dataclass(slots=True)` for internal values, `request.state.user` and a typed `get_current_user` dependency, four-column type map (Postgres, Python, SQLAlchemy column, Pydantic field). |
| 36 | RESTful Route Naming | 12 | Cross-reference plus the `/v1` prefix requirement. |
| 37 | Testing (pytest) | 28 | Existing content plus a negative-input test per handler (R-406) and the real-Postgres truncation pattern. |
| 38 | Tooling | 18 | ruff, black at line length 100 to match the portfolio-wide Prettier width, mypy strict, pre-commit on staged files. |
| 39 | Enforcement | 15 | Names every Python enforcer, including the new `D100`/`D103` entry. |
| 40 | Build/Run Assets (R-407) | 12 | Existing content. |

The Alembic and SQLAlchemy restatements of `CLAUDE-DATABASE.md` land in sections 21 through 24 and the type map in section 35. Stack-agnostic database rules (table and column naming, timestamps, access control) are cited, not copied.

### 3. Enforcement additions

Each row ships with a manifest entry and a fixture test in the same PR.

| # | Rule | Change | Effort | Fixture to model on |
|---|---|---|---|---|
| E1 | R-321, R-323, R-324, R-326, R-327, R-329, R-325, R-316/317, R-320 | Install `vue-eslint-parser` and `eslint-plugin-vue`; add `**/*.vue` to every `files:` array in `eslint.config.mjs` and `eslint-options.mjs`; set `languageOptions.parser` to the Vue parser with `parserOptions.parser` set to the TypeScript parser so `<script setup lang="ts">` is type-checked. | Medium | `enforce/tests/eslint.test.sh`, extended with a `.vue` fixture |
| E2 | R-303 | Add `.vue` to `import-x/extensions` and the resolver extension list. | Small | `enforce/tests/push-eslint-gate.test.sh` |
| E3 | R-342, R-343, R-344 | Add `**/server/api/**` and `**/server/middleware/**` to the server-tree glob list. | Small | Same |
| E4 | R-320 | Add `vue` to the extension regex in `hooks/new-file-header-reminder.sh`. | Small | `hooks/tests/new-file-header-reminder.test.sh` |
| E5 | R-351 | Add `nuxt.config.*` to the config-file case in `hooks/dockerfile-reminder.sh`. | Small | `enforce/tests/dockerfile-reminder.test.sh` |
| E6 | R-320 (Python) | Add `D100` and `D103` to `ruff-enforce.toml`'s select list. | Small | `enforce/tests/push-ruff-gate.test.sh` |
| E7 | R-304, R-305, R-311, R-312 (Vue) | Add an `is_vue` branch to `hooks/structure-gate.sh` keyed on a `.vue` extension or a `nuxt` dependency in the nearest `package.json`; root the segment walk on `app` and `server` for that branch; extend the per-component-folder check to `.vue` files with a `vue` or `nuxt` dependency. The Express and React branches must produce byte-identical results on the existing fixtures. | Large | `hooks/tests/structure-gate.test.sh`, with new cases for a flat `.vue` in `components/`, a stray `app/utils/`, and a compliant Nuxt tree |

The `structure-conventions` skill gains the Nuxt vocabulary in R-305 and the Python vocabulary in R-304, and its description line stops saying "TypeScript server or web client".

### 4. `add-stack-track` skill and invariant test

`claude/skills/add-stack-track/SKILL.md` carries the stack track procedure as a numbered checklist:

1. Write `claude/CLAUDE-<TRACK>.md` with a `paths:` frontmatter block and the section outline of its parity target.
2. Add the tracked symlink `claude/rules/<name>.md`.
3. Add or edit the stack-detection row in `claude/rules/session-types.md` and the read-on-demand row in `claude/CLAUDE.md`.
4. For every manifest rule with a stack-specific enforcer, add the analog or record the gap as a manifest note (R-516), with one fixture test per new enforcer.
5. Extend `structure-gate.sh` and the `structure-conventions` skill with the track's directory vocabulary.
6. Run `sync.sh`, then `hook-integrity-check.sh --update`, then `git diff origin/main` before pushing (R-106).

`enforce/tests/convention-track-invariants.test.sh` asserts, for every `claude/CLAUDE-*.md` other than `CLAUDE.md`: a `paths:` frontmatter block exists, a `claude/rules/*.md` symlink resolves to it, and `session-types.md` or the core's Framework Files table names it. The test runs in the existing enforce test suite.

### 5. Wiring changes

- `claude/rules/`: new symlinks `frontend-react.md`, `frontend-vue.md`, `frontend-nuxt.md`.
- `claude/rules/session-types.md`: the `package.json` row's Read cell lists the Vue and Nuxt files as the alternative to Next or Vite.
- `claude/CLAUDE.md`: the Convention files table's stack-detection sentence names the Vue track.
- `enforce/manifest.json`: entries for E1 through E7 and the invariant test.
- `enforce/hook-hashes.txt`: regenerated in the PR that changes any hook.

## Acceptance criteria

Each criterion is testable and cited by the tests in the slice plan.

- AC-1: A file at `app/components/Foo/Foo.vue` matches the `paths:` of the Vue file and the core, and matches no glob in the React, Next, or Vite files. Verified by a test that runs each file's globs against a fixture path list.
- AC-2: `grep -c 'React\|useCallback\|Zustand' CLAUDE-FRONTEND.md` returns 0 after the refactor.
- AC-3: `CLAUDE-PYTHON.md` contains none of the strings `Django`, `Celery`, `RQ`, `pip install`, or `stdlib`, and contains a section header for every row of the outline above.
- AC-4: `CLAUDE-PYTHON.md` is between 800 and 1000 lines, the band that matches `CLAUDE-BACKEND.md` plus the 14 sections the Express file never documents.
- AC-5: The ESLint fixture test fails on a `.vue` fixture containing a nested ternary, a magic number, and an `any`, and passes on the compliant fixture.
- AC-6: The structure-gate fixture test denies `app/components/Foo.vue` (flat) and `app/utils/x.ts` in a Nuxt tree, allows `app/components/Foo/Foo.vue` and `server/api/health.get.ts`, and produces unchanged results on every pre-existing Express and React case.
- AC-7: The push-ruff-gate fixture test fails on a `.py` file with no module docstring.
- AC-8: The invariant test passes on the repo after this slice, and fails when any one of a symlink, a `paths:` block, or a session-types mention is removed from a temporary copy.
- AC-9: `enforce/tests` and `hooks/tests` suites are green at the end of every PR.
- AC-10: After `sync.sh`, `hook-integrity-check.sh` reports no drift.

## Slice and PR breakdown (draft for the slice plan)

One slice, seven PRs, each independently mergeable. Order matters: the skill and invariant test land first so the Vue track is the skill's first execution.

| PR | Concern | Size |
|---|---|---|
| 1 | `add-stack-track` skill, invariant test, manifest entry | ~4 files, ~200 lines |
| 2 | Frontend core refactor: agnostic `CLAUDE-FRONTEND.md`, new `CLAUDE-FRONTEND-REACT.md`, cross-reference edits in NEXT and VITE, symlink | ~5 files, ~350 lines moved |
| 3 | `CLAUDE-FRONTEND-VUE.md`, `CLAUDE-FRONTEND-NUXT.md`, STYLING subsections, symlinks, session-types and CLAUDE.md rows | ~6 files, ~350 lines |
| 4 | `CLAUDE-PYTHON.md` rewrite | 1 file, ~900 lines |
| 5 | Enforcement E1 to E6: parser wiring, globs, hook extensions, ruff select, fixtures, manifest | ~10 files, ~300 lines |
| 6 | Enforcement E7: structure-gate Vue branch, fixtures, structure-conventions skill update, manifest | ~4 files, ~200 lines |
| 7 | Sync, hash regeneration, README convention-files table, handoff | ~3 files |

## Later list

Ideas raised during design that are out of this slice's scope.

- Python naming-lexicon AST enforcer for R-316 and R-317.
- SFC-aware brace counting in `clean-code-scan.mjs` for R-322.
- Delete `enforce/eslintOptions.mjs`, a byte-identical stale duplicate of `eslint-options.mjs` that the integrity guard currently flags.
- The Express template's `scripts/seed-test.ts` imports paths that no longer exist; rewrite from behavior in the template workstream, not here.

## Risks

- The structure-gate change (E7) touches the root-trigger logic every stack branch depends on. Mitigation: the existing fixture suite must pass unchanged, and the new branch is additive (a new `is_vue` condition), never a rewrite of the `src` or `app` conditions.
- The core refactor (PR 2) changes what auto-loads in every existing React project. Mitigation: AC-1 tests the globs against fixture paths for React, Next, Vite, and Nuxt trees before merge.
- A 900-line Python file written in one PR is hard to review in one sitting. Mitigation: the PR body lists the sections by number with the Express parity target for each, and the reviewer is pointed at sections 12, 18, 22, 23, and 25 as the risk-weighted ones.
