---
name: structure-conventions
description: The stack-specific layout and syntax conventions. Use before creating, moving, splitting, or renaming a directory, module, migration, or test tree in a server or web client (TypeScript, Python, Vue, or Nuxt), before writing a pg migration or Alembic default, and when planning a package layout.
---

# Structure Conventions

Read before creating, moving, splitting or renaming a directory, module, migration or test tree.

## Directories

- Express `src/` uses only: `config`, `constants`, `types`, `schemas`, `middleware`, `routes`, `handlers`, `services`, `repositories`, `clients`, `database`, `dependencyInjection`, `prompts`, `workers`. Add another only for a real domain responsibility. The root holds directories, not loose modules (entry point and `.d.ts` excepted).
- FastAPI `app/` uses `core`, `db`, `middleware`, `dependencies`, `routers`, `schemas`, `services`, `repositories`, `clients`, `constants`, `analytics`, `prompts`, `tools`, `workers`, all `snake_case`.
- Web client `src/` uses `app`, `components`, `features`, `services`, `api`, `clients`, `state`, `config`, `constants`, `data`, `styles`. One component per folder (`components/Header/Header.tsx`); context providers live in `state/`.
- Nuxt roots at `app/` (`pages`, `layouts`, `middleware`, `plugins`, `components`, `features`, `composables`, `stores`, plus the shared set) and `server/` (`api`, `routes`, `middleware`, `plugins`). `composables/` and `stores/` replace `state/`; pages and Nitro route directories are kebab-case URL segments.
- Never `lib/`, `utils/`, `helpers/` or other catch-alls. Use full words (`database/`, not `db/`; the Python `db/` package is the exception).
- Multi-word directories are camelCase. Exceptions: URL route segments are kebab-case, Python and Ruby use snake_case, Go uses lowercase packages with kebab-case `cmd/` binaries.
- A folder needs two or more sibling source files; a lone module stays a flat file. Split a directory with more than 20 modules into domain subfolders.

## Tests

- Tests sit in a sibling test directory, never beside the source: `__tests__/` (TypeScript), `tests/` (Python), `spec/` (Ruby). Go co-locates `*_test.go`.
- TypeScript: one top-level `__tests__/` per package `src/`, mirroring its layout; fixtures in `src/__fixtures__/`.
- Add a build-smoke test asserting every runtime-loaded non-code asset exists under `dist/` and that `dist/` holds no `.env*` or secrets.

## Inside a module

- One public function per module in `services/`, `api/` and `clients/`; shared helpers and state go in their own modules.
- File order: imports, types, `ALL_CAPS` constants, primary export, helpers (caller above callee). In bodies: guards, hooks in fixed order, `const` then `let`, main logic. Helpers are `function` declarations.
- Sort sibling keys alphabetically where order carries no meaning; never reorder where position matters.
- Extract meaningful literals to named constants (exempt `0`, `1`, `-1`, `''`, booleans, test literals).
- No IIFEs (declare a named `async function` and call it), no nested ternaries, no `any`, `@ts-ignore` or `@ts-nocheck` (type it or narrow `unknown`; `@ts-expect-error` with a description is the only suppression).

## Migrations

- pg-migrate defaults: bare strings for constants, `pgm.func()` for SQL expressions, never nested quotes.
