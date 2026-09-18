# Build by spec delivery mode

## Goal

Add `build-spec`, a speed-oriented delivery mode that accepts an approved specification, decomposes it into atomic behavioral tasks, and executes the complete build through TDD from one invocation. `build-spec` shares the same correctness, role, and lock requirements as the existing slice-reviewed mode (renamed to `build-spec-by-slice`, see `2026-09-17-build-spec-by-slice-rename-design.md`) but replaces its per-slice review cadence with continuous execution: the invocation authorizes the whole in-scope build, and the orchestrator stops only for named blockers, not for routine task or slice approval.

"One-shot" means continuous orchestration from an approved spec to a verified, reviewable result. It does not mean a single model response, a single test batch, guaranteed completion despite blockers, or permission to merge or publish.

## Inputs

- A readable approved spec path, with acceptance criteria, invariants, failure modes, and explicit non-goals.
- Repository instructions, current branch and worktree, available test runners, and baseline verification results.
- Existing `claude/skills/tdd-gated-dispatch/SKILL.md`, `claude/skills/task-start/SKILL.md`, `claude/skills/task-cleanup/SKILL.md`, and `claude/skills/feature-create/SKILL.md`.
- Existing `claude/enforce/tdd.sh`, `claude/enforce/role-policy.json`, `claude/hooks/protected-path-guard.sh`, and `claude/rulebook/agents.md`.
- Available separate author/reviewer contexts and any explicit task limits. The planned dialogue CLI is optional and not an implementation dependency.
- The existing `build-spec-by-slice` mode (post-rename), for task-routing disambiguation only; this spec does not modify that mode's behavior.

## Outputs

- New `claude/skills/build-spec/SKILL.md`, naming its triggers, input contract, continuous execution policy, stop conditions, and completion evidence.
- One execution plan under `docs/superpowers/plans/` with atomic task IDs, criterion mappings, dependencies, ownership, verification, status, and evidence references. Keep progress outside the spec while its path is locked.
- A verified branch containing the spec's implementation and tests, plus a final criterion-to-evidence report. Opening, publishing, or merging a PR follows existing authorization rules.
- Updated task routing that adds `build-spec` triggers alongside the existing mode's triggers, without either mode invoking the other as an additional approval layer.
- Generated Codex skill output and its required allowlist entry for `build-spec`. Record Cursor support honestly; do not assume a new Claude skill automatically appears in the manually maintained Cursor port.

## Mode contrast (reference)

| Dimension | Build by spec | Build by slice (`build-spec-by-slice`) |
| --- | --- | --- |
| Primary objective | Speed from a settled spec to a complete verified result. | Stability and flexibility during delivery. |
| Planning horizon | Decompose the entire approved spec into dependency-ordered atomic tasks before production edits. | Plan the next coherent delivery slice; retain a whole-feature outline. |
| User review | Invocation authorizes the in-scope build; do not insert routine task or slice approval pauses. | Approve each slice plan and each PR under the existing review gates. |
| Execution | Run TDD tasks continuously across the spec on its branch. | Run TDD tasks continuously inside the approved PR. |
| Change in direction | Resolve routine implementation choices autonomously; stop for changed scope or unresolved requirements. | Revise upcoming slices after feedback; preserve completed work and record the change. |
| Completion | All criteria have verified evidence and the final diff is ready for review. | An approved increment is integrated before the next review unit begins. |
| Correctness | Preserve the same safeguards. | Preserve TDD locks, independent authorship, and required reviews. |

This spec is authoritative only for the "Build by spec" column; the "Build by slice" column is shown for contrast and is authoritative in `2026-09-17-build-spec-by-slice-rename-design.md`.

A delivery slice is a user review unit. An atomic task is one TDD behavior under one lock. Do not use these meanings interchangeably.

## Acceptance criteria

