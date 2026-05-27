# Backend Conventions

These rules apply to all `server/` and API packages across every app in this portfolio.

---

## Stack

- **Express 5** + TypeScript on Railway
- **PostgreSQL** on Neon (via `pg` driver; raw SQL, no ORM)
- **Zod** for request validation and type derivation
- **Pino** for structured logging
- **Redis** (ioredis) for caching where needed
- **Anthropic Claude API** for LLM calls

---

## Directory Structure

```
src/
├── index.ts                      # Express app entry point
├── config/                       # Configuration modules
│   ├── env.ts                    # Environment helpers (isProduction, etc.)
│   ├── corsConfig.ts             # CORS middleware config
│   └── redis.ts                  # Redis client setup (apps that use it)
├── constants/                    # Hard-coded constants
│   └── session.ts
├── db/
│   └── pool/
│       └── pool.ts               # PostgreSQL pool + query wrapper + transaction helper
├── handlers/                     # HTTP request handlers (thin; validate, delegate, respond)
│   ├── auth/
│   │   └── auth.ts
│   ├── jobs/
│   │   ├── jobs.ts
│   │   └── analyze.ts
│   └── links/
│       └── summary.ts
├── middleware/                    # Express middleware
│   ├── csrfGuard/
│   │   └── csrfGuard.ts
│   ├── errorHandler/
│   │   └── errorHandler.ts
│   ├── notFoundHandler/
│   │   └── notFoundHandler.ts
│   ├── rateLimiter/
│   │   └── rateLimiter.ts
│   ├── requestLogger/
│   │   └── requestLogger.ts
│   └── requireAuth/
│       └── requireAuth.ts
├── prompts/                      # LLM system/user prompt templates
│   └── summarize.ts
├── repositories/                 # Data access layer (all SQL lives here)
│   ├── auth/
│   │   └── auth.ts
│   └── jobs/
│       └── jobs.ts
├── routes/                       # Express router definitions
│   ├── auth.ts
│   └── jobs.ts
├── schemas/                      # Zod schemas + derived TypeScript types
│   ├── auth.ts
│   ├── job.ts
│   └── job-extraction.ts
├── services/                     # Business logic layer
│   ├── analyzer.service.ts
│   ├── anthropic.service.ts
│   └── cache.service.ts
├── tools/                        # Agent tool definitions + executor (agentic apps)
│   ├── definitions.ts
│   ├── executor.ts
│   └── flights.tool.ts
├── types/                        # TypeScript ambient declarations
│   └── express.d.ts
└── utils/
    ├── logs/
    │   └── logger.ts             # Pino logger instance
    └── parsers/
        ├── parsePagination.ts
        └── parseIdParam.ts
```

### Layer Responsibilities

| Layer | Does | Does NOT |
|-------|------|----------|
| **Handlers** | Validate input (Zod), call services/repos, return HTTP responses | Contain business logic, run SQL |
| **Services** | Orchestrate business logic, call repos, call external APIs | Parse HTTP requests, return HTTP responses |
| **Repositories** | Run parameterized SQL queries, return typed results | Know about HTTP, validate input |
| **Middleware** | Cross-cutting concerns (auth, logging, CORS, rate limiting) | Contain business logic |

Never skip layers. Handlers call services or repositories; repositories never call handlers.

---

## File Naming

| What | Convention | Example |
|------|-----------|---------|
| Middleware | `camelCase/camelCase.ts` | `errorHandler/errorHandler.ts` |
| Routes | `kebab-case.ts` | `auth.ts`, `jobs.ts` |
| Handlers | `kebab-case.ts` | `jobs.ts`, `summary.ts` |
| Repositories | `kebab-case.ts` | `jobs.ts`, `auth.ts` |
| Services | `kebab-case.service.ts` | `analyzer.service.ts` |
| Schemas | `kebab-case.ts` | `job.ts`, `job-extraction.ts` |
| Tools | `kebab-case.tool.ts` | `flights.tool.ts` |
| Utils | `camelCase.ts` | `parsePagination.ts` |
| Constants | `camelCase.ts` | `session.ts` |

