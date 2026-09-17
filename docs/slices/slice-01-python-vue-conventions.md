# Slice 01: Python and Vue Convention Tracks

Spec: `claude/docs/superpowers/specs/2026-09-17-python-vue-convention-tracks-design.md`
Branch: `feat/python-vue-conventions` (the slice branch; each PR branches from it and squash-merges back, and the slice branch squash-merges to `main` when PR 7 lands)
Status: Gate 1 approved 2026-09-17; PR 1 in progress
Tracker: Linear project Agent Governance, slice ticket IAN-72, one child ticket per PR
Started: 2026-09-17

## Purpose

This slice brings the Python convention track to the depth of the TypeScript track, adds a Vue and Nuxt track, and makes both mechanical through enforcement hooks and fixture tests. It is workstream 1 of 3; the FastAPI + Nuxt template (workstream 2) and Voyager 2.0 (workstream 3) build on it. Every PR below is independently mergeable and reviewable in one sitting.

## Execution record

| PR | Concern | Share | PR number | Merged | Scope change |
|---|---|---|---|---|---|
| 1 | `add-stack-track` skill and invariant test | 8% | IAN-73, PR #2 | 2026-09-17 | No manifest entry: the invariant test is a repo-level test like `manifest.test.sh`, which carries none; the manifest models rule enforcers. |
| 2 | Frontend core refactor and `CLAUDE-FRONTEND-REACT.md` | 15% | IAN-75, PR #4 | | AC-1 and AC-2 live in a new fixture `convention-paths-scope.test.sh` (codex-authored) rather than inside the invariant test. The fixture caught the Next file's `**/app/**/*.ts` glob matching Nuxt's `app/` tree; narrowed to `**/src/app/**` in this PR. |
| 3 | `CLAUDE-FRONTEND-VUE.md` and `CLAUDE-FRONTEND-NUXT.md` | 20% | | | |
| 4 | `CLAUDE-PYTHON.md` rewrite | 25% | | | |
| 5 | Enforcement E1 to E6 | 15% | | | |
| 6 | Enforcement E7: structure-gate Vue branch | 12% | | | |
| 7 | Sync, hashes, README, handoff | 5% | | | |

Later list (deferred, not in this slice): Python naming-lexicon AST enforcer; SFC-aware brace counting in `clean-code-scan.mjs`; deletion of the stale `enforce/eslintOptions.mjs` duplicate.

## PR 1: `add-stack-track` skill and invariant test

**Context:** Nothing in this slice has landed. The repo has four stack tracks (TypeScript, Python, Go, Ruby) and each was wired in by hand: a convention file, a git-tracked symlink under `claude/rules/`, a row in `claude/rules/session-types.md`, and manifest entries in `enforce/manifest.json`. The Python track shows what recall misses: its file and symlink exist, but only eight ruff rules back it and no fixture tests were added for it.

**Problem:** The Vue track is about to be added the same way, and the sixth track after it. The procedure must exist as a checklist before the Vue PRs run, so those PRs are its first execution rather than a fifth hand-wired track.

**Approach:** A skill is a markdown file under `claude/skills/<name>/SKILL.md` that Claude Code loads on demand; it carries the procedure. The skill is an eight-step numbered checklist: convention file, rules symlink, detection rows, enforcer analogs, structure gate, repo docs, verification, ports and hash manifest then publish. Imperatives only, no rationale (R-206).

The invariant that the procedure protects is separately mechanized as a shell test in `enforce/tests/`, because a manual structure rule loses to what is already on disk (feedback memory `feedback_mechanize_structure_rules`). The test iterates every `claude/CLAUDE-*.md` except `CLAUDE.md` and asserts three things per file: a `paths:` frontmatter block, a resolving `claude/rules/*.md` symlink, and a mention in `session-types.md` or the core's Framework Files table.

**Contents:** `claude/skills/add-stack-track/SKILL.md`; `claude/enforce/tests/convention-track-invariants.test.sh`, named under Components in `claude/enforce/README.md`; the existing test runner picks the new test up by glob. No manifest entry: the manifest registers enforcers of numbered rules, and this is a repo-level test like `manifest.test.sh`.

**Tests:** The invariant test itself, run against the repo (passes today, since all four tracks are wired) and against a temporary copy with one symlink removed, one `paths:` block stripped, and one session-types row deleted (three failing cases, each asserting the failure names the offending file). Cites AC-8.

