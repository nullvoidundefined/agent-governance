---
paths:
  - "**/*.vue"
  - "**/app/components/**"
  - "**/app/composables/**"
  - "**/app/stores/**"
---

# Vue Frontend Conventions

The Vue half of the frontend track. Read together with `~/.claude/CLAUDE-FRONTEND.md` (the framework-agnostic core) and the framework file the core's dispatch table names (`CLAUDE-FRONTEND-NUXT.md` for Nuxt projects). Everything not covered here follows the core. Nothing in `CLAUDE-FRONTEND-REACT.md` applies to a Vue project.

---

## Framework & Stack

- **Vue 3.5 or later** (reactive props destructure and `useTemplateRef` below need it; Nuxt 4 already requires it) with the Composition API and `<script setup lang="ts">` only; no Options API, no `defineComponent({ setup() })` objects, no plain `<script>` blocks without `setup`
- **TypeScript**; strict mode, no `any`, `vue-tsc --noEmit` in CI next to `tsc`
- **TanStack Query for Vue** (`@tanstack/vue-query`) for all server state; no `fetch` inside `onMounted` or a `watch`
- **Pinia** for app state that outlives one component
- **Reka UI** (the Vue port of the Radix headless primitives) for dialogs, toasts, menus, popovers, and tabs
- **SCSS Modules** in a sibling `.module.scss` file and CSS custom properties for all styling (see `CLAUDE-STYLING.md`); no Tailwind, no `<style>` block inside the SFC

---

## Directory Vocabulary (Vue rows)

The shared vocabulary lives in the core. Under Nuxt the source root is `app/`, and Vue replaces the React `state/` directory with two directories:

- `composables/` holds every `useX` function: query wrappers, reactive helpers, DOM behavior. It is the Vue analog of React hooks and is never named `hooks/`.
- `stores/` holds Pinia stores, one store per file, one domain per store.
- `utils/` is banned here as everywhere (R-306), even though Nuxt auto-imports from `app/utils/`; pure functions go to `services/`.

---

## File Naming (Vue rows)

| What | Convention | Example |
|------|-----------|---------|
| Components | `PascalCase.vue`, multi-word | `ChatBox.vue`, `AppHeader.vue` |
| Composables | `camelCase.ts`, `use` prefix | `useTripsQuery.ts`, `useToast.ts` |
| Pinia stores | `camelCase.ts`, `Store` suffix; the store's id is the noun | `themeStore.ts` exporting `useThemeStore`, id `'theme'` |
| Component tests | `PascalCase.test.ts` beside the component | `ChatBox.test.ts` |

A component folder repeats the component name (`components/ChatBox/ChatBox.vue`); Nuxt's component auto-registration collapses the duplicated segment, so the tag is `<ChatBox>`, not `<ChatBoxChatBox>`.

---

## Component Patterns

### File Structure (top to bottom)

```vue
<script setup lang="ts">
import { computed, ref } from 'vue';                    // 1. Framework imports
import type { Ref } from 'vue';                         //    Type-only imports use `type`
import { useMutation } from '@tanstack/vue-query';      // 2. Third-party imports
import { sendMessage } from '@/api/sendMessage';        // 3. Local imports (@ alias)
import styles from './ChatBox.module.scss';             // 5. SCSS module import (always last)

defineOptions({ name: 'ChatBox' });                     // Component name (see Rules)

interface Props {                                       // Props interface
    tripId: string;
    isDisabled?: boolean;
}

interface Emits {                                       // Emits interface
    (event: 'sent', messageId: string): void;
}

const { tripId, isDisabled = false } = defineProps<Props>();
const emit = defineEmits<Emits>();

const draftMessage = ref('');
const canSend = computed(() => draftMessage.value.trim().length > 0 && !isDisabled);

const sendMutation = useMutation({
    mutationFn: (body: string) => sendMessage(tripId, body),
    onSuccess: (sentMessage) => emit('sent', sentMessage.id),
});

function submitDraftMessage() {
    sendMutation.mutate(draftMessage.value);
    draftMessage.value = '';
}
</script>

<template>
    <form :class="styles.chatBox" data-test-id="chat-box" @submit.prevent="submitDraftMessage">
        <!-- ... -->
        <button type="submit" :disabled="!canSend">Send</button>
    </form>
</template>
```

### Rules

