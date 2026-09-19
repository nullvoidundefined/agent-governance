---
paths:
  - "**/app/pages/**"
  - "**/app/layouts/**"
  - "**/app/middleware/**"
  - "**/app/plugins/**"
  - "**/app/app.vue"
  - "**/server/api/**"
  - "**/server/middleware/**"
  - "**/server/routes/**"
  - "**/server/plugins/**"
  - "**/nuxt.config.*"
---

# Nuxt Frontend Conventions

Framework-specific rules for Nuxt 4 clients. Read together with `~/.claude/CLAUDE-FRONTEND.md` (the shared core) and `~/.claude/CLAUDE-FRONTEND-VUE.md` (the Vue rules); everything not covered here follows those two. This file mirrors `CLAUDE-FRONTEND-NEXT.md` section for section, so a Nuxt client reproduces every convention a Next client carries.

---

## Framework

- **Nuxt 4** with the `app/` source root, the Nitro server engine, and SSR on (the default); no `ssr: false` for a whole app
- Nuxt's own `compatibilityDate` pinned in `nuxt.config.ts`, bumped deliberately in its own commit
- Nitro code under `server/` runs only on the server and never imports from `app/`; shared types live in `shared/types/`

---

## Directory Structure

```
app/
├── app.vue                   # Root component: <NuxtLayout><NuxtPage /></NuxtLayout>
├── error.vue                 # Error page for SSR and client errors
├── pages/                    # File-based routes only; no business logic
│   ├── index.vue
│   ├── login.vue
│   ├── register.vue
│   └── dashboard/index.vue
├── layouts/                  # default.vue, auth.vue, protected.vue
├── middleware/               # Named route middleware (requireSession.ts)
├── plugins/                  # queryClient.ts, sentry.client.ts, theme.client.ts
├── assets/css/main.scss      # CSS custom properties, resets, base styles
├── components/               # Shared UI components (see core)
├── features/                 # Feature slices (see core)
├── composables/              # useX functions (see the Vue file)
├── stores/                   # Pinia stores, only when a project adopts Pinia (see the Vue file)
├── api/                      # Own-backend fetch wrappers (see core)
├── clients/                  # Third-party SDK wrappers (see core)
├── services/                 # Domain logic (see core)
├── config/                   # queryClient.ts, env parsing
├── constants/
├── data/
├── styles/                   # Design tokens, shared SCSS partials
└── types/
server/
├── api/                      # Nitro routes: health.get.ts, the proxies
├── middleware/               # Nitro request middleware (sessionCookieGate.ts)
└── plugins/                  # Nitro plugins (Sentry server init)
shared/types/                 # Types imported by both app/ and server/
```

### Rules

- Pages live in `app/pages/`; everything else under `app/` follows the shared directory vocabulary in the core file
- Directories appear only when occupied (R-309); the vocabulary is fixed, not mandatory on day one
- Page file names are URL segments and take kebab-case per the R-312 exception (`coming-soon.vue`, `[tripId].vue`); every other directory and file follows R-312 camelCase
- Page components stay thin: compose from `features/` and `components/`; no business logic in `pages/`
- `app/utils/` and `server/utils/` are banned (R-306) even though Nuxt auto-imports from them; the `services/` and `clients/` trees take their place

---

## Route Groups and Layouts

Next's parenthesized route groups have no Nuxt directory equivalent. The group becomes a named layout, and each page opts into it:

```vue
<script setup lang="ts">
definePageMeta({ layout: 'protected', middleware: 'require-session' });
</script>
```

- `layouts/default.vue` for public pages, `layouts/auth.vue` for login and register (the `(auth)` group), `layouts/protected.vue` for signed-in pages (the `(protected)` group)
- A layout name is the file name; a middleware name is the file name normalized to kebab-case (`requireSession.ts` is `'require-session'`)
- Shared route-group styles live beside the layout (`layouts/auth.module.scss`)

---

## Auth Gating

Next gates protected routes with edge middleware. Nitro server middleware is not edge middleware: it runs in the same Node process on every request, so it stays a cheap presence check, and the real verification happens once per navigation in the app. Three pieces, each doing one job:

1. **`server/middleware/sessionCookieGate.ts`**: on a full page request for a protected path prefix with no session cookie, `sendRedirect(event, '/login', 302)`. Presence only; it never calls the backend and never parses the cookie. It skips `/api/**` and asset paths.
2. **`app/middleware/requireSession.ts`**: named route middleware on every protected page. It reads the session through `useSessionQuery()` and returns `navigateTo('/login')` when the backend answers 401. It covers client-side navigation, which never reaches Nitro middleware, and an expired cookie that step 1 let through.
3. **`app/layouts/protected.vue`**: renders only after the session query resolves, and the logout mutation's `onSuccess` removes that query from the cache (corrected 2026-09-19: the session lives in the query cache, not in an auth store, now that app state is `useState` composables rather than Pinia).

