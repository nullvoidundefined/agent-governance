# Frontend Conventions

These rules apply to all `web-client/` and frontend packages across every app in this portfolio.

---

## Framework & Stack

- **Next.js 15** with App Router (`src/app/`)
- **React 19** with functional components only; no class components
- **TypeScript**; strict mode, no `any`
- **SCSS Modules** for all component styling (see `CLAUDE-STYLING.md`)
- **TanStack Query** (React Query) for all server state; no raw `useEffect` + `fetch`
- **No Tailwind**; all styling through SCSS modules and CSS custom properties

---

## Directory Structure

```
src/
├── app/                          # Next.js App Router pages
│   ├── layout.tsx                # Root layout (metadata, fonts, providers)
│   ├── page.tsx                  # Landing / index page
│   ├── globals.scss              # CSS custom properties, resets, base styles
│   ├── (auth)/                   # Route group for auth pages
│   │   ├── login/page.tsx
│   │   ├── register/page.tsx
│   │   └── auth.module.scss      # Shared auth styles
│   └── (protected)/              # Route group for authed pages
│       ├── layout.tsx            # Auth-guarded layout
│       └── dashboard/page.tsx
├── components/                   # Shared UI components
│   ├── Header/
│   │   ├── Header.tsx
│   │   └── Header.module.scss
│   ├── Footer/
│   │   ├── Footer.tsx
│   │   └── Footer.module.scss
│   └── Toast/
│       ├── Toast.tsx
│       └── Toast.module.scss
├── hooks/                        # Custom React hooks
│   └── useAuth.ts
├── lib/                          # Utilities and API client
│   ├── api.ts                    # Fetch wrapper (typed, credentials, error handling)
│   └── queryClient.ts            # TanStack Query client config
└── types/                        # Shared TypeScript types (frontend-only)
    └── index.ts
```

### Rules

- Each component gets its own folder: `ComponentName/ComponentName.tsx` + `ComponentName.module.scss`
- Pages live in `src/app/` following Next.js App Router conventions
- Route groups use parentheses: `(auth)`, `(protected)`
- Hooks go in `src/hooks/`, utilities in `src/lib/`
- No `index.ts` barrel files; import directly from the file

---

## File Naming

| What | Convention | Example |
|------|-----------|---------|
| Components | `PascalCase.tsx` | `ChatBox.tsx`, `Header.tsx` |
| SCSS modules | `PascalCase.module.scss` | `ChatBox.module.scss` |
| Pages | `page.tsx` (Next.js convention) | `app/dashboard/page.tsx` |
| Layouts | `layout.tsx` | `app/(protected)/layout.tsx` |
| Hooks | `camelCase.ts` | `useAuth.ts`, `useToast.ts` |
| Utilities | `camelCase.ts` | `api.ts`, `queryClient.ts` |
| Types | `camelCase.ts` | `index.ts` |
| Global styles | `globals.scss` | `app/globals.scss` |
| Route-level styles | `camelCase.module.scss` | `tripDetail.module.scss` |

---

## Component Patterns

### File Structure (top to bottom)

```typescript
'use client';                                      // 1. Directive (if needed)

import { useState, useCallback } from 'react';     // 2. React imports
import type { FormEvent } from 'react';            //    Type-only imports use `type`
import Link from 'next/link';                      //    Next.js imports
import { useQuery } from '@tanstack/react-query';  //    Third-party imports
import { api } from '@/lib/api';                   //    Local imports (@ alias)
import styles from './ChatBox.module.scss';         //    SCSS module import (always last)

interface ChatBoxProps {                             // 3. Props interface
    tripId: string;
    onSend: (message: string) => void;
}

export default function ChatBox({ tripId, onSend }: ChatBoxProps) {  // 4. Component
    const [input, setInput] = useState('');

    const handleSubmit = useCallback(async (e: FormEvent) => {
        e.preventDefault();
        // ...
    }, []);

    return (                                        // 5. JSX
        <div className={styles.chatBox}>
            {/* ... */}
        </div>
    );
}
```

### Rules

- **Default exports** for all components and pages
- **Named exports** for hooks and utilities
- **Props interfaces** named `{ComponentName}Props`, defined above the component
- **`'use client'`** directive on every interactive component (has state, handlers, effects)
- **`useCallback`** for event handlers and async functions passed as props
- **Destructure props** in the function signature
- **No inline styles**; use SCSS modules for all styling (see `CLAUDE-STYLING.md`)
- **No React.FC**; use plain function declarations with typed props

---

## Import Ordering

Imports are grouped with blank lines between groups, in this order:

```typescript
// 1. React / Next.js
import { useState, useEffect } from 'react';
import type { Metadata } from 'next';
import Link from 'next/link';

// 2. Third-party packages
import { useQuery, useMutation } from '@tanstack/react-query';

// 3. Local imports (@ alias paths)
import { api } from '@/lib/api';
import type { Trip } from '@/types';

// 4. Relative imports (sibling components, utils)
import { formatDate } from './utils';

// 5. Style imports (always last)
import styles from './Component.module.scss';
```

- Use `type` keyword for type-only imports: `import type { Foo } from '...'`
- Sort specifiers alphabetically within each import
- Use `@/` path alias for `src/` imports; never relative `../../` beyond one level

---

## TypeScript Patterns

- **Interfaces** for component props: `interface FooProps { ... }`
- **Types** for unions and utility types: `type Status = 'idle' | 'loading' | 'error'`
- **Zod-inferred types** when shared with backend: `type Job = z.infer<typeof jobSchema>`
- Props interfaces live in the same file as the component, above the component
- Shared types go in `src/types/`
- Never use `any`; use `unknown` and narrow

