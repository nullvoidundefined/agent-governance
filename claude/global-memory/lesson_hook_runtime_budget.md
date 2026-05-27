---
name: lesson_hook_runtime_budget
description: Pre-commit hooks on this project cost ~7 seconds per run (format 3s, lint 7s, structure-check sub-second). Every retry doubles the hook cost. Plan commits to land in one pre-commit pass.
type: feedback
---

**Pre-commit hooks are not free. Assume ~7-10 seconds per commit attempt and optimize to land in one pass.**

**Why:** On 2026-04-08 I burned roughly 30 seconds of pure hook time across three commit attempts during the CLAUDE.md split work (initial fail on format, retry after format fix, final success). That is not catastrophic but it compounds across long sessions. The main cost drivers in this project:
- `format:check`: ~3 seconds (runs prettier across workspaces)
- `lint`: ~7 seconds (runs eslint across workspaces)
- `structure-check`: sub-second (grep-based staged file scan)
- `commit-msg` (fix-commit gate): sub-second

**How to apply:**
- Plan commits to be pre-commit clean on the first try: format, lint, em-dash scan, structure check all done manually before staging.
- When committing multiple related files, batch them into one commit rather than three commits. Three commits = three hook runs = 30 seconds of hook time. One commit = one run = 10 seconds.
- If a hook fails on the first attempt, fix the root cause (not just the failing check) before retrying, so the next commit lands clean.
- For exploratory work where commit volume is high, the hook overhead is still net positive because it catches real errors. Do not work around hooks; work with them efficiently.

**Related:** the efficiency triad from lesson_inline_execution_efficiency.md (L2, L4). This memory is the hook-specific corollary: the harness costs time, so feed it clean input.
