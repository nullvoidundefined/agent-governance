---
name: Ask judgment calls one at a time with option tiles
description: Canonical R-211 detail. User wants every fork in a task surfaced as its own option-tile question, never batched and never decided silently
type: feedback
---

When a task carries two or more judgment calls, ask them through option tiles (`AskUserQuestion`), one question per turn. Never batch several forks into one prompt, and never decide silently and report the decision afterward.

**Why:** stated 2026-09-17, after a session where the scope was widened three times on Claude's own judgment (a grep-portability fix, an emptied-directory cleanup, and a stale hash manifest, each found while verifying the previous one) and every one of those calls was reported only after the work was already committed. Each was defensible on its own and the user accepted all three, but the pattern gives them a decision they can only review in hindsight. A fork costs one question to ask and a commit to undo.

**How to apply:**

- Two or more forks in the same task: ask the first, act on the answer, then ask the next. One question per turn, so each answer can change what the following question even is.
- One fork: still ask it with tiles rather than narrating the options in prose.
- Give every option a concrete consequence, not a label. Where the choice produces text, code, or structure, put the actual result in the option's `preview` so the decision is made against the thing itself rather than a description of it.
- Put the recommendation first and mark it, rather than hiding it after the alternatives.
- Reserve blocking on an answer for a fork where proceeding either way would be unsafe or would waste the work. Otherwise do everything that does not depend on the answer while it is outstanding.

**What counts as a judgment call:** scope forks (widen the task or file the finding), where-to-codify choices, naming and structure decisions, anything reversible only at cost, and anything a reasonable colleague would expect to be consulted on. An implementation detail with one obviously correct answer is not a judgment call: pick it, say so in one line, and move on. Asking about those is its own failure, and the user has separately said Claude should act rather than hand back a checklist (`feedback_be_proactive.md`).

**Interaction with the rest of the harness:** R-211 carries the norm line, this file is its canonical detail, and `feedback_be_proactive.md` bounds it on the other side. Confirmation gates that already exist (R-105 for MCP writes, R-514 for merges, the destructive-action guards) are not judgment calls and do not become tile questions; they stay where they are.
