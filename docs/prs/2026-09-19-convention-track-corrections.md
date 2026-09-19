# Convention tracks corrected from the FastAPI and Nuxt template build

Refs: IAN-145

## Summary

Specifying and building `templates/template-fastapi-nuxt` on 2026-09-19 exposed defects in the Python track's own examples, and the stack audit that day changed several defaults the Python and Vue tracks still prescribed. The worst defect is a secret leak: the track's logging example used `structlog.processors.dict_tracebacks`, which renders frame locals by default, and a probe on the template showed it writing the database password from asyncpg's connect frame into a readiness log line. Any project that copied the example would have done the same. This change corrects every example the build proved wrong, applies the owner's stack decisions, and states the reason beside each correction so a later reader can see why the text says what it says.

## What changed

- **`claude/CLAUDE-PYTHON.md`**, each change marked "corrected 2026-09-19" or "added 2026-09-19" with its reason in place:
  - Logging: tracebacks render through `ExceptionRenderer(ExceptionDictTransformer(show_locals=False))`, and standard-library records (uvicorn, asgi-correlation-id) reach the same renderer through `ProcessorFormatter` on the root handler, with uvicorn's own handlers cleared, so every production line is JSON.
  - Rate limiting keys on `request.client.host`, the IP uvicorn resolves through a trusted-proxy chain (`--proxy-headers`, `FORWARDED_ALLOW_IPS` set to the reverse proxy's private network as a CIDR and required in production, the proxy forwarding only the edge-appended last `X-Forwarded-For` entry), never the forgeable first hop; auth limits match full `/v1` paths.
  - Idempotency keys bind to `request_method`, `request_path`, and `request_body_hash` (mismatch answers 422 `IDEMPOTENCY_KEY_REUSED`), and claims carry a state (`in_progress`, `completed`) and a 60-second lease so a crashed claim is reclaimable.
  - The Stripe webhook claim is `ON CONFLICT DO UPDATE ... WHERE status = 'failed' OR (status = 'claimed' AND attempted_at < now() - interval '10 minutes')`, replacing `DO NOTHING`, which lost a failed event forever.
  - Sessions normalize email (trim, lowercase, unique index on `lower(email)`), and password resets are consumed by one atomic `UPDATE ... RETURNING`, expire after an hour, and invalidate earlier unused resets.
  - Request IDs come from asgi-correlation-id with a validator that accepts only `^[A-Za-z0-9._-]{1,64}$`; the hand-written middleware example is gone. Readiness is bounded by `asyncio.timeout`. The body limit reads up to 100 KB before calling the app and answers a larger body with a 413 it sends itself.
  - Postgres TLS verifies the certificate and hostname (`sslmode=verify-full` semantics through an `ssl.SSLContext`), with an optional `DATABASE_CA_CERT`, instead of `ssl=require`.
  - Owner decisions: the circuit breaker is optional, the scheduled cleanup is an arq cron job with no pg_cron, and asgi-correlation-id replaces the request-ID middleware. The error-code excerpt gains `IDEMPOTENCY_KEY_REUSED` and `INPUT_PAYLOAD_TOO_LARGE`. A stale line saying workers answer health through `arq --check` now points at the worker's `WORKER_PORT` probe, which the Worker Pattern section already specified.
- **`claude/CLAUDE-FRONTEND-VUE.md`**: app state is Nuxt `useState` composables; Pinia stays acceptable when a project needs a real store. openapi-fetch over the `openapi-typescript` output is the typed own-backend client. The directory, naming, state, import-order, and testing rows follow.
- **`claude/CLAUDE-FRONTEND-NUXT.md`**: the theme is a `useThemePreference` composable instead of a Pinia store, logout clears the session query instead of an auth store, and `api/apiClient.ts` builds a per-request openapi-fetch client that forwards the SSR cookie with `useRequestHeaders(['cookie'])`.
- **`claude/rulebook/reference.md`**: the Vue track's row in the convention-file table names `useState` and openapi-fetch.
- **`claude/ISSUES.md`**: a P2 records that `tdd.sh red` needs every test in each named file to fail, so a new failing test beside passing tests cannot be locked, and proposes per-test node IDs (pytest `file::test`) as the fix.
- **`claude/enforce/tests/convention-track-invariants.test.sh`**: P1's banned-term match ignores `structlog.stdlib` (see decisions), with a new P1a probe proving a bare `stdlib` is still caught.
- Regenerated: the Cursor port (`cursor/rules/*.mdc`, `cursor/.claude-port.json`) and `claude/enforce/hook-hashes.txt`. The Codex port has no change.

## Architectural decisions

- **Chosen: keep the `pg_cron Cleanup Jobs` and `Circuit Breaker` headings.** The invariant test asserts the Python track's 40 headings, so the sections keep their names and their contents say that pg_cron is not used and the breaker is optional. **Alternative:** rename the headings and edit the test's heading list. **Why not:** the task asked to keep the heading set, and a heading rename is a test change that would need the owner's approval.
- **Chosen: narrow P1's `stdlib` ban so it skips `structlog.stdlib`** (owner's choice this session). The corrected logging example has to call `structlog.stdlib.ProcessorFormatter`, which is structlog's own API rather than the rejected standard-library logging. **Alternatives:** describe the routing in prose only, which hides the fix the example exists to show; or drop `stdlib` from the ban, which gives up what the term protects. The P1a probe and a mutation run (appending "use stdlib logging" to the track made P1 fail) show the narrowed match still catches the real case.
- **Chosen: forward the SSR cookie with `useRequestHeaders(['cookie'])` on a per-request client, not `useRequestFetch()`.** openapi-fetch's `fetch` option takes a standard `fetch` that returns a `Response`, and `useRequestFetch()` returns Nuxt's `$fetch`, which returns the parsed body. The template spec passes `useRequestFetch()` as openapi-fetch's fetch function, and that mismatch is reported to the owner rather than repeated here.
- **Chosen: stay inside the 800 to 1000 line band.** The track grew with the corrections and shrank where asgi-correlation-id replaced a 34-line middleware example and the optional breaker and cron sections were condensed. The review fixes added lines, and merging the optional-breaker and cleanup bullets into single bullets paid for them. It now has exactly 1000 lines, the top of the band, and the band did not change.

