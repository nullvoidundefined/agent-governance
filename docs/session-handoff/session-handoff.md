# Session Handoff: 2026-09-17 Voyager 2.0 kickoff, slice 01 PR 1, Linear tracker

## 1. Last commit

- Slice branch `feat/python-vue-conventions` at `4fe10db docs(specs): application baseline design for testing levels, tracing, and agent evals`, based on `origin/main` `6bc9b24`, pushed. Carries the slice 01 spec (approved), the slice 01 plan (Gate 1 approved), and the slice 02 spec (awaiting owner review).
- PR branch `feat/slice01-pr1-add-stack-track` at `a2b1706 feat(skills): add-stack-track skill and convention-track invariant test`, pushed; PR #2 open against the slice branch, CI fixtures job pending at handoff time. Ticket IAN-73 (parent IAN-72), state in-review.
- Worktree: `agent-governance-conventions`, a sibling of the other checkouts. Local `main` in the hardening2 checkout is a stale divergent line (13 commits squashed into `6bc9b24`); branch off `origin/main`, never local `main`.

## 2. Production state

- Live `~/.claude` is behind `origin/main` `6bc9b24` (ticket-lifecycle skill, hook-integrity-check, secret-scan). Session-start integrity guard already warns of drift. Three fixture tests read `$HOME/.claude` and fail locally for that reason only: `credential-mutation-guard.test.sh`, `hook-hashes-closure.test.sh`, `hook-integrity-check.test.sh`. Expected green in CI, where `$HOME/.claude` links to the checkout. Fix is `./sync.sh` from a checkout at or past `6bc9b24`, then `hook-integrity-check.sh --update`.
- New invariant test `claude/enforce/tests/convention-track-invariants.test.sh` passes 5/5 locally. Hooks suite: 14 ok, 1 drift failure above.
- Linear tracker configured at `~/.claude/TICKET-TRACKER.json` (gitignored): active `linear`, team Ian.greenough.developer, one project per repository (Agent Governance, Voyager 2.0; template project pending its repo), four state labels created (specced, planned, in-review, blocked), canonical fields in a `ticket-fields` block at the top of each description. Linear is not yet in the skill's provider table.

## 3. What shipped

- Decisions (all owner-approved, logged as a comment on IAN-72): workstream order conventions, template, Voyager; Nuxt 4; SQLAlchemy 2 Core async on asyncpg with Alembic; arq; uv; structlog; four-file frontend split; enforcement scope E1 to E7 with the Python naming AST and SFC brace counting deferred; cross-provider gating judge; Linear per repo, ticket per slice and per PR; Voyager 2.0 reuses the 1.0 schema as one initial Alembic revision.
- Docs: `claude/docs/superpowers/specs/2026-09-17-python-vue-convention-tracks-design.md`; `docs/slices/slice-01-python-vue-conventions.md`; `claude/docs/superpowers/specs/2026-09-17-application-baseline-design.md` (slice 02: R-347, R-413, R-421 to R-426, Testing and Evals spec headings enforced by `spec-glossary-check.sh`, build-skill pointers).
- Code: `claude/skills/add-stack-track/SKILL.md`; the invariant test above.
- Research distilled into the specs and the Voyager 2.0 project memory (raw agent reports were not persisted): template-express-next feature inventory (17 routes, middleware order, auth, infra clients, four test levels, CI, Docker), Voyager 1.0 product and eval-harness audit (three tracks, 54 attacks over 8 categories, two-layer verdict, free-text judge output, no CI gate, no dataset hash), LangGraph eval practice (five levels, structured judges, baseline gating, OpenTelemetry tracing).
- Project memories (voyager_2.0 project dir): workstreams and decisions, testing and observability bar, database reuse, questions as answer tiles, no deprecated tools, background codex log file.

## 4. Pending, by urgency

- P1: Gate 2 review and merge of PR #2 on GitHub (squash, delete branch, verify landing on the slice branch with `git log`). Then close IAN-73 with actuals and start PR 2 (frontend core refactor). About 10 minutes to close out.
- P1: Sync `origin/main` into live `~/.claude` to clear the three drift failures and the integrity warning. About 5 minutes, owner's checkout.
- P2: Owner review of the slice 02 spec, then its slice plan (three PRs) and Gate 1. About 20 minutes to write the plan.
- P2: Add a Linear row to the ticket-lifecycle skill's provider table and the project-per-repository rule; fold into slice 02 PR 3 or a `chore(skills)` PR. About 20 minutes.
- P2: The slice 01 spec's Domain vocabulary lacks the `chosen over:` form the advisory hook expects (written via Bash, hook did not fire). About 10 minutes, bundle into PR 2.
- P3: Later list: delete stale `enforce/eslintOptions.mjs`; template seed script rewrite (template workstream); Python naming-lexicon AST; SFC-aware clean-code scan; judge calibration tooling; `observability-reminder.sh` span check.
- P3: Create the template-fast-api-vue Linear project when that repo is initialized.

## 5. Next-session tasks

- Read first: `docs/slices/slice-01-python-vue-conventions.md` (execution record), `claude/docs/superpowers/specs/2026-09-17-python-vue-convention-tracks-design.md` section 1, `~/.claude/TICKET-TRACKER.json`, `claude/skills/ticket-lifecycle/SKILL.md`, `claude/skills/add-stack-track/SKILL.md`.
- If PR #2 merged: `ticket-lifecycle close` on IAN-73; open IAN child for PR 2; branch `feat/slice01-pr2-frontend-core-split` off the slice branch; read `claude/CLAUDE-FRONTEND.md`, `CLAUDE-FRONTEND-NEXT.md`, `CLAUDE-FRONTEND-VITE.md` in full before moving content.
- If slice 02 spec approved: write `docs/slices/slice-02-application-baseline.md` in the PR description format, Gate 1.
- Codex test authoring: run in the background to a log file, no pipe, allow 15 minutes before judging liveness.