Middleware and handlers are organized in folders by feature:
```
handlers/
├── auth/
│   └── auth.ts
├── jobs/
│   ├── jobs.ts       # CRUD handlers
│   └── analyze.ts    # Action handler
```

---

## Import Ordering

Imports are grouped with blank lines between groups:

```typescript
// 1. Environment setup (always first if present)
import "dotenv/config";

// 2. Node builtins (alphabetical)
import crypto from "node:crypto";
import path from "node:path";

// 3. Third-party packages (alphabetical)
import Anthropic from "@anthropic-ai/sdk";
import type { Request, Response } from "express";
import express from "express";
import { z } from "zod";

// 4. Local imports by layer (config → db → middleware → repos → schemas → services → utils)
import { corsConfig } from "app/config/corsConfig.js";
import { query } from "app/db/pool/pool.js";
import * as jobsRepo from "app/repositories/jobs/jobs.js";
import type { Job } from "app/schemas/job.js";
import { logger } from "app/utils/logs/logger.js";
```

- Use `type` keyword for type-only imports: `import type { Request } from "express"`
- Use `app/*` path alias mapping to `src/*`; never relative `../../` beyond one level
- All local imports end with `.js` extension (ESM resolution)

---

## Entry Point Pattern

Every backend has two files at the entry point:

**`src/index.ts`**; loads secrets, then dynamically imports app code:
```typescript
import { loadSecrets } from "app/config/secrets.js";

await loadSecrets();
await import("app/app.js");  // dynamic import: secrets are in process.env before any API client initializes
```

**`src/app.ts`**; creates and starts the Express server:
```typescript
import express from "express";
import http from "node:http";
// ... other imports

export const app = express();
// ... middleware and routes

const port = Number(process.env.PORT) || 3000;
const server = http.createServer(app);
server.listen(port, () => {
    logger.info({ port }, "Server started");
});
```


---

## Build Tool

All backends build with `tsc` + `tsc-alias`:

```json
{
  "scripts": {
    "build": "tsc && tsc-alias",
    "start": "node dist/index.js"
  }
}
```

- **Never use `tsup`**
- `tsc-alias` rewrites `app/*` path aliases in compiled output

---

## Health Endpoints

Every API service exposes two health endpoints:

```typescript
// Fast liveness check; always returns 200
app.get("/health", (_req, res) => {
    res.status(200).json({ status: "ok" });
});

// Readiness check; verifies DB connectivity
app.get("/health/ready", async (_req, res) => {
    try {
        await query("SELECT 1");
        res.status(200).json({ status: "ok", db: "connected" });
    } catch {
        res.status(503).json({ status: "degraded", db: "disconnected" });
    }
});
```

- `/health` is configured as Railway's healthcheck path (fast, no DB call)
- `/health/ready` is used for smoke tests after deploy (verifies DB is reachable)
- Register these routes **before** all application routes and **before** the notFoundHandler

---

## Worker Pattern (BullMQ)

Workers live in `packages/worker/src/workers.ts`. Every worker includes a minimal HTTP health server for Railway's healthcheck:

```typescript
import http from "node:http";
import { Worker } from "bullmq";
import IORedis from "ioredis";
import { logger } from "app/utils/logger.js";

const connection = new IORedis.default(process.env.REDIS_URL ?? "redis://localhost:6379", {
    maxRetriesPerRequest: null,
});

const worker = new Worker<MyJobType>(
    "queue-name",
    async (job) => {
        logger.info({ jobId: job.id }, "Processing job");
        await processMyJob(job);
    },
    { connection, concurrency: 2 },
);

worker.on("completed", (job) => logger.info({ jobId: job.id }, "Job completed"));
worker.on("failed", (job, err) => logger.error({ jobId: job?.id, err }, "Job failed"));
worker.on("error", (err) => logger.error({ err }, "Worker error"));

// Health server; required for Railway healthcheck
const healthServer = http.createServer((_req, res) => {
    res.writeHead(200);
    res.end("ok");
});
healthServer.listen(Number(process.env.PORT) || 3001);

logger.info("Worker started");

async function shutdown(signal: string) {
    logger.info({ signal }, "Shutting down worker gracefully");
    await worker.close();
    await connection.quit();
    healthServer.close();
    process.exit(0);
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
```

