# Database Conventions

These rules apply to all PostgreSQL schemas, migrations, and database access code across every app in this portfolio.

---

## Stack

- **PostgreSQL** on Neon
- **Migrations:** `node-pg-migrate` (builder API)
- **Driver:** `pg` (node-postgres); raw parameterized SQL
- **No ORM**; no Knex, Drizzle, Prisma, or TypeORM

---

## Migration Files

### Location

```
migrations/                       # At the package root (server/ or app root)
├── 1771879388542_create-users-table.js
├── 1771879388552_add-name-columns-to-users.js
├── 1774251317842_create-jobs-table.js
└── 1774300000000_create-sessions-table.js
```

### Naming

- Format: `{UNIX_TIMESTAMP_MS}_{description}.js`
- Description uses kebab-case: `create-users-table`, `add-name-columns-to-users`
- One logical change per migration file
- Migrations are JavaScript (`.js`), not TypeScript

### Structure

All packages use `"type": "module"` in their `package.json`, so migrations **must** use ESM `export` syntax; not CommonJS `exports`.

```javascript
/**
 * @type {import("node-pg-migrate").ColumnDefinitions | undefined}
 */
export const shorthands = undefined;

/**
 * @param pgm {import("node-pg-migrate").MigrationBuilder}
 */
export const up = (pgm) => {
    pgm.createTable("jobs", {
        id: { type: "uuid", primaryKey: true, default: pgm.func("gen_random_uuid()") },
        user_id: { type: "uuid", notNull: true, references: "users", onDelete: "CASCADE" },
        title: { type: "varchar(255)" },
        status: { type: "varchar(50)", notNull: true, default: "saved" },
        requirements: { type: "text[]", default: pgm.func("'{}'::text[]") },
        preferences: { type: "jsonb", default: pgm.func("'{}'::jsonb") },
        created_at: { type: "timestamptz", default: pgm.func("NOW()") },
        updated_at: { type: "timestamptz", default: pgm.func("NOW()") },
    });

    pgm.createIndex("jobs", "user_id");
    pgm.createIndex("jobs", "created_at");
};

/**
 * @param pgm {import("node-pg-migrate").MigrationBuilder}
 */
export const down = (pgm) => {
    pgm.dropTable("jobs");
};
```

> **Do not use `exports.up = ...`**; use ESM `export const up = ...` syntax only.

### Rules

- Always provide both `up` and `down` functions
- Use `pgm` builder API, not raw SQL (except for triggers and complex DDL)
- Add JSDoc type hints for `pgm` parameter
- Comment dependencies: `// Requires users table to exist`
- Drop in reverse order in `down` (constraints before tables, types after tables)

---

## Schema Conventions

### Table Naming

- **Plural**, lowercase, snake_case: `users`, `jobs`, `link_tags`, `trip_flights`
- Junction tables: combine both table names: `link_tags` (links + tags)

### Column Naming

- **snake_case** exclusively: `user_id`, `created_at`, `url_hash`, `summary_status`
- Never camelCase in the database
- Foreign keys: `{referenced_table_singular}_id` → `user_id`, `trip_id`, `tag_id`
- Boolean columns: prefix with `is_` or `has_`: `is_active`, `has_summary`

### Primary Keys

- Type: `uuid`
- Default: `pgm.func("gen_random_uuid()")`
- Every table has a UUID primary key; no serial/bigint IDs

### Timestamps

Every table includes:
```javascript
created_at: { type: "timestamptz", default: pgm.func("NOW()") },
updated_at: { type: "timestamptz", default: pgm.func("NOW()") },
```

Create the `set_updated_at` trigger function once (in the users table migration), then reuse it:

```javascript
// In the first migration:
pgm.sql(`
    CREATE OR REPLACE FUNCTION set_updated_at()
    RETURNS TRIGGER AS $$
    BEGIN
        NEW.updated_at = NOW();
        RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
`);

// Apply to each table:
pgm.sql(`
    CREATE TRIGGER set_jobs_updated_at
    BEFORE UPDATE ON jobs
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
`);
```

### Foreign Keys

```javascript
user_id: {
    type: "uuid",
    notNull: true,
    references: "users",
    onDelete: "CASCADE",
}
```

- `onDelete: "CASCADE"` for user-owned data (jobs, links, posts)
- `onDelete: "SET NULL"` for optional/loose references (tool call logs)
- Foreign key column is always `notNull: true` unless the relationship is optional

### Constraints

```javascript
// CHECK constraint
status: {
    type: "varchar(50)",
    notNull: true,
    default: "saved",
    check: "status IN ('applied', 'interviewing', 'offer', 'rejected', 'saved')",
}

// Composite unique constraint
pgm.addConstraint("tags", "tags_user_id_name_unique", {
    unique: ["user_id", "name"],
});
```

### Array Columns

