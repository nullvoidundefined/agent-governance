---
name: task-start
description: Use at the beginning of any work to classify scope, determine process requirements (TDD, spec, plan, model), and dispatch the correct workflow. Replaces ad-hoc decisions about when to brainstorm, plan, or execute inline.
---

# Task Start

Examine scope. Determine process. Dispatch the right workflow.

**Announce at start:** "I'm using the task-start skill to classify this work and determine the right process."

## Why This Exists

Without this skill, every task starts with an implicit judgment call: "Is this big enough to need a spec? A plan? TDD? Subagents?" Those calls are inconsistent. This skill makes them mechanical.

## Step 1: Classify Scope

Read the user's request. Check the codebase for context (files involved, cross-package dependencies, test coverage). Classify into exactly one tier:

| Tier | Signal | Examples |
|---|---|---|
| **Trivial** | Single-file edit, config change, doc tweak, env var rename, dependency bump | Fix a typo, update a README, add an env var, rename an import |
| **Standard** | Multi-file change, real logic, new function or component with tests | Add a new API endpoint, create a React component, fix a multi-file bug |
| **Complex** | Cross-cutting refactor, new subsystem, security-sensitive, auth-sensitive, 10+ files | New auth flow, design token overhaul, new service layer, database migration with data backfill |
| **Saga** | Multi-surface, multi-package, multiple independent subsystems that must ship together | Extension + web + server feature, full feature with spec + plan + E2E + docs |

**Announce the classification:** "This is a **[tier]** task. Here's why: [one sentence]."

If uncertain between two tiers, choose the higher one. Downgrading mid-task wastes less time than upgrading.

## Step 2: Determine Process Requirements

Each tier has a fixed process. No negotiation.

### Trivial

```
Spec:           No
Plan:           No
TDD:            No (but fix bugs test-first per R-403)
Model:          Haiku or Sonnet
Branch:         Optional (commit directly to current branch if clean)
Worktree:       No
Subagents:      No
Execution:      Inline, immediate
Skills invoked: None (just do it)
```

Execute the change directly. Commit. Done.

### Standard

```
Spec:           No (unless the user asks for one)
Plan:           No (inline mental model is sufficient)
TDD:            Yes. Write failing test, watch it fail, implement, watch it pass.
Model:          Sonnet
Branch:         Yes (feature branch off main)
Worktree:       No (unless parallel work is active)
Subagents:      No
Execution:      Inline with TDD discipline
Skills invoked: superpowers:test-driven-development
```

Create a feature branch. Write tests first. Implement. Commit per task. Squash merge when done.

### Complex

```
Spec:           Yes. One spec. Written inline or via brainstorming skill.
Plan:           Yes. One plan. Written via writing-plans skill.
TDD:            Yes. TDD-gated if using subagents.
Model:          Opus for planning and review. Sonnet for implementation.
Branch:         Yes (feature branch off main)
Worktree:       Yes (isolated workspace)
Subagents:      Optional (if 5+ independent tasks)
Execution:      superpowers:executing-plans or superpowers:subagent-driven-development
Skills invoked: superpowers:brainstorming, superpowers:writing-plans, then execution skill
```

One spec. One plan. One branch. Never split a complex task into multiple plans.

### Saga

```
Spec:           Yes. ONE spec covering all subsystems.
Plan:           Yes. ONE plan with staged sections (not multiple plan files).
TDD:            Yes. TDD-gated dispatch mandatory for all subagents.
Model:          Opus throughout.
Branch:         Yes (feature branch off main)
Worktree:       Yes (isolated workspace)
Subagents:      Yes, with tdd-gated-dispatch skill
Execution:      superpowers:subagent-driven-development with review checkpoints
Skills invoked: superpowers:brainstorming, superpowers:writing-plans,
                tdd-gated-dispatch, superpowers:subagent-driven-development
```

**The one-spec-one-plan rule is absolute.** A saga that touches extension + web + server gets ONE spec and ONE plan with sections for each surface. The plan may have stages ("Stage 1: shared foundation, Stage 2: extension, Stage 3: web"), but it is one document. Multiple plan files for the same feature invite contradictions, type drift, and the failure mode that sank the V2 extension work.

If the scope is genuinely too large for one plan (50+ tasks), decompose the feature into independent sub-features that each get their own spec-plan cycle. Each sub-feature must be independently shippable and testable.

## Step 3: Set Up and Dispatch

Based on the tier, execute the setup:

### Trivial
Just do the work. Skip to implementation.

### Standard
```bash
git checkout -b feat/<slug> main
```
Invoke superpowers:test-driven-development. Start coding.

### Complex
Check if a spec already exists. If not, invoke superpowers:brainstorming.
After spec approval, invoke superpowers:writing-plans.
After plan approval, invoke feature-create for worktree setup, then the chosen execution skill.

### Saga
Same as complex, but enforce:
- Opus model for all planning and review
- tdd-gated-dispatch for all subagent work
- Review checkpoint after each plan stage completes
- No stage proceeds until the prior stage's tests are green

## The One-Spec-One-Plan Rule

This is the most important rule in this skill. It exists because of a specific failure:

The V2 extension shipped Plans 1-3 plus Plan D as separate documents. Types defined in Plan 1 were referenced differently in Plan 3. Component names drifted. The squash merge was 73 files and 6,691 lines. Six P0 bugs were filed within hours.

**One spec. One plan. Always.** If you catch yourself about to create a second plan file for the same feature, stop. Either:
1. The first plan is too narrow (expand it), or
2. You are building two features (decompose into independent sub-features with separate cycles)

## Model Routing

| Activity | Model |
|---|---|
| Classify scope, read files | Current model (whatever is active) |
| Brainstorming, spec writing | Opus for complex/saga, Sonnet for standard |
| Plan writing, plan review | Opus for complex/saga, Sonnet for standard |
| Implementation (inline) | Sonnet |
| Implementation (subagent) | Sonnet (implementer), Opus (reviewer) |
| Audit/review | Opus |
| Doc edits, file moves, config | Haiku or Sonnet |

## Reclassification

If you discover mid-task that the scope is larger than classified:
1. Stop implementation
2. Announce: "This is bigger than I thought. Reclassifying from [old] to [new] because [reason]."
3. Set up the process requirements for the new tier
4. Do not lose work already done; commit it to the branch first

If you discover the scope is smaller:
1. Announce the downgrade
2. Continue with simpler process (no need to add ceremony)

## Integration

- **Replaces:** ad-hoc decisions about brainstorming, planning, and execution
- **Composes with:** all superpowers skills (brainstorming, writing-plans, executing-plans, subagent-driven-development, TDD, feature-create, tdd-gated-dispatch)
- **Paired with:** task-cleanup (run at the end of every task)
