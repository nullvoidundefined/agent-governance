---
name: session-handoff
description: Close a coding session with the applicable handoff, memory, and repository bookkeeping under R-601 through R-603. Do not use for general conversation with no coding work.
---
<!-- Hand-ported from CLAUDE.md R-001 / R-601+R-602; not generated. Listed hand_authored in translate/codex-port-map.json -->

# Session Handoff

Apply the canonical applicability rule first. Do not create a development handoff, inspect Git, or perform repository bookkeeping solely for a non-coding question. A general-question detour does not erase pending coding work or remove its eventual handoff requirements.

Close a coding session per R-601 and R-602:

1. Write `docs/session-handoff/session-handoff.md` (overwrite, under 8KB, bullets) in the fixed section order: Last commit, Production state, What shipped, Pending, Next-session tasks with files to read. Record the current commit SHA in the first section so the next session can verify it.
2. Move deferred work into `TODO.md` or `ISSUES.md`.
3. Route learnings to per-project feedback memory with the R-603 tags (`success`, `correction`, `fired: R-NNN`, `miss: R-NNN; gap:`).
4. If `~/.claude` is dirty, review `git diff origin/main` for secrets, local paths, and client-identifying content (R-106), then commit and push it.
5. Bundle the handoff into the final commit of the session.
