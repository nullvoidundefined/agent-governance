# Cloud Deployment Guide

Covers Railway (API/workers/Redis/Postgres) and Cloudflare (document/file storage).

---

## General Rules

- **Always set `NODE_ENV`**; every remote deployment must have `NODE_ENV=production` (or `NODE_ENV=staging` for staging environments). Never leave it unset or defaulted.
- **Never deploy to production without a staging smoke test**; deploy to staging first, verify core flows, then promote.
- **One service per Railway project**; keep API, worker, Redis, and Postgres as separate Railway services within one project.
- **Commit after every task, deploy after every phase.** Never defer deploys.

---

## Security Rules (Non-Negotiable)

These are hard rules. No exceptions, no shortcuts to facilitate a deploy.

### TLS / SSL

- **Never set `rejectUnauthorized: false`** in any database, Redis, or HTTPS client connection config.
- **Never set `NODE_TLS_REJECT_UNAUTHORIZED=0`** as an environment variable.
- **Never use `checkServerIdentity: () => {}`** or any no-op TLS identity check.
- The correct pattern for `pg` Pool SSL in production:

  ```typescript
  ssl: isProduction()
    ? { rejectUnauthorized: process.env.DATABASE_SSL_REJECT_UNAUTHORIZED !== "false" }
    : { rejectUnauthorized: process.env.DATABASE_SSL_REJECT_UNAUTHORIZED === "true" },
  ```

  Railway's private networking (`*.railway.internal`) carries Postgres traffic inside the project network, so `ssl: false` is correct there. This is disabling SSL for an internal hop, not bypassing certificate verification on a public connection; never use `rejectUnauthorized: false` on a public DB URL.

### Secrets

- **Never commit `.env` files** containing real credentials. `.env` is for local dev only and must be in `.gitignore`.
- **Never hardcode API keys, passwords, or tokens** in source code. In production, set them as **secret/sealed** env vars on the hosting platform (Railway for the backend, Vercel for the frontend); use `.env` files locally.
- **Set secrets on every service that needs them.** Railway variables are per-service; a value set on one service is not shared with another.

### CORS

- **Never use `origin: '*'` with `credentials: true`**.
- `CORS_ORIGIN` must always be set to the exact production frontend URL in Railway. Never use `localhost` in production.
- For Railway-hosted frontends, use the custom domain (e.g., `your-app.com`). For Vercel-hosted frontends, use the team-scoped stable URL.

---

## Railway

### Project Structure

```
Railway Project (per app)
├── api         ; Express/TypeScript server (packages/api)
├── worker      ; BullMQ worker (packages/worker, apps 3+)
├── postgres    ; Managed Postgres (Neon is the DB, but Railway provides the Redis)
└── redis       ; Managed Redis
```

### Deploying a Service

1. Link the service to the repo via the Railway MCP or dashboard.
2. Set the root directory to the package being deployed (e.g., `packages/api`).
3. Set the start command explicitly; e.g., `node dist/index.js` or `npm run start`.
4. Set `NODE_ENV=production` (or `staging`); **this must always be set explicitly**.
5. Configure all required env vars before the first deploy (see env var checklist below).
6. Use the Railway MCP `deploy` tool or `railway up` from the correct package directory.

### Environment Variables (Required for Every Service)

| Variable | Value | Notes |
|----------|-------|-------|
| `NODE_ENV` | `production` or `staging` | **Always set. Never omit.** |
| `PORT` | Railway injects this | Do not hardcode |
| `DATABASE_URL` | Postgres connection string | Use pooled URL for the API, direct URL for migrations |
| `REDIS_URL` | Railway Redis URL | Required for apps 3+ |

Sensitive API keys (`ANTHROPIC_API_KEY`, `VOYAGE_API_KEY`, `SESSION_SECRET`, etc.) are set directly as **secret** Railway env vars on each service that needs them. There is no external secret manager; the app reads everything from `process.env` (validated through a Zod env schema where present).

Add app-specific non-secret vars (e.g., `CLOUDFLARE_ACCOUNT_ID`, `CORS_ORIGIN`) as plain Railway env vars.

