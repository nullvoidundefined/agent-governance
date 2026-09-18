# Recipes documentation

## Goal

Create a professional day-to-day task cookbook for the `agent-governance` harness: how to start a feature, write a spec, run a test-first slice, review work, clean up docs, sync live tool directories, and end a session. Installation and verification live in a separate spec (`2026-09-17-setup-design.md`); this spec owns recurring workflows for an already-installed harness.

## Inputs

- Existing skills: `task-start`, `tdd-gated-dispatch`, `feature-create`, `task-cleanup`, `cleanup-specs-plans`, `session-handoff`, `bug-hunt`, `known-issues`.
- `build-spec` and `build-spec-by-slice` (see `2026-09-17-build-spec-design.md` and `2026-09-17-build-spec-by-slice-rename-design.md`), once named and shipped.
- The cross-model dialogue spec (`2026-09-17-cross-model-dialogue-design.md`), for a review-dispatch recipe.
- The setup doc (sibling spec), for the "which document do I read?" table only.

## Outputs

- `RECIPES.md` at the repo root or a `docs/recipes.md` equivalent, covering common day-to-day tasks with commands and expected outputs.
- README link to `RECIPES.md`.

## Acceptance criteria

- B-1: Recipes docs include "start a new feature", "write or update a spec", "run a TDD slice", "dispatch a reviewer", "run cleanup at task end", "sync live configs", "prepare for public push", and "write a session handoff".
- B-2: Each recipe states the trigger, command sequence, expected success signal, and where to look when it fails.
- B-3: Recipes reference skills by their final clean names after the naming-normalization spec (`2026-09-17-harness-naming-normalization-design.md`) lands, or include a compatibility note for old names.
- B-4: Recipes avoid long explanations of internal history and link to protocol docs when rationale is needed.
- B-5: Recipes docs are safe for public readers and contain no local paths beyond examples that use placeholders.

## Invariants

- Commands in recipes are copy-paste safe from the repository root unless the recipe says otherwise.
- Recipes do not bypass hooks, tests, or TDD locks.

## Failure modes

- A recipe command differs by operating system: document macOS as the maintained path, same policy as the setup doc.
- A recipe overlaps a skill: link the skill and give only the operator-facing command path.

## State transitions

None. Recipes may reference the setup doc's `uninstalled`/`synced`/`verified` states but do not implement them.

## Non-goals

- No replacement for skill files; recipes are human-facing operational docs.
- No installation or verification content; see `2026-09-17-setup-design.md`.

## Dependencies

- Public documentation refresh (`2026-09-17-public-documentation-design.md`) should link to this doc.
- Naming-normalization spec (`2026-09-17-harness-naming-normalization-design.md`) should settle final skill names before recipes are finalized.
- `2026-09-17-build-spec-design.md` and `2026-09-17-build-spec-by-slice-rename-design.md` should settle final mode names before their recipes are written.

## Observability

- Recipe success signals are command outputs, clean git status, green fixture suites, or named hook messages.

## Security

- Do not include tokens, account ids, local usernames, or real remote URLs.

## Domain vocabulary

- recipe - short repeatable workflow for a common task - chosen over: runbook because these are local development actions, not production operations.
- success signal - observable command output or state that proves a recipe step completed - chosen over: expected result because the harness should prefer checkable evidence.
