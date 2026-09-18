# PR: Structure gate for Vue and Nuxt (slice 01 PR 6, E7)

Ticket: IAN-97 (parent IAN-72). Branch: `feat/structure-gate-vue`. Spec: `claude/docs/superpowers/specs/2026-09-17-python-vue-convention-tracks-design.md`, section 3, row E7. Plan: `docs/slices/slice-01-python-vue-conventions.md`, PR 6.

## Summary

This PR makes the structure gate enforce the directory rules on Nuxt projects. The gate starts its directory walk at `src/` (or at `app/` for Python, and at the Ruby and Go roots). Nuxt has no `src/`, so every Nuxt path skipped the walk entirely: a new `app/utils/` or `server/utils/`, a kebab-case directory, or a loose `.vue` component in `components/` was never denied. The directory vocabulary for Vue and Nuxt was enforced only by the push-time judge and by memory.

## What changed

- `claude/hooks/structure-gate.sh` gains a Nuxt branch. A package whose nearest `package.json` depends on `nuxt` roots the walk at `app/` and `server/`. Page directories and Nitro `server/api` and `server/routes` directories are exempt from the camelCase rule as URL segments. The R-305 folder-pairing check gains a `.vue` case for any package that depends on `vue` or `nuxt`.
- `claude/enforce/tests/structure-gate.test.sh` gains the AC-6 cases plus kebab, snake, abbreviation, route-directory, Vite-Vue, and non-Nuxt controls.
- `claude/skills/structure-conventions/SKILL.md` adds the Python vocabulary to R-304 and the Nuxt vocabulary to R-305, and its description no longer says the skill applies only to TypeScript. The Cursor and Codex copies are regenerated.
- `claude/enforce/manifest.json` notes for R-305, R-311, and R-312 name the Nuxt behavior, and the hash manifest is updated.

## Architectural decisions

- **The branch keys on the `nuxt` dependency, not the `.vue` extension.** The plan said either one would do. A `.vue` file in a Vite app lives under `src/`, which the gate already roots on, and treating any `.vue` path's `app/` segment as a root would misfire in a repository that happens to have an `app/` directory above `src/`. So the extension keys only the component-folder check, where it is exact.
- **Route directories are exempt the way Next's are.** Nuxt page directories and Nitro route directories become URL segments, so kebab-case there is the R-312 exception that already exists for Next's `app/`. A catch-all name under `pages/` is still denied, because the exemption covers directory case only.
- **Existing lines are unchanged except for one move.** The review focus asks that every existing condition stay byte-identical. The diff's 20 deleted lines are the two package-lookup helpers, and each one reappears verbatim above the walk, where the Nuxt detection needs them. A script checked this: every deleted line is re-added verbatim.

## Testing

- The new cases failed at the first Nuxt assertion before the change and pass after it.
- Every pre-existing Express, React, Python, Ruby, and Go case still passes, and so do the controls showing that `/x/app/utils/format.ts` and `/x/server/utils/format.ts` are untouched without a Nuxt package.
- The full enforce suite and the full hooks suite pass, and both port checks are clean.

## Reflection

About 15 minutes have passed since implementation started (at 13:35Z).

This time I read the neighbouring fixture's helpers before writing a single case, which is the lesson PR 5 taught, and no fixture needed a correction. The one design change from the plan, keying on the dependency rather than the extension, came from asking where a `.vue` file lives in each framework rather than what it is called.