Workers have their own `Dockerfile.worker` at the monorepo root. See `CLOUD-DEPLOYMENT.md` for the per-service Dockerfile strategy.

---

## Session Store

Sessions must use PostgreSQL-backed storage; never in-memory `MemoryStore`:

```typescript
import connectPgSimple from "connect-pg-simple";
import session from "express-session";
import { pool } from "app/db/pool/pool.js";
import { SESSION_COOKIE_NAME, SESSION_MAX_AGE_MS } from "app/constants/session.js";

const PgStore = connectPgSimple(session);

export const loadSession = session({
    store: new PgStore({ pool, tableName: "sessions" }),
    secret: process.env.SESSION_SECRET!,
    resave: false,
    saveUninitialized: false,
    name: SESSION_COOKIE_NAME,
    cookie: {
        httpOnly: true,
        secure: isProduction(),
        sameSite: "lax",
        maxAge: SESSION_MAX_AGE_MS,
    },
});
```

Requires a `sessions` table (created by node-pg-migrate with the `connect-pg-simple` schema). The `sessions` table migration uses raw SQL:

```javascript
export const up = (pgm) => {
    pgm.sql(`
        CREATE TABLE IF NOT EXISTS sessions (
            sid VARCHAR NOT NULL COLLATE "default",
            sess JSON NOT NULL,
            expire TIMESTAMP(6) NOT NULL
        );
        ALTER TABLE sessions ADD CONSTRAINT sessions_pkey PRIMARY KEY (sid) NOT DEFERRABLE INITIALLY IMMEDIATE;
        CREATE INDEX IF NOT EXISTS IDX_session_expire ON sessions (expire);
    `);
};
```

---

## Environment Validation

Every server validates required env vars at startup. **In production, `CORS_ORIGIN` must be set**; an unset CORS_ORIGIN in production means all cross-origin requests are blocked:

```typescript
export function validateEnv() {
    const required = ["DATABASE_URL", "SESSION_SECRET"];
    if (isProduction()) {
        required.push("CORS_ORIGIN");
    }
    for (const key of required) {
        if (!process.env[key]) {
            throw new Error(`Missing required environment variable: ${key}`);
        }
    }
}
```

Call `validateEnv()` at the top of `app.ts`, before any middleware registration.

---

## Express App Structure (`app.ts`)

Middleware is applied in this exact order:

```typescript
app.set("trust proxy", 1);
app.use(helmet());
app.use(corsConfig);
app.use(requestLogger);
app.use(rateLimiter);
app.use(express.json({ limit: "10kb" }));
app.use(cookieParser());
app.use(csrfGuard);
app.use(loadSession);

// Routes
app.use("/auth", authRouter);
app.use("/jobs", jobsRouter);

// Error handlers (always last)
app.use(notFoundHandler);
app.use(errorHandler);
```

---

## Router Pattern

```typescript
import express from "express";
import * as jobHandlers from "app/handlers/jobs/jobs.js";
import { requireAuth } from "app/middleware/requireAuth/requireAuth.js";

const jobsRouter = express.Router();

jobsRouter.use(requireAuth);
jobsRouter.get("/", jobHandlers.listJobs);
jobsRouter.post("/", jobHandlers.createJob);
jobsRouter.get("/:id", jobHandlers.getJob);
jobsRouter.put("/:id", jobHandlers.updateJob);
jobsRouter.delete("/:id", jobHandlers.deleteJob);

export { jobsRouter };
```

- Import handlers with `import * as` namespace import
- Apply auth middleware at the router level, not per route
- Named export for the router: `export { jobsRouter }`

---

## Handler Pattern