### Railway MCP Workflow

```
# Check current projects
railway list-projects

# Check service logs after a deploy
railway get-logs --serviceId <id>

# Set env vars from Claude Code
railway set-variables --serviceId <id> --variables '{"NODE_ENV":"production"}'

# List current variables to verify
railway list-variables --serviceId <id>
```

### Healthcheck & Zero-Downtime

- Expose a `GET /health` endpoint on every API service that returns `200 { status: "ok" }`.
- Configure Railway's healthcheck path to `/health`.
- Railway will wait for the healthcheck to pass before routing traffic to the new deploy.
- **Workers also need a health server**; BullMQ worker processes must expose a minimal HTTP server on `process.env.PORT` or `3001`, or Railway's healthcheck will mark the service as failed. See `CLAUDE-BACKEND.md` → Worker Pattern for the implementation.
- **Cron services do not healthcheck.** A Railway cron runs its start command to completion and exits; there is no long-lived port to probe, so leave the healthcheck unset on cron-only services.

### Per-Service Dockerfiles

Monorepo apps with both an API and a worker use separate Dockerfiles to control which entrypoint is run:

```
Dockerfile          # API service (CMD: node server/dist/index.js or packages/api/dist/index.js)
Dockerfile.worker   # Worker service (CMD: node worker/dist/index.js or packages/worker/dist/index.js)
```

**Important:** The `RAILWAY_DOCKERFILE_PATH` environment variable does **not** reliably override which Dockerfile Railway uses. Instead, modify `railway.toml` to specify the Dockerfile path before deploying the worker service:

```toml
# railway.toml (temporarily set for worker deploy, then restore)
[build]
dockerfilePath = "Dockerfile.worker"
```

After the worker is deployed, restore `railway.toml` to the default (`Dockerfile`) for future API deploys.

### Cron Services

A Railway cron is an ordinary service that shares the app image but overrides the start command and sets a cron schedule (Settings → Cron Schedule, standard 5-field cron in UTC). It runs the command, then exits. Use one cron service per job.

- Set the same env vars the job needs (e.g., `DATABASE_URL`, plus any secrets) on each cron service; variables are per-service.
- Build the same Docker image; only the start command differs (e.g., `node dist/jobs/scheduled-ingest.js`).
- Cron services do not need a healthcheck (see above).
- Make jobs idempotent and self-alerting: a job that throws should set a non-zero exit code and notify (e.g., a heartbeat wrapper that posts to Telegram), so a missed run is visible.

### Database Migrations

- Run migrations **before** the new API code goes live.
- Use a Railway one-off job or a `prestart` script: `npm run migrate && node dist/index.js`. From a workstation, `railway run npm run migrate:up` injects the linked service's `DATABASE_URL`.
- Never run migrations from the worker service; API service owns schema changes.
- Keep `DATABASE_URL` (pooled) and `DATABASE_MIGRATION_URL` (direct) as separate vars.

---

## Secrets Management

Secrets live in the hosting platform's env var store. There is no external secret manager (no GCP Secret Manager, no Doppler). The app reads everything from `process.env` directly, validated through a Zod env schema where one exists.

- **Production:** set each secret as a **secret/sealed** env var on the Railway service that needs it (and on Vercel for any frontend secret). Set on every service separately; Railway variables are per-service.
- **Local development:** set values in the package's `.env` file (gitignored). Never commit real credentials.
- **Never print a secret.** Do not `console.log` secret values; check Railway log output after a deploy to confirm none leaked.

### Setting a secret

```bash
# Link the target service first; variables are per-service.
railway service <service-name>
railway variables --set "ANTHROPIC_API_KEY=sk-ant-..." --set "APP_SECRET=$(openssl rand -hex 32)"

# Verify
railway variables
```

### Rotating a key

```bash
# Rotate at the provider (Anthropic, Resend, etc.), then set the new value and redeploy.
railway service <service-name>
railway variables --set "ANTHROPIC_API_KEY=<new-value>"
railway redeploy
```

Revoke the old credential at the provider once the new value is confirmed working.

---

## Cloudflare (Document / File Storage)