---

## State Management

- **TanStack Query** for all server state (fetching, caching, mutations)
- **React Context** for auth state and app-wide concerns
- **`useState`** for local UI state (form inputs, modals, toggles)
- **`useCallback`** for memoizing handlers
- **`useRef`** for DOM refs and stable references (EventSource, timers)
- No Redux, Zustand, or other state libraries

---

## API Calls

All API calls go through a typed fetch wrapper in `src/lib/api.ts`:

```typescript
export const api = {
    get: <T>(path: string) => apiFetch<T>(path),
    post: <T>(path: string, json: unknown) => apiFetch<T>(path, { method: 'POST', json }),
    patch: <T>(path: string, json: unknown) => apiFetch<T>(path, { method: 'PATCH', json }),
    del: (path: string) => apiFetch(path, { method: 'DELETE' }),
};
```

- Base URL from `NEXT_PUBLIC_API_URL` env var
- `credentials: 'include'` on every request
- `X-Requested-With: XMLHttpRequest` header for CSRF
- Errors throw with the server's error message
- Components use TanStack Query hooks, not direct api calls in effects

---

## Error Handling

- **Toast component** for API/server errors; never show raw error text inline
- **Inline errors** only for form validation (field-level messages)
- TanStack Query `onError` callbacks route to toast
- Never show stack traces to the user

---

## Next.js Patterns

- App Router only; no Pages Router
- `layout.tsx` for root layout (metadata, fonts, global providers)
- Route groups `(auth)`, `(protected)` for shared layouts
- `loading.tsx` and `error.tsx` boundary files where appropriate
- Metadata exported from server components:
  ```typescript
  export const metadata: Metadata = {
      title: 'App Name',
      description: 'Description here',
  };
  ```
- Font system via `next/font/google` with CSS variable injection

---

## Formatting (Prettier)

```json
{
    "singleQuote": true,
    "jsxSingleQuote": false,
    "semi": true,
    "trailingComma": "all",
    "tabWidth": 4,
    "useTabs": false,
    "printWidth": 100,
    "arrowParens": "always",
    "bracketSpacing": true
}
```

| Rule | Value | Example |
|------|-------|---------|
| Quotes (JS/TS) | Single | `const x = 'hello';` |
| Quotes (JSX attrs) | Double | `<div className="foo">` |
| Semicolons | Always | `const x = 1;` |
| Trailing commas | All | `{ a: 1, b: 2, }` |
| Indentation | 4 spaces | (n/a) |
| Line width | 100 chars | (n/a) |
| Arrow parens | Always | `(x) => x` |
| Bracket spacing | Yes | `{ x: 1 }` not `{x:1}` |

---

## ESLint Rules

- `@typescript-eslint/naming-convention`: camelCase for functions/variables, PascalCase for types/components
- `curly: 'error'`; always use braces
- No unused imports (eslint-plugin-unused-imports)
- No explicit `any`

---

## E2E Test Layout (Playwright)

End-to-end tests live in `e2e/` at the repo root and follow a **user-story-driven hybrid structure**.

### Coverage rule

Every user story documented in `docs/USER_STORIES.md` MUST have exactly one mapped E2E test. Include 2-3 journey tests covering realistic multi-story flows.

### Spec file grouping

Group spec files by the `## Section` headings in `docs/USER_STORIES.md`. **Do
not invent section groupings**; read the full user stories file and mirror
its actual sections. If the file has sections `Public Pages`, `Authentication`,
`Trip Management`, etc., the spec files are:

```
e2e/
├── public-pages.spec.ts      ; stories in "Public Pages" section
├── auth.spec.ts              ; stories in "Authentication" section
├── trip-management.spec.ts   ; stories in "Trip Management" section
├── ...                       ; one spec file per section heading
└── journeys/
    ├── happy-path.spec.ts    ; realistic multi-story success flow
    ├── returning-user.spec.ts; returning-user iteration flow
    └── failure-path.spec.ts  ; documented error flows only (no invented stories)
```

### Test naming

Each `test()` name starts with the user story ID:

```typescript
test.describe('Public pages', () => {
    test('US-1: home page discovery', async ({ page }) => { ... });
    test('US-2: browse destinations', async ({ page }) => { ... });
});
```

### Fixtures and helpers

```
e2e/
├── fixtures/  ; mock data for external APIs, seeded test users
└── helpers/   ; page objects, auth helpers, common interaction helpers
```

### Rules

- **One test per user story.** Exactly one. Test names include the `US-N:` prefix.
- **Mirror the user-stories file's sections.** Do not invent categories.
- **No invented stories.** Journey tests reference only documented user stories. If a journey needs a story that doesn't exist yet, add it to `USER_STORIES.md` first; do not fake it in the test.
- **Error paths live inside their story's test**, not in a dedicated
  `error-states.spec.ts`. Example: "failed login" is a documented story
  (e.g., US-10) and belongs in `auth.spec.ts`, not in a separate file.
- **Journey tests** (2–3 per project) cover multi-story realistic flows:
  happy-path success, returning-user iteration, documented failure path.
- **Mock external APIs in E2E.** Real third-party calls (LLMs, search APIs, payment processors) belong in a separate nightly real-API smoke suite, not the main E2E run.
- **Tag fast-lane tests with `@fast`** in the test name so pre-push hooks can
  `--grep '@fast'` for a < 30s subset. Include: smoke test, auth spec, and
  one happy-path journey test.
