---
paths:
  - "**/src/app/**/*.ts"
  - "**/src/app/**/*.tsx"
  - "**/next.config.*"
---

# Next.js Conventions

Read with `CLAUDE-FRONTEND.md` and `CLAUDE-FRONTEND-REACT.md`.

- New projects use the App Router. An existing Pages Router app keeps it until the owner asks to migrate.
- Server components are the default. Add `'use client'` as the first line only on a component that has state, handlers or effects, and keep the client subtree small.
- Pages stay thin: compose from `features/` and `components/`; no business logic in `app/`. Everything outside `app/` follows the core layout.
- `NEXT_PUBLIC_*` is for values the browser reads. They are inlined at build time, so they never carry a secret.
- Load fonts with `next/font` and expose them as CSS custom properties.
- Containers: set `output: "standalone"`. `NEXT_PUBLIC_*` values are build arguments, the one exception to run-time-only configuration.

## Known traps (Vercel and pnpm)

- In a pnpm monorepo, set `outputFileTracingRoot: path.resolve(__dirname, '..')` in `next.config.ts`. Without it, dynamic routes work locally and return 500 on Vercel because the bundler cannot find the hoisted `node_modules`.
- `pnpm.autoInstallPeers: true` installs optional peers too; suppress an unwanted one with a `pnpm.overrides` entry of `"pkg": "-"` (removes the dependency).
- `@playwright/test` anywhere in a Next.js app's dependency tree causes `Cannot find module 'next/dist/compiled/source-map'` on Vercel. Keep Playwright in the monorepo root `devDependencies` only.
- Delete passthrough `middleware.ts` (or `proxy.ts`) files: one that only calls `NextResponse.next()` still adds a hop to every request.
- Add an `error.tsx` boundary to a route that returns unexplained 500s; it surfaces the real error instead of leaving the route to be debugged blind.