- **Block order:** `<script setup lang="ts">` first, `<template>` second; no `<style>` block (styles live in the sibling `.module.scss`)
- **Props** declared with the type-only form `defineProps<Props>()`, the interface named `Props` above it in the same file; destructure with defaults in the declaration (reactive props destructure), never `withDefaults` in new code
- **Emits** declared with `defineEmits<Emits>()` using the call-signature form; event names are kebab-case in templates and camelCase in the signature
- **`ref`** for primitives and reassigned values, **`computed`** for derived values; `reactive` only for a local object never reassigned or destructured
- **Explicit imports** from `vue` and `#imports`, even though Nuxt auto-imports them, so every file type-checks and lints on its own and a reader sees where each name comes from
- **Handlers** are named functions in `<script setup>` (verb plus noun, R-316); no multi-statement inline handlers in the template
- **No inline styles** and no `style` bindings except for a runtime-computed CSS custom property (`:style="{ '--progress': progressRatio }"`)
- **Component name** set with `defineOptions({ name })` on every component, and a kebab-case `data-test-id` on each component's root element and every page's root element
- **`v-for`** always carries a stable `:key` from the data, never the index; never `v-if` and `v-for` on the same element
- **`v-html`** is banned unless the input passes a sanitizer in `services/`; the call site names the sanitizer
- **Slots** over render props; typed with `defineSlots<{ default(props: { item: Trip }): unknown }>()` when a slot passes props
- **`provide`/`inject`** only through a typed `InjectionKey` exported from the providing composable; never string keys

---

## Import Ordering

The five groups and their order are in the core. In Vue, group 1 is `vue`, `vue-router`, and Nuxt's own `#imports` and `#app` virtual modules:

```typescript
// 1. Framework imports
import { computed, ref } from 'vue';
import { useRoute } from 'vue-router';
import { useRuntimeConfig } from '#imports';

// 2. Third-party packages
import { useQuery } from '@tanstack/vue-query';
import { storeToRefs } from 'pinia';

// 3. Local imports (@ alias paths)
import { fetchTrips } from '@/api/fetchTrips';
import type { Trip } from '@/types/trip';

// 4. Relative imports (sibling components, helpers)
import TripCard from './TripCard/TripCard.vue';

// 5. Style imports (always last)
import styles from './TripList.module.scss';
```

---

## State Management

- **TanStack Query for Vue** for all server state (fetching, caching, mutations); the `QueryClient` config lives in `config/queryClient.ts` and is installed once by a Nuxt plugin
- Every query is wrapped in a composable (`composables/useTripsQuery.ts`) that owns the query key and calls the `api/` function; components never build query keys inline
- **Pinia** setup stores (`defineStore('theme', () => { ... })`) for app state: theme, UI state shared across routes. Never copy query data into a store; the query cache is the only copy of server state
- Reading several store fields destructures through `storeToRefs(store)` so the fields stay reactive (R-325); actions are called on the store, never destructured off it
- **`ref` and `computed`** for component-local state (form inputs, open panels, toggles)
- Template refs through `useTemplateRef('name')`; timers and `EventSource` handles in a plain `let` cleared in `onBeforeUnmount`
- No Vuex, no event bus, no global mutable module state
- Query and mutation `onError` callbacks route to the toast (core, Error Handling)

---

## Headless Primitives

- **Reka UI** for dialogs, toasts, menus, popovers, tabs, and every other headless primitive, styled with SCSS modules through the `class` prop
- The toast lives in one `components/ToastRegion/` wrapper around Reka UI's `ToastProvider` and is driven by `useToast()`
- Never `role="button"` on a non-interactive element; use the primitive or a native `<button>`

---

## Formatting (Vue rows)

The Prettier config is in the core. Vue adds:

| Rule | Value | Example |
|------|-------|---------|
| Template attribute quotes | Double (Prettier's fixed behavior for Vue templates) | `<div class="foo">` |
| Script and template indent | `vueIndentScriptAndStyle: false` | `<script setup>` body starts at column 0 |

---

## ESLint (Vue rules)

The shared rules are in the core. Vue adds, through `eslint-plugin-vue` and `vue-eslint-parser` with `@typescript-eslint/parser` for the script block:

- `plugin:vue/recommended` (the strictest preset)
- `vue/block-order: ['error', { order: ['script', 'template'] }]`
- `vue/multi-word-component-names`: on for components; pages, layouts, and `error.vue` are exempt because Nuxt derives their names from routes
- `vue/define-macros-order`: `defineOptions`, `defineProps`, `defineEmits`, `defineSlots`
- `vue/no-v-html: 'error'` (the sanitizer rule above is the only exception, with an inline disable naming it)
- `vuejs-accessibility` recommended set, the Vue analog of `jsx-a11y`

---

## Testing (Vue rows)

- **Vitest** with `happy-dom`, `@vue/test-utils`, and `@testing-library/vue` for component tests; `@nuxt/test-utils` with `mountSuspended` for any component that needs the Nuxt runtime (auto-imports, `useRuntimeConfig`, route)
- Query the DOM by role and accessible name, never by class or test id, except through the `data-test-id` a Playwright test also uses
- Pinia stores are tested through `createTestingPinia` only when the store is a collaborator; a store under test uses a real `createPinia()`
- Storybook (`@storybook/vue3-vite`) stories for shared components (`components/ui/*`), with visual-regression snapshots run by the Playwright `visual-regression` project
