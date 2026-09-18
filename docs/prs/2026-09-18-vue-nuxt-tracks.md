# PR: Vue and Nuxt convention tracks (slice 01 PR 3)

Ticket: IAN-90 (parent IAN-72). Branch: `feat/vue-nuxt-tracks`. Spec: `claude/docs/superpowers/specs/2026-09-17-python-vue-convention-tracks-design.md`. Plan: `docs/slices/slice-01-python-vue-conventions.md`, PR 3.

## Summary

This PR adds the Vue track to the convention stack, so that the FastAPI and Nuxt template (workstream 2) has written rules before its first `.vue` file exists. `CLAUDE-FRONTEND-VUE.md` is the Vue analog of the React file, and `CLAUDE-FRONTEND-NUXT.md` mirrors the Next file section for section. The core's dispatch table already pointed at both files, and PR 2 had made the core framework-agnostic.

## What changed

- `claude/CLAUDE-FRONTEND-VUE.md`: Vue 3 with `<script setup lang="ts">` only, type-only `defineProps` and `defineEmits`, the sibling `.module.scss` import, composables, Pinia setup stores with `storeToRefs`, TanStack Query for Vue behind query composables, Reka UI, the `eslint-plugin-vue` rules, and Vitest with `@vue/test-utils` and `@nuxt/test-utils`.
- `claude/CLAUDE-FRONTEND-NUXT.md`: the `app/` root and directory tree, named layouts in place of Next's route groups, a three-part auth gate, Nitro proxies, `useSeoMeta` and `@nuxt/fonts`, run-time `runtimeConfig`, the theme store with its anti-flash script, `@sentry/nuxt`, file naming, and the `node-server` container.
- `claude/CLAUDE-STYLING.md`: two Vue subsections, the `:class` array form for variants and the `<script setup>` module import.
- `claude/rules/frontend-vue.md` and `claude/rules/frontend-nuxt.md`: the auto-load symlinks.
- `claude/README.md` and `claude/rulebook/reference.md`: one row for each new file.
- `claude/enforce/tests/convention-paths-scope.test.sh`: four new assertions (A7 to A10), and `claude/enforce/hook-hashes.txt` updated because that fixture is a hashed file.
- `translate/cursor-port-map.json` gained two rule descriptions, and the Cursor port was regenerated (`frontend-vue.mdc`, `frontend-nuxt.mdc`, `styling.mdc`, and the convention-files reference rule).
- The slice plan's execution record gained rows 2 and 3.

## Architectural decisions

- **Auth gating is split into three pieces instead of one middleware.** Next gates at the edge before rendering. Nitro server middleware runs in the same process as rendering and never sees client-side navigation, so one check cannot cover both. The chosen design uses a Nitro cookie-presence redirect for the first full page load, a named route middleware that asks the backend through the session query for every navigation, and a protected layout that renders only after the session resolves. The alternative, a single global route middleware, would have had to read an `httpOnly` cookie in the browser, which it cannot do.
- **The Nuxt globs are narrower than the spec's.** The spec wrote `**/server/**/*.ts`, which also matches an Express `apps/server/src/app.ts`, so every Express backend session would have loaded Nuxt rules. The file names Nitro's four directories instead, and assertion A10 fails if an Express path ever matches again.
- **Imports are explicit even though Nuxt auto-imports them.** Auto-imports hide where a name comes from, and a file that relies on them does not lint or type-check on its own. The cost is a few import lines per file.
- **No `<style>` block in an SFC.** The spec keeps the sibling `.module.scss` file for parity with the per-component-folder rule (R-305), so the structure gate and the styling conventions treat `.vue` and `.tsx` components the same way.
- **This PR branches off `main`, not off the slice branch.** PR #19 already carried PRs 1 and 2 to `main` and left `feat/python-vue-conventions` stale (24 commits behind), and PR #19's own body records that the slice-branch route kept producing conflicts.

## Testing

- Test first: A7 (a `.vue` component loads only the core and the Vue file), A8 and A9 (the section outlines the spec's section 1 table names), and A10 (the Nitro globs exclude an Express tree) all failed before the files existed, and they pass now.
- `convention-track-invariants.test.sh` passes with the two new tracks (AC-8).
- The full enforce suite and the full hooks suite pass, with `HOME` pointed at this checkout the way CI runs it.
- `node translate/cursor.mjs --check` and `node translate/codex.mjs --check` are clean.

## Reflection

The time since implementation is about 20 minutes (work started at 09:27Z; this document was written at about 09:48Z).

The auth gate is the part this PR understands better now than the spec did. The spec treated Nitro middleware as the Nuxt counterpart of Next middleware, but the two sit at different points of the request, so the gate needed a second piece for client navigation. At first I also carried the spec's `**/server/**/*.ts` glob over without checking it against an Express tree, and only a second read of the glob list against the Express layout caught the overlap. The new fixture assertion now makes that check mechanical.
