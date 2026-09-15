---
name: build-by-slice-require-review
description: Use when building or implementing a feature, starting a slice, or executing any multi-PR build where the user must review and approve the work as it lands. Triggers on "build", "implement", "start the slice", "next slice", or kicking off work from an approved spec.
---
<!-- Cloned from claude/skills/build-by-slice-require-review/SKILL.md. Do not edit here; change the source and re-copy. -->

# Build by Slice, Require Review

Run the build as a sequence of user-approved slices, each slice as a sequence of reviewable PRs, each PR as a sequence of strict TDD tasks. The human owns the architecture (the spec and the slice plans); the agent executes; comprehension is preserved by review at the gates. This is how a developer reaches roughly 5x velocity with AI without skill atrophy or a codebase that escapes their understanding.

**Announce at start:** "I'm using the build-by-slice-require-review skill to run this build slice by slice with review gates."

## Hard first step: read the spec

Before any planning or code, read the project's spec, its flows, and its acceptance criteria in full. Not optional. Build against the spec, not against assumptions. If no spec exists, stop and say so; this skill has nothing to build from.

## Three tiers of work

| Tier | Size | Definition |
|---|---|---|
| Slice | 1 to 2 days, may span several PRs | A coherent chunk of the build |
| PR | A few hundred to ~2000 lines | The review unit: one coherent concern, reviewable in one sitting |
| Task | One strict TDD cycle | The smallest unit, inside a PR |

Size PRs to the reader: go smaller for dense, concurrent, or security-sensitive code. Group a PR's tasks logically; never ship a tranche of mixed actions.

## The loop

1. Read the spec, flows, and acceptance criteria.
2. Plan the next slice: list its PRs and each PR's single concern.
3. **Gate 1:** present the slice plan and get explicit user approval before building.
4. Build each PR as a sequence of TDD tasks (below).
5. Open the PR; **Gate 2:** the user reviews and approves it on GitHub before merge. No auto-merge, no CLI merge; branch protection requires manual approval.
6. After merge, update the spec and the tracker, then start the next PR or slice.

For a hard or risky PR, write a one-paragraph explain-back of what it does and why before merge, and offer to send it to a third-party AI review (for example Copilot).

## TDD rules (every task)

1. **Red:** write the failing test first; run it and confirm it fails.
2. **Green:** write the minimal implementation to pass.
3. **Refactor:** clean up with tests green.

Tests cite the spec's acceptance criteria. End-to-end tests come from the spec's flows.

## Guardrails

- Don't start the next task, PR, or slice before the current one is approved and merged.
- Don't write implementation before its failing test.
- Don't merge without explicit approval; "looks fine" in chat is not a GitHub approval.
- Don't widen scope beyond the approved slice; defer new ideas to a Later list.
- Don't bundle unrelated concerns into one PR.
- No per-task stops: inside an approved PR, run task after task without asking.

## Living docs

Keep the project's spec and its task/PR tracker a factual reflection of the current state. Update them as each PR and slice completes, in the same PR when the change makes them stale.

## Review depth

Weight review by risk: skim boilerplate; interrogate the hard parts (concurrency, transactions, security, anything novel). Direct the user's attention there when presenting a PR.
