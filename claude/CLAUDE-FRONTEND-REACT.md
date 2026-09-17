---
paths:
  - "**/*.tsx"
  - "**/*.jsx"
  - "**/src/state/**"
---

# React Frontend Conventions

The React half of the frontend track. Read together with `~/.claude/CLAUDE-FRONTEND.md` (the framework-agnostic core) and the framework file the core's dispatch table names (`CLAUDE-FRONTEND-NEXT.md` or `CLAUDE-FRONTEND-VITE.md`). Everything not covered here follows the core.

---

## Framework & Stack

- **React 19** with functional components only; no class components
- **TypeScript**; strict mode, no `any`
- **TanStack Query** (React Query) for all server state; no raw `useEffect` + `fetch`
- **SCSS Modules** and CSS custom properties for all styling (see `CLAUDE-STYLING.md`); no Tailwind

---

## Directory Vocabulary (React rows)

The shared vocabulary lives in the core. React adds one rule to it:

- Hooks live in `state/`; never a separate `hooks/` directory. Context providers live in `state/` too.

---

## File Naming (React rows)

| What | Convention | Example |
|------|-----------|---------|
| Components | `PascalCase.tsx` | `ChatBox.tsx`, `Header.tsx` |
| Hooks | `camelCase.ts`, `use` prefix | `useAuth.ts`, `useToast.ts` |
| Context providers | `PascalCaseProvider.tsx` | `AuthProvider.tsx` |

---

## Component Patterns

### File Structure (top to bottom)

```typescript
import { useState, useCallback } from 'react';      // 1. React imports
import type { FormEvent } from 'react';             //    Type-only imports use `type`
import { useQuery } from '@tanstack/react-query';   //    Third-party imports
import { fetchMessages } from '@/api/fetchMessages'; //   Local imports (@ alias)
import styles from './ChatBox.module.scss';          //   SCSS module import (always last)

interface ChatBoxProps {                             // 2. Props interface
    tripId: string;
    onSend: (message: string) => void;
}

export default function ChatBox({ tripId, onSend }: ChatBoxProps) {  // 3. Component
    const [input, setInput] = useState('');

    const handleSubmit = useCallback(async (e: FormEvent) => {
        e.preventDefault();
        // ...
    }, []);

    return (                                         // 4. JSX
        <div className={styles.chatBox}>
            {/* ... */}
        </div>
    );
}
```

### Rules

- **Default exports** for all components and pages
- **Named exports** for hooks and services
- **Props interfaces** named `{ComponentName}Props`, defined above the component, in the same file
- **`useCallback`** for event handlers and async functions passed as props
- **Destructure props** in the function signature
- **No inline styles**; use SCSS modules for all styling (see `CLAUDE-STYLING.md`)
- **No React.FC**; use plain function declarations with typed props
- `displayName` and a kebab-case `data-test-id` on every component and page
- Framework directives (`'use client'`) per the framework file; a Vite SPA has none

---

## Import Ordering

The five groups and their order are in the core. In React, group 1 is React plus the framework's own packages (the framework file names them):

```typescript
// 1. React / framework imports
import { useState, useEffect } from 'react';

// 2. Third-party packages
import { useQuery, useMutation } from '@tanstack/react-query';

// 3. Local imports (@ alias paths)
import { fetchTrips } from '@/api/fetchTrips';
import type { Trip } from '@/types/trip';

// 4. Relative imports (sibling components, helpers)
import { formatDate } from './formatDate';

// 5. Style imports (always last)
import styles from './Component.module.scss';
```

---

## State Management

- **TanStack Query** for all server state (fetching, caching, mutations); the client config lives in `config/queryClient.ts`
- **React Context** for auth state and app-wide concerns; providers live in `state/`
- **`useState`** for local UI state (form inputs, modals, toggles)
- **`useCallback`** for memoizing handlers
- **`useRef`** for DOM refs and stable references (EventSource, timers)
- No Redux, Zustand, or other state libraries
- Components consume the API through TanStack Query hooks (`useQuery`, `useMutation`) wrapping the `api/` functions from the core's API Calls section; never a direct `api` call inside an effect
- TanStack Query `onError` callbacks route to the toast (core, Error Handling)

---

## Headless Primitives

- **Radix UI** for dialogs, toasts, menus, and other headless primitives, styled with SCSS modules
- Never `role="button"` on a non-interactive element; use the primitive or a native `<button>`

---

## Formatting (JSX rows)

The Prettier config is in the core. JSX adds one row:

| Rule | Value | Example |
|------|-------|---------|
| Quotes (JSX attrs) | Double (`jsxSingleQuote: false`) | `<div className="foo">` |

---

## ESLint (React rules)

The shared rules are in the core. React adds:

- `react-hooks/rules-of-hooks: 'error'` and `react-hooks/exhaustive-deps: 'warn'`
- `eslint-plugin-jsx-a11y` recommended set
- `eslint-config-next` in Next.js projects; `eslint-plugin-react-refresh` in Vite projects

---

## Testing (React rows)

- **Vitest** with jsdom, React Testing Library, `@testing-library/jest-dom`, and `@testing-library/user-event` for component tests
- Query the DOM by role and accessible name, never by class or test id, except through the `data-test-id` a Playwright test also uses
- Storybook stories for shared components (`components/ui/*`), with visual-regression snapshots run by the Playwright `visual-regression` project
