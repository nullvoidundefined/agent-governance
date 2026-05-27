---
name: 20 process learnings from 2026-04-05/06 debug session (PL1-PL20)
description: Cross-project rules from production incidents, applies to every Node/TS/Next.js/pnpm-monorepo project
type: feedback
---

These rules came from a multi-hour production session where the app broke multiple times during schema changes, pricing changes, and dependency cleanup. Each is backed by a specific incident, not theory. Full context lives in `the project's ISSUES.md` under "Process Learnings".

**Why:** Every rule has a real incident behind it. Treat as defaults for any new project. Flag to the user when any are being violated.

## Testing
- **PL1.** Unit tests that mock a broken repo call don't catch the bug. Every DB-touching handler needs an integration test against real Postgres. (Incident: `getUserSubscription` queried a removed column; unit tests mocked it and passed; production 500 on first request.)
- **PL3.** Every user flow needs at least one E2E test before shipping. No E2E test = feature doesn't exist yet.
- **PL12.** Playwright `projects` config must include chromium + webkit + mobile-safari (real iPhone profile). Chromium-only = Safari ITP bugs in production forever.
- **PL20.** "Test passes" ≠ "feature works". For each feature, ask: "which E2E/integration test would fail if this broke?" If the answer is "none," the feature is untested.

## Migrations / schema
- **PL2.** After any destructive migration (column removal, type change), grep the full codebase for the column name, its TypeScript type, and all repository functions. Delete dead code in the same commit as the migration.
- **PL15.** After any migration-related deploy, manually exercise every endpoint that reads/writes the changed tables. Do not trust CI alone.
- **PL19.** Removing a subscription/tier/plan system is a full-codebase sweep, not just a DB migration. Every reference (columns, types, handlers, constants, UI copy) gets deleted in the same PR.

## Next.js / Vercel / pnpm monorepo
- **PL5.** In pnpm monorepos, set `outputFileTracingRoot: path.resolve(__dirname, '..')` in `next.config.ts`. Otherwise dynamic routes work locally but 500 on Vercel because the bundler can't find hoisted node_modules.
- **PL6.** `pnpm.autoInstallPeers: true` installs *optional* peers too. Use `pnpm.overrides` with `"pkg": "never"` to suppress unwanted optional peers.
- **PL7.** `@playwright/test` anywhere in a Next.js app's dep tree causes `Cannot find module 'next/dist/compiled/source-map'` on Vercel. Put Playwright in the monorepo root `devDependencies` only, and suppress it from the app's peer resolution.
- **PL8.** Delete passthrough `middleware.ts` files. Every middleware intercepts every request through the Edge runtime, even the ones that just `NextResponse.next()`.

## Debugging
- **PL9.** After the *second* unexplained 500 on any Next.js App Router route, add an `error.tsx` boundary. You get the real error in 30 seconds instead of debugging blind for hours.
- **PL10.** After the third recurrence of a class of problem, it gets an issue number and a rule in `ISSUES.md`.
- **PL11.** Kill ports (`lsof -ti :3000 :3001 | xargs kill -9`) before running E2E tests locally. Stale dev servers silently break Playwright's `webServer` config.
- **PL14.** After regenerating a lockfile (`rm pnpm-lock.yaml && pnpm install`), grep it for the packages you were adding/removing to confirm the resolution matches expectations.

## Deploy / infra
- **PL13.** First step of any post-deploy workflow setup: `gh variable set` for every `${{ vars.X }}` it references. Missing vars resolve to empty string and curl fails with exit code 3 (URL malformed), which is easy to misdiagnose.

## Process
- **PL4.** Audits must never be told which categories of findings to suppress. "Don't suggest more tests" = audit misses obvious gaps. Audit's job is to find everything in scope; triage is the human's job afterward.
- **PL16.** Any action that debits credits, deletes data, or hits a paid API gets a `ConfirmDialog` with a cost/impact preview before proceeding. Never surprise-charge on first click.
- **PL17.** Any system billing on AI/API usage needs an `ai_jobs` (or similar) table with `estimated_cost_cents`, `actual_cost_cents`, `differential_cents`, `input_tokens`, `output_tokens`. Populate on every call. Aggregate via SQL for margin reporting.
- **PL18.** Every pricing formula needs a comment stating the business intent, not just the math. "uploads at cost + 15% minimum profit" is a business decision; `const TARGET_MARGIN = 0.96` is not.
