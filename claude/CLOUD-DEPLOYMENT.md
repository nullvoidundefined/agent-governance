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

### Secrets

- **Never commit `.env` files** containing real credentials. `.env` is for local dev only and must be in `.gitignore`.
- **Never hardcode API keys, passwords, or tokens** in source code. Use GCP Secret Manager in production, `.env` files locally.
- **Never set sensitive API keys as Railway env vars directly**; use GCP Secret Manager. Only `GCP_SA_JSON` and `GCP_PROJECT_ID` go in Railway.

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
| `DATABASE_URL` | Neon connection string | Use pooled URL for the API, direct URL for migrations |
| `REDIS_URL` | Railway Redis URL | Required for apps 3+ |
| `GCP_PROJECT_ID` | `<GCP_PROJECT_ID>` | Required for GCP Secret Manager integration |
| `GCP_SA_JSON` | Service account JSON | **Secret**; paste full JSON from GCP console |

Sensitive API keys (`ANTHROPIC_API_KEY`, `VOYAGE_API_KEY`, `SESSION_SECRET`, etc.) are **not** set as Railway env vars; they are fetched at startup from GCP Secret Manager. See [GCP Secret Manager](#gcp-secret-manager) below.

Add app-specific non-secret vars (e.g., `CLOUDFLARE_ACCOUNT_ID`, `CORS_ORIGIN`) directly as Railway env vars.

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

### Database Migrations

- Run migrations **before** the new API code goes live.
- Use a Railway one-off job or a `prestart` script: `npm run migrate && node dist/index.js`.
- Never run migrations from the worker service; API service owns schema changes.
- Keep `DATABASE_URL` (pooled) and `DATABASE_MIGRATION_URL` (direct) as separate vars.

---

## GCP Secret Manager

All sensitive API keys are stored in GCP Secret Manager (project `<GCP_PROJECT_ID>`) and fetched at process startup.

### Secrets Stored in GCP

| Secret Name | Used By |
|-------------|---------|
| `ANTHROPIC_API_KEY` | All apps |
| `SESSION_SECRET` | Apps 1, 2, 4, 6, 7 |
| `VOYAGE_API_KEY` | App 7 |
| `OPEN_AI_API_KEY` | Apps 4, 5 |
| `CLOUDFLARE_R2_SECRET_ACCESS_KEY` | Apps 4, 7 |
| `SERPAPI_API_KEY` | App 8 |
| `GOOGLE_PLACES_API_KEY` | App 8 |

### Startup behavior

`src/config/secrets.ts` behavior:
- Development (`NODE_ENV !== "production"`): skipped; uses `.env` file values
- Production without `GCP_SA_JSON`: logs warning, falls back to Railway env vars
- Production with `GCP_SA_JSON`: fetches all secrets from GCP before any app code initializes

`index.ts` must use dynamic `import()` for all app code.

### GCP Setup (One-Time Per Developer)

```bash
# 1. Create service account
gcloud iam service-accounts create railway-apps \
  --display-name="Railway Apps" --project=<GCP_PROJECT_ID>

# 2. Grant read access to secrets
gcloud projects add-iam-policy-binding <GCP_PROJECT_ID> \
  --member="serviceAccount:railway-apps@<GCP_PROJECT_ID>.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

# 3. Download JSON key
gcloud iam service-accounts keys create ~/railway-sa.json \
  --iam-account=railway-apps@<GCP_PROJECT_ID>.iam.gserviceaccount.com
```

Then set on each Railway service:
- `GCP_SA_JSON` = contents of `~/railway-sa.json`
- `GCP_PROJECT_ID` = `<GCP_PROJECT_ID>`

**Delete the local `~/railway-sa.json` after setting it in Railway.**

### Rotating a Key

```bash
# Add new secret version in GCP
echo -n "new-key-value" | gcloud secrets versions add SECRET_NAME \
  --data-file=- --project=<GCP_PROJECT_ID>

# Restart Railway service to pick up new version
railway redeploy --service <service-name>
```

Disable the old version once the new version is confirmed working:

```bash
gcloud secrets versions disable VERSION_NUMBER \
  --secret=SECRET_NAME --project=<GCP_PROJECT_ID>
```

### Local Development

Set values directly in the package's `.env` file. Fill in placeholders locally as needed:

```bash
# Quick way to populate a key locally from GCP
export ANTHROPIC_API_KEY=$(gcloud secrets versions access latest \
  --secret=ANTHROPIC_API_KEY --project=<GCP_PROJECT_ID>)
```

---

## Cloudflare (Document / File Storage)

Store all user-uploaded files and generated documents in Cloudflare R2. Never use the Railway filesystem.

### Required Variables (API service)

| Variable | Notes |
|----------|-------|
| `CLOUDFLARE_ACCOUNT_ID` | From Cloudflare dashboard |
| `CLOUDFLARE_R2_BUCKET` | Bucket name (e.g., `doc-qa-rag-prod`) |
| `CLOUDFLARE_R2_ACCESS_KEY_ID` | R2 API token; use separate tokens per environment |
| `CLOUDFLARE_R2_SECRET_ACCESS_KEY` | R2 API token secret |
| `CLOUDFLARE_R2_PUBLIC_URL` | Public bucket URL or custom domain (if bucket is public) |

### Bucket Naming Convention

```
{app-slug}-{environment}
# e.g., doc-qa-rag-prod, doc-qa-rag-staging
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
- [ ] Migrations have run successfully against the production DB
- [ ] `GET /health` returns 200 on the API service
- [ ] A smoke test of the core AI loop (submit → process → response) passes
- [ ] R2 bucket is the production bucket, not staging
- [ ] Redis is the production Redis instance
- [ ] `GCP_SA_JSON` and `GCP_PROJECT_ID` are set on all Railway services
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
| Setting API keys as Railway env vars | Put them in GCP Secret Manager; only `GCP_SA_JSON` and `GCP_PROJECT_ID` go in Railway |
| Forgetting `GCP_SA_JSON` after SA key rotation | Download new key, update Railway var, restart service, delete old local key file |
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
