# Agents and Dispatch (R-7xx)

R-701: Include in every dispatch prompt: task, file paths, branch instructions, role file path; pass paths, not values.
  Spec: audit dispatch prompts additionally restate the R-804 output discipline: every finding pastes the offending code with file:line, precedence is resolved before flagging, and fixes are given as a direction plus `to confirm: <what to check>`, never a finished patch.
  Enforcement: manual

R-702: Include in every git-work dispatch prompt, in order: (1) the absolute worktree path as the first shell command; (2) `git branch --show-current` verification before `git add`/`git commit`; (3) verification and commit chained with `&&`.
  Spec: paste the reusable block from `~/.claude/prompts/subagent-branch-setup.md` into the dispatch prompt rather than rewriting the verification chain.
  Enforcement: manual

R-703: Send one canary agent first when dispatching N>=3 agents; fan out only after a clean return.
  Spec: default serial; parallel only when wall-clock dominates cost.
  Enforcement: manual

R-704: Execute plans with fewer than 5 independent tasks inline.
  Enforcement: manual

R-705: Gate every implementation dispatch on failing tests written first.
  Spec, in order, before dispatching:
  1. Answer the pre-dispatch checklist in writing before any tool call.
  2. Map the task to a test layer: unit for handlers/services, integration for API endpoints, component for UI, E2E for user flows.
  3. Write failing tests and commit before dispatch.
  4. Run tests, confirm FAIL (not error), record the count.
  5. Run the full existing suite, record the passing count as the regression baseline.
  6. Include in the dispatch prompt: task, test file paths, baseline numbers, exact definition-of-done commands, "do not modify test files".
  7. On return: run the new tests, the full suite, and the build; all three pass before merge.
  Pre-dispatch checklist:
  - What test layer covers this task?
  - What specific behavior will the failing test assert?
  - Does this task touch existing components/hooks/utilities? If yes, the test must assert reuse, not reimplementation.
  - Does this task have E2E behavioral requirements? If yes, write that test now.
  - Am I invoking the exception? State explicitly why.
  Scope: the only exception is pure pixel/spacing/color aesthetic decisions with zero behavioral component. NOT exceptions: "it's visual work", "interface still being designed", "it's exploratory", "it's simple", component selection, API integration, state management, session behavior, layout correctness, dark mode, accessibility. If the thought "this counts as visual work" arises for anything beyond pixel values, write the test.
  Enforcement: manual

R-706: Cap each dispatched subagent task at 50 tool calls; stop and report when reached.
  Scope: dispatched subagent tasks, not the main session.
  Enforcement: manual

## Multi-repo dispatch

Before launching agents across repos:
1. `grep -rl 'pattern'` across all repos first; target only repos that need changes.
2. Check task/TODO status; verify the work isn't already done.
3. Verify environment assumptions (git repo exists, branch exists, file present) before launching dependent work.

Minimize prompt size: write a shared template file, reference it by path not content, use diff-style instructions for variations.
Batch similar repos into one agent. Do the first repo manually, then templatize. Sequential with pattern reuse beats parallel with redundancy.
