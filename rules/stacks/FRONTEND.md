---
paths:
  - "**/src/components/**"
  - "**/src/features/**"
  - "**/src/state/**"
  - "**/src/hooks/**"
  - "**/src/api/**"
  - "**/app/components/**"
  - "**/app/composables/**"
  - "**/app/stores/**"
---

# Frontend Conventions

Framework-agnostic rules for web clients. Read the matching framework files too: `next` in `package.json` means `CLAUDE-FRONTEND-REACT.md` plus `CLAUDE-FRONTEND-NEXT.md`; `vite.config.ts` with `react` means `CLAUDE-FRONTEND-REACT.md` plus `CLAUDE-FRONTEND-VITE.md`; `nuxt.config.ts` means `CLAUDE-FRONTEND-VUE.md` plus `CLAUDE-FRONTEND-NUXT.md`.

The existing repository's architecture wins. The layouts and library choices below are defaults for new code, not migrations; do not restructure an existing app toward them unless the owner asks.

## Stack

- TypeScript in strict mode. No gratuitous `any`: use `unknown` and narrow. A justified `any` or `@ts-expect-error` carries a one-line reason.
- Use the repo's existing server-state layer (TanStack Query in the standard stacks). Do not hand-roll fetch-in-effect, and do not replace the layer with another.
- Use the repo's existing state-management layer. Do not add Redux, Zustand or another store library, and do not copy server state into app state.
- Avoid unnecessary dependencies. Every new package needs a reason the platform or an existing dependency cannot cover.

## Styling policy

- SCSS Modules (`.module.scss`) plus CSS custom properties are the default for all JS/TS frontend styling.
- Do not introduce Tailwind or any utility-first CSS framework, CSS-in-JS (styled-components, emotion, vanilla-extract, inline style objects), or any other styling framework or component-styling library, unless the owner explicitly asks for it. A new styling package is an owner decision.
- If the repository already uses a different styling system, keep using it and match it. Do not migrate it, mix a second system in, or convert it to SCSS Modules without an explicit owner request.
- Extend the existing design tokens, custom properties, mixins and partials. Do not replace them, fork a parallel token set, or hardcode a value a token already names.
- No BEM, no plain `.css` for new component styles, no `classnames`/`clsx`.

Details: `CLAUDE-STYLING.md`.

## Layout for new frontends

- Source root holds `components/` (one folder per component: `Header/Header.tsx` plus `Header.module.scss`), `features/`, `api/`, `clients/`, `services/`, `state/` (Vue: `composables/`, `stores/`), `config/`, `constants/`, `data/`, `styles/`, `types/`. Directories appear only when occupied.
- No `lib/`, `utils/` or `helpers/` catch-alls; classify into `api/`, `clients/`, `services/` or the state directory. No `index.ts` barrel files.
- Use the repo's source-root alias (`@/`) over deep relative paths.
- No import cycles: enable `import-x/no-cycle` with the settings in `CLAUDE-BACKEND.md` "Layers"; without them the rule silently reports nothing.
- Derive types shared with the backend from the schema (`z.infer`, generated OpenAPI types) instead of duplicating them.

## Components

Keep components small and cohesive. Split one when it mixes data fetching, layout and behavior, or when a piece is reusable on its own. There is no line-count target.

## Server/client boundary

- Own-backend calls go through one typed transport module in `api/`, one exported function per route. It sets `credentials: 'include'` and `X-Requested-With: XMLHttpRequest` (the backend CSRF guard rejects requests without it) and throws with the server's error message.
- Components consume those functions through the server-state layer's query and mutation hooks, never by calling them inside an effect or lifecycle hook.
- Components never read env directly; the base URL and other config come from the framework's env module.
- API and server errors go to the toast; inline errors are for form-field validation only. Never show raw error text or a stack trace to the user.

## E2E tests (Playwright)

- A user flow is not shipped until an E2E test exercises it. For each feature, name the test that would fail if it broke; if there is none, the feature is untested.
- Playwright `projects` include chromium, webkit and mobile-safari (a real iPhone profile). A chromium-only suite let a Safari ITP bug reach production.
- `fullyParallel: true`. A spec that cannot run in parallel gets isolated users and data, not `workers: 1`.
- Mock external APIs (LLMs, search, payments) in the main suite; real third-party calls belong in a separate nightly smoke suite.
- Assert the data the user sees or the state the server holds, never element presence alone.
- Before a local run, stop stale dev servers on the E2E ports, or set `reuseExistingServer: false` so Playwright fails loudly. A stale server silently broke the `webServer` config once.
- If the repo has `docs/USER_STORIES.md`, E2E specs live in `e2e/` and mirror its sections.
