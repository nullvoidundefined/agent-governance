# Session Handoff: 2026-09-19, convention-track corrections (#75), template spec fixes, Nuxt track client rules

## 1. Last commit

- Last commit on `main` from this session: `45cf28a` (docs(tracks): correct the Python and Vue tracks from the FastAPI and Nuxt template build, #75). This PR's branch commits (from `f90fb3f`, IAN-159) are replaced on `main` by its squash commit. This handoff, the ISSUES.md move, and the PR document ship in the same PR, which squash-merges onto `main`.
- Earlier this session: agent-governance PR #75 merged as `45cf28a` (IAN-145); template-fastapi-nuxt PR #8 merged as `d9baabd` (IAN-146).

## 2. Production state

- The primary checkout was fast-forwarded to `51461e9` and `./sync.sh` ran at about 17:30Z; the live `~/.claude`, `~/.cursor`, and `~/.codex` matched `main` at that point (checked with `cmp` on `CLAUDE-PYTHON.md`, `ticket-at-start-gate.sh`, and `tdd.sh`). This PR's track changes reach the live tree only after the next `git pull --ff-only && ./sync.sh`.
- Codex was over its usage limit for this whole session; every pre-merge review ran on the fallback reviewer (a Claude subagent on fable) with `prompts/codex-pr-review-prompt.md`.
- The Linear connector sat at "pending" until the owner enabled it mid-session; the tools load by the exact names in `~/.claude/TICKET-TRACKER.json`.

## 3. Session metrics

- Commits: #75 had 2 branch commits (13 files, +262/-172), squash `45cf28a`; template #8 had 3 commits plus a merge of `main` (3 files), squash `d9baabd`; this PR has 1 commit so far plus this handoff.
- Rework: #75 had one fallback-review round of 7 findings (all fixed before the PR) and one Copilot round with no change needed. #8 had one review round of 8 findings and one Copilot finding, which is recorded on IAN-146 as rework 1.
- Velocity flag: normal. Two tickets closed at estimate ratios 0.54 and 0.56.

## 4. What shipped

- **Python, Vue, and Nuxt track corrections (#75, IAN-145).** Security and correctness fixes in `CLAUDE-PYTHON.md`'s own examples, each with its reason beside it: structlog `show_locals=False` (the old `dict_tracebacks` leaked the database password), proxy-chain rate-limit keying, idempotency binding with a lease and an owner token, webhook reclaim, email normalization, atomic reset tokens, asgi-correlation-id with a validator, a readiness timeout, the 413 body limit, and verify-full TLS. The 2026-09-19 stack decisions are applied: the breaker is optional, cleanup is an arq cron job, app state is `useState` rather than Pinia, and the client is openapi-fetch. The P1 invariant now skips `structlog.stdlib`, with a probe.
- **Template spec (template-fastapi-nuxt #8, IAN-146).** A per-request openapi-fetch client with no `useRequestFetch()`, base URLs that do not double `/v1`, server-side cookie, `X-Request-Id`, and `X-Forwarded-For` forwarding, and a `claim_token` on idempotency claims, with claim statements in their own transactions. New criteria B-52 and B-53. A heads-up went to IAN-126 (slice 01 PR 3) and IAN-130 (the Express template idempotency work).
- **This PR (IAN-159).** The Nuxt and Vue tracks now carry the spec's client rules: `shared/services/` for functions both `app/` and `server/` apply, the server-side base URL and headers, and `app/api/` functions taking the client as a parameter. ISSUES.md moves the `tdd.sh` per-test RED entry to Resolved, because #74 shipped the fix.

## 5. Pending (by urgency)

1. **Sync after this PR merges** (2 minutes): `git pull --ff-only && ./sync.sh` in the primary checkout.
2. **Task chip: isolate `task-cleanup-scan.test.sh` from the real tracker** (about 30 minutes). It fails on every local run on clean `main`, because it reads the owner's `~/.claude/TICKET-TRACKER.json` and `task-tier.sh set standard` now requires `--ticket`. CI stays green because it has no tracker file. `git-workflow-guard.test.sh` failed once in a full local run and passed alone, so it may have the same leak.
3. **Template spec follow-up** (10 minutes): once this PR merges, the template spec's sentence saying `shared/services/` departs from the Nuxt track is stale, and the spec's proxy description should name the query string as the track now does. Slice 01 PR 3 (#9) already built the client to the spec.

## 6. Next session

1. Run pending item 1. When testing locally, run the enforcement suite with `HOME` pointed at a temp directory whose `.claude` links to the checkout's `claude/`, until the fixture chip lands.
2. For template work, read the spec's Request path paragraph and the `request_idempotency_keys` row first, then `claude/CLAUDE-FRONTEND-NUXT.md` Auth Gating and Proxies.
3. Merge PRs with a bare `gh pr merge <n> --squash --delete-branch --repo <owner/repo>`, and run `gh pr create` in a separate call from the commit that adds `Refs:`, because the gates judge the whole command before it runs.
