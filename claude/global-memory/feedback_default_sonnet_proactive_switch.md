---
name: feedback_default_sonnet_proactive_switch
description: Default every session to Sonnet. Opus is the exception the user asks for, not the default they live with. When a session drifts into mechanical work, Claude proactively tells the user to `/model sonnet`, not silently burns Opus.
type: feedback
---

**Default every session to Sonnet. Treat Opus as the exception the user explicitly asks for.**

**Why:** On 2026-04-08 the user burned through a Max 20x quota in 5 days, losing 2 days of access. The single biggest avoidable driver was that the session ran on Opus the entire time while doing mechanical work (bash file splits, prettier runs, git plumbing, file moves, memory writes, slash command rewrites, hook edits). R-503 in `~/.claude/CLAUDE.md` was clear about using Sonnet for medium and mechanical tasks, but the rule was honor-system on both sides: the Max 20x launch default is Opus (so the session came up on Opus), and Claude did not proactively surface the mismatch when the work drifted into Sonnet-level territory. Both sides failed.

**How to apply (user side):**

- Set `"model": "claude-sonnet-4-6"` in `~/.claude/settings.json` so every new session starts on Sonnet unless overridden.
- When a session genuinely needs Opus (audits, complex refactors, security reviews, ambiguous architecture, multi-step debugging), type `/model opus` consciously to step up. The friction is the feature: Opus becomes a deliberate choice, not a default.

**How to apply (Claude side):**

- At session start, check if the task description matches one of the Opus-worthy categories: architecture, audit, complex refactor, security, debugging, multi-step planning. If not, proactively tell the user "this is Sonnet-level work; run `/model sonnet` before we continue" BEFORE doing any substantial tool calls.
- When a session drifts from reasoning work into mechanical work (bash plumbing, file moves, format runs, git plumbing, documentation edits, slash command rewrites), stop and surface the mismatch: "the next stretch is mechanical; switch to Sonnet to save quota."
- When dispatching subagents, explicitly pass `model: "sonnet"` or `model: "haiku"` for mechanical tasks rather than letting the agent default to Opus. The agent tool accepts this parameter.
- When writing memories like this one, batch writes tight and do not spend Opus tokens on verbose narrative when bullet points would do.

**Hard rule:** Claude cannot switch the main session's model mid-session. Only the user can, via `/model`. So Claude's job is to RECOGNIZE the mismatch and ASK the user to switch, not to silently continue on the wrong model.

**Evidence:** a 2026-04-08 audit-and-refactor session ran ~100 turns on Opus, including bash file extractions, three prettier runs, two audit writeups, a CLAUDE.md three-way split, slash command conversions, and a staging deploy. Maybe 10-15% of that work genuinely needed Opus. Rough back-of-envelope: Sonnet would have cost 3-5x less for the same output.
