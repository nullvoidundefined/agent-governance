# Agents and Dispatch (R-7xx)

R-701: Include in every dispatch prompt: task, file paths, branch instructions, role file path; pass paths, not values.
  Spec: audit dispatch prompts additionally restate the R-804 output discipline: every finding pastes the offending code with file:line, precedence is resolved before flagging, and fixes are given as a direction plus `to confirm: <what to check>`, never a finished patch. A prompt handing off work above the trivial tier, whether a subagent dispatch or a spawned task chip, also names its ticket key (`Refs: <KEY>` on every commit) or tells the receiver to open one with `/ticket-lifecycle` before its first edit (R-605); `hooks/pr-ticket-ref-gate.sh` refuses the receiver's `gh pr create` otherwise.
  Enforcement: manual

R-702: Include in every git-work dispatch prompt, in order: (1) the absolute worktree path as the first shell command; (2) `git branch --show-current` verification before `git add`/`git commit`; (3) verification and commit chained with `&&`.
  Spec: paste the reusable block from `~/.claude/prompts/subagent-branch-setup.md` into the dispatch prompt rather than rewriting the verification chain.
  Enforcement: manual

R-703: Send one canary agent first when dispatching N>=3 agents; fan out only after a clean return.
  Spec: default serial; parallel only when wall-clock dominates cost.
  Enforcement: manual

R-704: Execute plans with fewer than 5 independent tasks inline.
  Enforcement: manual

R-705: Gate every implementation on a RED slice proven by `enforce/tdd.sh`.
  Spec, per slice (R-412 carries the phase mechanics):
  1. `tdd.sh open "B-n <behavior>" --spec <path>`; the guard now denies production writes.
  2. Codex writes the test for `B-n` only, in every tier (R-907): the orchestrator dispatches `codex exec -s workspace-write` with the slice prompt, runs `tdd.sh red <file>` until it prints `RED:`, and runs `tdd.sh validate test-author` to prove Codex wrote only test and fixture paths. Only when Codex is unavailable or rate-limited does the `test-author` agent write it instead (exempt from the R-907 guard, since R-411 keeps it out of implementation), and the fallback is recorded on the slice as R-907's Degradation line says.
  3. Commit the test and the lock as `test(<scope>): B-n <behavior>` before any implementation.
  4. The implementer (you, or the `implementer` agent) writes the minimum and runs `tdd.sh green` until it prints `GREEN:`; refactors; runs it again.
  5. Commit the implementation. Dispatch the `slice-critic` for Complex and Saga, and for any Standard slice touching auth, money, concurrency, or an external call. `tdd.sh close`.
  Scope: the only exception is pure pixel/spacing/color aesthetic decisions with zero behavioral component. NOT exceptions: "it's visual work", "interface still being designed", "it's exploratory", "it's simple", component selection, API integration, state management, session behavior, layout correctness, dark mode, accessibility. If the thought "this counts as visual work" arises for anything beyond pixel values, write the test.
  Enforcement: manual for opening the slice and committing between RED and GREEN; hook:protected-path-guard and `enforce/tdd.sh` for everything after `open` (R-410, R-411, R-412)

R-706: Cap each dispatched subagent task at 50 tool calls; stop and report when reached.
  Scope: dispatched subagent tasks, not the main session.
  Enforcement: manual

R-707: Dispatch the slice roles as separate fresh contexts in Complex and Saga: the test author (Codex through `codex exec`, per R-907, or the `test-author` subagent on Opus as its recorded fallback) receives the spec path and the slice id, never a plan's code blocks; `implementer` (Sonnet) receives the spec path, the test paths, and the lock; `slice-critic` (Opus) receives the spec path, the diff range, and the test paths, never the implementer's transcript or summary.
  Spec:
  - The primary session orchestrates: it opens and closes slices, commits, validates returns with `tdd.sh status` and `tdd.sh green`, and arbitrates nothing; a `DISPUTE:` goes to the user.
  - Prompts carry paths, not content (R-701); the plan's behavior line for the slice is copied as text, its code is not.
  - Role boundaries are enforced by R-411, not by the prompt; the prompt still states them so a refusal cites the rule.
  - Standard tier runs the same loop in one session under the lock (2026-09-06 decision 3), with Codex still authoring each test (R-907, 2026-09-19).
  Enforcement: manual (the write boundaries are R-411)

## Review agents

`agents/slice-critic.md` reviews one green slice from a fresh context with seven fixed questions (untested requirements, missing failure modes, overfit branches, mocks that hide behavior, layer bypasses and duplication, untested state transitions, green-but-unsafe code) and returns findings plus candidate tests as prose; it writes nothing. Dispatch it per slice in Complex and Saga per R-707. `agents/implementer.md` is the other dispatched slice role; `agents/test-author.md` is the fallback test author when Codex, the default test author in every tier (R-907), is unavailable or rate-limited.

`agents/spec-conformance-review.md` reviews a diff against a named spec or plan file and reports only gaps that affect correctness or violate a stated requirement. Dispatch it after implementing against an approved spec and before merge. It needs the spec path in the dispatch prompt (R-701); with no spec it has nothing to review against and stops. It inherits the R-804 output discipline and returns the literal `No gaps found.` rather than manufacturing findings.

Precedence: `/code-review` reviews a diff against itself, the `gof` skill reviews a spec with no diff, and this agent covers the case neither does, a diff checked against the spec it was written from. Run `/code-review` for general correctness and quality; run this when a spec exists and conformance to it is the question. None of them replaces the blocking pre-merge Codex review (R-517) or the adversarial Codex spec review in task-start; those run in a different model on purpose, and their fallback is a separate Claude agent given the same prompt template from `prompts/`.

## Multi-repo dispatch

Before launching agents across repos:
1. `grep -rl 'pattern'` across all repos first; target only repos that need changes.
2. Check task/TODO status; verify the work isn't already done.
3. Verify environment assumptions (git repo exists, branch exists, file present) before launching dependent work.

Minimize prompt size: write a shared template file, reference it by path not content, use diff-style instructions for variations.
Batch similar repos into one agent. Do the first repo manually, then templatize. Sequential with pattern reuse beats parallel with redundancy.
