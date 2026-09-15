---
name: lesson_batch_file_creation_then_commit
description: When a task requires creating multiple related files (e.g., a new hook script + a lefthook.yml edit + a test run), batch all the creation work before the first commit attempt. Stagger the commit for the whole batch.
type: feedback
---

**Batch multi-file creation work before committing. Do not commit incrementally during setup of a related change set.**

**Why:** On 2026-04-08 shipping the `structure-check` pre-commit hook required four coordinated actions: Write the script, Edit `lefthook.yml` to register it, `chmod +x` the script, and test it by running the hook manually. That is four tool calls that belong to one logical change. Committing them one at a time would have meant four pre-commit hook runs (~30s) for one unit of work. Batching them into one commit meant one hook run (~7s).

**How to apply:**
- When a task involves multiple files that only make sense together (hook + registration + test; new component + its module.scss + its test; new migration + its repository function + its handler), do all the file work first, verify manually (run the hook, run the test, compile the type), then commit once.
- The commit message can still describe the multi-file change atomically because all the files serve one purpose.
- Resist the urge to "commit as you go" for related files. Incremental commits make sense for independent logical units, not for coordinated changes within one unit.
- When in doubt, ask: "does each file make sense without the others?" If no, one commit. If yes, separate commits are fine.

**Related:** this is the positive companion to lesson_hook_runtime_budget.md. Batching commits minimizes hook overhead by packing more work per hook run.
