# Next.js Frontend Conventions

Framework-specific rules for Next.js App Router clients. Read together with `~/.claude/CLAUDE-FRONTEND.md` (the shared core); everything not covered here follows the core.

---

## Framework

- **Next.js 15+** with **App Router** (`src/app/`); no Pages Router

---

## Directory Structure

```
src/
├── app/                      # App Router pages only; no business logic
│   ├── layout.tsx            # Root layout (metadata, fonts, providers)
│   ├── page.tsx              # Landing / index page
│   ├── globals.scss          # CSS custom properties, resets, base styles
│   ├── (auth)/               # Route group for auth pages
│   │   ├── login/page.tsx
│   │   ├── register/page.tsx
│   │   └── auth.module.scss  # Shared auth styles
│   └── (protected)/          # Route group for authed pages
│       ├── layout.tsx        # Auth-guarded layout
│       └── dashboard/page.tsx
├── components/               # Shared UI components (see core)
├── features/                 # Feature slices (see core)
├── api/                      # Own-backend fetch wrappers (see core)
├── clients/                  # Third-party SDK wrappers (see core)
├── services/                 # Domain logic (see core)
├── state/                    # Stores, hooks, context providers (see core)
├── config/                   # queryClient.ts, env parsing
├── constants/
├── data/
├── styles/                   # Design tokens, shared SCSS partials
└── types/
```

### Rules

- Pages live in `src/app/` following App Router conventions; route groups use parentheses: `(auth)`, `(protected)`
- Everything outside `app/` follows the shared directory vocabulary in the core file
- Directories appear only when occupied (R-309); the vocabulary is fixed, not mandatory on day one
- Route URL segments are kebab-case (`app/coming-soon/`) per the R-312 exception; route groups and every other directory are camelCase
- Page components stay thin: compose from `features/` and `components/`; no business logic in `app/`

### Migration from the pre-split structure

Projects built against the old single-file conventions use `lib/` and a flat `hooks/`; both are banned (R-305/R-306). When touching such a project:

- `lib/api.ts` becomes `api/` modules (transport wrapper plus one fetch function per backend route; see the core's API Calls section)
- `lib/queryClient.ts` becomes `config/queryClient.ts`
- `hooks/` folds into `state/`

---

## `'use client'`

- Directive on every interactive component (has state, handlers, effects), as the first line of the file
- Server components stay the default; add the directive only when the component needs interactivity

---

## Metadata and Fonts

- `layout.tsx` for the root layout: metadata, fonts, global providers
- `loading.tsx` and `error.tsx` boundary files where appropriate
- Metadata exported from server components:
  ```typescript
  export const metadata: Metadata = {
      title: 'App Name',
      description: 'Description here',
  };
  ```
- Font system via `next/font/google` with CSS variable injection
- Import ordering group 1 (see core) is React plus `next/*` imports (`next/link`, `next/font`, `next` types)

---

## Environment Variables

- `NEXT_PUBLIC_*` prefix for anything read in the browser
- API base URL comes from `NEXT_PUBLIC_API_URL`

---

## File Naming (framework-specific rows)

| What | Convention | Example |
|------|-----------|---------|
| Pages | `page.tsx` | `app/dashboard/page.tsx` |
| Layouts | `layout.tsx` | `app/(protected)/layout.tsx` |
| Global styles | `globals.scss` | `app/globals.scss` |
| Route-level styles | `camelCase.module.scss` | `tripDetail.module.scss` |
