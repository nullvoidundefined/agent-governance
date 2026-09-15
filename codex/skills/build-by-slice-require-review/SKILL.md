---
name: build-by-slice-require-review
description: Use when building or implementing a feature, scaffolding a project, starting a slice, or executing any multi-PR build where the user must review and approve the work as it lands. Triggers on "build", "implement", "scaffold", "start the slice", "next slice", or kicking off work from an approved spec.
---
<!-- Cloned from claude/skills/build-by-slice-require-review/SKILL.md. Do not edit here; change the source and re-copy. -->

# Build by Slice, Require Review

Run the build as a sequence of user-approved slices, each slice as a sequence of reviewable PRs, each PR as a sequence of strict TDD tasks. The human owns the architecture (the spec and the slice plans); the agent executes; comprehension is preserved by review at the gates. This is how a developer reaches roughly 5x velocity with AI without skill atrophy or a codebase that escapes their understanding.

An agent generates code faster than a human builds a mental model of it. Every rule here exists to keep those two rates matched. The unit of progress is not code written, it is a change the user understood and accepted; a merged PR the user cannot explain back is debt wearing the costume of progress.

**Announce at start:** "I'm using the build-by-slice-require-review skill to run this build slice by slice with review gates."

## Hard first step: read the spec

Before any planning or code, read the project's spec, its flows, and its acceptance criteria in full. Not optional. Build against the spec, not against assumptions. If no spec exists, stop and say so; this skill has nothing to build from.

The spec is not documentation of a finished system. It is the execution graph for the build: spec, scaffold, slices, PRs, tasks, with tests and a review gate at every level. It stays current while the build runs; see Decision log.

## Commitment levels

Over-specification turns spec-driven work into waterfall; under-specification lets the architecture emerge by accident from a sequence of local optimizations. Tag every statement in the spec and in each slice plan with what it actually commits to:

| Level | What it covers | How it changes |
|---|---|---|
| Invariant | Product behavior, public interfaces, architectural boundaries, data contracts | Only with a decision log entry and a re-approved slice plan |
| Hypothesis | The expected implementation approach | Freely, inside the slice that tests it; say so in the PR |
| Deferred | Deliberately unresolved until its slice reaches it | Resolved in that slice, then recorded |

