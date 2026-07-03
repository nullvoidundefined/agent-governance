---
name: lesson_break_sessions_at_task_boundaries
description: Context accumulates per turn. A 100-turn session costs disproportionately more than two 50-turn sessions because each turn includes the full conversation history as input. Break sessions at natural task boundaries and use the handoff doc to preserve state.
type: feedback
---

**End sessions at natural task boundaries. Do not let one session grow into a multi-task marathon.**

**Why:** Every turn in a Claude Code session sends the full conversation history as input. By turn 50, each new user message is costing the full context of 50 prior turns to generate a response. By turn 100, it is costing double that. This is geometric in context accumulation even though each individual turn feels linear. On 2026-04-08 a production session ran ~100 turns including two audits, a CLAUDE.md restructure, a refactor plan, agent conversions, and a staging deploy. The last 20 turns of that session were costing 5-10x what the first 20 turns did, purely from context accumulation, regardless of what work was happening in those turns.

**How to apply:**

- **End the session at task completion.** When a natural deliverable lands (doc committed, feature shipped, audit filed, plan approved), write a handoff doc and stop. Do not roll into the next task in the same session.
- **Write the handoff.** The session-handoff pattern at `docs/audits/YYYY-MM-DD-session-handoff.md` is exactly the tool for preserving state across session boundaries. Keep it under 8KB; bullets, not prose. See R-602.
- **Start fresh for the next task.** A new session starts with an empty conversation history and auto-loads only the CLAUDE.md files. That is the cheapest context state. Every turn after that costs more.
- **Recognize the "one more thing" trap.** When a task finishes and the next obvious follow-up is small, the instinct is to keep going in the same session. Resist. Two small tasks in two sessions is cheaper than two small tasks bolted onto the end of a session that already has 50 turns of history.

**Signs it is time to end the session:**

- A major deliverable just committed cleanly
- The current conversation has stretched past ~40 turns
- The user has expressed satisfaction or closure
- The next task is conceptually different from the current task (building vs auditing, planning vs executing, backend vs frontend)
- The user asks "is it done?" or similar closing language

**When a long session is correct:**

- A single deeply-entangled refactor where every turn builds on the previous one and the state cannot be cleanly handed off mid-work
- Active debugging where the context of failed attempts is load-bearing for the next attempt
- Brainstorming where the user is actively iterating and needs continuity of thought

Even in these cases, watch the turn count. Past 60 turns, the cost curve starts to dominate.

**Evidence:** the 2026-04-08 session passed at least three natural break points (after the audit, after the CLAUDE.md split, after the refactor plan) and kept rolling into new tasks each time. Each rollover inherited the full context of everything that came before. By the time the session ended with the ship command, turn-level cost was substantially above where it started.
