---
name: lesson_format_before_commit
description: Run prettier --write immediately after creating or editing files, before attempting the first commit. Pre-commit format:check failures force a second commit attempt and double the hook runtime cost.
type: feedback
---

**Run `prettier --write` on any newly created or edited file immediately, before attempting the first commit.**

**Why:** On 2026-04-08 a bash-generated `web-client/CLAUDE.md` split tripped the pre-commit `format:check` because prettier had an opinion about the heredoc-generated markdown (trailing whitespace, wrap width, or similar). The commit failed, I had to run prettier manually, then retry the commit. That is two pre-commit runs for work that should have been one. Pre-commit runtime on this project is ~7 seconds per run, so the duplicated cost is real when it happens repeatedly in a session.

**How to apply:**
- Any file created via `Write`, `Edit`, bash `sed`, bash `printf`, or bash heredoc should be passed through `prettier --write` (via the workspace that owns the file) before staging and committing.
- For monorepo workspaces where prettier lives in each workspace package: use `pnpm --filter <workspace-name> exec prettier --write <absolute path>` or `cd` into the workspace first. The root may not have prettier installed.
- Specifically for generated files: bash heredocs and `printf` output often have subtle formatting prettier disagrees with (list separators, blank lines, trailing whitespace). Assume prettier will touch it and pre-run.
- This pairs with the em-dash pre-scan (see lesson_prescan_writes_for_em_dashes.md): scan for em dashes, then format, then commit. Two checks upfront beat two hook failure cycles.

**Related:** R-203 (stay inside the safety harness). Running the harness tools yourself first means the harness never has to fire.