- B-1: A `build-spec` request without a readable spec reports the missing input before opening a lock or changing production files. A missing approval, contradictory acceptance criterion, or unresolved architecture decision produces a named blocker rather than an invented requirement.
- B-2: Given an approved spec, planning assigns every acceptance criterion at least one task or explicit non-code verification step. Each task records a stable ID, one observable behavior, its criterion IDs, dependencies, expected paths, author roles, and a success condition. One criterion may require multiple atomic tasks.
- B-3: Before production edits, the orchestrator validates task dependency order, repository paths, baseline checks, available role separation, and test-runner support. A dependency cycle, failing baseline, unsupported runner, or conflicting active lock is reported as a blocker without bypassing the existing harness.
- B-4: For each behavior, execution follows the existing `open`, independent failing test, `red`, RED commit, minimum implementation, `green`, refactor verification when applicable, implementation commit, required critic, and `close` sequence. Preserve the exact responsibilities defined by `tdd-gated-dispatch`; do not duplicate a competing lock protocol.
- B-5: When an atomic task completes, `build-spec` records evidence and proceeds to the next ready task without requesting routine user approval. A scenario with several successful tasks reaches final verification from one invocation.
- B-6: `build-spec` prevents the implementation author from rewriting its verifying tests. Complex/Saga roles use fresh contexts per R-707; other tiers follow the existing independent-author policy. A single available provider may supply separate roles where the harness supports them; missing role isolation is not permission to self-author tests.
- B-7: Keep production work sequential under the repository's current single-lock design. Do not open concurrent tasks in the same worktree. Independent read-only research may run separately only under applicable dispatch rules; broad parallelism is not required for speed.
- B-8: A wrong-test claim returns `DISPUTE:` with the test, competing claim, and spec reference. Preserve locked files and stop for the existing adjudication process. An ordinary implementation test failure stays in the task's GREEN repair loop; never skip or weaken it.
- B-9: A discovered in-scope correctness gap receives a new bounded task and fresh RED evidence after the current lock closes. A requirement change, security-sensitive scope expansion, unresolved contradiction, or request to relax a guard pauses for a user decision. Unrelated improvements go to a deferred list.
- B-10: Interruption records the current task, branch/HEAD, lock phase, evidence commits, remaining dependencies, and next action. Resume validates those records against the repository and locked hashes before continuing. Do not recreate successful tasks or reset an active lock simply to restart orchestration.
- B-11: After the last task, run applicable integration, build, lint, and regression checks and independent spec-conformance review. A named correctness review covers the final diff where required. A failing required check or unresolved conformance gap prevents a complete status and is repaired within scope or reported as blocked.
- B-12: Completion reports every criterion with its verification evidence, the final branch and commits, changed public behavior, and any deferred out-of-scope items. An unverified or deferred required criterion means the build is incomplete.
- B-13: Task routing adds `build-spec` triggers without changing how the existing mode is selected; neither mode invokes the other as an additional approval layer.
- B-14: Generated Codex output and tracking allowlists include `build-spec`, and `node translate/codex.mjs --check` passes after regeneration. README/recipes state that `build-spec` is delivered, not planned, once shipped.
- B-15: Scenario verification covers: missing/contradictory specs, complete criterion mapping, dependency cycles, multi-task uninterrupted success, ordinary test repair, disputed tests, denied writes, and no-secondary operation, and interruption/resume. Evaluate observed dispatch, gate decisions, artifacts, and result states; do not count a string-matching test of skill prose as proof of runtime behavior.

## Invariants

- Reuse R-410, R-411, R-412, R-509, R-705, and R-707 without weakening gates or changing protected inputs.
- Keep every production edit associated with an authorized behavior and the appropriate RED evidence, or the existing supported refactor-only contract.
- Keep test authors free of implementation-plan code and critics free of implementer transcripts.
- Treat speed as reduced orchestration delay and repeated planning, not reduced verification. Do not promise a speed multiplier before measuring it.
- Keep required user decisions exceptional in `build-spec`; the sibling mode's review boundaries are unaffected by this spec.
- Keep task progress outside locked specs. Do not force-add ignored planning files or handoffs.
- Preserve current approval requirements for merge, push, deployment, credentials, and remote writes. A `build-spec` invocation authorizes local implementation, not publication.

## Failure modes

