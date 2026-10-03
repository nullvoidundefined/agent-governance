# E. Stack files: frontend, styling, Go, Ruby, structure-conventions

Baseline: /home/user/ag-main/claude (post-IAN-568). Comparison: /home/user/agent-governance/claude (branch claude/streamline, "trim").
Classes: KI = KEEP-INVARIANT, KINC = KEEP-INCIDENT, MOVE, RT = REMOVE-TOOLING, RO = REMOVE-OBSOLETE, RC = REMOVE-CEREMONY, RW = REWRITE.
Sizes (baseline / trim lines): FRONTEND 257/60, REACT 158/59, NEXT 117/38, VITE 95/32, VUE 195/78, NUXT 163/50, STYLING 429/63, GO 290/81, RUBY 256/73, structure-conventions 57/36.

Global findings that apply to every table:
- "R-nnn" ids appear inline in nearly every baseline sentence ("(R-305)", "per R-315"). Every id is RC as a citation; the underlying sentence is classified on its own merit and the id is dropped in the proposed text. The rulebook (rulebook/reference.md) holds the ids; a stack file should not need them.
- Enforcer reality (checked): the only mechanical frontend enforcement is structure-gate.sh (creation-time deny of catch-all dirs, loose components/*.tsx|vue, co-located tests; dir-case and abbreviation now warn), dependency-add-guard.sh (asks on ANY new package, name-agnostic), and push-eslint-gate (enforce/eslint.config.mjs: no-explicit-any, ban-ts-comment, sort-keys, member-ordering, no-magic-numbers, no-restricted-syntax). The harness eslint config does NOT enforce curly, naming-convention, unused-imports, jsx-a11y; react-hooks/exhaustive-deps is set to NOOP there. Those rules in the stack files describe the PROJECT's own lint config.
- Nothing anywhere (hook, eslint, skill, CLAUDE.md, agents) enforces the styling preference. `grep -i tailwind|css-in-js|styled-comp` over claude/{hooks,enforce,CLAUDE.md,agents,PROTOCOL.md} finds only agents/audit-design.md line 50, which names "Tailwind config" neutrally. The styling preference lives only in prose in 4 convention files.

---------------------------------------------------------------------------------------------------
## 1. STYLING PREFERENCE: precise audit and proposed text (read this first)

### How strongly it is stated now (baseline)
| Where | Text | Gap |
|---|---|---|
| CLAUDE-STYLING.md Stack | "SCSS Modules for all component styles"; "No Tailwind; never use utility classes"; "No CSS-in-JS; no styled-components, emotion, or inline style objects"; "No plain CSS" | Strong but absolute and unconditional: no "unless owner asks / repo already uses it" clause, so it contradicts "existing repository architecture wins" in a Tailwind or Emotion repo. No "extend existing tokens" rule. |
| CLAUDE-FRONTEND.md Stack | "SCSS Modules for all component styling"; "No Tailwind; all styling through SCSS modules and CSS custom properties" | Same. Does not name CSS-in-JS or "another styling framework". |
| CLAUDE-FRONTEND-REACT.md | "SCSS Modules and CSS custom properties for all styling; no Tailwind"; "No inline styles" | No CSS-in-JS ban. |
| CLAUDE-FRONTEND-VUE.md | "SCSS Modules ... no Tailwind, no `<style>` block inside the SFC" | Same. |
| NEXT / VITE / NUXT | only `globals.scss` / `main.scss` file naming | Silent. |
| Loading | CLAUDE-STYLING.md `paths:` is only `**/*.scss` and `**/*.module.css`. | **It does not load when editing a .tsx/.vue component**, which is exactly where a model reaches for Tailwind classes or styled-components. Only the one-line "No Tailwind" in FRONTEND/REACT/VUE (loaded on tsx/vue/components paths) covers that moment. This is the real structural weakness. |
| Enforcement | none (see global findings) | A `tailwindcss`/`styled-components`/`@emotion/*`/`clsx` add only triggers the generic R-331 "new dependency" ask, which does not name the styling policy. |

### What the trim (claude/streamline) did to it
- STYLING trim: kept "No Tailwind or utility classes, no BEM, no CSS-in-JS (styled-components, emotion, inline style objects), no plain CSS" (one bullet). Not weakened in substance; still unconditional, still scss-path-only loading.
- FRONTEND trim: kept "SCSS Modules plus CSS custom properties for all styling (see CLAUDE-STYLING.md). No Tailwind."
- REACT trim: **dropped** the "no Tailwind" mention entirely (keeps only "No inline styles; use SCSS modules"). Weakened at the .tsx path, the most important one.
- VUE trim: kept "no `<style>` block and no Tailwind".
- Trim also dropped: `:class` array example block in STYLING (kept in one line), "never `classnames`/`clsx`" (kept), px/typography detail (compressed). None of that is the preference.
- Net: trim did not add the owner's exceptions, did not fix the loading gap, and removed the React mention. Neither version states "extend existing tokens".

### Proposed text (exact)
Put the block below verbatim at the TOP of CLAUDE-STYLING.md (replace the "Stack" section's first bullets) and as the "Styling" bullet of CLAUDE-FRONTEND.md "Stack". Framework files (REACT, VUE) keep one pointer line only: "Styling follows the Styling policy in CLAUDE-FRONTEND.md." (no per-framework restatement, so there is one source of truth).

```
## Styling policy

- SCSS Modules (`.module.scss`) plus CSS custom properties are the default for all JS/TS frontend styling.
- Do not introduce Tailwind or any utility-first CSS framework, CSS-in-JS (styled-components, emotion, vanilla-extract, inline style objects), or any other styling framework or component-styling library, unless the owner explicitly asks for it. A new package for styling is an owner decision, not an implementation detail.
- If the repository already uses a different styling system, keep using it and match it. Do not migrate it, mix a second system in, or "fix" it to SCSS Modules. Replacing an established system needs an explicit owner request.
- Extend the existing design tokens, custom properties, mixins and partials; do not replace them, fork a parallel token set, or hardcode values a token already names.
- No BEM, no plain `.css` for new component styles (SCSS), no `classnames`/`clsx` (template literals; the array form in Vue).
```
Notes on wording: "unless the owner explicitly asks" and "already uses ... replacing it would be inappropriate" are the owner's two exceptions, stated once. The BEM/`classnames` line is a house style, kept short. Drop "never use utility classes" (the `.srOnly` class is a utility; the sentence is self-contradicting).

### Where it belongs / what else to change
1. CLAUDE-STYLING.md (full block) and CLAUDE-FRONTEND.md Stack (same block, or a 3-line version plus pointer).
2. **Widen CLAUDE-STYLING.md `paths:`** to add `**/*.tsx`, `**/*.jsx`, `**/*.vue` (or have REACT/VUE, which already load on those, carry a one-line pointer). Without this the full policy is not in context when a component is written. Cheapest fix: the one-line pointer in REACT and VUE plus the block in FRONTEND.md (loads on components/features/state/api).
3. Optional enforcement, ONLY if the owner wants a mechanical backstop (they asked for a preference, not a gate; the 1:1 budget says do not add one by default): extend dependency-add-guard.sh's ask message to name `tailwindcss|styled-components|@emotion|@stitches|@vanilla-extract|@mui|@chakra-ui|clsx|classnames` and say "styling policy: owner decision". It already asks on every new package, so this is a message change, not a new gate. Do NOT add a deny: that would violate the "repo already uses it" exception.
4. agents/audit-design.md line 50 is neutral ("whichever styling system the project uses"); leave it, it is consistent with the exception.
5. cursor/ and codex/ ports are generated from claude/ (translate/*.mjs); regenerate, do not hand-edit.

---------------------------------------------------------------------------------------------------
## 2. CLAUDE-FRONTEND.md (257 lines baseline, 60 trim)

| Excerpt | Class | Reason | Proposed text |
|---|---|---|---|
| Intro: rules apply to all frontend packages "across every app in this portfolio" | RC | portfolio framing, no instruction | drop |
| Framework Files dispatch table (markers -> files) | KI | routing between files; needed so the right framework file loads | keep, shorten to one line per framework |
| Stack: TypeScript strict mode, no `any` | KI | owner-preserved; harness eslint no-explicit-any only at push | "TypeScript in strict mode. No gratuitous `any`: use `unknown` and narrow; a justified `any` or `@ts-expect-error` carries a one-line reason." (RW to match owner's "gratuitous", and to match R-329's actual allowance) |
| Stack: SCSS Modules for all component styling | RW | see Section 1 | replace with Styling policy block (Section 1) |
| Stack: server-state cache (TanStack Query) for all server state; no fetch-in-effect | RW | owner: use existing server-state layer rather than replacing; as written it mandates TanStack | "Use the repo's existing server-state layer (TanStack Query in the standard stacks); do not hand-roll fetch-in-effect and do not replace the layer with another" |
| Stack: No Tailwind | RW | see Section 1 | folded into policy block |
| Directory Vocabulary tree + "(R-305)" | RW | good default layout for NEW code; owner says existing architecture wins; structure-gate already fires on creation only | "Default layout for new frontends (existing repositories keep their own structure): components/ (one folder per component), features/, api/, clients/, services/, state/ ..." keep the 11-name list inline, drop the ASCII tree |
| Each component gets its own folder `X/X.<ext>` + `X.module.scss` | KI | enforced by structure-gate (loose-component deny) | keep (one line) |
| Never `lib/`, `utils/`, `helpers/` catch-alls (R-306) | KI | global rule in CLAUDE.md (dependencies/no catch-alls) and structure-gate; here only the frontend classification | keep one line: "classify into api/, clients/, services/ or state/"; drop id |
| Directories appear only when occupied (R-309) | KI | cheap, true | keep, drop id |
| No `index.ts` barrel files | KI | architectural (tree-shaking, circular imports), enforced by nothing | keep |
| File Naming table (PascalCase.module.scss; camelCase.ts per R-315; types camelCase.ts) | RC | naming-by-case table; prettier/eslint naming-convention class of rule, no incident; R-315 reference | keep only "name modules for what they do" (already global CLAUDE.md "name files for responsibility"); MOVE-to-global covered |
| Import Ordering: 5 groups, blank lines | RT | eslint `import/order` / prettier-plugin-sort-imports owns this | delete; if wanted: "follow the repo's import-order lint config" |
| `type` keyword for type-only imports | RT | `@typescript-eslint/consistent-type-imports` + `verbatimModuleSyntax` | delete |
| Sort specifiers alphabetically | RT | eslint `sort-imports` / sort plugin | delete |
| `@/` alias, never `../../` beyond one level | RW | real architecture hygiene but alias must exist in the repo | "Use the repo's source-root alias (`@/`) over deep relative paths" |
| Interfaces for props; types for unions | RC | taste; TypeScript has no semantic difference at this use | delete (trim kept it; drop) |
| Zod-inferred types when shared with backend | KI | single source of truth for shared shapes | keep: "Derive shared types from the schema (`z.infer`) instead of duplicating them" |
| Props types in same file above component | RC | layout taste | delete |
| Shared types go in `types/` | KI | part of vocabulary; fold into layout line | fold |
| Never `any`; use `unknown` and narrow (TS Patterns) | RT | duplicate of Stack line and eslint no-explicit-any | delete (single statement in Stack) |
| API Calls: one transport module + one module per route (R-306/R-319) | RW | good invariant (typed transport boundary) but hard-codes `apiFetch` name; Vue file already overrides with openapi-fetch | "Own-backend calls go through one typed transport module in api/, one exported function per route; components do not call them inside effects" |
| Base URL from framework env var; components never read env directly | KI | server/client + config boundary | keep |
| `credentials: 'include'` on every request | KI | session-cookie auth contract | keep, fold into transport line |
| `X-Requested-With: XMLHttpRequest` for CSRF | KI | backend CSRF guard rejects without it (also repeated in Nuxt) | keep once |
| Errors throw with server's error message | KI | | keep, fold |
| Consume via cache query/mutation hooks, never in effect/lifecycle | KI | dup of Stack line; consolidate | fold into one rule |
| Cache config lives in `config/queryClient.ts` | RC | file placement taste; vocabulary already says config/ | delete |
| Error Handling: toast for API errors; never raw error text inline | KI | UX and info-leak boundary | keep |
| Inline errors only for form validation | KI | | keep |
| cache `onError` routes to toast | RC | implementation detail restated 3x (React, Vue) | delete here |
| Never show stack traces to the user | KI | security | keep |
| Formatting (Prettier) json block + 7-row table | RT | .prettierrc is the source of truth; the table restates the json | delete both; at most "Prettier config is the authority" (see CLAUDE.md `feedback_mjs_prettier_config`: `.mjs` extension) |
| Template-attribute quoting row | RT | prettier | delete |
| ESLint shared: naming-convention | RT | eslint naming-convention | delete |
| ESLint: `curly: 'error'` | RT | eslint `curly` | delete |
| ESLint: no unused imports | RT | eslint-plugin-unused-imports / tsc noUnusedLocals | delete |
| ESLint: no explicit `any` | RT | eslint (and harness gate already enforces) | delete |
| E2E: tests in `e2e/` at repo root, user-story-driven hybrid | RW | repo-structure assumption (docs/USER_STORIES.md) that many repos lack | "If the repo has docs/USER_STORIES.md, E2E lives in e2e/ mirroring its sections" |
| Coverage: every story has exactly one mapped E2E test; 2-3 journey tests | RC | arbitrary count ("exactly one", "2-3"); the useful invariant is "no story ships without an E2E" (already PL3/R-401) | delete counts; keep PL3 |
| Spec grouping by `## Section`; do not invent groupings; ASCII tree | RC | file-layout ceremony; trim keeps it, no incident | delete |
| Running: `fullyParallel: true`, fix instead of `workers: 1` (R-509) | KI | durable (serialized tests hide data isolation bugs) | keep one line |
| `--only-changed=origin/main` at turn ends | MOVE | R-509 test-run cadence is global (rulebook), duplicated in Go/Ruby/Backend | move to global testing rule; delete here |
| CI full suite; pre-push not (IAN-98) | MOVE | same | global |
| Shard with `--shard` | RC | tuning tip | delete |
| Test naming: `US-N:` prefix | RC | convention that depends on USER_STORIES.md | delete (or fold into the conditional E2E rule) |
| Fixtures/helpers dir tree | RC | layout ceremony | delete |
| Rules: one test per story; exactly one | RC | duplicate of Coverage rule | delete |
| Rules: mirror user-stories sections; no invented stories | RC | duplicate | delete |
| Rules: error paths inside the story's test, not error-states.spec.ts | RC | taste, contradicts good coverage practice | delete |
| Rules: journey tests 2-3 | RC | arbitrary count | delete |
| Rules: mock external APIs in E2E; real calls in nightly smoke | KI | cost, flake, and secret exposure | keep |
| Rules: `@fast` tag so pre-push can grep (<30s) | RC | pre-push no longer runs E2E (IAN-98) so the tag has no consumer | delete |
| Rules: assert data/behavior, never element presence alone | KI | matches global "assert behavior" and the eslint `behavior-assertion-required` rule | keep (or MOVE to global testing rule) |
| PL3: every user flow gets at least one E2E before it ships | KINC | 2026-04 debug session (flows shipped without E2E). Partly duplicated by R-401/R-607 per pruning proposal | RW: "A user flow is not shipped until an E2E test exercises it." |
| PL11: kill stale dev servers before local E2E (`lsof ... | xargs kill -9`) | KINC | 2026-04 session: stale server silently broke Playwright `webServer`. But the command is a broad `kill -9` on ports 3000/3001, which can kill unrelated work; | RW: "Stop stale dev servers on the E2E ports before a local run, or set `reuseExistingServer: false` so Playwright fails loudly instead of using one." (fixes the cause, avoids kill -9) |
| PL12: Playwright projects chromium, webkit, mobile-safari | KINC | 2026-04 Safari ITP production bug. Trim kept it as one clause | keep verbatim in meaning |
| PL20: passing test is not working feature; name the test that would fail | KINC | 2026-04 session. Overlaps PL3 and global TDD/verification skills | MOVE to global testing guidance or merge into PL3; delete here |
| Header "Moved from global-memory PL list on 2026-10-02 (IAN-568)" | RC | provenance | drop |

Counts: KI 13, KINC 3 (PL3, PL11 reworded, PL12) + PL20 (merge), RW 7, MOVE 3, RT 12, RC 17.
Trim comparison: trim kept Stack, Directories, API, Errors, and a compressed E2E list; DROPPED PL3, PL11, PL20 and all incident attribution (kept the webkit/mobile-safari clause as a one-liner), dropped the Prettier json (correct) and import-order detail (correct). Valuable things the trim dropped: PL11 (stale-server lesson), PL3/PL20 (E2E-before-ship invariant). Things the trim wrongly kept: `@fast` tag, USER_STORIES section mirroring, "exactly one test per story", `X-Requested-With` is correctly kept.
Proposed shape (~35 lines): (1) dispatch line, (2) Stack: strict TS/no gratuitous any; existing server-state layer; Styling policy block; avoid unnecessary dependencies (one line pointing at the dependency-add ask: "justify new packages"); existing repo architecture wins, default layout for new code; (3) Server/client boundary (components never read env or call api in effects; errors to toast; credentials/CSRF header in one transport; no stack traces); (4) Components stay small and cohesive: "split a component when it mixes data fetching, layout and behavior; no line-count targets"; (5) E2E: parallel, mock externals, assert behavior, no flow ships without E2E, three-browser projects, Playwright stale server fix, repo-has-USER_STORIES conditional layout.

---------------------------------------------------------------------------------------------------
## 3. CLAUDE-FRONTEND-REACT.md (158 / 59)

| Excerpt | Class | Reason | Proposed text |
|---|---|---|---|
| Intro (read together with core + framework file) | KI | routing | keep one line |
| React 19, functional components only; no class components | RW | version pin is a default for new work; "no class components" is a good default but existing code may contain them | "Functional components; do not introduce class components in new code. Follow the repo's React version." |
| TypeScript strict, no any | RT | duplicate of core | delete |
| TanStack Query for all server state; no raw useEffect+fetch | RW | duplicate of core; keep the "no fetch in effect" as React-specific wording | one line: "Server state goes through the repo's query layer, never `useEffect` + `fetch`" |
| SCSS Modules ... no Tailwind | RW | see Section 1; trim dropped this | pointer to Styling policy |
| Hooks live in state/; never a separate hooks/ dir. Providers in state/ | RW | project vocabulary choice; conflicts with the very common `hooks/` in existing repos; "existing architecture wins" | "In new frontends hooks and providers live in state/; in an existing repo follow its layout" |
| File naming table (PascalCase.tsx; useX.ts; XProvider.tsx) | RT/RC | React community convention, eslint-plugin-react `filename-rules`/ naming; no incident | delete or keep one line "components PascalCase, hooks `use` prefix" (React itself requires the `use` prefix for the hooks lint) -> keep that clause only |
| File-structure code example (5 numbered sections) | RC | layout ceremony | delete |
| Default exports for components and pages; named for hooks/services | RW | Next needs default exports for pages; for components it is taste and conflicts with `one-export` style | "Pages and route files export default as the framework requires; elsewhere follow the repo" |
| Props interfaces `{ComponentName}Props` above, same file | RC | naming taste | delete |
| `useCallback` for event handlers/async fns passed as props | RC | premature memoization; React Compiler/ React 19 makes it unnecessary; arbitrary and often harmful | delete |
| Destructure props in signature | RT | eslint `react/destructuring-assignment` / R-325 global rule | delete |
| No inline styles; SCSS modules | RW | keep with the runtime-custom-property exception that Vue already has | "No inline `style` except a runtime-computed CSS custom property" |
| No `React.FC` | RC | taste (no behavior bug since React 18 types) | delete |
| `displayName` and kebab-case `data-test-id` on every component and page | RC | `displayName` is redundant for named function components and is ceremony; `data-test-id` is only needed if Playwright uses it, and the REACT testing rows say "query by role" | delete displayName; keep: "Add a `data-test-id` only where an E2E test cannot select by role/name" |
| Framework directives per framework file | KI | routing | keep |
| Import Ordering (5 groups example) | RT | duplicate of core and import-order lint | delete |
| State: TanStack Query; client config `config/queryClient.ts` | RW | dup of core | fold |
| State: React Context for auth/app-wide; providers in state/ | RW | | "Use existing context/store for app state; do not add one for server state" |
| State: `useState` for local UI state | RT | React basic, no rule | delete |
| State: `useCallback` memoizing handlers | RC | dup | delete |
| State: `useRef` for DOM refs and stable refs | RT | React basic | delete |
| No Redux, Zustand, other state libraries | RW | owner: "use existing state-management layers rather than replacing them"; absolute ban would forbid an existing Redux repo's own code | "Do not add a state library; if the repo already has one, use it, do not replace it" |
| Components consume API through useQuery/useMutation, never api call in effect | KI | dup of core | fold |
| onError routes to toast | RC | dup | delete |
| Headless: Radix UI for dialogs/menus, styled with SCSS | RW | "avoid unnecessary dependencies"; Radix is a default only when the repo has it | "Use the repo's existing primitive library (Radix in the standard stack) for dialogs/menus/toasts; do not hand-roll focus traps" |
| Never `role="button"` on a non-interactive element | KI | a11y invariant (jsx-a11y partially covers: `no-static-element-interactions`) | keep as "Use native `<button>`/primitive for clickable things" |
| Formatting (JSX): jsxSingleQuote false | RT | prettier | delete |
| ESLint: rules-of-hooks error, exhaustive-deps warn | RT | eslint-plugin-react-hooks (note: harness config NOOPs exhaustive-deps for its own source, project config is the authority) | delete |
| ESLint: jsx-a11y recommended | RT | eslint-plugin-jsx-a11y | delete |
| ESLint: eslint-config-next / react-refresh | RT | tooling choice | delete |
| Testing: Vitest + jsdom + RTL + jest-dom + user-event | RT | package.json is the source; listing is a dependency recipe | delete or keep "use the repo's test stack" |
| Query DOM by role and accessible name, not class or test id | KI | testing-library invariant; durable | keep (reconcile with data-test-id line above) |
| Storybook for components/ui/*, visual-regression via Playwright project | RC | tooling recipe, only some repos have it | delete (or "if the repo has Storybook, shared ui components get stories") |

Counts: KI 4, RW 9, RT 13, RC 9, MOVE 0, KINC 0, RO 0 (React-19 pin treated as RW).
Trim comparison: 59 lines; kept Component-shape code, useCallback, displayName, data-test-id, "No Redux/Zustand", Radix; DROPPED "no Tailwind" (weakened, see Section 1). The trim's retained `useCallback`/displayName/`React.FC` rules are ceremony the trim should also have dropped.
Proposed shape (~15 lines): routing line; functional components; server state through query layer never in effects; no state library added (existing one used); styling pointer + inline-style custom-property exception; native elements/existing primitive library for interactive controls; test by role; boundary line for `'use client'` pointing at NEXT.

---------------------------------------------------------------------------------------------------
## 4. CLAUDE-FRONTEND-NEXT.md (117 / 38)

| Excerpt | Class | Reason | Proposed text |
|---|---|---|---|
| Next.js 15+ App Router; no Pages Router | RW | default for new projects; existing Pages Router repos exist | "New projects use the App Router; an existing Pages Router app keeps it until the owner asks to migrate" |
| Directory tree of src/app incl. route groups | RC | tree restates Next docs | delete; keep "route groups in parentheses" implicit |
| Pages live in src/app per App Router | RT | framework behavior | delete |
| Everything outside app/ follows shared vocabulary | KI | | keep as one line |
| Directories appear only when occupied (R-309) | RC | duplicate of core | delete |
| Route URL segments kebab-case; other dirs camelCase (R-312 exception) | RC | camelCase directory rule is house taste; URL segments are kebab because URLs are lowercase, that part is a fact, not a rule | delete |
| Page components thin; no business logic in app/ | KI | architecture | keep |
| Migration from pre-split structure (lib/ -> api/, queryClient, hooks -> state) | RO | one-time migration for projects built under the old conventions; also contradicts "existing architecture wins" | delete (trim kept it; it should go) |
| `'use client'` on every interactive component, first line | KI | server/client boundary discipline (owner-preserved) | keep |
| Server components stay default; directive only when needed | KI | same | keep, merge with above |
| layout.tsx root layout: metadata, fonts, providers | RT | Next docs | delete |
| loading.tsx / error.tsx "where appropriate" | RC | vague | delete (PL9 supersedes) |
| metadata export from server components + code block | RT | Next docs | delete |
| next/font/google with CSS variable injection | RW | the "CSS variable" part ties to the tokens policy | keep as "load fonts with `next/font` and expose them as CSS custom properties" |
| Import group 1 = React + next/* | RT | import-order | delete |
| `NEXT_PUBLIC_*` for browser values; API base URL name | KI | server/client boundary + build-time exposure | keep with "never a secret" (trim's addition, correct) |
| File naming table (page.tsx, layout.tsx, globals.scss, route styles) | RT | framework-mandated names | delete |
| Containers (R-351): standalone, node:22-alpine, USER node, HEALTHCHECK, CMD, .dockerignore, build args | MOVE | R-351 is the global "dockerize every deployable" rule; each stack restating the Dockerfile recipe is 1 paragraph x 5 stacks. Next-specific facts worth keeping: `output: "standalone"`, `NEXT_PUBLIC_*` are build args | keep 2 lines (standalone; NEXT_PUBLIC build args), move rest to CLOUD-DEPLOYMENT / a container skill |
| PL5: pnpm monorepo `outputFileTracingRoot: path.resolve(__dirname,'..')` | KINC | 2026-04 debug session: dynamic routes 500 on Vercel, fine locally | keep |
| PL6: `autoInstallPeers: true`, suppress optional peer with `pnpm.overrides` "never" | KINC | same session; narrow pnpm quirk | keep, shorten |
| PL7: `@playwright/test` in app dep tree breaks Vercel (`next/dist/compiled/source-map`) | KINC | same | keep, shorten |
| PL8: delete passthrough middleware.ts (Edge on every request) | KINC | same; performance | keep |
| PL9: add error.tsx after second unexplained 500 | RC | a debugging tip with an arbitrary count ("second"); trim kept as "add error.tsx to a route that returns unexplained 500s" | RW: "Add an `error.tsx` boundary to a route that returns unexplained 500s." (trim wording is better) |
| "Moved from global-memory PL list 2026-10-02" | RC | provenance | drop |

Counts: KI 4, KINC 4 (PL5-8), RW 3 (App Router default, fonts, PL9), MOVE 1, RT 6, RC 5, RO 1.
Trim comparison: trim preserved PL5-PL9 in compressed form and the Container block; it kept the legacy-`lib/` migration line (obsolete) and dropped the directory tree (fine). Nothing valuable dropped.
Proposed shape (~20 lines): App Router default for new projects; `'use client'` boundary; thin pages; env: NEXT_PUBLIC rule; font/metadata one line; Vercel/pnpm incident lessons PL5-PL9 as a short "Known traps" list; container: two Next-specific lines + pointer.

---------------------------------------------------------------------------------------------------
## 5. CLAUDE-FRONTEND-VITE.md (95 / 32)

| Excerpt | Class | Reason | Proposed text |
|---|---|---|---|
| Vite + React 19 client-rendered SPA; no SSR | KI | defines the file's scope | keep |
| TanStack Router file-based routing | RW | default for new SPAs; existing SPAs may use react-router | "New SPAs use TanStack Router; in an existing app use its router" |
| routeTree.gen.ts generated; commit it; never hand-edit | KI | generated-file hygiene, true | keep |
| Directory tree | RC | repeats core + router docs | delete |
| Everything outside routes/main/routeTree follows core | KI | | keep (one line) |
| Directories only when occupied | RC | dup | delete |
| Route URL kebab-case; others camelCase (R-312) | RC | see NEXT | delete |
| Pathless layout routes `_prefix`; auth guard in `route.tsx` | RT | TanStack Router convention | delete |
| Route files thin | KI | | keep |
| `__root.tsx` holds providers + shell | RT | router docs | delete |
| Global styles import once in main.tsx | KI | tokens/global-style boundary | keep |
| Entry chain: index.html loads main.tsx | RT | Vite default | delete |
| main.tsx does exactly createRouter + mount, nothing else | RW | "nothing else" is overly rigid (Sentry, MSW init) | "Keep `main.tsx` to router creation, mounting, and global-style import; bootstrap logic lives in config/" |
| No `'use client'` anywhere in SPA | RT | meaningless directive in Vite, harmless | delete |
| `VITE_*` prefix, `import.meta.env` | KI | client-exposed env boundary | keep "never a secret" (trim's addition) |
| Parse/validate env in config/env.ts; components never read import.meta.env | KI | | keep |
| API base URL = VITE_API_URL | RC | var name | delete |
| `@/` alias in vite.config and tsconfig | RT | tooling config (tsc/vite fail on mismatch) | delete |
| Import group 1 | RT | import order | delete |
| File Naming table | RT | router/Vite mandated | delete |
| Containers (R-351): nginx:1.27, nginx.conf SPA fallback, /health | MOVE | global container rule; keep 2 Vite-specific lines (SPA fallback, `VITE_*` are build args never secret) | as in NEXT |

Counts: KI 6, RW 2, MOVE 1, RT 8, RC 4.
Trim comparison: trim kept most Layout bullets (including the _prefix and entry-chain ones), fine to drop; nothing valuable dropped. Trim kept container text; both versions equally long on that.
Proposed shape (~14 lines): scope; router default; generated file; thin routes; env boundary; one global-styles line; container 2 lines.

---------------------------------------------------------------------------------------------------
## 6. CLAUDE-FRONTEND-VUE.md (195 / 78)

| Excerpt | Class | Reason | Proposed text |
|---|---|---|---|
| Intro: Nothing in REACT applies | KI | routing | keep |
| Vue 3.5+, Composition API, `<script setup lang="ts">` only; no Options API | RW | good default for new components; existing Options-API code exists | "New components use `<script setup lang="ts">`; do not rewrite existing Options API components without being asked" |
| strict, no any, `vue-tsc --noEmit` in CI | RW | strict/any dup of core; vue-tsc fact is real and non-obvious (tsc alone does not check .vue) | "Type-check .vue files with `vue-tsc --noEmit` (tsc does not)" |
| @tanstack/vue-query for all server state; no fetch in onMounted/watch | RW | dup of core | fold to core wording |
| Nuxt `useState` for app state; Pinia only when needed (with 2026-09-19 correction text) | RW | the "(corrected ..., owner decision in stack audit)" is provenance noise; the rule is fine as: use existing store; do not add Pinia for trivial state | "App state outliving a component uses the repo's existing store (Nuxt `useState` or Pinia). Do not add Pinia just for a theme/modal flag." |
| openapi-fetch + openapi-typescript generated types, no hand-written types | RW | durable single-source-of-truth idea, but it is a dependency choice; apply when the backend has a committed OpenAPI doc | "If the backend publishes an OpenAPI document, generate client types from it rather than hand-writing them" |
| Reka UI for headless primitives | RW | as in React | "Use the repo's existing headless primitive library" |
| SCSS Modules sibling .module.scss; no Tailwind; no `<style>` block | RW | see Section 1 | pointer + keep "no `<style>` block; styles in sibling .module.scss" |
| composables/ not hooks/; stores/ only if Pinia; utils/ banned | RW | same default-vs-existing issue; `utils/` ban is global | one line |
| File naming table (6 rows) + folder-repeat note | RT/RC | naming-convention taste; the auto-registration note ("<ChatBox> not <ChatBoxChatBox>") is a real trap | keep only the auto-registration note |
| Component example (full SFC) | RC | template ceremony | delete |
| Block order script then template; no style block | RT | `vue/block-order` | delete (style-block part stays under styling) |
| Props via `defineProps<Props>()`, destructure defaults, no withDefaults | RW | taste for Vue 3.5; correct on 3.5 but fragile on older | keep as one line "type-only defineProps; reactive destructure on 3.5+" or delete |
| Emits `defineEmits<Emits>()` call-signature form, kebab in templates | RT | `vue/*` + vue-tsc | delete |
| `ref` for primitives, `computed` derived; `reactive` only local | RC | Vue style guide taste | delete |
| Explicit imports from `vue` and `#imports` even with auto-import | RW | defensible (lint/typecheck) but contradicts Nuxt idiom; arbitrary | delete or keep: "explicit imports so files type-check alone" |
| Handlers named functions; no multi-statement inline handlers (R-316) | RC | style | delete |
| No inline styles except runtime CSS custom property | KI | tokens + CSP-friendly | keep |
| File header comment inside `<script setup>` (R-320) | RC | R-320 header rule, enforced by eslint file-header-comment; the "never HTML comment" part is a hook mechanic | delete here; the hook states it |
| `defineOptions({ name })` on every component + data-test-id root | RC | see React displayName | delete |
| `v-for` stable `:key` not index; no `v-if` with `v-for` | RT | `vue/require-v-for-key`, `vue/no-use-v-if-with-v-for` | delete |
| `v-html` banned unless sanitized in services/ | KI | XSS; `vue/no-v-html` backs it | keep |
| Slots over render props; defineSlots typing | RC | taste | delete |
| provide/inject only via typed InjectionKey, never string keys | KI | type safety; small | keep (one line) |
| Import ordering block | RT | import order | delete |
| State: vue-query; QueryClient config in config/queryClient.ts installed by Nuxt plugin | RW | dup/placement | fold |
| Every query wrapped in a composable owning the query key; no inline keys | KI | durable (cache-key discipline, same lesson as React) | keep |
| `useState` composables for app state, SSR-safe, named setters, never copy query data into app state | KI | server-state boundary; the "query cache is the only copy of server state" is the best sentence in the file | keep |
| Pinia setup stores, `storeToRefs`, R-325 | RC | Pinia usage detail; R-325 reference | one line "destructure store state with storeToRefs" is a real reactivity trap (KI) |
| Own-backend calls via openapi-fetch client, createApiClient/useApiClient memoize per Nuxt app; no module-level singleton; useApiClient only in setup, not after await (added 2026-09-19) | KINC | 2026-09-19 stack audit: a module-level client leaks the first request's cookie into later users' SSR calls; `useNuxtApp()` throws after await. Real incident-class lesson | keep, split into two short rules (no module-level client in SSR; call in setup only), drop provenance parenthetical |
| ref/computed for local; useTemplateRef; timers cleared in onBeforeUnmount | RC | framework basics | delete |
| No Vuex, event bus, global mutable module state | RW | "global mutable module state" is the SSR cross-request leak (KI); Vuex ban is RO | keep "no module-level mutable state in SSR code" only |
| onError routes to toast | RC | dup | delete |
| Headless: Reka UI; toast wrapper ToastRegion; role=button | RW/KI | as in React | one line |
| Formatting rows (template quotes, vueIndentScriptAndStyle) | RT | prettier | delete |
| ESLint: vue/recommended, block-order, multi-word names, define-macros-order, no-v-html, vuejs-accessibility | RT | eslint-plugin-vue | delete |
| Testing: Vitest + happy-dom + @vue/test-utils + testing-library; @nuxt/test-utils mountSuspended | RW | `mountSuspended` for runtime-dependent components is a real non-obvious trap | keep that clause only |
| Query DOM by role | KI | | keep (shared with React) |
| App-state composables tested via exported functions against fresh Nuxt app; real createPinia | RC | testing recipe | delete |
| Storybook visual-regression | RC | tooling | delete |
| "(corrected 2026-09-19, owner decision in the stack audit)" x4, "(added 2026-09-19)" x2 | RC | in-text changelog | delete all |

Counts: KI 8, KINC 1 (SSR client singleton/Nuxt context), RW 10, RT 10, RC 16.
Trim comparison: trim keeps ~all rules incl. defineOptions name, handlers, `v-for` key, Slots, in 78 lines; it dropped the changelog parentheticals (good) and the SFC file-header "never HTML comment" reason. Valuable preserved by trim: SSR client rules (kept). Trim kept unneeded eslint-restating bullets.
Proposed shape (~25 lines): scope; `<script setup lang="ts">` for new code + vue-tsc; server state through vue-query, query in composable owning key, never copy into app state; typed client from OpenAPI when available; SSR safety (no module-level client or mutable state, call composables in setup); `v-html` ban; typed InjectionKey; styling pointer (+ no `<style>` block, custom-property inline exception); native/primitive controls; tests by role, `mountSuspended` note.

---------------------------------------------------------------------------------------------------
## 7. CLAUDE-FRONTEND-NUXT.md (163 / 50)

| Excerpt | Class | Reason | Proposed text |
|---|---|---|---|
| Nuxt 4, app/ root, Nitro, SSR on; no `ssr: false` for whole app | RW | default; an existing SPA-mode Nuxt app is legitimate | "New Nuxt apps keep SSR on; don't turn it off globally without the owner's decision" |
| compatibilityDate pinned, bumped in its own commit | KI | upgrade hygiene | keep |
| Nitro `server/` never imports from `app/`; shared in `shared/`; resolveClientAddress (added 2026-09-19) | KINC | 2026-09-19: SSR API client and Nitro proxy had two copies of the client-IP trust rule that drift. Security lesson | keep: "server/ never imports from app/; code both sides must apply identically (the client-address trust rule) lives once in shared/" |
| Directory tree (app/, server/, shared/) | RC | restates Nuxt docs | delete |
| Pages in app/pages; rest follows vocabulary | RT | Nuxt behavior | delete |
| Directories only when occupied | RC | dup | delete |
| Page file names kebab (R-312 exception) | RC | URL facts | delete |
| Pages thin; no business logic in pages/ | KI | | keep (same as Next/Vite) |
| `utils/` banned even though Nuxt auto-imports it | RW | house rule against Nuxt default; global no-catch-all applies | keep one line |
| Route groups become named layouts; definePageMeta example; layout list; middleware naming; layout styles | RT/RC | Nuxt docs; naming mechanics | delete |
| Auth gating: 3-piece design (cookie presence gate in Nitro, requireSession route middleware, protected layout) | KINC | derived from the stack audit (Nitro middleware is not edge middleware; verification must happen once per navigation) | keep condensed: "Nitro middleware is a cheap cookie-presence redirect only; real session verification is the route middleware calling the backend, so it also covers client-side navigation" |
| session cookie httpOnly; no document.cookie | KI | security | keep |
| api/apiClient: createApiClient never module-level; per-request memo; X-Requested-With; base URL /api in browser vs runtimeConfig on server; forward cookie, x-request-id, single X-Forwarded-For via resolveClientAddress; useRequestFetch not passed to openapi-fetch (3 added/corrected notes) | KINC | 2026-09-19 audit: module-scope client leaks cookies; relative base cannot resolve on server; missing headers lose session/correlation/rate-limit bucket. Each clause is a recorded failure | keep as 4 bullets; drop the one 500-word sentence and date parentheticals; the `useRequestFetch` shape mismatch stays as a one-line trap |
| Proxies: catch-all `[...path].ts` proxyRequest with query string and XFF rewrite; PostHog ingest; health route; no routeRules proxy | KINC | same audit; `proxyRequest` drops the query string (real bug class) and client-supplied XFF entries (security) | keep 3 bullets: forward query string; rewrite XFF; health route does not touch backend. Drop the "No routeRules" taste line |
| useSeoMeta per page, app.head defaults, useHead only when needed | RT | Nuxt docs | delete |
| Fonts via @nuxt/fonts as CSS custom properties | RC | tooling choice | delete |
| runtimeConfig declares every var with empty default; NUXT_* vs NUXT_PUBLIC_*; one image per env | KI | server/client boundary + one-image-all-envs | keep |
| Read via useRuntimeConfig; never process.env/import.meta.env in components | KI | boundary | keep |
| Backend URL server-only; browser only NUXT_PUBLIC_* (PostHog key, Sentry DSN) | KI | boundary | keep |
| Theme: useThemePreference composable, localStorage via client plugin, data-theme on html, inline head script to avoid flash | RW | good SSR-flash lesson; fold with the tokens rule in STYLING (data-theme) | keep one line: "Set `data-theme` before first paint with an inline head script so SSR does not flash the wrong theme" |
| Sentry: module, DSN, request ID tag, sourcemaps in CI | RC | observability recipe; belongs in CLAUDE-OBSERVABILITY.md | MOVE (observability) |
| File naming table | RT | | delete |
| Containers (R-351): node-server preset, .output only, USER node, HEALTHCHECK, `NUXT_PUBLIC_*` run time | MOVE | global container rule; keep 1 line: runtime config means no env build args | |
| "This file mirrors NEXT section for section" | RC | structure ceremony; creates artificial sections (Route Groups for a framework with no groups) | drop |

Counts: KI 7, KINC 4, RW 3, MOVE 2, RT 6, RC 7.
Trim comparison: trim preserved the SSR/proxy/XFF/cookie lessons in condensed form (good, it kept resolveClientAddress, query-string, "never module-level client because first user's cookie"). It dropped the explanatory "why" for the gating design and `useRequestFetch` shape mismatch; the latter is a minor loss. It kept Sentry and theme bullets that could MOVE.
Proposed shape (~25 lines): scope + SSR default + compatibilityDate; boundaries (server/ vs app/ vs shared/); auth gating principle; API client per-request + header forwarding; proxy rules; runtimeConfig/env; theme flash; container 1 line.

---------------------------------------------------------------------------------------------------
## 8. CLAUDE-STYLING.md (429 / 63). Every directive.

| Excerpt | Class | Reason | Proposed text |
|---|---|---|---|
| SCSS Modules for all component styles | RW | critical preference | Section 1 policy block |
| Global SCSS for custom properties, resets | KI | global-token boundary | keep |
| CSS custom properties for theming | KI | | keep, with "extend existing tokens" |
| No Tailwind; never use utility classes | RW | Section 1 | policy block |
| No BEM | KI | house convention, coherent with camelCase modules (CSS Modules already scope) | keep one phrase |
| No CSS-in-JS | RW | Section 1 | policy block |
| No plain CSS | RW | "always SCSS" but a repo using CSS Modules `.module.css` (the path glob even lists `*.module.css`) | "SCSS by default; follow the repo's `.module.css` if that is what it uses" |
| File Structure tree | RC | | delete; keep "co-located `.module.scss` per component; shared partials in styles/ via `@use`" |
| Every component has co-located module | KI | enforced indirectly by structure-gate | keep |
| Global styles in src/app/globals.scss | RW | framework-specific path (Nuxt/Vite differ) | "Global styles live in the framework's global stylesheet (`globals.scss` / `main.scss`)" |
| Shared partials in styles/ with @use | KI | | keep |
| Page-level styles camelCase.module.scss | RC | naming | delete |
| Token example block (11 hex vars) | RC | example palette; the example's colors get copied into new projects against "extend existing" | delete |
| All colors from custom properties; never hardcode hex | KI | token discipline | keep ("hardcoded colors only where no token exists; add the token") |
| Exception #fff and #ef4444 | RC | arbitrary exceptions | delete |
| Token names kebab-case | RC | | delete |
| Semantic token names (`--accent` not `--blue`) | KI | durable | keep |
| Class naming camelCase, example | KI | needed so `styles.chatBox` works without bracket access | keep one line |
| camelCase; no BEM; no kebab-case | KI | same (no kebab = bracket access) | keep, merge |
| Variants separate classes, state classes camelCase, `.srOnly` | RC | taste | delete |
| Applying variants: TSX template-literal composition and Vue array | RW | no clsx rule is a dependency policy; examples are verbose | one line each, or "compose with template literals (array form in Vue)" |
| SCSS nesting list (pseudo, parent selector, child elements, media) | RC | taste | delete |
| Nest only 2 levels max (excluding pseudo) / "never more than 3 levels" | RC | arbitrary count, self-contradicting (2 vs 3) | RW: "keep selectors shallow; flatten into a new class when nesting gets hard to read" (or stylelint `max-nesting-depth` if wanted: RT) |
| `&` use; parent selector patterns | RC | | delete |
| Responsive: media queries nested/bottom grouped | RC | the example nests nothing; contradiction between "nested inside" and "bottom of file" | delete |
| Breakpoints $bp-mobile 480/800/1200 | RW | tokens are good; fixed values are a house default | "Use the repo's existing breakpoint variables" |
| Desktop-first max-width; not mobile-first | RC | arbitrary | delete |
| Breakpoints at bottom of module; values | RC | | delete |
| Spacing: px; scale 4..80 | RW | existing design tokens win | "Use the spacing/radius scale already defined in the repo's tokens" |
| Border radius scale; max width 1400; page padding 24/16 | RC | design values; belong in the repo's tokens not a global rule | delete |
| Typography: font, 14px base, size/weight/letter-spacing/line-height scales | RC | design values from one product (Geist, hero sizes) | delete |
| Transitions: 0.15s hover, 0.2s state; keyframes camelCase | RC | design values | delete |
| Buttons example, Inputs example | RC | | delete |
| Always `font-family: inherit` on interactive elements | RC | | delete |
| Always `cursor: pointer` on clickable | RC | | delete |
| Handle `:disabled` with opacity + not-allowed; `:hover:not(:disabled)` | RC | | delete |
| `outline: none` on inputs with border-color on :focus | RW | **accessibility defect**: removing the outline without an equally visible replacement fails WCAG focus-visible; the rule is actively harmful | RW: "Never remove a focus indicator without replacing it with one of equal visibility (`:focus-visible`)." (KI after rewrite) |
| Global reset block | RC | | delete |
| Section separators `/* ---- X ---- */`, 100+ lines | RC | arbitrary line count (owner flagged) | delete |
| SCSS Module Import in TSX: `import styles`, always this name | RC | `styles` naming convention | keep only "import the module as `styles`" if wanted; trim kept |
| Never `classnames`/`clsx`; template literals sufficient | RW | dependency policy; fold into policy block | policy block |
| Vue import block; never `<style module>`; array :class | KI/RC | Vue-specific; the "no `<style module>` / SFC imports sibling file" is the real rule | keep one line |
| Formatting: 4-space indent | RT | prettier/stylelint | delete |
| Properties ordered by box model | RT/RC | stylelint-config-rational-order or none; arbitrary | delete |
| One declaration per line; brace; blank line; trailing semicolons | RT | prettier | delete |

Counts: KI 12, RW 9, RT 3, RC 28 (including design-value scales), KINC 0, MOVE 0.
Trim comparison: 63 lines; kept camelCase, tokens, nesting max-2, breakpoints, scales, interactive rules, section separators (100+ lines), formatting bullet list; preserved the no-Tailwind/CSS-in-JS/BEM bullet (not weakened); kept the `outline: none` accessibility defect and the 100-line separator rule and the arbitrary nesting count. Dropped only example code and the Vue import section (kept in a Files bullet).
Proposed shape (~25 lines): (1) Styling policy block (Section 1), (2) File placement: co-located `.module.scss`, global stylesheet per framework, shared partials via @use, import as `styles`, Vue imports sibling file, no `<style>` block, (3) Tokens: all color/spacing from custom properties, semantic names, extend existing tokens, theme by `data-theme`, (4) Class names camelCase (so `styles.x` works), no BEM, (5) Accessibility: never remove focus indicator without replacement; interactive elements use native controls, (6) Keep selectors shallow, breakpoints from the repo's variables. Widen `paths:` to tsx/jsx/vue.

---------------------------------------------------------------------------------------------------
## 9. CLAUDE-GO.md (290 / 81) (no Go project exists per IAN-568; Go push gate was removed)

| Excerpt | Class | Reason | Proposed text |
|---|---|---|---|
| Intro: mirrors BACKEND/PYTHON; universal rules still apply | RC | | drop |
| Stack list: chi, pgx, golang-migrate, encoding/json, Config struct, testing+go-cmp, gofmt/goimports/go vet/golangci-lint, one go.mod | RW | a recipe, not a rule; existing repo wins | "Default stack for a new Go service: stdlib `net/http` + chi, pgx, golang-migrate, stdlib testing + go-cmp. Match an existing repo." |
| gofmt + goimports non-negotiable | RT | gofmt/goimports | delete (state "run gofmt/goimports") |
| Directory tree (cmd/internal/...) | RC | layout; fold into layering | keep "all app code under internal/, no pkg/ unless published, no src/" as a line |
| cmd/<binary> kebab (R-312 exception) | RC | | delete |
| Layer table (Handlers/Services/Repositories/Clients/Domain: Does / Does NOT) | KI | architectural invariant | keep (core value) |
| Dependencies flow one direction, compiler-enforced | KI | | keep |
| Packages short lowercase; never util/common/helpers/base | KI | global no-catch-all, Go idiom | keep one line; `db` acceptable |
| MixedCaps, exported names carry doc comments | RT | `go vet`/golint/revive | delete |
| Functions verb+noun; constructors NewX; predicates IsX/HasX | RC | global naming rule R-316 | delete |
| R-317 exception: short names in small scopes | RC | Go idiom needs no exception | delete |
| Files snake_case.go; doc.go | RC | | delete |
| File Layout (5 steps; UPPER_SNAKE not Go style) | RC | gofmt/goimports/idiom | delete |
| Handler Pattern code sample | RC | | delete; keep "Handlers are thin: decode, validate, delegate, encode; guard clauses, happy path left-aligned" |
| Error Handling: wrap with %w, errors.Is/As | RT | `errorlint`/`go vet` partial, idiom | keep one line (KI) |
| Sentinel errors in domain; repositories translate driver errors | KI | | keep |
| No panic outside main startup; no swallowed errors (`_ = err` needs comment) | KI | enforced by errcheck in golangci, but the rule is durable | keep |
| Handlers map domain errors to status; no internals in responses | KI | security | keep |
| Env Validation: config.Load typed Config, fail fast, never os.Getenv in business code | KI | | keep |
| Secrets off-path/out of logs (R-102) | MOVE | global secrets rule | delete |
| CORS_ORIGIN own parser, wildcard/null refused, credentialed | KINC | stack-audit finding: credentialed API with `*`/`null` origin hands cookie boundary to any caller; same lesson is in Ruby/Python/Backend tracks | KEEP the one-paragraph rule; MOVE the regex + 20 lines of code + 4 tests to CLAUDE-BACKEND.md (shared across stacks) or delete; the 400-char port-range regex is ceremony |
| Config struct / Load / parseCORSOrigin code, newCORSMiddleware, 4 tests | RC | code dump, one per stack (Go, Ruby, Py, TS) | delete; keep rule + "an empty AllowedOrigins in go-chi/cors means allow-all, so install no middleware when blank" (KINC trap) |
| Session cookie Secure flag names development only (not "production") | KINC | staging sent cookie over HTTP; stack audit | keep as 1 line; drop code + test |
| Migrations: raw SQL defaults; staged risky changes; never destructive one-shot against prod (R-101) | KI/MOVE | staged migration is global DB rule (CLAUDE-DATABASE.md) | MOVE to CLAUDE-DATABASE.md; delete here |
| Testing: `*_test.go` co-located (R-313 exception) | KI | toolchain fact | keep |
| Table-driven + t.Run; go-cmp not mock-call counts | RW | "assert behavior not mock call counts" is global; table-driven is Go idiom | delete (global) |
| Integration tests hit real DB; never mock the repo under test | KI | durable | keep |
| One negative-input test per handler (R-406) | MOVE | global CLAUDE.md rule | delete |
| LLM consumers include one fixture test against captured real response | KI | durable | keep (or MOVE to global) |
| No t.Skip to hide a failing test; fix or delete | MOVE | global "never skip a failing test" | delete |
| Test runs (R-509): t.Parallel; go list reverse-dependency selection; CI full run (IAN-98) | RC | a 200-word shell recipe for affected-package selection; global testing rule covers cadence | delete (keep "mark independent tests t.Parallel") |
| Tooling: gofmt+goimports pre-commit; go vet and tests in CI; trust the hooks | RT | formatter + vet | delete |
| Enforcement: No Go push gate ships; rule-judge CI; structure-gate; ternaries don't exist | RC | describes harness internals, one bullet is a statement of non-existence | delete |
| Containers: Dockerfile in creating commit; golang builder; distroless nonroot; HEALTHCHECK note; .dockerignore; compose | MOVE | global R-351; Go-specific: `CGO_ENABLED=0`, distroless static, platform healthcheck | keep 2 lines |
| Observability: lives in CLAUDE-OBSERVABILITY.md | RC | pointer stub | delete (CLAUDE-OBSERVABILITY already loads on backend files) |

Counts: KI 15, KINC 2 (CORS parsing/allow-all trap, session Secure flag), MOVE 6, RT 5, RC 14, RW 1.
Trim comparison: trim 81 lines kept layers table, errors, config/CORS paragraph, session note, container; dropped code dumps (good), the R-509 recipe (good). Nothing valuable lost found without re-reading each; the go-chi/cors empty-origin allow-all trap should be confirmed retained in trim (not verified line by line).
Proposed shape (~40 lines): default stack line; layer table + one-direction rule; error handling (4 lines); config/env fail-fast + CORS rule + allow-all trap; session cookie Secure rule; testing (co-located, integration real DB, fixture test); container 2 lines. Consider archiving the file to docs/ until a Go project exists (IAN-568 removed its gate for the same reason).

---------------------------------------------------------------------------------------------------
## 10. CLAUDE-RUBY.md (256 / 73) (no Ruby project; gate removed IAN-568)

| Excerpt | Class | Reason | Proposed text |
|---|---|---|---|
| Intro mirrors BACKEND/PYTHON | RC | | drop |
| Stack list (Rails 7.x API, Puma, PG/AR, strong_migrations, Sidekiq, serializers, credentials, RSpec+FactoryBot, RuboCop, one Gemfile) | RW | recipe; version pin "7.x" | "Default stack: Rails API-only, ActiveRecord/PG, RSpec + FactoryBot, RuboCop. Match an existing repo." |
| RuboCop is also the formatter | RT | | delete |
| Directory tree (app/controllers..., lib blessed) | RC | Rails dictates it ("Rails is omakase") | keep two facts: do not relocate framework dirs; `lib/` is allowed here, domain logic still goes to services/ |
| Layer table | KI | | keep |
| Dependencies flow one direction; no repository layer; query objects | KI | | keep |
| Files snake_case matching class (R-312 Ruby exception) | RT | Zeitwerk requires it | delete |
| Service objects `Verb+Noun` with single public `call` | RW | house pattern | keep as one line |
| Predicate methods end in `?` (never is_x); bang methods only for raising variants | RT | RuboCop `Naming/PredicateName`/ `Naming/PredicatePrefix` | delete |
| Constants UPPER_SNAKE; single-use stay beside consumer (R-324) | RT/RC | RuboCop + R-324 | delete |
| File Layout (frozen_string_literal, header, constants, public, private) | RT | RuboCop `Style/FrozenStringLiteralComment`, `Layout/ClassStructure` | delete |
| One class per file | RT | Zeitwerk/RuboCop | delete |
| Controllers sample code | RC | | delete |
| Strong params always; never pass raw params down | KI | security | keep |
| Errors propagate to rescue_from; rescue locally only to add message | KI | | keep (merge with Error Handling section) |
| Validation at edge: strong params shape, model validations invariants | KI | | keep |
| One negative-input spec per endpoint (R-406) | MOVE | global rule | delete |
| Migrations: constant default bare, SQL expr lambda; never nested quotes or bare "now()" | KINC | `migration-defaults-guard` hook backs it; recorded incident (DEFAULT 'now()' literal string bug, R-328 origin) | keep 3 lines (hook-enforced; hook message is enough, so could delete) |
| strong_migrations staged approach; no destructive one-shot on prod | MOVE | global DB rule (CLAUDE-DATABASE.md, R-101) | delete here |
| Env validation initializer; never log credential/ENV dump | KI/MOVE | R-102 global; fail-fast initializer is the stack part | keep one line |
| CORS_ORIGIN parser (paragraph) | KINC | same stack-audit lesson as Go | keep paragraph; MOVE regex/code/spec (40 lines) to BACKEND or delete; note Ruby `\A...\z` vs `^$` anchor trap (KINC, one line) |
| Session cookie `secure: !Rails.env.development?`; code + spec | KINC | staging sent cookie over HTTP | keep 1 line; drop code/spec |
| Error Handling: rescue_from central mapping; never rescue Exception; no internals | KI | | keep (one of the two copies) |
| Logging / Observability stub sections | RC | pointers | delete |
| Containers (Rails 7.1 Dockerfile, worker image, .dockerignore, compose) | MOVE | R-351 | 2 lines max |
| Testing: request specs over controller specs; real test DB; never mock AR in model/query spec; factories; fixture spec; spec/ mirrors app/; no skip/pending | KI/MOVE | request specs + no AR mocks are durable; skip rule global; R-313 | keep 3 lines, delete rest |
| Test runs (R-509): parallel_tests; affected specs; full on CI; "new dependency needs R-331 justification" | RC | recipe | delete |
| Tooling: rubocop -a pre-commit; trust hooks | RT | RuboCop | delete |
| Enforcement bullets: no Ruby gate ships; rule-judge; structure-gate; migration-defaults-guard | RC | harness self-description | delete |

Counts: KI 9, KINC 3 (migration defaults, CORS parser/anchors, session secure), MOVE 6, RT 9, RC 10, RW 2.
Trim comparison: 73 lines kept layers, controllers, validation, CORS/session paragraphs, migrations, testing; dropped code dumps. Nothing valuable dropped found (the `\A \z` anchor trap and `rack-cors` credentials note should be confirmed in trim).
Proposed shape (~35 lines): default stack; layers table; service-object pattern; strong params; rescue_from; env/CORS/session rules; migrations defaults; request specs/real DB. Same archive suggestion as Go.

---------------------------------------------------------------------------------------------------
## 11. skills/structure-conventions/SKILL.md (57 / 36)

This skill is the pre-emptive read for hook-enforced R-3xx rules. Its description line (`R-304, R-305, R-309 to R-314...`) and the "What stayed in CLAUDE.md" section are meta-ceremony.

| Excerpt | Class | Reason | Proposed text |
|---|---|---|---|
| description: lists rule ids; "each rule is also enforced mechanically" | RW | ids in the description are noise for triggering; keep the trigger context | "Use before creating, moving, splitting or renaming a directory, module, migration or test tree in a server or web client; before writing a pg migration or Alembic default; when planning a package layout." |
| Intro: "moved out of always-loaded CLAUDE.md on 2026-09-04"; "Full Spec in rulebook/reference.md" | RC | history | delete |
| R-304 Express src/ vocabulary (14 names) | KI | enforced by structure-gate at creation; vocabulary is architecture | keep as list |
| R-304 FastAPI vocabulary snake_case | KI | | keep |
| R-305 web client vocabulary; one component per folder; Nuxt app/server vocabulary | KI | | keep; add "for new code; an existing repo keeps its layout" |
| R-311 full-word dir names (`database/` not `db/`) | RC | warn-only since IAN-568 (recorded fires were fixtures); taste | delete |
| R-312 camelCase directories; exceptions | RC | warn-only; taste; exceptions list shows the rule fights the ecosystem (kebab URL, snake_case, Go) | delete, or "match the language's convention" |
| R-309 collapse single-module folder to flat file | RC | arbitrary (audit 2026-09-26 recommends deleting its only enforcer) | delete |
| R-310 regroup past 20 sibling modules | RC | arbitrary count; flat-directory-reminder hook | delete |
| R-313 tests in sibling __tests__/tests/spec, never co-located; Go exception | KI | enforced by structure-gate; conflicts with common co-located TS tests in existing repos | RW: "In new code tests live in a sibling test directory; in an existing repo follow its test layout" |
| R-314 one top-level __tests__ mirroring src; fixtures in src/__fixtures__ | RC | layout detail | delete |
| R-407 build-smoke test: runtime assets exist under dist/; no .env/secrets in dist | KINC | recorded production failure class (non-code asset missing from dist; secret in artifact) | keep |
| R-319 one public function per module in services/api/clients | RW | enforced by eslint one-export-per-file; contradicts React/Vue convention (hooks, default exports); applies only to those dirs | keep as is, scoped to those dirs |
| R-321 file order: imports, types, ALL_CAPS, primary export, helpers; body ordering; helpers are function declarations | RT/RC | eslint `member-ordering` + taste | delete |
| R-323 sort sibling keys alphabetically | RT | eslint `sort-keys` (churn-heavy in practice, "never reorder where position matters") | delete or leave to eslint |
| R-324 extract literals to named constants (exempts) | RT | eslint `no-magic-numbers`, ruff PLR2004, golangci mnd | delete |
| R-326 no IIFEs | RT | eslint no-restricted-syntax | delete |
| R-327 no nested ternaries | RT | eslint `no-nested-ternary` | delete |
| R-329 never any / @ts-ignore / @ts-nocheck; @ts-expect-error with description | RT/KI | eslint no-explicit-any + ban-ts-comment (harness gate at push); the principle also lives in FRONTEND Stack | delete here; single statement in FRONTEND and BACKEND |
| R-328 migration defaults | KINC | hook migration-defaults-guard; origin: quoted-default migration bug | keep 1 line or delete (hook explains at the moment of the write) |
| "What stayed in CLAUDE.md" paragraph + claude-md-lint test mention | RC | meta | delete |

Counts: KI 5, KINC 2, RW 3, RT 7, RC 8.
Trim comparison: trim 36 lines kept every directory, test, in-module and migration rule (it removed ids and hook tags, and the R-311/R-312 detail partly). It kept the nested-ternary/IIFE/any/magic-number bans (should go) and the 20-module and 1-module folder rules (arbitrary). It did not add existing-repo precedence.
Proposed shape (~20 lines): directories (Express, FastAPI, web client, Nuxt) as lists "for new code"; tests: sibling dir for new code, Go exception; build-smoke test; one public function per module in services/api/clients; migration defaults one-liner. Remove everything an eslint/ruff/golangci rule already says.
