---
paths:
  - "**/migrations/**"
  - "**/*.sql"
  - "**/src/database/**"
  - "**/src/repositories/**"
---

# Database Conventions

Stack: PostgreSQL on Neon, `node-pg-migrate` (builder API), `pg` with raw parameterized SQL. No ORM (no Knex, Drizzle, Prisma, TypeORM).

## Migrations

- Location: `migrations/` at the package root. File name `{UNIX_TIMESTAMP_MS}_{kebab-description}.js`, one logical change per file. Migrations are JavaScript with ESM `export const up` / `export const down` (never `exports.up`).
- Always write both `up` and `down`. Use the `pgm` builder; raw `pgm.sql` only for triggers and complex DDL. Add JSDoc types for `pgm`.
- In `down`, drop in reverse order: constraints before tables, types after tables. Create enum types before the tables that use them.
- Create indexes in the same migration as their table.
- After a destructive migration (column removal, type change), search the codebase for the column and delete dead repository code in the same commit.

## Schema

- Tables: plural, lowercase snake_case (`users`, `link_tags`). Columns: snake_case only. Foreign keys: `{singular_table}_id`. Booleans: `is_` or `has_` prefix.
- Primary key on every table: `uuid` default `gen_random_uuid()`. No serial or bigint ids.
- Every table has `created_at` and `updated_at` (`timestamptz`, default `NOW()`). Create a `set_updated_at()` trigger function once in the first migration and attach a `BEFORE UPDATE` trigger per table.
- Foreign keys are `notNull` unless optional. `onDelete: "CASCADE"` for user-owned data, `"SET NULL"` for loose references.
- Use CHECK constraints or `createType` enums for closed value sets, and `addConstraint` for composite unique keys.
- Arrays: `text[]` defaulting to `'{}'::text[]`. JSON: `jsonb` (never `json`) defaulting to `'{}'::jsonb`; suffix `_json` for stored API payloads.
- Index every foreign key and every column used in `WHERE`, `ORDER BY`, `JOIN` or `= ANY($1)`. Use auto-generated index names.

## Types

`uuid` is `string` / `z.string().uuid()`; `varchar`/`text` is `string | null` / `.nullable()`; `text[]` is `string[]`; `integer` is `number`; `jsonb` is `Record<string, unknown>`; `timestamptz` is `Date` / `z.coerce.date()`; enums are string unions / `z.enum`.

## Query code

- All queries go through `query(text, values, client?)` in `src/database/pool.ts`. Inside a transaction pass the `client` so the statement runs on the transaction's connection.
- Uppercase SQL keywords, lowercase table and column names, multi-line queries for readability.
- Values are always `$n` placeholders, including `LIMIT`, `OFFSET` and `= ANY($1::uuid[])`. Never interpolate.
- Identifiers (sort columns, update columns) come from a constant allowlist object; an unknown key is a 400, never a pass-through.

```typescript
const UPDATABLE_JOB_COLUMNS = { company: "company", status: "status", title: "title" } as const;
const fields = Object.entries(input).filter(
    ([key, value]) => value !== undefined && Object.hasOwn(UPDATABLE_JOB_COLUMNS, key),
);
const setClauses = fields.map(([key], i) => `${UPDATABLE_JOB_COLUMNS[key as keyof typeof UPDATABLE_JOB_COLUMNS]} = $${i + 3}`);
```

- Single row: `result.rows[0] ?? null`. Inserts and updates use `RETURNING *`. Upserts use `ON CONFLICT`.
- Run independent list and count queries with `Promise.all`.

## Query discipline

- No query per element. Never call a repository or `query` inside a `for`, `while`, `.map`, `.forEach` or `Promise.all(xs.map(...))`. Add a plural repository function (`listLegsByTripIds`) using `= ANY($1::uuid[])`, a `JOIN`, or a lateral `json_agg`, then group in memory with `Map.groupBy`. Write sets with one statement (`INSERT ... SELECT FROM unnest($2::uuid[]) ... ON CONFLICT DO NOTHING`).
- Writes that must succeed together run in one `withTransaction`, every statement awaited in turn on the same `client` (repository functions take `client?` as a trailing parameter). No network calls inside the transaction; send emails after the commit. A single statement or data-modifying CTE is already atomic.
- A side effect that must happen exactly when the commit happens (job enqueue, webhook) is an outbox row written in the transaction.
- Lock several rows in primary-key order (`WHERE id = ANY($1) ORDER BY id FOR UPDATE`).
- No unguarded read-modify-write. Compute in SQL with a guard (`SET credits = credits - 1 WHERE id = $1 AND credits >= 1`, zero rows means failure), or use `FOR UPDATE`, or a `version` column. "Select then insert if absent" becomes a unique constraint plus `ON CONFLICT`. Idempotency keys sit under a unique constraint and are written in the same transaction.
- Bound every read: capped `LIMIT` (clamp to `MAX_PAGE_SIZE`), `ORDER BY` ending in `id`, keyset pagination (`WHERE (created_at, id) < ($2, $3)`) on tables that grow without bound, `OFFSET` only on small tables.
- Aggregate in SQL (`COUNT`, `SUM`, `GROUP BY`, `EXISTS`), never over loaded rows. Name columns when a table has large `jsonb` or `text` columns the endpoint does not return.
- `EXPLAIN ANALYZE` a new query on a table that can pass a few thousand rows.

## Access control and tests

- No RLS; access control lives in the API layer. Every tenant-data query is scoped with `user_id = $N`. Only the API server connects to the database.
- Every handler that touches the database gets an integration test against real Postgres, not a mocked repository.
- Every function or endpoint that returns a collection has a query-count test: run it with 1 row and with several rows and assert the count is equal (use an `AsyncLocalStorage` counter in the pool wrapper).
- After a deploy carrying a migration, exercise every endpoint that reads or writes the changed tables.
- Removing a subscription, tier or plan system deletes every column, type, handler, constant and UI string that references it in the same PR.
