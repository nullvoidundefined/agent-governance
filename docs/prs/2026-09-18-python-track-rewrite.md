# PR: CLAUDE-PYTHON.md rewrite (slice 01 PR 4)

Ticket: IAN-92 (parent IAN-72). Branch: `feat/python-track-rewrite`. Spec: `claude/docs/superpowers/specs/2026-09-17-python-vue-convention-tracks-design.md`, section 2. Plan: `docs/slices/slice-01-python-vue-conventions.md`, PR 4.

## Summary

This PR rewrites the Python convention file from 199 lines to 998 lines, following the spec's 40-section outline, so that the FastAPI template can be specified against rules that exist. The old file offered Django, Celery, a second installer, and the standard logging module as alternatives to the settled decisions, and it lacked the worker, session store, middleware order, response envelope, and the fourteen infrastructure patterns the Express template implements. The new file removes every alternative and documents each of those patterns in the same shape the Express template uses, so that one frontend can talk to either backend.

## What changed

- `claude/CLAUDE-PYTHON.md` is replaced. Its sections follow the Express file's macro order (stack, structure, naming, app wiring, data layer, cross-cutting concerns, tooling), and it keeps the sections the Express file lacks (File Layout, Testing, Enforcement, Build/Run Assets).
- `claude/enforce/tests/convention-track-invariants.test.sh` gains a Python-track block. P1 checks that no rejected alternative is named, P2 checks the 40 outline headings, and P3 checks the 800 to 1000 line band. These cover AC-3 and AC-4.
- `claude/enforce/hook-hashes.txt` is updated for that hashed test file, and the Cursor port's `python.mdc` is regenerated.
- The slice plan's execution record gains rows 3 and 4.

## Architectural decisions

- **The connection dependency is declared with `scope="function"`.** FastAPI's default request scope runs a `yield` dependency's exit code after the response is sent. With the default, a commit that fails would follow a 201 the client already received. Function scope commits before the response is sent. I confirmed this against the current FastAPI documentation before writing the rule. The alternative, an explicit commit in every route, repeats the same line in every route and is easy to forget.
- **Every middleware is a pure ASGI class.** `BaseHTTPMiddleware` breaks streaming responses and context-variable propagation, and the timeout and idempotency middleware both wrap streaming routes. The cost is more boilerplate per middleware.
- **The middleware order is stated twice: as registration order and as request order.** Starlette wraps middleware from the outside in, so the list in `register_middleware` is the reverse of the order a request meets them. Copying the Express list as written would have reversed the whole stack.
- **The envelope is `{ code, error }` for errors and `{ data }` for success.** These are the shapes the Express template actually returns, so a single frontend `apiFetch` handles both backends. `CLAUDE-BACKEND.md` still documents the older `{ error: { message } }` shape, which is a separate drift for a separate PR.
- **Table names follow R-334, not the spec.** R-334 (compound naming) merged after this spec was written, so the file uses `user_sessions`, `request_idempotency_keys`, and `billing_webhook_events` in place of the spec's `sessions`, `idempotency_keys`, and `stripe_events`.

## Testing

- P1, P2, and P3 failed against the 199-line file and pass against the rewrite.
- The first full draft was 1,060 lines, so P3 failed. I trimmed duplicate examples (three of the five router routes, one of the two repository methods, and the leaves of the directory tree) rather than widening the band, because the test was already locked.
- The full enforce suite and the full hooks suite pass with `HOME` pointed at this checkout, and both port `--check` runs are clean.
- The file contains no em dash and no credential-shaped URI.

## Reflection

About 45 minutes have passed since implementation started (at 11:35Z).

This PR taught me that FastAPI's default dependency scope commits after the response. I first wrote the connection dependency the common way, and only a documentation check prompted by this PR's review focus caught it. I also wrote the first draft 6 percent over the line band because I copied every Express example one for one, when a single example per pattern teaches the same thing.