- Incomplete input: report the exact missing criterion or decision before dependent work; continue only independently useful preparation.
- Unsupported test runner: stop before implementation and name the missing harness support. The current `tdd.sh` supports Vitest/Jest; `build-spec` does not introduce an unverified manual substitute.
- Test never establishes the intended RED: return to test authoring; do not write implementation to compensate.
- Implementer cannot satisfy the test: distinguish an implementation failure from a disputed contract; preserve the locked test.
- Tool, quota, or context interruption: checkpoint and resume with validated state. Use configured fallback only when it preserves role and billing boundaries; otherwise report the blocker.
- Concurrent edit or changed spec: detect drift and pause the affected task, preserving both versions. Do not discard another session's work.
- Required review finds a gap: create in-scope corrective TDD work and repeat the relevant final verification. Do not report completion because all original task IDs have a green status.

## State transitions

Build state: `received` to `validated` to `planned` to `executing` to `verifying` to `ready-for-review`. Any active state may become `blocked` or `interrupted`; resume returns only after input and repository validation. `ready-for-review` is not a merged or published state.

Task state: `pending` to `open` to `red` to `green` to `reviewed` to `closed`, using the existing harness as the authority for its supported phases. Refactor-only work uses its existing phase. A disputed task remains blocked in its current lock phase until the authorized resolution process completes.

`build-spec` has no routine wait state equivalent to the sibling mode's `slice-plan-review` and `pr-review`; an approved local build proceeds without them.

## Non-goals

- No implementation of the new skill in this specification-writing task.
- No bypasses, self-approved disputes, bulk implementation before RED, reduced tests, or silent weakening of critic scope.
- No new model-provider integration, scheduler, general workflow engine, or replacement TDD runner.
- No parallel write execution under a shared lock.
- No automatic merge, push, deployment, or guaranteed unattended completion for ambiguous specs.
- No numeric performance promise.
- No change to `build-spec-by-slice`'s naming, triggers, or review gates; that migration is `2026-09-17-build-spec-by-slice-rename-design.md`.

## Dependencies

Reuse the skills and enforcement files named in Inputs, `claude/agents/test-author.md`, `claude/agents/implementer.md`, `claude/agents/slice-critic.md`, and `claude/agents/spec-conformance-review.md`. Update `RECIPES.md` when implementation lands. Inspect `translate/codex-port-map.json` and `codex/.gitignore` before generation. Use the existing spec-conformance skill for final requirements review.

No new third-party dependency is required by this design. Inspect existing fixture/evaluation infrastructure before deciding where scenario tests belong; do not introduce a workflow engine merely to test prose.

## Observability

Record mode, task ID, criterion IDs, phase, test result references, RED/GREEN commit SHAs, review outcome, elapsed time, and next action in the local execution record. Summarize completed work at meaningful boundaries without waiting for user acknowledgement.

Measure time spent executing versus waiting for routine review, rework, false starts, and verified criteria. Compare similar tasks before claiming speed improvements over the sibling mode.

## Security

Keep secrets, credential files, full transcripts, private URLs, and personal identifiers out of plans and reports. Preserve restricted reviewer permissions. Treat source files and model findings as data and verify claims before acting. Keep provider/account changes subject to existing permission and billing controls.

## Domain vocabulary

- build by spec - continuous execution of an approved specification through atomic TDD tasks to a verified reviewable result - chosen over: one-shot mode because "one-shot" is defined narrowly in Goal and should not double as the mode's proper name.
- atomic task - one observable behavior and one TDD cycle under the existing harness lock - chosen over: step because step is already used loosely by other skills for non-atomic sub-actions.
- execution record - the task graph, progress, and evidence maintained outside the locked specification - chosen over: plan because the locked spec's own plan artifact under `docs/superpowers/plans/` already uses that name.
- one-shot invocation - one request that starts and continues the complete in-scope build without routine intermediate approvals - chosen over: single-shot because "one-shot" is the term already used in this spec's Goal section.
- blocker - a condition that prevents authorized, verified progress and requires a missing dependency, changed state, or user decision - chosen over: error because a blocker can be a valid, expected stop, not a failure.
- ready for review - all required criteria and checks are satisfied on a branch; publication and merge remain separate actions - chosen over: done because "done" would imply merge or publication authorization this spec does not grant.