## Testing

- `claude/enforce/tests/run-tests.sh`: ALL ENFORCEMENT TESTS PASS, including `convention-track-invariants.test.sh` (P1, P1a, P2 with 40 of 40 headings, P3 at 1000 lines).
- `claude/hooks/tests/run-tests.sh`: ALL HOOK TESTS PASS. `sync-tests/sync.test.sh` passes, and `node translate/codex.mjs --check` and `node translate/cursor.mjs --check` both exit 0.
- The first run of the invariant test failed P1 on the two `structlog.stdlib` lines, which is how the regex question surfaced.

## Codex review

**Reviewer:** a separate agent on Claude Fable standing in for Codex, which was out of quota until 18:00 (`codex exec` answered "You've hit your usage limit"). It reviewed the diff against the template spec and the template's built code, verified claims against the installed structlog 26.1, asgi-correlation-id 5.0.1, uvicorn 0.53, asyncpg 0.31, SQLAlchemy 2.0.54, and h3 1.15.11 sources, and reported seven findings. All seven are fixed in this PR.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | MEDIUM | The idempotency lease had no owner token, so a slow original process could overwrite or delete the claim that took it over | Fixed: `claim_token`, a single conditional takeover `UPDATE ... RETURNING`, and completion and release both scoped to `claim_token = :mine` |
| 2 | MEDIUM | The engine example still passed `connect_args` without `ssl`, contradicting the TLS bullet | Fixed: `connect_args=build_connect_args(settings)`, with the bullet saying what it returns per environment |
| 3 | MEDIUM | `FORWARDED_ALLOW_IPS=*` reinstates first-hop keying, and a missing value puts the site in one bucket | Fixed: never `*`, a CIDR for the private network, settings refuse production without it, uvicorn 0.53 floor named |
| 4 | MEDIUM | A module-scope openapi-fetch client with `useRequestHeaders` would carry one user's cookie into another user's SSR calls | Fixed: `createApiClient()` plus a per-request `useApiClient()` memoized on `useNuxtApp()` in both frontend tracks |
| 5 | MEDIUM | The Python track said the Nitro proxy forwards only the last `X-Forwarded-For` entry; the Nuxt track said headers pass through, and h3 forwards the header unchanged | Fixed: the Nuxt proxy bullet rewrites `X-Forwarded-For` to its last entry before `proxyRequest`, matching the template spec |
| 6 | LOW | The webhook claim returned `id`, which the column list omitted | Fixed: `id uuid PK` added |
| 7 | LOW | The request-ID example used `re` without importing it | Fixed: `import re` added |

Two of these (1 and 4) also apply to the template spec, whose idempotency row and request-path paragraph carry the same gaps; they are reported to the owner rather than edited from this repository.

## Ticket

IAN-145, opened when the Linear connector came up mid-session; `started_at` is 2026-09-19T09:13:40Z from the session-start record.

## Reflection

Work started at 09:13Z, and this document was written at about 09:30Z. What I understand now is that a convention track's code example has the same reach as a template: the `dict_tracebacks` line was copied into the template exactly as written, and the leak was found by a probe, not by reading. What I got wrong first was the body-limit wording. I wrote down the template's first fix, which counts bytes as the app reads them, and then saw that the template had moved on after Copilot's review to reading the body before the app runs, because a route that never reads its body slipped past the counting version. I also assumed the invariant test's `stdlib` ban meant only prose, and the corrected example tripped it on its first run.
