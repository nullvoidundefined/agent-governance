# Build spec by slice rename

## Goal

Rename and refocus the existing `build-by-slice-require-review` skill as `build-spec-by-slice`: same incremental, human-reviewed TDD delivery, a name that pairs cleanly with the new `build-spec` mode (see `2026-09-17-build-spec-design.md`), and a documented, time-boxed compatibility alias so existing triggers, memory, and generated ports keep working during the transition. This spec changes identity and routing, not delivery behavior.

## Naming decision

Use `build-spec-by-slice` as the user-approved skill, directory, and invocation name, replacing `build-by-slice-require-review`. Retain the old name as a documented temporary compatibility alias. Remove the alias only after documentation and generated ports use the new name and the migration note has been available for a release.

## Inputs

- Existing `claude/skills/build-by-slice-require-review/SKILL.md`.
- Existing `claude/skills/tdd-gated-dispatch/SKILL.md`, `claude/skills/task-start/SKILL.md`, and `claude/skills/task-cleanup/SKILL.md`, which the renamed skill continues to call unchanged.
- Existing `claude/enforce/tdd.sh`, `claude/enforce/role-policy.json`, and `claude/hooks/protected-path-guard.sh`.
- Task routing tables, generated Codex output, tracking allowlists, README, and recipes that currently reference `build-by-slice-require-review`.
- The new `build-spec` mode (see sibling spec), for task-routing disambiguation only; this spec does not add or change `build-spec`'s behavior.

## Outputs

- `claude/skills/build-spec-by-slice/SKILL.md`, migrated from `claude/skills/build-by-slice-require-review/SKILL.md`, preserving its user review gates while emphasizing stable increments and changes between approved slices.
- A documented compatibility alias so `build-by-slice-require-review` still routes correctly until it is removed.
- Updated task routing, generated Codex skill output, and its required allowlist entry reflecting the new canonical name plus the alias.
- Updated README/recipes references from the old name to `build-spec-by-slice`.
- A corrected guardrail statement (see B-2) and removal of the unsupported velocity claim (see B-3).

## Mode contrast (reference)

| Dimension | Build by slice (`build-spec-by-slice`) | Build by spec (sibling) |
| --- | --- | --- |
| Primary objective | Stability and flexibility during delivery. | Speed from a settled spec to a complete verified result. |
| Planning horizon | Plan the next coherent delivery slice; retain a whole-feature outline. | Decompose the entire approved spec into dependency-ordered atomic tasks before production edits. |
| User review | Approve each slice plan and each PR under the existing review gates. | Invocation authorizes the in-scope build; no routine task/slice approval pauses. |
| Execution | Run TDD tasks continuously inside the approved PR. | Run TDD tasks continuously across the spec on its branch. |
| Change in direction | Revise upcoming slices after feedback; preserve completed work and record the change. | Resolve routine implementation choices autonomously; stop for changed scope or unresolved requirements. |
| Completion | An approved increment is integrated before the next review unit begins. | All criteria have verified evidence and the final diff is ready for review. |
| Correctness | Preserve TDD locks, independent authorship, and required reviews. | Preserve the same safeguards. |

This spec is authoritative only for the "Build by slice" column; the "Build by spec" column is shown for contrast and is authoritative in the sibling spec.

## Acceptance criteria

- B-1: `build-spec-by-slice` continues to require slice-plan and PR review before the next review unit. It runs tasks without per-task approval pauses inside an approved PR, unchanged from the current skill's behavior.
- B-2: The current guardrail wording that says not to start the next task until approval and merge is corrected, because it contradicts the existing no-per-task-stops instruction; the corrected wording ships with the renamed skill.
- B-3: The unsupported approximate 5x-velocity claim is removed from the skill's introduction.
- B-4: Slice mode records feedback and adjusts only upcoming, unlocked work. If feedback changes a locked requirement, invoke the existing dispute/replanning procedure; do not mutate the active spec under RED/GREEN.
- B-5: Task routing preserves `build-by-slice-require-review` as a documented compatibility trigger while migrating the canonical identifier to `build-spec-by-slice`, and this mode does not invoke `build-spec` as an additional approval layer.
- B-6: Generated Codex output and tracking allowlists reflect `build-spec-by-slice` as the canonical name, list `build-by-slice-require-review` as an alias for the transition window, and `node translate/codex.mjs --check` passes after regeneration.
- B-7: README and recipes reference `build-spec-by-slice`; any remaining reference to `build-by-slice-require-review` is explicitly marked as the compatibility alias, not presented as a second, competing skill.
- B-8: `build-spec-by-slice` continues to prevent the implementation author from rewriting its verifying tests, unchanged from the pre-rename skill's behavior.
- B-9: Scenario verification confirms the renamed skill's preserved slice-mode review gates and the alias resolving to the same skill as the canonical name.