**Review focus:** The three assertions in the test: that each one fails independently and names the file, and that the symlink check follows the link rather than testing for the link's existence only.

**Size:** 6 files (skill, test, enforce README line, spec consistency edit, slice record, generated codex port), about 260 lines.

## PR 2: Frontend core refactor and `CLAUDE-FRONTEND-REACT.md`

**Context:** PR 1 has landed. `CLAUDE-FRONTEND.md` is the core file every framework file is read alongside, and today it is React-coupled: React 19, `useCallback`, TanStack Query for React, and an explicit ban on Zustand and other state libraries. Its `paths:` globs include `**/src/components/**`, so any project with a `components/` directory loads it.

**Problem:** A Vue project would load React rules, and Pinia contradicts the state-library ban outright. The core must become framework-agnostic before the Vue track can read it, and the React content needs a home that only React files trigger.

**Approach:** Content moves, it is not rewritten. Every sentence in the core that names a hook, a directive, or a state library moves to the new `CLAUDE-FRONTEND-REACT.md`, scoped by `paths:` to `**/*.tsx` and `**/*.jsx`. What stays in the core is the directory vocabulary shape, generic file naming rows, the API wrapper pattern, error handling, the Prettier config minus `jsxSingleQuote`, and the entire Playwright E2E section.

The Framework Files dispatch table in the core gains the `nuxt.config.ts` marker row now, pointing at files PR 3 creates, so PR 3 does not touch the core. `CLAUDE-FRONTEND-NEXT.md` and `CLAUDE-FRONTEND-VITE.md` change only where a cross-reference to the core now belongs to the React file.

**Contents:** Refactored `claude/CLAUDE-FRONTEND.md` (about 140 lines); new `claude/CLAUDE-FRONTEND-REACT.md` (about 170 lines); new symlink `claude/rules/frontend-react.md`; cross-reference edits in the NEXT and VITE files; the session-types Read cell edit for the React file.

