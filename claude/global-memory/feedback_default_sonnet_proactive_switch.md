---
name: feedback_default_sonnet_proactive_switch
description: Owner decision 2026-11-20 (supersedes the 2026-09-05 opusplan default): the main session runs on Opus (`settings.json` model is `opus`). Do not ask the user to `/model sonnet`. Subagents still get the cheapest model that can do the job.
type: feedback
---

**Owner decision 2026-11-20: the main session runs on Opus (`"model": "opus"` in `settings.json`, replacing `opusplan`). Do not ask the user to switch to Sonnet.** Everything below this block is the earlier Sonnet-default reasoning, kept as history; where it conflicts with this block, this block wins. Subagents are unchanged: pass the cheapest model that can do the job (Haiku for lookups, Sonnet for routine implementation and review, Opus for hard design and risky diffs).

**Why:** On 2026-04-08 the user burned through a Max 20x quota in 5 days, losing 2 days of access. The single biggest avoidable driver was that the session ran on Opus the entire time while doing mechanical work (bash file splits, prettier runs, git plumbing, file moves, memory writes, slash command rewrites, hook edits). R-903 in `~/.claude/CLAUDE.md` was clear about using Sonnet for medium and mechanical tasks, but the rule was honor-system on both sides: the Max 20x launch default is Opus (so the session came up on Opus), and Claude did not proactively surface the mismatch when the work drifted into Sonnet-level territory. Both sides failed.

**How to apply (user side):**

- `~/.claude/settings.json` sets `"model": "opus"` (owner decision 2026-11-20; it replaced `opusplan`, which was decided 2026-09-05). Type `/model sonnet` consciously only when you want the cheaper model for a stretch of mechanical work.

**How to apply (Claude side):**

- When dispatching subagents, explicitly pass `model: "sonnet"` or `model: "haiku"` for mechanical tasks rather than letting the agent default to Opus. The agent tool accepts this parameter.
- When writing memories like this one, batch writes tight and do not spend Opus tokens on verbose narrative when bullet points would do.

**Hard rule:** Claude cannot switch the main session's model mid-session. Only the user can, via `/model`. Under the 2026-11-20 decision Claude does not ask the user to step down to Sonnet.

**Evidence:** a 2026-04-08 audit-and-refactor session ran ~100 turns on Opus, including bash file extractions, three prettier runs, two audit writeups, a CLAUDE.md three-way split, slash command conversions, and a staging deploy. Maybe 10-15% of that work genuinely needed Opus. Rough back-of-envelope: Sonnet would have cost 3-5x less for the same output.
