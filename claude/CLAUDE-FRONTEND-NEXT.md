---
paths:
  - "**/src/app/**/*.ts"
  - "**/src/app/**/*.tsx"
  - "**/next.config.*"
---

# Next.js Frontend Conventions

Next.js 15+ App Router only (no Pages Router). Follows `CLAUDE-FRONTEND.md` and `CLAUDE-FRONTEND-REACT.md` for everything not covered here.

## Layout

- `src/app/` holds routes only: `layout.tsx` (metadata, fonts, providers), `page.tsx`, `globals.scss` (custom properties, resets), `loading.tsx` and `error.tsx` boundaries. Route groups use parentheses: `(auth)`, `(protected)` with an auth-guarded `layout.tsx`.
- Pages stay thin: compose from `features/` and `components/`, no business logic in `app/`. Everything outside `app/` follows the shared directory vocabulary.
- Route URL segments are kebab-case (`app/coming-soon/`); route groups and all other directories are camelCase.
- Files: `page.tsx`, `layout.tsx`, `globals.scss`; route-level styles `camelCase.module.scss`.
- Legacy projects with `lib/` or a flat `hooks/`: `lib/api.ts` becomes `api/` modules, `lib/queryClient.ts` becomes `config/queryClient.ts`, `hooks/` folds into `state/`.

## Components and metadata

- Server components are the default. Put `'use client'` as the first line of a component only when it has state, handlers or effects.
- Export `metadata: Metadata` from server components. Load fonts with `next/font/google` and inject them as CSS variables.
- Import group 1 is React plus `next/*` (`next/link`, `next/font`, `next` types).
- Delete passthrough `middleware.ts` files; every middleware runs each request through the Edge runtime.
- Add an `error.tsx` boundary to a route that returns unexplained 500s.

## Environment and build

- Browser-visible values use the `NEXT_PUBLIC_` prefix (API base URL: `NEXT_PUBLIC_API_URL`). They are baked in at build time, so never put a secret in one.
- In a pnpm monorepo set `outputFileTracingRoot: path.resolve(__dirname, '..')` in `next.config.ts`, or dynamic routes 500 on Vercel.
- Keep `@playwright/test` in the monorepo root `devDependencies` only, not in the app.
- Suppress an unwanted optional peer with a `pnpm.overrides` entry of `"pkg": "never"`.

## Container

- Set `output: "standalone"` in `next.config.ts`. The multi-stage Dockerfile builds on `node:22-alpine`, copies `.next/standalone`, `.next/static` and `public/` into the runtime stage, runs `USER node`, has a `HEALTHCHECK` on an `/api/health` route handler, and starts with `CMD ["node", "server.js"]`.
- `.dockerignore` excludes `.git`, `node_modules`, `.next`, `.env*` and tests. `NEXT_PUBLIC_*` values are the only build arguments.