```javascript
requirements: { type: "text[]", default: pgm.func("'{}'::text[]") }
tech_stack: { type: "text[]", default: pgm.func("'{}'::text[]") }
```

- Type: `text[]`
- Default to empty array: `pgm.func("'{}'::text[]")`

### JSONB Columns

```javascript
preferences: { type: "jsonb", default: pgm.func("'{}'::jsonb") }
tool_input_json: { type: "jsonb" }
```

- Use `jsonb`, not `json`
- Default to empty object: `pgm.func("'{}'::jsonb")`
- Suffix with `_json` when the column stores API response payloads

### Custom ENUM Types

```javascript
pgm.createType("trip_status", ["planning", "saved", "archived"]);

// Usage:
status: { type: "trip_status", notNull: true, default: "planning" }

// In down():
pgm.dropType("trip_status");
```

- Create types before the tables that use them
- Drop types after dropping the tables in `down()`

---

## Indexes

```javascript
// Single column
pgm.createIndex("jobs", "user_id");
pgm.createIndex("jobs", "created_at");

// Multi-column
pgm.createIndex("messages", ["conversation_id", "created_at"]);

// Create indexes in the same migration as the table
```

- Use auto-generated names (don't specify custom index names)
- Index all foreign key columns
- Index columns used in `WHERE`, `ORDER BY`, and `JOIN` clauses
- Create indexes in the same migration as the table they belong to

---

## Query Patterns

### Connection

All queries go through the pool wrapper in `src/db/pool/pool.ts`:

```typescript
export async function query<T extends QueryResultRow>(
    text: string,
    values?: unknown[],
    client?: PoolClient,
): Promise<QueryResult<T>> { ... }

export async function withTransaction<T>(
    fn: (client: PoolClient) => Promise<T>,
): Promise<T> { ... }
```

### SQL Formatting

- **UPPERCASE** keywords: `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `FROM`, `WHERE`, `JOIN`, `ORDER BY`, `LIMIT`, `RETURNING`
- **lowercase** table and column names
- Parameterized placeholders: `$1`, `$2`, `$3`; never string interpolation
- Multi-line queries for readability:

```typescript
const result = await query<Job>(
    `SELECT * FROM jobs
     WHERE user_id = $1
     ORDER BY created_at DESC
     LIMIT $2 OFFSET $3`,
    [userId, limit, offset],
);
```

### Common Patterns

```typescript
// Single row; return null if not found
const result = await query<Job>(`SELECT * FROM jobs WHERE id = $1 AND user_id = $2`, [id, userId]);
return result.rows[0] ?? null;

// Insert; always RETURNING *
const result = await query<Job>(
    `INSERT INTO jobs (user_id, title) VALUES ($1, $2) RETURNING *`,
    [userId, title],
);
const row = result.rows[0];
if (!row) throw new Error("Insert returned no row");
return row;

// Upsert
await query(
    `INSERT INTO conversations (trip_id) VALUES ($1)
     ON CONFLICT (trip_id) DO UPDATE SET updated_at = NOW()
     RETURNING *`,
    [tripId],
);

// Parallel queries for list + count
const [dataResult, countResult] = await Promise.all([
    query<Job>(`SELECT * FROM jobs WHERE user_id = $1 ORDER BY created_at DESC LIMIT $2 OFFSET $3`, [userId, limit, offset]),
    query<{ count: string }>(`SELECT COUNT(*)::text AS count FROM jobs WHERE user_id = $1`, [userId]),
]);
```

### Dynamic Updates

```typescript
const fields = Object.entries(input).filter(([, v]) => v !== undefined);
if (fields.length === 0) return getJobById(id, userId);

const setClauses = fields.map(([key], i) => `"${key}" = $${i + 3}`).join(", ");
const values = fields.map(([, v]) => v);

const result = await query<Job>(
    `UPDATE jobs SET ${setClauses} WHERE id = $1 AND user_id = $2 RETURNING *`,
    [id, userId, ...values],
);
```

---

## Type Mapping

| PostgreSQL | TypeScript | Zod |
|-----------|-----------|-----|
| `uuid` | `string` | `z.string().uuid()` |
| `varchar(n)` | `string \| null` | `z.string().max(n).nullable()` |
| `text` | `string \| null` | `z.string().nullable()` |
| `text[]` | `string[]` | `z.array(z.string())` |
| `integer` | `number` | `z.number().int()` |
| `boolean` | `boolean` | `z.boolean()` |
| `jsonb` | `Record<string, unknown>` | `z.record(z.unknown())` |
| `timestamptz` | `Date` or `string` | `z.coerce.date()` |
| custom enum | string union | `z.enum(["a", "b", "c"])` |

---

## Access Control

- No RLS policies; access control is enforced in the API layer
- Every repository query includes `user_id = $N` scoping
- No direct frontend-to-database connections
- The API server is the only database client