```typescript
import type { Request, Response } from "express";
import * as jobsRepo from "app/repositories/jobs/jobs.js";
import { createJobSchema } from "app/schemas/job.js";

export async function createJob(req: Request, res: Response): Promise<void> {
    const parsed = createJobSchema.safeParse(req.body);
    if (!parsed.success) {
        const message = parsed.error.issues.map((e) => e.message).join("; ");
        res.status(400).json({ error: { message } });
        return;
    }

    const job = await jobsRepo.createJob(req.user!.id, parsed.data);
    res.status(201).json({ data: job });
}
```

- Return type is always `Promise<void>`
- Validate with `safeParse`, not `parse`; handle errors explicitly
- Return early on validation failure
- Let unhandled errors propagate to the global error handler

---

## Response Format

```typescript
// Success; single resource
res.json({ data: job });
res.status(201).json({ data: job });

// Success; collection with pagination
res.json({ data: jobs, meta: { total, limit, offset } });

// Error
res.status(400).json({ error: { message: "Validation failed" } });
res.status(401).json({ error: { message: "Authentication required" } });
res.status(404).json({ error: { message: "Not found" } });
res.status(409).json({ error: { message: "Email already registered" } });

// SSE streaming
res.write(`data: ${JSON.stringify({ type: "token", token })}\n\n`);
res.write(`data: ${JSON.stringify({ type: "done", summary, usage })}\n\n`);
```

Always wrap in `{ data: ... }` for success, `{ error: { message: ... } }` for errors.

---

## Validation (Zod)

Schemas live in `src/schemas/` alongside their derived types:

```typescript
import { z } from "zod";

export const jobSchema = z.object({
    id: z.string().uuid(),
    user_id: z.string().uuid(),
    title: z.string().nullable(),
    requirements: z.array(z.string()),
    created_at: z.coerce.date(),
    updated_at: z.coerce.date().nullable(),
});

export const createJobSchema = z.object({
    title: z.string().max(255).optional(),
    company: z.string().max(255).optional(),
});

export type Job = z.infer<typeof jobSchema>;
export type CreateJobInput = z.infer<typeof createJobSchema>;
```

- Schema names: `camelCase` + `Schema` suffix
- Type names: `PascalCase`, derived with `z.infer`
- Input schemas are separate from data model schemas
- Schemas validate at the handler layer, not the repository layer

---

## Repository Pattern

```typescript
import { query } from "app/db/pool/pool.js";
import type { Job } from "app/schemas/job.js";

export async function getJobById(id: string, userId: string): Promise<Job | null> {
    const result = await query<Job>(
        `SELECT * FROM jobs WHERE id = $1 AND user_id = $2`,
        [id, userId],
    );
    return result.rows[0] ?? null;
}

export async function createJob(userId: string, input: CreateJobInput): Promise<Job> {
    const result = await query<Job>(
        `INSERT INTO jobs (user_id, title, company)
         VALUES ($1, $2, $3)
         RETURNING *`,
        [userId, input.title ?? null, input.company ?? null],
    );
    const row = result.rows[0];
    if (!row) throw new Error("Insert returned no row");
    return row;
}
```

- Parameterized queries only (`$1, $2, ...`); never string interpolation
- Every query includes `user_id` scoping for multi-tenant safety
- Return `null` for not-found, not empty arrays
- `RETURNING *` on inserts and updates
- Named exports, imported as namespace: `import * as jobsRepo from "..."`

---

## Error Handling

**Global error handler** (last middleware):
```typescript
export function errorHandler(err: unknown, req: Request, res: Response, _next: NextFunction) {
    logger.error({ err, reqId: req.id }, "Unhandled error");
    res.status(500).json({
        error: {
            message: isProduction() ? "Internal server error" : (err instanceof Error ? err.stack : String(err)),
        },
    });
}
```

- Hide stack traces in production
- Specific database errors (e.g., `23505` unique violation) caught in handlers, not globally
- Cache operations degrade gracefully; catch and log, never rethrow

---

## Logging (Pino)

```typescript
// Structured context objects first, message string second
logger.info({ event: "register_success", userId: user.id }, "User registered");
logger.warn({ event: "login_failure", reason: "user_not_found" }, "Login failed");
logger.error({ err, linkId }, "Failed to fetch content");
logger.debug({ hash }, "Cache hit");
```