Store all user-uploaded files and generated documents in Cloudflare R2. Never use the Railway filesystem.

### Required Variables (API service)

| Variable | Notes |
|----------|-------|
| `CLOUDFLARE_ACCOUNT_ID` | From Cloudflare dashboard |
| `CLOUDFLARE_R2_BUCKET` | Bucket name (e.g., `my-app-prod`) |
| `CLOUDFLARE_R2_ACCESS_KEY_ID` | R2 API token; use separate tokens per environment |
| `CLOUDFLARE_R2_SECRET_ACCESS_KEY` | R2 API token secret |
| `CLOUDFLARE_R2_PUBLIC_URL` | Public bucket URL or custom domain (if bucket is public) |

### Bucket Naming Convention

```
{app-slug}-{environment}
# e.g., my-app-prod, my-app-staging
```

Use separate buckets for production and staging; never share a bucket across environments.

### Access Pattern

- Files are uploaded server-side (API generates a presigned URL or streams directly).
- Never expose R2 credentials to the frontend.
- For private files, generate short-lived presigned URLs server-side and return them to the client.
- For public assets (e.g., processed output), use the R2 public URL with a custom domain.

---

## Staging vs Production Checklist

Before promoting a staging deploy to production:

- [ ] `NODE_ENV` is set to `production` on all services
- [ ] All env vars are set (no placeholders like `TODO` or empty strings)
- [ ] Every required secret is set on every service that needs it (variables are per-service)
- [ ] Migrations have run successfully against the production DB
- [ ] `GET /health` returns 200 on the API service
- [ ] A smoke test of the core AI loop (submit → process → response) passes
- [ ] R2 bucket is the production bucket, not staging
- [ ] Redis is the production Redis instance
- [ ] No `console.log` of secrets in logs (check Railway log output after deploy)

---

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Forgetting `NODE_ENV` | Always set it explicitly; never rely on a default |
| Using the same R2 bucket for staging and prod | Use separate buckets per environment |
| Running migrations from the worker | Always run from the API service |
| Hardcoding `PORT` | Use `process.env.PORT`; Railway injects it |
| Deploying without a healthcheck | Add `/health` and configure it in Railway before first production deploy |
| Using the pooled DB URL for migrations | Use the direct (non-pooled) URL for migrations only |
| Setting a secret on one service and assuming all get it | Railway variables are per-service; set each secret on every service that reads it |
| Leaving a secret value in logs | Never `console.log` secrets; review Railway log output after the first deploy |
| `rejectUnauthorized: false` in db pool | Always use the env-var-controlled pattern; see Security Rules above. Never hardcode `false`. |
| `CORS_ORIGIN` pointing to `localhost` in production | Set `CORS_ORIGIN` to the production frontend URL in Railway before first deploy |
| `CORS_ORIGIN` containing a preview/hash URL | Use the stable production domain, not a per-deployment hash URL |
| `CORS_ORIGIN` missing `http://localhost:3000` when local frontend hits prod API | Include `http://localhost:3000` in Railway's `CORS_ORIGIN` (comma-separated) so local dev works against the deployed API |

---

## Debugging "Failed to fetch" / CORS Errors

When the user reports "Failed to fetch" or a CORS error:

1. **Check Railway logs first** (`railway logs -n 30`). The server logs will show the exact rejected origin (e.g., `Origin http://localhost:3000 not allowed by CORS`). This is always faster than testing with curl.
2. **Do not test CORS with curl.** Curl does not enforce CORS; it will always succeed regardless of the server's CORS policy. Curl tests are meaningless for CORS debugging.
3. **Common rejected origins:**
   - `http://localhost:3000`; local dev frontend hitting production API. Add to `CORS_ORIGIN`.
   - Preview/deployment-specific URLs from hosting providers. The CORS config should allow these via regex pattern matching, not exact allowlist.
4. **Fix the `CORS_ORIGIN` env var** on Railway, then wait for the service to redeploy (~30s).

---

## Per-Project Overrides

Project-specific deployment details (service IDs, custom domains, workspace-specific env vars) live in each project's own `CLAUDE.md` file. The rules above are the universal defaults.
