---
name: build-by-slice-require-review
description: Use when running a feature build as slices of PRs, starting a slice, or executing any multi-PR build. The owner approves the slice plan once at Gate 1 and chooses that slice's merge mode there: by default the session merges each PR on green CI and a passed review, except security-touching or guarded ranges, or the owner chooses to read and merge each PR. Triggers on "start the slice", "next slice", "build this slice by slice", or "implement with review gates". For the TDD lock on a high-risk slice, tdd-gated-dispatch owns the trigger.
---

# Build by Slice, Require Review

Run the build as owner-approved slices, each slice one PR by default. The owner owns the architecture (the spec and the slice plans) and approves each plan once at Gate 1; one review checks every PR before merge; the owner reads and merges a PR wherever Gate 2 applies (owner decisions 2026-09-23, IAN-333; 2026-09-24, IAN-352; 2026-09-30, IAN-517).

**Budget (owner decision 2026-10-02, IAN-568):** process time never exceeds work time, 1:1, for every PR, high-risk ones included. The only exception is the R-109 security review, which continues while each round still finds a MEDIUM or higher.

**Announce at start:** "I'm using the build-by-slice-require-review skill to run this build slice by slice, with the plan approved once up front."

## Hard first step: read the spec

Read the spec, its flows, and its acceptance criteria in full before planning or code. No spec: stop and say so.

## The loop

1. Plan the next slice in `docs/slices/slice-<nn>-<slug>.md` (below): one PR block by default, split only past about 2000 lines or where dense security code needs a smaller review unit.
2. **Gate 1:** present the plan with its `**Risk:**` line, ask one owner tile per fuzzy control (below), ask the merge mode (below), and get explicit approval. Write the answers onto the plan before the first commit.
3. Build each PR: a standard-risk slice runs the lean tier (tests written alongside the code, each failing if the code were wrong, R-401); a high-risk slice runs `tdd-gated-dispatch` (the lock and the three roles, R-412, R-707).
4. Commit the slice's edits and its bookkeeping, then run the one pre-merge review (below).
5. Once CI is green and the review has passed, follow the merge mode (R-514). After a merge on green, go straight to the next PR; when the PR went to the owner, their merge is the stop. A fork the plan leaves open, a destructive action, or a confirmation gate also stops the run (R-211).

## Risk (once per slice, at Gate 1)

Record `**Risk:** high` or `**Risk:** standard` per slice with the reason (R-110). High-risk means the diff touches security, money, or concurrency: auth, sessions, cookies, CORS/CSP/security headers, rate limits, trust-boundary input validation, SQL construction, secrets, redaction or PII, payments, transactions, locks, queues, or retries, or the R-109 security-surface detector flags the range. When unsure, record high. A high-risk PR also carries a one-paragraph explain-back in its body.

## Fuzzy controls (asked before any code, at Gate 1)

For each control with no natural endpoint (redaction and PII scrubbing, rate limits, input classification, allow and deny lists), ask the owner one tile (R-211, one per turn) for its threat model (who supplies the input, what they control, what a miss costs) and its acceptance boundary (what must be caught, what may pass, and the tests that prove it). Record both under the slice's `**Fuzzy controls:**` heading. A review round never stands in for the answer.

## Merge mode (once per slice, at Gate 1)

Ask as a tile with the default first, and record the answer on the plan's `**Merge mode:**` line:

- **Merge on green (default):** the session merges each PR once CI is green and the review passed, through the guard's per-merge confirmation.
- **Owner merges (Gate 2):** each PR is handed to the owner with its findings and dispositions, and the owner reads and merges it.

The answer covers this slice only. A PR whose range is security-touching (R-109) or that `build-lane.sh classify` classes guarded goes to the owner under either mode; say so in the PR.

## Pre-merge review (every PR, one reviewer)

One fresh `pr-reviewer` subagent on `sonnet` reviews the PR's diff against the spec and the PR block's acceptance criteria (R-517), after the last bookkeeping commit, with the filled `~/.claude/prompts/codex-pr-review-prompt.md` and the diff pasted in. Codex or `opus`/`fable` only on the owner's opt-in. A security-touching range also gets the R-109 security review on `securityReviewModel`.

- **Review rounds:** one round per PR, and a second only when round one finds a HIGH. Each fix lands as an ordinary commit with a test that fails without it, not as a TDD slice. A LOW left after the last round becomes a ticket answered in the PR with its key. HIGH and MEDIUM block the merge. A security finding of any severity is fixed or waived by the owner, never ticketed (R-109).
- **PR body:** the `## Codex review` section carries `reviewer`, `model`, and `range` lines and a findings table; record each fix as `fixed <sha>` in the table's disposition cell, since a plain bullet list does not count. The `range` may end before the head only when every later commit is a clean base merge or a `fixed <sha>` commit in that table; otherwise re-run the review on the new range. When fixes land after the R-109 security review, its range must end at the artefact commit that carries them. The full section grammar is in the `task-cleanup` skill.

## Slice plan document

`docs/slices/slice-<nn>-<slug>.md` carries the `**Merge mode:**`, `**Risk:**`, and `**Fuzzy controls:**` lines, then one `### PR 1: <title>` block per PR in the format below. `hooks/spec-glossary-check.sh` reminds when a block lacks a label or the plan has no merge mode. The PR body is written from the block; the plan keeps no per-PR execution record.

## PR description format

Each field is its own paragraph:

- **Context:** where the build stands when this PR starts.
- **Problem:** what this PR solves and why now.
- **Approach:** how, and why this way, in short paragraphs.
- **Contents:** what is in the diff.
- **Tests:** the tests that prove it and who wrote them (the session, or the `test-author` agent on a high-risk slice).
- **Review focus:** where the reviewer's attention pays most.
- **Size:** approximate files and lines.

## Guardrails

- No implementation before its test on a high-risk slice; tests alongside the code on a standard one.
- No merge before the review ran and every finding is fixed or answered.
- No second review round without a HIGH in round one.
- No code for a fuzzy control before the owner answered its tile.
- No scope beyond the approved slice; new ideas go to a Later list.
- No per-task stops inside an approved PR.
