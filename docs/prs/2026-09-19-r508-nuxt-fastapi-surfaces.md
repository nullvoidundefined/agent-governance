# PR: R-508 surface list covers Nuxt pages, Nitro routes, and FastAPI routers

Ticket: IAN-118. Branch: `fix/r508-nuxt-fastapi-surfaces`.

## Summary

`claude/hooks/git-workflow-guard.sh` warns when a commit adds a user-facing surface without touching a README (R-508), but its surface list only knew the Next.js and Express shapes. A commit that added a Nuxt page under `app/pages/`, a Nitro handler under `server/api/`, or a FastAPI router under `app/routers/` produced no warning, even though the R-607 feature checklist already treats every one of those as a new route. This PR adds those surfaces to the guard, widens the Next.js page and route patterns to the extensions the checklist accepts, and adds a fixture that fails whenever the guard stops covering a route the checklist triggers on.

## What changed

- `claude/hooks/git-workflow-guard.sh` now keeps its R-508 surface patterns in a named array, `R508_SURFACE_PATTERNS`, instead of one long alternation. The array adds `(^|/)app/pages/.+\.vue$`, `(^|/)server/api/`, and `(^|/)app/routers/[^/]+\.py$`, and widens `page.tsx` and `route.ts` to `(page|route)\.(tsx|ts|jsx|js)`. Nitro's `server/routes/` was already covered by the existing `(routes|handlers)/` pattern. The comment above the array names the checklist as the list it must cover and explains why the two cannot share one file.
- `claude/enforce/tests/git-workflow-guard.test.sh` gains three groups of cases. Eight named surfaces must each warn, including a dynamic Nuxt page (`app/pages/trips/[id].vue`) and a monorepo prefix (`apps/client/web/app/pages/about.vue`). Three non-surfaces must stay silent: a Vue component under `app/components/`, a composable, and a Python service module. A parity group reads `BUILTIN_TRIGGERS` straight out of `claude/enforce/require-feature-checklist.sh` and requires the guard to warn on every sample path any of those triggers matches.
- The hash manifest is regenerated.

## Architectural decisions

- **The two lists stay separate, and a fixture enforces their agreement.** The ticket asked for one source if a shared helper already existed. None does: `hooks/push-feature-docs-gate.sh` already runs the checklist script itself, so it has no list of its own, and the checklist is the only other list. Moving the checklist's triggers into a sourced helper was the alternative, but repo-setup copies `require-feature-checklist.sh` into product repositories as a standalone `scripts/require-feature-checklist.sh`, where a sibling helper would not exist, so the script must stay self-contained. A parity fixture that parses the checklist's array gives the same guarantee without a new module.
- **The guard's list stays broader than the checklist's.** R-508 also treats `features/`, `.env.example`, compose files, and Dockerfiles as user-facing, and it fires on any file under `routes/` or `handlers/`, not only route files. Those are setup and structure changes the README must describe, which is a wider question than R-607's "did this branch add a route". Parity is therefore one-directional: every checklist route is an R-508 surface, not the reverse.
- **The patterns became an array.** The alternative was to append three more alternatives to a regular expression that was already over 150 characters. An array with one pattern per line makes each surface reviewable and matches the checklist's own shape.

## Testing

- Red first: with the guard unchanged, the fixture stopped at `expected a R-508 warning for: git commit -m "feat: surface"` on the first new case, `app/pages/index.vue`. After the change it prints `git-workflow-guard.test.sh PASS`, and stashing the guard change alone brings the same failure back.
- The first draft of the parity group used `src/routes/jobs.ts`, which the fixture had already committed, so it was a modification rather than an addition and the guard correctly stayed silent; the sample names were changed to fresh files. The group also counts the samples it checked and requires exactly eight, and it matches with a here-string rather than a pipe, so a `SIGPIPE` under `pipefail` cannot skip a sample silently.
- The full enforce suite and the full hooks suite pass, `shellcheck --severity=error` is clean, and both port `--check` runs are clean.

## Reflection

The ticket named three places to align, and reading them showed that only one actually carried a list: the push gate delegates to the checklist, and the checklist already had every pattern. The real gap was narrower than it looked, and the durable part of the fix is the parity fixture rather than the three new patterns, because the next stack added to the checklist would otherwise drift out of R-508 the same way these three did.
