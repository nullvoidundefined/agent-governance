R-102: Dispatch prompts contain: task, file paths, branch instructions, role file path. Pass paths not values.
R-303: Dispatch prompts doing git work include in order: (1) absolute worktree path as first shell command; (2) `git branch --show-current` verification before `git add`/`git commit`; (3) verification and commit chained with `&&`. Paste the reusable block from `~/.claude/prompts/subagent-branch-setup.md` into the dispatch prompt rather than rewriting the verification chain from scratch.
R-304: N>=3 agents: send one canary first, fan out after clean return. Default serial; parallel only when wall-clock dominates cost.
R-501: Plans with <5 independent tasks execute inline.

## TDD-gated dispatch

R-511: Before dispatching any sub-agent for implementation:
1. Answer pre-dispatch checklist in writing before any tool call.
2. Map task to test layer: unit for handlers/services, integration for API endpoints, component for UI, E2E for user flows.
3. Write failing tests and commit before dispatch.
4. Run tests, confirm FAIL (not error), record count.
5. Run full existing suite, record passing count as regression baseline.
6. Dispatch prompt includes: task, test file paths, baseline numbers, exact "definition of done" commands, "do not modify test files".
7. On return: run new tests, full suite, build. All three pass before merge.

Pre-dispatch checklist:
- [ ] What test layer covers this task?
- [ ] What specific behavior will the failing test assert?
- [ ] Does this task touch existing components/hooks/utilities? If yes, test must assert reuse, not reimplementation.
- [ ] Does this task have E2E behavioral requirements? If yes, write that test now.
- [ ] Am I invoking the exception? State explicitly why.

Exception: pure pixel/spacing/color aesthetic decisions with zero behavioral component.

NOT exceptions: "it's visual work", "interface still being designed", "it's exploratory", "it's simple", component selection, API integration, state management, session behavior, layout correctness, dark mode, accessibility. If the thought "this counts as visual work" arises for anything beyond pixel values, write the test.

## Multi-repo dispatch

Before launching agents across repos:
1. `grep -rl 'pattern'` across all repos first. Only target repos that need changes.
2. Check task/TODO status. Verify work isn't already done.
3. Verify environment assumptions (git repo exists, branch exists, file present) before launching dependent work.

Minimize prompt size: write shared template file, reference by path not content, use diff-style instructions for variations.
Batch similar repos into one agent. Do first repo manually, then templatize. Sequential with pattern reuse beats parallel with redundancy.
