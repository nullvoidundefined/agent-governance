# PR: Enforcement E1 to E6 for the Vue and Python tracks (slice 01 PR 5)

Ticket: IAN-95 (parent IAN-72). Branch: `feat/vue-python-enforcement`. Spec: `claude/docs/superpowers/specs/2026-09-17-python-vue-convention-tracks-design.md`, section 3. Plan: `docs/slices/slice-01-python-vue-conventions.md`, PR 5.

## Summary

This PR makes the new Vue and Python convention tracks mechanical rather than recall-based. Before it, no enforcer ever read a `.vue` file, the logging rules never reached Nitro server routes, the two reminder hooks skipped Vue components and Nuxt configs, and ruff had no docstring rule. After it, the existing ESLint rules fire inside `<script setup lang="ts">`, the server rules cover `server/api` and `server/middleware`, both reminders cover Nuxt, and Python repos can turn on docstring enforcement with the same switch that turns on TypeScript file headers.

## What changed

- **E1 to E3** (commit `14c4a0e`): `vue-eslint-parser` and `eslint-plugin-vue` are added to `claude/enforce/package.json`. A `.vue` block in `eslint.config.mjs` hands the script to the TypeScript parser. import-x parses and resolves `.vue` neighbours. `eslint-options.mjs` adds `**/*.vue` to every opt-in block. `push-eslint-gate.sh` and `ratchet.mjs` accept `.vue` paths, and the server-tree globs gain `**/server/api/**/*.ts` and `**/server/middleware/**/*.ts`.
- **E4** (commit `5ccb367`): `new-file-header-reminder.sh` covers `.vue` files and accepts a leading HTML comment or a leading script comment as the header.
- **E5** (commit `13c0172`): `dockerfile-reminder.sh` treats `nuxt.config.*` as a frontend build config.
- **E6** (commit `1204e0c`): `push-ruff-gate.sh` adds `D100` and `D103` through `--extend-select` when `.enforce.json` sets `fileHeaders: true`. `ruff-enforce.toml` exempts tests, fixtures, and migrations. `manifest.json` gains `ruff:D100` and `ruff:D103` under R-320, and the hash manifest and the Python track's Enforcement section are updated to match.

## Architectural decisions

- **E6 is opt-in, which is a change from the spec.** The spec turned `D100` and `D103` on for every repo. The TypeScript header rule shipped that way first, and five unrelated fixtures broke because each minimal test file suddenly needed a header, so it was made opt-in through `.enforce.json` `fileHeaders`. The owner chose to reuse that one switch for Python, so a repo turns headers on for both languages at once. The alternative, always-on docstrings, would have denied the gate's own "handled exception passes" fixture.
- **`eslint-plugin-vue` is registered with no rules enabled.** The gate does not enforce Vue style. But a Vue repo keeps live disable comments for its own `vue/*` rules, and the Vue track requires one beside every `v-html`. ESLint fails on a disable comment whose rule is undefined, the same failure the config already stubs for React plugins. Registering the real plugin defines every `vue/*` rule at once, which is what justifies the dependency under R-331.
- **`.vue` joins only the main rule block.** The spec said "every `files:` array", but the server, services, and test blocks target trees where no `.vue` file lives. Adding `.vue` there would only risk applying a server-only rule to browser code, which is the risk this PR's review focus names.
- **The gate and ratchet filters were widened too.** The spec did not list these. `push-eslint-gate.sh` and `ratchet.mjs` both filtered paths to `\.tsx?$`, so without this change the parser wiring would have been dead code, and every `.vue` violation would have pushed silently. The push-gate fixture now proves a `.vue` file reaches the linter.

## Testing

- Every case failed before its implementation and passes after it. The cases cover AC-5, the E2 no-cycle case through a `.vue` file, the E3 Nitro `no-console` cases, the E4 header cases, the E5 `nuxt.config` case, AC-7 with the opt-in switch, and the gate's `.vue` filter.
- Two fixtures were wrong at first, and I corrected them before implementing. The E2 cycle case used macOS's symlinked `mktemp` path, which hides every cycle from import-x. `test-quality-rules.test.sh` documents that trap, so the case now uses the real path. The E6 case expected `D100` on an unchanged line 1, but the gate judges added lines only, so the opted-in module is now a new file.
- The full enforce suite and the full hooks suite pass with `HOME` pointed at this checkout. The manifest, manifest-fixture-closure, and enforcement-guard-check tests pass, and both port `--check` runs are clean.

## Reflection

About 25 minutes have passed since implementation started (at 12:26Z).

I first read E1 as "add `.vue` to the globs". In fact the gate never saw a `.vue` file at all, because the filter one layer out threw it away, and only following a path from `git push` to the linter showed that. I also wrote two fixtures that would have failed against a correct implementation. Both mistakes came from not reading the neighbouring fixture before writing mine, and I had already done exactly that reading for PR 3.
