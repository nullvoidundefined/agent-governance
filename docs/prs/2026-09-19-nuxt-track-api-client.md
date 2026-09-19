# Nuxt and Vue tracks carry the template spec's API client rules

Refs: IAN-159

## Summary

Template-fastapi-nuxt PR #8 (IAN-146) settled how the Nuxt app talks to its backend, and three of those decisions go beyond what the Nuxt and Vue tracks said. A shared module lives in `shared/services/`, where the Nuxt track listed only `shared/types/`, so the spec had to record a departure. The server-side client has its own base URL and headers, which the tracks never stated. And `app/api/` functions take the client as a parameter instead of calling a composable. The template spec says the track wins when the two disagree, so the tracks are updated here to remove the disagreement before slice 01 PR 3 builds the client. This PR also moves a stale ISSUES.md entry to Resolved and carries the session handoff.

## What changed

- **`claude/CLAUDE-FRONTEND-NUXT.md`:**
  - The Framework rule and the directory tree add `shared/services/` for pure functions that both `app/` and `server/` must apply identically, such as `resolveClientAddress`, imported through `#shared`.
  - The Auth Gating client bullet sets `X-Requested-With` as a base header. It uses base URL `/api` in the browser and `runtimeConfig.apiBaseUrl` on the server, because the generated paths already carry `/v1`. Server-side calls carry the cookie, `X-Request-Id`, and a single-value `X-Forwarded-For`.
  - The Proxies bullet maps `/api/<rest>` to the backend's `/<rest>` and rewrites `X-Forwarded-For` through `resolveClientAddress`.
- **`claude/CLAUDE-FRONTEND-VUE.md`:** query composables obtain the client in setup and pass it to the `app/api/` function, which takes the client as its first parameter. `useApiClient()` never runs inside an `api/` function or after an `await`.
- **`claude/ISSUES.md`:** the 2026-09-19 `tdd.sh red` per-test entry moves to Resolved. PR #74 (IAN-139) shipped test node ids, but that PR left the entry open.
- **`docs/session-handoff/session-handoff.md`:** this session's handoff (R-602).
- The Cursor port is regenerated. The Codex port has no change, and neither do the hook hashes.

## Architectural decisions

- **Chosen: `shared/services/` in the Nuxt track.** **Alternative:** keep `shared/types/` only and duplicate the client-IP rule in `app/` and `server/`. **Why not:** two copies of a security rule drift. The structure gate already allows the path: a probe with a Nuxt package and a Write to `shared/services/resolveClientAddress.ts` passed.
- **Chosen: `api/` functions take the client as a parameter.** **Alternative:** each `api/` function calls `useApiClient()`. **Why not:** `useNuxtApp()` throws once an `await` inside a query function has dropped the Nuxt context, and `experimental.asyncContext` is off by default.

## Testing

- `claude/enforce/tests/run-tests.sh` and `claude/hooks/tests/run-tests.sh` both pass with `HOME` pointed at a temporary directory whose `.claude` links to the worktree's `claude/`, which matches how CI runs them. `sync-tests/sync.test.sh` passes, and both translator `--check` runs exit 0.
- With the real `HOME`, `task-cleanup-scan.test.sh` fails on clean `main` as well, because it reads the owner's tracker config. That problem predates this change and is filed as a separate task.

## Codex review

Filled in after the review runs.

## Reflection

Work started at 17:22Z (the ledger clock), and this document was written at about 17:38Z. The first ticket write carried a guessed `started_at`, which the session-start rule forbids; it was corrected to the ledger clock. The ISSUES entry this session filed in the morning was already fixed by another session's PR that afternoon. Checking `git log` before writing the handoff is what caught it.