## Invariants

- The rename and alias must not change delivery behavior: every acceptance criterion the pre-rename skill satisfied still holds post-rename.
- Reuse R-410, R-411, R-412, R-509, R-705, and R-707 without weakening gates or changing protected inputs.
- Keep required user decisions deliberate at review boundaries, as before the rename.
- Keep task progress outside locked specs. Do not force-add ignored planning files or handoffs.
- Preserve current approval requirements for merge, push, deployment, credentials, and remote writes.
- The compatibility alias is temporary and documented with a removal condition (documentation and generated ports use the new name, and the migration note has been available for a release).

## Failure modes

- A reference to the old name is missed during migration: tests and manifests fail when a referenced old name remains without an alias entry (see `2026-09-17-harness-naming-normalization-design.md` for the general mechanism this reuses).
- The alias silently becomes permanent: the removal condition in Invariants is unmet and is called out at the next docs/recipes review rather than left indefinite.
- Concurrent edit or changed spec during the rename: detect drift and pause, preserving both versions. Do not discard another session's work.
- Required review finds a gap in the renamed skill: create in-scope corrective work; do not report completion because the rename is done while behavior regressed.

## State transitions

Name lifecycle: `current` (`build-by-slice-require-review`) to `renaming` (both names route, alias active) to `canonical` (`build-spec-by-slice` is the only documented name) to `retired` (alias removed from files and generated outputs).

Task state: `pending` to `open` to `red` to `green` to `reviewed` to `closed`, unchanged from the pre-rename skill. `build-spec-by-slice` additionally waits at `slice-plan-review` and `pr-review`, unchanged.

## Non-goals

- No change to `build-spec`'s triggers, behavior, or acceptance criteria; that is the sibling spec.
- No bypasses, self-approved disputes, bulk implementation before RED, reduced tests, or silent weakening of critic scope.
- No new model-provider integration, scheduler, general workflow engine, or replacement TDD runner.
- No parallel write execution under a shared lock.
- No automatic merge, push, deployment, or guaranteed unattended completion for ambiguous specs.
- No removal of existing slice-review options.

## Dependencies

Reuse the skills and enforcement files named in Inputs, `claude/agents/test-author.md`, `claude/agents/implementer.md`, `claude/agents/slice-critic.md`, and `claude/agents/spec-conformance-review.md`. Update `RECIPES.md` when implementation lands. Inspect `translate/codex-port-map.json` and `codex/.gitignore` before generation. This rename should sequence with, or defer to, the broader `2026-09-17-harness-naming-normalization-design.md` lexicon work if both land close together, so the alias mechanism stays consistent across the harness.

No new third-party dependency is required.

## Observability

Record the rename's old-to-new mapping and the check commands run to confirm no orphaned references remain. Session handoffs name the alias's removal condition status when the rename is in the `renaming` state.

## Security

Renames must not expose local paths or private repo names in generated headers. The compatibility alias must not bypass guards or permissions.

## Domain vocabulary

- build by slice - incremental delivery with approved slice plans and reviewed PRs, optimized for stability and feedback - chosen over: build-by-slice-require-review because that is the pre-rename name this spec retires to a compatibility alias.
- delivery slice - a coherent user review unit that may contain multiple PRs and atomic tasks - chosen over: increment because increment does not carry the required-review connotation.
- compatibility alias - a temporary reference from `build-by-slice-require-review` to `build-spec-by-slice` with a documented removal condition - chosen over: deprecation because deprecation implies an end-of-life timeline this spec does not set.
- canonical name - `build-spec-by-slice`, the only name new documentation, triggers, and generated ports should use once the alias is retired - chosen over: preferred name because the harness needs one source of truth, not a preference among equals.