Untagged prose is a hypothesis, not a promise. Nothing is an invariant because it was written first; an implementation detail becomes one only when a boundary or a contract depends on it. Name deferred decisions out loud: a deferred decision is a written line, not an absent one. (This is a commitment level, distinct from the spec template's `## Invariants` section, which lists properties that hold across behaviors.)

## Phase 0: scaffold the whole application

Before the first feature slice, scaffold the entire application in one reviewable PR, or a short series of them: module boundaries, directory vocabulary, interfaces and contracts, schemas, routing, dependency direction, configuration, the test tree and its harness, CI. Wire it end to end with stubs. Implement no feature logic.

This is what gives the agent global context. "Build authentication", then "build search", against no scaffold, produces an architecture nobody chose. Scaffold decisions are invariants; what the scaffold stubs is a hypothesis or a deferred decision.

Skip this phase only when the project is already scaffolded, and say which existing structure you are building into.

## Three tiers of work

| Tier | Size | Definition |
|---|---|---|
| Slice | 1 to 2 days, may span several PRs | A coherent chunk of the build |
| PR | A few hundred to ~2000 lines | The review unit: one coherent concern, reviewable in one sitting |
| Task | One strict TDD cycle | The smallest unit, inside a PR |

Slices are vertical. A slice cuts through every layer it needs (schema and contracts, service, API, a thin UI path, telemetry, acceptance tests) and closes with software that runs and does something a user would recognize. Never slice by layer: a "database slice" or an "API slice" produces nothing reviewable as behavior and defers every integration problem to the end of the build.

Size PRs to the reader: go smaller for dense, concurrent, or security-sensitive code. Group a PR's tasks logically; never ship a tranche of mixed actions. A PR is small enough when the user can say why each part of the diff exists and reject architectural drift before it propagates; when they can't, it was too big, and the next one splits.

## The loop

1. Read the spec, flows, and acceptance criteria.
2. Scaffold (Phase 0) when the project has none; it runs through the same gates as any other work.
3. Write or update the spec acceptance tests covering the slices in play (Test layers below).
4. Plan the next slice: write its slice plan document (below) listing its PRs, each PR's single concern in the PR description format, each claim tagged with its commitment level.
5. **Gate 1:** present the slice plan document and get explicit user approval before building.
6. Write the slice's integration tests; they stay unsatisfied until the slice closes.
7. Build each PR as a sequence of TDD tasks (below).
8. Open the PR; **Gate 2:** the user reviews and approves it on GitHub before merge. No auto-merge, no CLI merge; branch protection requires manual approval.
9. After merge, update the spec, the decision log, the tracker, and the slice plan document, then start the next PR or slice.

For a hard or risky PR, write a one-paragraph explain-back of what it does and why before merge, and offer to send it to a third-party AI review (for example Copilot).

## Slice plan document

Write `docs/slices/slice-<nn>-<slug>.md` before Gate 1. It states the slice's vertical path (which layers it touches and what works when it closes), lists every PR of the slice in the PR description format below, names the slice's integration tests, and tags the commitment level of each claim it makes. It is the artifact the user approves at Gate 1. As each PR merges, record its PR number, merge date, decision log entries, and any scope change in the same file. The document is the slice's execution record.

## PR description format

Describe every PR with these fields, in the slice plan document and in the PR body. Each field is its own paragraph, separated by blank lines:

- **Context:** where the build stands when this PR starts.
- **Problem:** what this PR solves and why it lands now.
- **Approach:** how, and why this way. Short paragraphs, 2 to 4 sentences each, one idea per paragraph, blank lines between; never one block of text.
- **Contents:** what is in the diff.
- **Tests:** the tests that prove it, and which layer each one belongs to.
- **Spec delta:** the decision log entries this PR adds and what they change in the spec; "none" when it built exactly what was approved.
- **Review focus:** where the reviewer's attention pays most.
- **Size:** approximate files and lines.

On the first mention of any framework or tool in a document, state what it is and why the project uses it in one clause or sentence; later mentions in the same document stay bare.

## Test layers

Four layers, written outside in. The higher layers say what the product must eventually do; the lower ones say what this particular change is allowed to do. Together they hand the agent a bounded definition of correctness, which is what conventional red-green-refactor alone does not supply.

| Layer | Written | Derived from | Scope |
|---|---|---|---|
| Spec acceptance | When the spec is approved | Acceptance criteria and flows | Whole product behavior |
| Slice integration | At the start of the slice, before its first PR | The slice plan's vertical path | The slice, end to end |
| Task behavioral | The red step of each TDD task | The PR's single concern | One unit of behavior |
| Implementation | After red | The failing test | The minimum to pass |

The top two layers are written before the code that satisfies them and stay unsatisfied for a while. Keep them in the suite, marked pending or expected-to-fail against the criterion ID they cover, so the suite stays green and the gap stays visible; flip each on when the slice that satisfies it closes. Never delete or weaken one to get green: a weakened higher-level test removes the only standing check on drift.

## TDD rules (every task)

1. **Red:** write the failing test first; run it and confirm it fails.
2. **Green:** write the minimal implementation to pass.
3. **Refactor:** clean up with tests green.

Tests cite the spec's acceptance criteria. End-to-end tests come from the spec's flows.

## Decision log

Keep `docs/decisions/decision-log.md`, appended to and never rewritten. When an implementation shows the approved design was wrong, the code does not quietly diverge from the spec; the decision is recorded and the spec is updated to match:

```markdown
## Decision 014: retrieval jobs moved behind a queue
Date: 2026-09-15. PR: #87. Level: invariant (was hypothesis).
Original assumption: ingestion runs synchronously inside the request.
Discovery: ingestion latency breaks the API's p95 latency target.
Decision: enqueue ingestion; the API returns a job ID the client polls.
Affected slices: ingestion, retrieval, observability.
```

- Write the entry in the same PR that diverges, and link it from the spec section it overrides.
- Changing an invariant re-opens Gate 1 for the affected slice: the decision goes to the user before that PR is opened, not after it merges.
- Resolving a deferred decision gets an entry too; that is how it stops being deferred.
- A divergence between code and spec with no entry is a defect, fixed in the PR that created it.

The log is what makes the spec evolve with the program instead of becoming obsolete documentation.

## Guardrails

- Don't start the next task, PR, or slice before the current one is approved and merged.
- Don't write implementation before its failing test.
- Don't merge without explicit approval; "looks fine" in chat is not a GitHub approval.
- Don't widen scope beyond the approved slice; defer new ideas to a Later list.
- Don't bundle unrelated concerns into one PR.
- Don't slice by layer; every slice closes with working behavior.
- Don't let the code diverge from the spec silently; every divergence is a decision log entry in the same PR.
- Don't fix an implementation detail as an invariant before a boundary depends on it, and don't promote a hypothesis just because it shipped.
- No per-task stops: inside an approved PR, run task after task without asking.

## Living docs

Keep the project's spec, its decision log, and its task/PR tracker a factual reflection of the current state. Update them as each PR and slice completes, in the same PR when the change makes them stale.

## Review depth

Weight review by risk: skim boilerplate; interrogate the hard parts (concurrency, transactions, security, anything novel). Direct the user's attention there when presenting a PR.

The gate asks more than whether the code is correct: it asks whether the user understands why this code exists. When a diff is too large or too unfamiliar to be understood in one sitting, say so and split it rather than defending it through review.