- Pretty printing in development, JSON in production
- Request IDs via `pino-http` middleware
- Always pass error objects as `{ err }`; Pino serializes them properly

---

## Database Pool

```typescript
const pool = new Pool({
    connectionString: process.env.DATABASE_URL,
    max: 10,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 5_000,
    statement_timeout: 10_000,
    ssl: isProduction()
        ? { rejectUnauthorized: process.env.DATABASE_SSL_REJECT_UNAUTHORIZED !== "false" }
        : false,
});
```

- Query wrapper logs duration in development
- Transaction helper: `withTransaction(async (client) => { ... })`
- Pool lives in `src/db/pool/pool.ts`

---

## Risky Migrations and Large-Scale Schema Changes

Any migration that renames tables, drops tables, moves data between tables, renames FK columns, or changes CHECK constraints on columns with existing data is a risky migration. For these:

1. **Develop locally.** Write and iterate the migration against local Postgres until it runs cleanly.
2. **Validate on a Neon branch.** Create a branch off the staging database. Run the full migration against the branch. Verify:
   - Row counts match expectations (no data lost or duplicated)
   - All FK dependents resolve (no orphaned rows with dangling foreign keys)
   - CHECK constraints pass for all migrated rows (especially enum-like columns with new or changed value sets)
   - The full test suite passes against the branched database
3. **Deploy to staging.** Run against real staging only after the branch validation passes. Smoke test all affected flows.
4. **Deploy to production.** Only after staging is green for a full cycle.

If the migration fails at step 2, delete the branch and iterate.

Migrations that only add new tables, add nullable columns, or add indexes are not risky and do not require this process.

---

## Export Patterns

| What | Export Style | Import Style |
|------|-------------|-------------|
| Handlers | Named: `export async function listJobs(...)` | `import * as jobHandlers from "..."` |
| Repositories | Named: `export async function getJobById(...)` | `import * as jobsRepo from "..."` |
| Services | Named: `export async function analyzeJob(...)` | `import { analyzeJob } from "..."` |
| Schemas/Types | Named: `export const jobSchema`, `export type Job` | `import { jobSchema, type Job } from "..."` |
| Routers | Named: `export { jobsRouter }` | `import { jobsRouter } from "..."` |
| Middleware | Named: `export function requireAuth(...)` | `import { requireAuth } from "..."` |
| Logger | Named: `export const logger` | `import { logger } from "..."` |

No default exports in the backend; named exports only.

---

## TypeScript Patterns

- **Types** for Zod-derived models: `type Job = z.infer<typeof jobSchema>`
- **Interfaces** for callback/service contracts: `interface StreamCallbacks { onToken: ... }`
- **Types** for unions: `type ProgressEvent = { type: "tool_start"; ... } | { type: "tool_result"; ... }`
- Extend Express Request in `types/express.d.ts`:
  ```typescript
  declare global {
      namespace Express {
          interface Request {
              user?: User;
          }
      }
  }
  export {};
  ```

---

## RESTful Route Naming

```
GET    /jobs              → list (paginated)
POST   /jobs              → create
GET    /jobs/:id          → get single
PUT    /jobs/:id          → full update
PATCH  /jobs/:id          → partial update
DELETE /jobs/:id          → delete
POST   /jobs/analyze      → action on collection
GET    /links/:id/summary → nested resource
POST   /links/:id/tags    → add to sub-resource
DELETE /links/:id/tags/:tagId → remove from sub-resource
```

---

## Formatting (Prettier)

```json
{
    "singleQuote": false,
    "semi": true,
    "trailingComma": "all",
    "printWidth": 100,
    "tabWidth": 4,
    "useTabs": false
}
```

| Rule | Value | Example |
|------|-------|---------|
| Quotes | Double | `import express from "express";` |
| Semicolons | Always | `const x = 1;` |
| Trailing commas | All | `[a, b, c,]` |
| Indentation | 4 spaces | (n/a) |
| Line width | 100 chars | (n/a) |