**Tests:** A new codex-authored fixture `claude/enforce/tests/convention-paths-scope.test.sh`: AC-1 as a glob fixture (paths from a React, a Next, a Vite, and a Nuxt tree matched against each convention file's `paths:` globs; the React file matches no Nuxt path, the core matches both) and AC-2 as a grep for React rule tokens (`useCallback`, `useState`, `useRef`, `Zustand`, `use client`, `React.FC`, `from 'react'`, `React 19`) in the core returning 0; the framework name itself may appear where the core dispatches or contrasts. The invariant test from PR 1 passes with the new file and symlink.

**Review focus:** The line-by-line move: nothing React-specific left in the core, nothing agnostic moved out of it. The E2E section moved verbatim. The glob fixture list is the reviewer's checklist for what auto-loads where.

**Size:** 6 files, about 350 lines moved plus 60 lines of test.

## PR 3: `CLAUDE-FRONTEND-VUE.md` and `CLAUDE-FRONTEND-NUXT.md`

**Context:** PR 2 has landed; the core is agnostic and its dispatch table already points at the two files this PR creates.

**Problem:** There is no Vue track. The template workstream needs one before its first `.vue` file is written, and the file must reproduce every convention the Next template relies on in Nuxt terms: route groups, cookie gating, session re-verify, the two reverse proxies, the theme store, tokens, per-component folders, Docker output.

**Approach:** Two files following the existing core-plus-framework split. `CLAUDE-FRONTEND-VUE.md` is the Vue-core analog of the React file: Vue 3 (the framework) with the Composition API and `<script setup lang="ts">` only, TanStack Query for Vue (server-state caching) for server state, Pinia (Vue's official store) for app state, Reka UI (the Vue port of the Radix headless primitives) for dialogs and toasts, sibling `.module.scss` files kept for parity with the per-component-folder rule.

`CLAUDE-FRONTEND-NUXT.md` mirrors `CLAUDE-FRONTEND-NEXT.md` section for section: Nuxt 4 (the Vue SSR framework) with its `app/` root, route groups translated to named layouts plus `definePageMeta`, auth gating as a Nitro server middleware cookie check plus a protected layout that re-verifies the session, proxies as Nitro `server/api` catch-all routes, runtime `NUXT_PUBLIC_*` config, `useSeoMeta` and `@nuxt/fonts`, Sentry via `@sentry/nuxt`, and the Nitro `node-server` Docker preset.

`CLAUDE-STYLING.md` gains two short Vue subsections where it currently shows TSX syntax, and nothing else in it changes.

**Contents:** `claude/CLAUDE-FRONTEND-VUE.md` (about 190 lines); `claude/CLAUDE-FRONTEND-NUXT.md` (about 120 lines); two subsections in `claude/CLAUDE-STYLING.md`; symlinks `claude/rules/frontend-vue.md` and `claude/rules/frontend-nuxt.md`; the session-types Read cell and the `CLAUDE.md` convention-files sentence naming the Vue track.

**Tests:** The invariant test passes with both new files (AC-8). The glob fixture test from PR 2 gains the assertion that `app/components/Foo/Foo.vue` matches the Vue file and the core and nothing else, and that `server/api/health.get.ts` matches the Nuxt file (AC-1). A header-outline assertion checks every `##` heading the spec's section 1 table names is present in each file.

**Review focus:** The Nuxt file's auth-gating and proxy sections, since they are the two places where Next's primitives have no one-to-one Nuxt equivalent and a design choice was made (Nitro server middleware is not edge middleware). Also the Vue file's State Management section, which must not contradict the core.

**Size:** 7 files, about 350 lines.

## PR 4: `CLAUDE-PYTHON.md` rewrite

**Context:** PRs 1 to 3 have landed. `CLAUDE-PYTHON.md` is 199 lines against an 810-line Express parity target, and contradicts four settled decisions (it offers Django, Celery or RQ, pip, and stdlib logging as alternatives).

**Problem:** The FastAPI template cannot be specified against a convention file that lacks a worker pattern, a session store, middleware ordering, a response envelope, and the fourteen infrastructure patterns the Express template implements. The rewrite must land before the template spec is written.

**Approach:** A full rewrite to the spec's 40-section outline, about 900 lines, in the Express file's macro order. Every section that exists today and has no Express counterpart (Module and Symbol Naming, File Layout, Testing, Enforcement, Build/Run Assets) is carried forward. Every alternative is removed: FastAPI only, arq only, uv only, structlog only.

The Alembic and SQLAlchemy restatements of `CLAUDE-DATABASE.md` land in the migrations, repository, and session sections and a four-column type map, so `CLAUDE-DATABASE.md` itself is untouched. Where Starlette's middleware model differs from Express (outside-in wrapping), the section states the precedence rule and the resulting request-path order rather than copying the Express list.

The file is written in one PR because it is one artifact with cross-references between sections; splitting it would produce two half-files that each cite headings the other does not yet have.

**Contents:** `claude/CLAUDE-PYTHON.md`, replaced.

**Tests:** AC-3 as shell assertions: none of `Django`, `Celery`, `RQ`, `pip install`, `stdlib` present; a `##` heading for each of the 40 outline rows present. AC-4: line count between 800 and 1000. Both added to the invariant test file as a Python-track block.

**Review focus:** Sections 12 (Session Store), 18 (FastAPI App Structure), 22 (Database Session and Engine), 23 (Migrations), and 25 (Error Handling and Response Envelope). These are the sections where a wrong statement becomes a security or data bug in the template. Skim the rest.

**Size:** 1 file, about 900 lines.

## PR 5: Enforcement E1 to E6

**Context:** PRs 1 to 4 have landed; the convention files exist but nothing mechanical fires on a `.vue` file or on a missing Python docstring.

**Problem:** ESLint (the TypeScript linter that backs ten of the R-3xx rules) hardcodes `.ts` and `.tsx` in every glob and cannot parse `.vue`. The server-tree globs for the logging rules miss Nitro's `server/api`. Two reminder hooks skip `.vue` and `nuxt.config`. ruff (the Python linter) has no docstring rule selected.

**Approach:** Six additive changes, each with a fixture test, matching the spec's E1 to E6 table. E1 installs `vue-eslint-parser` and `eslint-plugin-vue`, adds `**/*.vue` to every `files:` array, and sets the Vue parser with the TypeScript parser for script blocks; after that the existing rules fire on SFC script content with no per-rule work. E2 through E5 are glob and regex extensions. E6 adds pydocstyle `D100` and `D103` to `ruff-enforce.toml`.

Each change gets its own commit so a reviewer can see the fixture that proves it.

**Contents:** `claude/enforce/eslint.config.mjs`, `claude/enforce/eslint-options.mjs`, `claude/enforce/package.json` and lockfile (two new dev dependencies), `claude/enforce/ruff-enforce.toml`, `claude/hooks/new-file-header-reminder.sh`, `claude/hooks/dockerfile-reminder.sh`, extended fixture tests, manifest entries for each.

**Tests:** AC-5: a `.vue` fixture with a nested ternary, a magic number, and an `any` fails the ESLint test; the compliant fixture passes. AC-7: a `.py` fixture without a module docstring fails the ruff gate test. Each hook extension gets a firing and a silent case in its existing test file. `enforce/tests` and `hooks/tests` green (AC-9).

**Review focus:** The parser wiring in E1 (that `parserOptions.parser` is the TypeScript parser, so type-aware rules still run on `<script setup lang="ts">`), and that adding `**/*.vue` did not widen any server-only rule onto browser files.

**Size:** About 10 files, about 300 lines.

## PR 6: Enforcement E7, structure-gate Vue branch

**Context:** PR 5 has landed. `hooks/structure-gate.sh` is the hook behind R-304, R-305, R-311, and R-312. It roots its directory walk on `src` for any file and on `app` only for Python, so a `.vue` or Nitro `.ts` file under Nuxt's `app/` or `server/` never triggers it. Its per-component-folder check is hardcoded to `.tsx` plus a React dependency.

**Problem:** The gate is silently inert on every Nuxt path: it neither denies a stray `app/utils/` nor a flat `.vue` in `components/`. Without this PR the Vue directory vocabulary is enforced only by the LLM judge and recall.

**Approach:** An additive `is_vue` branch, keyed on a `.vue` extension or a `nuxt` dependency in the nearest `package.json`, that roots the segment walk on `app` and `server`. The per-component-folder check gains a `.vue` case with a `vue` or `nuxt` dependency. The existing `src`, Python `app`, Ruby, and Go conditions are not edited; the new branch is a separate conditional block.

The `structure-conventions` skill gains the Nuxt vocabulary in R-305 and the Python vocabulary in R-304, and its description stops saying "TypeScript server or web client".

**Contents:** `claude/hooks/structure-gate.sh`; `claude/hooks/tests/structure-gate.test.sh` with new cases; `claude/skills/structure-conventions/SKILL.md`; manifest note updates for the four rules.

**Tests:** AC-6: denies `app/components/Foo.vue` (flat) and `app/utils/x.ts` in a Nuxt tree; allows `app/components/Foo/Foo.vue` and `server/api/health.get.ts`; every pre-existing Express, React, Python, Ruby, and Go case produces its previous result. AC-9 green.

**Review focus:** The whole diff of `structure-gate.sh`, line by line, because the root-trigger logic is shared by every stack. Confirm the existing conditions are byte-identical and the new block is reachable only for Vue and Nuxt files.

**Size:** 4 files, about 200 lines.

## PR 7: Sync, hashes, README, handoff

**Context:** PRs 1 to 6 have landed on the slice branch. The live `~/.claude` still runs the old files, and the hook-hash manifest does not cover the changed hooks.

**Problem:** The slice is not usable by the next workstream until it is synced to the live config, the integrity manifest matches, and the repo's own README lists the new convention files.

**Approach:** Run `sync.sh` (the script that copies tracked files from this repo into the live config directory), then `hook-integrity-check.sh --update` to regenerate `enforce/hook-hashes.txt`, then verify the integrity check reports no drift. Add the new convention files to the README's file table. Write the session handoff. This PR has no logic; it is the closing ceremony that R-601 and R-106 require.

**Contents:** `claude/enforce/hook-hashes.txt`; `README.md`; `docs/session-handoff/session-handoff.md`; this slice plan with the execution record filled in.

**Tests:** AC-10: `hook-integrity-check.sh` reports no drift after sync. AC-9 green. `git diff origin/main` reviewed for secrets, local paths, and client content before push (R-106).

**Review focus:** The `git diff origin/main` output, since this is the push that publishes the slice to a public remote.

**Size:** 4 files, small.

## Gate rules for this slice

- Gate 1: this document is approved by the owner before PR 1 starts.
- Gate 2: each PR is approved on GitHub before merge. Squash merge, branch deleted, landing on the slice branch verified with `git log`.
- No PR starts before the previous one is merged.
- New ideas go to the Later list above, not into a PR.
- Time estimate for the executor, divided per R-906: about 30 minutes per documentation PR (2, 3), about 60 minutes for PR 4, about 45 minutes each for PRs 5 and 6, under 15 minutes for PRs 1 and 7, plus review wait at each gate.
