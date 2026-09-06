---
name: tdd-gated-dispatch
description: Use for any Standard, Complex, or Saga task once a spec exists, to run each behavior as one RED/GREEN/REFACTOR/REVIEW slice with the harness proving each step. In Complex and Saga it dispatches the test-author, implementer, and slice-critic agents as separate fresh contexts; in Standard the same session runs the slice under the lock. Sits between writing-plans and subagent-driven-development; the Superpowers skills stay the skeleton, this skill is the enforcement.
---

# TDD-Gated Dispatch

One behavior at a time. The harness, not the prompt, proves RED and GREEN and
keeps the tests out of the implementer's hands.

**Stack assumption:** `enforce/tdd.sh` runs Vitest or Jest. Any other runner
refuses; the loop below still applies by hand until the runner lands.

## What the harness enforces (so this skill does not have to ask for it)

| Step | Mechanism | Rule |
|---|---|---|
| No production edit before the failing test | `.claude/tdd-lock.json` phase `open`, `hooks/protected-path-guard.sh` | R-412 |
| The test fails for the right reason, the rest is green | `tdd.sh red` | R-412 |
| Tests, fixtures, and the spec are read-only from RED to close | lock phases `red`/`green`, the guard | R-410 |
| Test author writes only tests; implementer never writes tests; critic writes nothing | `agent_type` against `enforce/role-policy.json` | R-411 |
| Named tests pass, suite at or above baseline, locked hashes match the RED commit | `tdd.sh green` | R-412 |
| A writing subagent cannot return on a red suite | `verification-gate.sh` on `SubagentStop` | R-509 |

What stays with you: choosing the slices, opening each one, committing between
RED and GREEN, and arbitrating a `DISPUTE:`.

## Slicing

Read the spec's acceptance criteria. Each criterion that a test can fail is a
slice, `B-1`, `B-2`, in the order the implementation needs them. A plan from
`writing-plans` maps one task to one slice; its code blocks are a suggestion
for the implementer and are never shown to the test author (2026-09-06
decision 2). Before dispatching the test author, write the slice's behavior
line and criteria into the prompt as text; do not paste the plan.

Too small to slice: pure pixel, spacing, or color decisions with no behavioral
component (the only R-705 exception). Everything else is a slice.

## The loop, per slice

```
1. open       bash ~/.claude/enforce/tdd.sh open "B-n <behavior>" --spec docs/specs/<slug>.md
2. RED        test author writes the test; tdd.sh red <file> prints RED:
3. commit     git add <test file> .claude/tdd-lock.json && git commit -m "test(<scope>): B-n <behavior>"
4. GREEN      implementer writes the minimum; tdd.sh green prints GREEN:
5. REFACTOR   implementer, same lock; tdd.sh green again
6. commit     git commit -m "feat(<scope>): B-n <behavior>"   (or fix:, refactor:)
7. REVIEW     slice critic returns findings and candidate tests
8. close      tdd.sh close; accepted candidates become B-n+1
```

Step 3 before step 4 is what makes `tdd.sh green`'s hash check bind to a git
object: skip it and the check runs against the lock only, and says so.

## Standard tier: one session

You are the test author, then the implementer, in turn, under the same lock.
The guard enforces the order: after `open`, a production write is denied until
`red` has run; after `red`, a test write is denied until `close`. Run the loop
exactly as above without dispatch. Dispatch the critic only when the slice
touches auth, money, concurrency, or an external call.

## Complex and Saga: three agents, fresh context each

Dispatch with the Agent tool, `subagent_type` naming the role file in
`~/.claude/agents/`, and the model the role file sets (test author and critic
on Opus, implementer on Sonnet; 2026-09-06 decision 5). Every prompt carries
paths, not content (R-701), and the branch block from
`~/.claude/prompts/subagent-branch-setup.md` (R-702) for `cd` only; the agents
do not commit, you do.

**Test author prompt:**

```markdown
## Slice
B-n: <behavior line from the spec>

## Spec
<absolute path to the spec>; read the B-n entry, its criteria, invariants, and failure modes.

## Conventions
<absolute path to CLAUDE-BACKEND.md or the project's test conventions>

## Branch
<R-702 block>

## Definition of done
`bash ~/.claude/enforce/tdd.sh red <test file>` prints RED:. Report the RED line, the failure class, every interface the test assumes, and any spec ambiguity you resolved. Do not implement. Do not commit.
```

**Implementer prompt** (after the RED commit):

```markdown
## Slice
B-n: <behavior line>

## Contract
Tests: <absolute test path(s)>. Lock: <repo>/.claude/tdd-lock.json. Spec: <absolute spec path>, the B-n entry.
<optional: plan task N at <absolute plan path>, a suggestion; the tests decide>

## Branch
<R-702 block>

## Definition of done
`bash ~/.claude/enforce/tdd.sh green` prints GREEN:. Then refactor and run it again. Report the GREEN line, files changed, reuse found (R-308), and anything the spec asks for that no test covers. If a test is wrong, return `DISPUTE: <file>: <title>: <why>` and stop. Do not edit tests, fixtures, the spec, or the lock. Do not commit.
```

**Critic prompt** (after the GREEN commit):

```markdown
## Slice
B-n: <behavior line>

## Inputs
Spec: <absolute spec path>. Tests: <absolute test path(s)>. Diff: git diff <RED commit sha>...HEAD.

## Output
The seven questions in your role file, with file:line evidence or "none found", then ## Candidate tests as behavior statements. Write nothing.
```

## Validating a return

Mechanical, in this order; a failure at any line means the slice is not done:

```bash
bash ~/.claude/enforce/tdd.sh status                # phase red after the test author, green after the implementer
git status --porcelain                              # only the files the role may write (R-411)
bash ~/.claude/enforce/tdd.sh green                 # re-run yourself before the GREEN commit
```

A `DISPUTE:` return stops the loop. Show the user the test, the claim, and the
spec line. If the user agrees the test is wrong, `tdd.sh` cannot unlock it: the
user deletes `.claude/tdd-lock.json` outside the session, you `open` the slice
again, and the test author writes the corrected RED. Never edit the test
yourself.

## Common mistakes

| Mistake | What happens now |
|---|---|
| Writing production code "while the test is fresh in mind" | denied by the guard until `tdd.sh red` has run |
| Handing the test author the plan with its code | the test mirrors the plan's misunderstanding; strip the code, pass the behavior line |
| Letting the implementer "fix" a flaky assertion | denied; the only path is `DISPUTE:` |
| Skipping the RED commit | `tdd.sh green` hash-checks against the lock only and warns |
| Dispatching the critic with the implementer's summary | anchored review; give it paths and the diff range only |
| Batching three behaviors into one slice | three tests, one implementation, no minimal step; slice again |
| Using this skill for exploratory or research work | nothing to assert; use plain dispatch |

## Refactor-only work

Open a slice with `--lock` on the files whose behavior must not change, skip
RED (`tdd.sh red` needs a failing test), and use the suite as the baseline:
`tdd.sh green` still refuses a drop below the count it records at `open`.
Until `tdd.sh` learns a refactor mode, record the count by hand in the commit
body.
