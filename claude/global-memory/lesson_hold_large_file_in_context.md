---
name: lesson_hold_large_file_in_context
description: When a large file has been read once in a session, hold its content in context instead of re-reading. Re-reads after Edit/Write modifications are sometimes unavoidable, but planning around them avoids the second read.
type: feedback
---

**For large files (>1000 lines), plan edits to avoid a second full read in the same session.**

**Why:** On 2026-04-08 I read the 1947-line root CLAUDE.md twice in one session: once to plan the split, and a second time after the file was modified by prettier (`File has been modified since read` error from Edit). Large reads are slow and they cost tokens. The second read was avoidable with better planning: do all the reading work up front, then do all the writing work, so the file is not read after an external modification.

**How to apply:**
- When a workflow involves multiple Edit calls to the same large file, interleave them with other actions that do not modify the file. Prettier, lint, other tools that touch the file will invalidate the context and force a re-read on the next Edit.
- Prefer one large Write over many small Edits for files over 500 lines when the edit volume is substantial. Write overwrites cleanly without the "file modified since read" concern.
- For bulk edits, extract section content to temp files with bash (sed, awk) before any mutation, then compose the final file from the temp files plus hand-written headers. This avoids reading the big file twice.
- If a second read is unavoidable, use `offset` and `limit` to read only the section you need, not the whole file.

**Related:** `lesson_no_reread_auto_injected_context.md` (do not re-read files already in auto-injected context). This memory extends that principle to files read explicitly via the Read tool within a single session.
