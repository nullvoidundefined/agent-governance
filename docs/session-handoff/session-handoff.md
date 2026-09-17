# Session Handoff: 2026-09-17 Voyager 2.0 kickoff, slice 01 PR 1, Linear tracker

## 1. Last commit

- Slice branch `feat/python-vue-conventions` at `7d85293` (PR #2 squash), based on `origin/main` `6bc9b24`, pushed. Carries the slice 01 spec (approved), the slice 01 plan (Gate 1 approved), the slice 02 spec and plan (awaiting owner review).
- PR branch `feat/slice01-pr1-add-stack-track` at `ab9f797 test(enforce): invariant test scopes session-types to its detection table and accepts only rules/*.md symlinks`, pushed; PR #2 open against the slice branch, CI green. Copilot reviewed three times (two requested, one automatic); all five inline threads replied with the fix SHA and resolved; the two-round cap is stated on the PR. Ticket IAN-73 (parent IAN-72), state in-review, rework_count 1. Gate 2 (owner approval and squash merge) is the only open step.
- Worktree: `agent-governance-conventions`, a sibling of the other checkouts. Local `main` in the hardening2 checkout is a stale divergent line (13 commits squashed into `6bc9b24`); branch off `origin/main`, never local `main`.

## 2. Production state

- Live `~/.claude` is behind `origin/main` `6bc9b24` (ticket-lifecycle skill, hook-integrity-check, secret-scan). Session-start integrity guard already warns of drift. Three fixture tests read `$HOME/.claude` and fail locally for that reason only: `credential-mutation-guard.test.sh`, `hook-hashes-closure.test.sh`, `hook-integrity-check.test.sh`. Expected green in CI, where `$HOME/.claude` links to the checkout. Fix is `./sync.sh` from a checkout at or past `6bc9b24`, then `hook-integrity-check.sh --update`.
- New invariant test `claude/enforce/tests/convention-track-invariants.test.sh` passes 5/5 locally. Hooks suite: 14 ok, 1 drift failure above.
- Linear tracker configured at `~/.claude/TICKET-TRACKER.json` (gitignored): active `linear`, team Ian.greenough.developer, one project per repository (Agent Governance, Voyager 2.0; template project pending its repo), four state labels created (specced, planned, in-review, blocked), canonical fields in a `ticket-fields` block at the top of each description. Linear is not yet in the skill's provider table. Tickets: IAN-72 (slice 01), IAN-73 (PR 1), IAN-74 (slice 02, backlog).
- GitHub rulesets: `require-pr-squash` (23599560) requires a PR and squash on `main` and `feat/python-vue-conventions` (direct pushes to the slice branch are blocked; docs ride in PR branches). `copilot-review-all-branches` (23605283) targets all branches with the independent `copilot_code_review` rule, `review_on_push` true, so every push gets an automatic Copilot pass; the older `automatic_copilot_code_review_enabled` parameter on the pull-request rule is silently dropped by the REST API and absent from GraphQL, so never use it. Standing rule from the owner, recorded in project memory and slice 02 PR 3: after opening a PR, poll for Copilot's review, verify each comment, fix the valid ones, reply to the rest, resolve threads with the SHA; two rounds cap.
- Open PRs at handoff time: PR #4 (slice 01 PR 2, frontend core split, Copilot round 1 fixed in a57a0a1) and PR #6 (chore against `main`: mcp-action-guard pre-authorizes the active tracker's tools from `TICKET-TRACKER.json`, fails closed on malformed configs, Copilot round 1 fixed in 8bda0f2). Both await Gate 2. After PR #6 merges, `./sync.sh` from a checkout at that commit ends the per-ticket prompts.
- Worktrees: `agent-governance-conventions` (chore branch checked out) and `agent-governance-pr4` (slice 01 PR 2 branch).
- Codex test authoring: `codex exec` needs stdin closed (`</dev/null`) and no `-m` (the cost.md model is rejected on this account); fix queued for slice 02.

## 3. What shipped

- Decisions (all owner-approved, logged as a comment on IAN-72): workstream order conventions, template, Voyager; Nuxt 4; SQLAlchemy 2 Core async on asyncpg with Alembic; arq; uv; structlog; four-file frontend split; enforcement scope E1 to E7 with the Python naming AST and SFC brace counting deferred; cross-provider gating judge; Linear per repo, ticket per slice and per PR; Voyager 2.0 reuses the 1.0 schema as one initial Alembic revision.
- Docs: `claude/docs/superpowers/specs/2026-09-17-python-vue-convention-tracks-design.md`; `docs/slices/slice-01-python-vue-conventions.md`; `claude/docs/superpowers/specs/2026-09-17-application-baseline-design.md` (slice 02: R-347, R-413, R-421 to R-426, Testing and Evals spec headings enforced by `spec-glossary-check.sh`, build-skill pointers).
- Code: `claude/skills/add-stack-track/SKILL.md`; the invariant test above, codex-authored, with a comment block above every function per the owner's new rule (proposed R-333, slice 02 PR 4).
- Slice 02 plan `docs/slices/slice-02-application-baseline.md` (four PRs: rules, spec template and hook, skill pointers plus ticket-lifecycle Linear row plus a new `repo-setup` skill, R-333) awaiting spec review then Gate 1.
- Research distilled into the specs and project memory: template-express-next inventory, Voyager 1.0 eval audit, LangGraph eval practice.
- Project memories (voyager_2.0 project dir): workstreams, testing bar, database reuse, answer tiles, no deprecated tools, codex procedure, Copilot loop, function comment blocks.

## 4. Pending, by urgency

- P1: Gate 2 for PR #4 (slice 01 PR 2) and PR #6 (guard chore, against `main`). After each merge: verify landing with `git log`, close the ticket with actuals (IAN-75 for PR #4). PR #2 merged 2026-09-17 as 7d85293; IAN-73 closed, ratio 3.7.
- Live `~/.claude` is synced by the other session from local `main` at c29bce9 (ahead of origin); never sync from a 6bc9b24-era checkout. The slice branch is based on 6bc9b24 and must be reconciled with `main` once c29bce9 is on origin, before slice 01 PR 7; expect conflicts in hook-hashes, README, reference.md, and skills, plus new checks (skills-lint needs a Cursor clone per skill, translate/cursor.mjs --check once it lands).
- P2: Re-apply `automatic_copilot_code_review_enabled` on ruleset 23599560 now that Copilot is active, and verify the parameter persists. About 5 minutes.
- P2: Owner review of the slice 02 spec, then Gate 1 on its slice plan (written, four PRs).
- P2: Add a Linear row to the ticket-lifecycle skill's provider table and the project-per-repository rule; fold into slice 02 PR 3 or a `chore(skills)` PR. About 20 minutes.
- P2: The slice 01 spec's Domain vocabulary lacks the `chosen over:` form the advisory hook expects (written via Bash, hook did not fire). About 10 minutes, bundle into PR 2.
- P3: Later list: delete stale `enforce/eslintOptions.mjs`; template seed script rewrite (template workstream); Python naming-lexicon AST; SFC-aware clean-code scan; judge calibration tooling; `observability-reminder.sh` span check.
- P3: Create the template-fast-api-vue Linear project when that repo is initialized.

## 5. Next-session tasks

- Read first: `docs/slices/slice-01-python-vue-conventions.md` (execution record), `claude/docs/superpowers/specs/2026-09-17-python-vue-convention-tracks-design.md` section 1, `~/.claude/TICKET-TRACKER.json`, `claude/skills/ticket-lifecycle/SKILL.md`, `claude/skills/add-stack-track/SKILL.md`.
- If PR #4 merged: close IAN-75; open the IAN child and branch `feat/slice01-pr3-vue-nuxt-tracks` off the slice branch; PR 3 writes `CLAUDE-FRONTEND-VUE.md` and `CLAUDE-FRONTEND-NUXT.md` per spec section 1 (the paths-scope fixture's A4 assertion switches from skipped to active once they exist). Run the add-stack-track skill end to end.
- If slice 02 spec approved: write `docs/slices/slice-02-application-baseline.md` in the PR description format, Gate 1.
- Codex test authoring: `codex exec -s workspace-write --skip-git-repo-check -C <repo> '<contract>' </dev/null > <log> 2>&1`, no `-m`, no pipe; include the function comment-block requirement in every contract. Review fixes to a codex-authored test go back to codex the same way (three passes this session, each under 5 minutes).
- The fix-commit-requires-test hook does not count `*.test.sh` as a test file; label a fixture-only correction `test(enforce):`, and add the `.test.sh` pattern to that hook in slice 02 PR 4 alongside R-333.