- The session cookie is `httpOnly`; the browser never reads it, so no client code checks `document.cookie`
- `api/apiClient.ts` exports `createApiClient()`, never a module-level client, and a `useApiClient()` composable memoizes one client per request on `useNuxtApp()` (the Vue file); a module-scope client would capture the first request's cookie and send it on every later user's SSR calls. During SSR it passes the incoming cookie with `headers: useRequestHeaders(['cookie'])`, so the request reaches the backend authenticated; a client created without it drops the cookie. openapi-fetch's `fetch` option takes a standard `fetch`, and `useRequestFetch()` returns Nuxt's `$fetch`, whose call and return shapes differ, so it is not passed there (corrected 2026-09-19: the typed client moved from a hand-written `apiFetch` to openapi-fetch)

---

## Proxies

The browser calls only its own origin. Two Nitro catch-all routes forward the rest:

- `server/api/[...path].ts` proxies `/api/**` to the backend with h3's `proxyRequest(event, target)`, the target built from `runtimeConfig.apiBaseUrl` (server-only); cookies, the `X-Requested-With` header, and the request ID pass through. Before `proxyRequest`, the route rewrites `X-Forwarded-For` to its last entry, the client address the edge appended, because every earlier entry is client-supplied and h3 forwards the header unchanged (added 2026-09-19: the backend's rate limiter keys on the address this chain resolves, `CLAUDE-PYTHON.md` Rate Limiting)
- `server/api/ingest/[...path].ts` proxies PostHog ingestion to `runtimeConfig.posthogHost`, so ad blockers do not drop analytics
- `server/api/health.get.ts` answers the container `HEALTHCHECK` without touching the backend; the specific route wins over the catch-all
- No `routeRules` proxy for the backend: a Nitro route file is visible, testable, and logs through the one logger

---

## Metadata and Fonts

- `useSeoMeta({ title, description, ogTitle })` in each page; `app.head` in `nuxt.config.ts` for site-wide defaults and the title template
- `useHead` only for tags `useSeoMeta` does not cover (the theme script, `link rel="preconnect"`)
- Fonts through `@nuxt/fonts`, exposed as CSS custom properties in `assets/css/main.scss`
- Import ordering group 1 (see the Vue file) is `vue`, `vue-router`, `#imports`, and `#app`

---

## Environment Variables

- `runtimeConfig` in `nuxt.config.ts` declares every variable with an empty default; values come from `NUXT_*` (server-only) and `NUXT_PUBLIC_*` (browser) at run time, so one image serves every environment
- Read through `useRuntimeConfig()`; components never read `process.env` or `import.meta.env`
- The backend URL is server-only (`NUXT_API_BASE_URL`) because the browser reaches it through the proxy; the browser needs only `NUXT_PUBLIC_*` values such as the PostHog key and the Sentry DSN

---

## Theme

- `composables/useThemePreference.ts` holds the theme (`light`, `dark`, `system`, which follows the operating system through a media-query listener) in `useState`, persisted to `localStorage` by `plugins/theme.client.ts` (corrected 2026-09-19: a `useState` composable replaces the Pinia theme store)
- The composable sets the `data-theme` attribute on `<html>`; tokens in `assets/css/main.scss` switch on it (`CLAUDE-STYLING.md`)
- An inline script in `app.head`, added through `useHead` with `tagPosition: 'head'`, reads `localStorage` and sets `data-theme` before first paint so SSR output never flashes the wrong theme

---

## Sentry

- `@sentry/nuxt` module, configured in `sentry.client.config.ts` and `sentry.server.config.ts`, DSN from `NUXT_PUBLIC_SENTRY_DSN`
- The request ID from the backend response header is set as a Sentry tag on the client and bound on the Nitro side (R-341)
- Source maps upload in CI only, never from a developer machine

---

## File Naming (framework-specific rows)

| What | Convention | Example |
|------|-----------|---------|
| Pages | `kebab-case.vue`, `index.vue`, `[param].vue` | `pages/trips/[tripId].vue` |
| Layouts | `camelCase.vue` | `layouts/protected.vue` |
| Route middleware | `camelCase.ts`, verb plus noun | `middleware/requireSession.ts` |
| Plugins | `camelCase.ts`, `.client` or `.server` suffix when side-specific | `plugins/theme.client.ts` |
| Nitro routes | `name.<method>.ts` | `server/api/health.get.ts` |
| Global styles | `main.scss` | `assets/css/main.scss` |

---

## Containers (R-351)

A Nuxt app is a deployable artifact: it ships its `Dockerfile` in the commit that creates it. Build with the Nitro `node-server` preset (the default); the multi-stage image builds on `node:22-alpine`, copies only `.output/` into the runtime stage, runs `USER node`, declares `HEALTHCHECK` against `server/api/health.get.ts` (`/api/health`), and starts with `CMD ["node", ".output/server/index.mjs"]`. `.dockerignore` excludes `.git`, `node_modules`, `.nuxt`, `.output`, `.env*`, and the test trees. Unlike Next's `NEXT_PUBLIC_*`, every `NUXT_PUBLIC_*` value is read at run time, so the image carries no environment-specific build argument. The image is the deploy unit: Railway builds it from the Dockerfile (`CLOUD-DEPLOYMENT.md`), and CI builds and smoke-tests the same image on every pull request.
