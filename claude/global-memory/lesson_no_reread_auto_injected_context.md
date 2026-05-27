---
name: Do not re-read files already in auto-injected context
description: Claude Code injects CLAUDE.md and related context at session start; re-reading them via the Read tool during the session costs tokens for no new information
type: feedback
---

**Rule:** Do not call the Read tool on files whose content has already been
provided in a system-reminder or the initial context block. The session
start injects `claudeMd` content (the project CLAUDE.md tree), memory
index files, skill definitions, and similar. Reading those same files
again during the session duplicates the bytes in context without adding
information.

**Why:** Every Read call bills the full file contents back into the
context window, even when the file is already present via an injection
that Claude Code loaded for free. In long sessions this compounds.
Observed on 2026-04-07 during a billing-doc edit: the Read tool was
invoked on a worktree `CLAUDE.md` that was already present in the
session's claudeMd block, spending tokens for zero new signal.

**How to apply:**

- Before calling Read on a file, ask: is this file's content already in
  my current context via a system-reminder or the initial claudeMd
  injection? If yes, quote it from memory or use Grep for a targeted
  lookup.
- For CLAUDE.md family files specifically: the project tree is
  always-injected. Do not Read them unless you need a section that was
  truncated in the injection.
- For large files where you only need one section, prefer targeted
  Grep with `-n` and `-C` or Read with `offset` and `limit` over a
  whole-file Read.
- A Read call is appropriate when the file is not in context, when the
  injected version may be stale (files you just modified), or when you
  genuinely need the whole file (e.g. to rewrite it).
