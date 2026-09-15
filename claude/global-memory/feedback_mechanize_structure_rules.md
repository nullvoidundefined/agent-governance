---
name: feedback_mechanize_structure_rules
description: A written-but-manual structure rule loses to the layout already on disk during a file-by-file build; mechanize it per R-516 the first time it is missed.
metadata:
  type: feedback
---

A structure rule enforced only by recall (`[manual]`) does not survive a multi-task build. Each task places its file next to where the previous one sat, the starter's flat layout self-perpetuates, and no gate objects. Mechanize the rule per R-516 the first time it is missed.

**Why:** two regroups in one session, both from the same cause. A server `src/` root accumulated eleven loose modules because R-304's layer vocabulary was `[manual]`; a client `components/` tree stayed flat because CLAUDE-FRONTEND.md's one-folder-per-component convention had no enforcer. The adjacent hooks that do fire (structure-gate on case, catch-alls, and test placement; the R-310 flat-directory reminder at 20+ siblings) all passed the whole time. Both rules existed and were correct. Neither was reachable at the moment the file was created.

**How to apply:**
1. When a structure or naming rule is missed, log it as `miss: R-NNN; gap: <what no enforcer covered>` before fixing the layout.
2. Ask whether the violation is decidable from the write path plus a cheap filesystem read. If yes it is mechanizable, and R-516 requires it registered rather than re-remembered.
3. Prefer extending the hook that already owns the event (structure-gate for PreToolUse Write/Edit paths) over adding a new one; add the fixture test in the same commit.
4. Scope every new deny by the nearest `package.json` dependency (express for a server rule, react for a client rule) so it never fires on a tree whose conventions differ, and fire on file creation only so an existing loose file stays editable.

The general signal: a rule whose violations only become visible in review, never at write time, is a rule that will be violated during the next build.

Related: [[feedback_process_learnings_20_rules]]
