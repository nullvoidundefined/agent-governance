---
name: build-by-slice-require-review
description: Use when running a feature build as slices of PRs, starting a slice, or executing any multi-PR build. The owner approves the slice plan once, then the build runs without stopping. Triggers on "start the slice", "next slice", "build this slice by slice", or "implement with review gates". For the in-harness TDD slice mechanics under the R-412 lock, tdd-gated-dispatch owns the trigger.
---

# Build by Slice, Require Review

Run the build as a sequence of owner-approved slices, each slice one PR by default, each PR a sequence of strict TDD tasks. The human owns the architecture (the spec and the slice plans); the agent executes; comprehension is preserved by the one owner approval at Gate 1 and the one review each PR gets before merge (owner decision 2026-09-23, IAN-333).

**Announce at start:** "I'm using the build-by-slice-require-review skill to run this build slice by slice, with the plan approved once up front."

## Hard first step: read the spec

Before any planning or code, read the project's spec, its flows, and its acceptance criteria in full. Not optional. Build against the spec, not against assumptions. If no spec exists, stop and say so; this skill has nothing to build from.

## Three tiers of work

| Tier | Size | Definition |
|---|---|---|
| Slice | 1 to 2 days, one PR by default | A coherent chunk of the build, reviewable in one sitting |
| Task | One strict TDD cycle | The smallest unit, inside a slice's PR |

Split a slice into more than one PR only when the diff would pass ~2000 lines or dense security, concurrency, or transaction code needs a smaller review unit; say why in the slice plan. Group a PR's tasks logically; never ship a tranche of mixed actions.

## The loop

1. Read the spec, flows, and acceptance criteria.
2. Plan the next slice: write its slice plan document (below) listing its PR block(s), each described in the PR description format.
3. **Gate 1:** present the slice plan document and get explicit user approval before building. This is the only stop in the loop.
4. Build the PR as a sequence of TDD tasks (below), doing the bookkeeping as each point comes up (R-605): ticket open and advance as direct tracker calls from the main session, and the handoff and the feature-list and user-story rows by the main session, or on a Complex or Saga slice by a background `haiku`/`sonnet` subagent.
5. Commit the slice's edits, the bookkeeping edits included (R-605), then run the pre-merge review (below). On green CI and a passed R-517 review, merge: an owner-approved slice plan authorizes merging its PRs (R-514). The harness's own `gh pr merge` permission prompt still applies.
6. Go straight to the next PR or slice; no stop between them. Report progress as one line inside the work. Only a fork the plan leaves open, a destructive action, or a confirmation gate stops the run (R-211).

For a hard or risky PR, write a one-paragraph explain-back of what it does and why before merge. A stronger reviewer (Codex, or a fresh Claude subagent on `opus`/`fable`) replaces the default reviewer for that PR rather than adding a second review; never Copilot (R-514).

## Pre-merge review (every PR, one reviewer)

Before any PR merges, one reviewer checks the PR's diff against the spec and the acceptance criteria of the PR's block in the slice plan document (R-517). It runs after the last commit on the branch, the bookkeeping doc edits included, so nothing but the PR body, title, or labels changes afterward, keeping one review sufficient for the merge guard.

- **Default:** a fresh Claude subagent on `sonnet`, given the filled `~/.claude/prompts/codex-pr-review-prompt.md` with the diff and the requirement text pasted in, so it uses tools only when the pasted text cannot answer (R-517).
- **Opt-in or required:** Codex (`codex exec -s read-only -C <repo root> --skip-git-repo-check -o <final-message file> "<prompt>" </dev/null > <log file> 2>&1`, run in the background and polled via the log file, stdin closed, no `-m`) or a stronger Claude subagent (`opus`/`fable`), when the owner opts in or the diff touches auth, money, or concurrency.
- **Dispositions:** fix each finding, or answer it with a reason in the PR.
- **PR body:** a `## Codex review` section carries a `reviewer` line naming the reviewer that ran and why, a `model` line naming the model it ran on, a `range` line naming the diff it read, and one line per finding with its severity and disposition. The range is a `<base>..<head>` expression whose head endpoint must be the PR's head commit, so a review that ran before the last push is re-run on the new range rather than re-typed. `git-workflow-guard` denies `gh pr merge` while the section is missing, empty, duplicated, missing one of the three lines, or naming a range whose head endpoint is not the head commit.

## Slice plan document

Write `docs/slices/slice-<nn>-<slug>.md` before Gate 1. The file carries one `### PR 1: <title>` block by default, in the PR description format below; it is the artifact the user approves at Gate 1. Split into more than one PR block only under the size or risk exception above. The PR body is written from this block (R-605); the plan document itself carries no per-PR execution record (no PR number, merge date, review outcome, or test-author fallback to track by hand). `hooks/spec-glossary-check.sh` reminds on the Write when a PR block lacks any of the seven labels or the plan has no PR block at all, so Gate 1 never sees a half-described PR.

## PR description format

Describe every PR with these fields, in the slice plan document and in the PR body. Each field is its own paragraph, separated by blank lines:

- **Context:** where the build stands when this PR starts.
- **Problem:** what this PR solves and why it lands now.
- **Approach:** how, and why this way. Short paragraphs, 2 to 4 sentences each, one idea per paragraph, blank lines between; never one block of text.
- **Contents:** what is in the diff.
- **Tests:** the tests that prove it, and who wrote them: the implementing session (Standard) or the `test-author` subagent (Complex/Saga), or Codex when the owner opted in.
- **Review focus:** where the reviewer's attention pays most.
- **Size:** approximate files and lines.

On the first mention of any framework or tool in a document, state what it is and why the project uses it in one clause or sentence; later mentions in the same document stay bare.

## Harness note

This skill is portable prose: it governs the slice, PR, and review cadence in any tool. In a Claude Code session governed by the R-412 slice lock, run each task's red/green/refactor through the tdd-gated-dispatch skill and `tdd.sh` (`open`, `red`, `green`, `close`); the lock denies production writes outside that sequence, and this skill's TDD rules describe the same cycle the harness enforces, not an alternative to it.

## TDD rules (every task)

1. **Red:** Standard tier: the implementing session writes the failing test itself, under the tdd lock. Complex and Saga: the `test-author` subagent writes it; Codex only when the owner opts in, with `test-author` as Codex's fallback. Run it and confirm it fails.
2. **Green:** write the minimal implementation to pass.
3. **Refactor:** clean up with tests green.

Tests cite the spec's acceptance criteria. End-to-end tests come from the spec's flows.

## Guardrails

- Don't write implementation before its failing test.
- No stopping between PRs or slices once the plan is approved at Gate 1; merge on green CI plus the R-517 review, then continue.
- Don't merge before the R-517 review ran and every finding is fixed or answered in the PR (R-517).
- Don't widen scope beyond the approved slice; defer new ideas to a Later list.
- Don't bundle unrelated concerns into one PR.
- No per-task stops: inside an approved PR, run task after task without asking.

## Living docs

Keep the project's spec and its task/PR tracker a factual reflection of the current state. The main session updates them (tracker writes as direct MCP calls, R-605), committed with the slice, as each PR and slice completes.

## Review depth

Weight review by risk: skim boilerplate; interrogate the hard parts (concurrency, transactions, security, anything novel). Direct the user's attention there when presenting a PR.
