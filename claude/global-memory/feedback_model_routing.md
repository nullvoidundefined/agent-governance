---
name: Route models by task difficulty (Opus / Sonnet / Haiku)
description: Use Opus for hard tasks, Sonnet for medium, Haiku for simple. Never default to Opus because it is smarter.
type: feedback
---

Match the model to the task. The Opus / Sonnet / Haiku price ladder is steep
and the quality delta on simple tasks is negligible. Defaulting to Opus
because it is "the smartest" is the single most expensive habit this harness
can have.

**Why:** observed token spend is dominated by subagent fan-out and audits,
both of which often dispatch Opus for tasks a smaller model would handle
fine. The cost analysis on 2026-04-07 estimated 60-70% of weekly spend sits
in subagent-driven plan execution and full-role audits. A meaningful share
of that is mis-routed model selection, not work that genuinely needs Opus.

**How to apply:**

- **Opus** when the task is genuinely hard:
  - Cross-cutting refactors with many integration points
  - Security-sensitive logic (auth, payments, RLS, secrets)
  - Ambiguous design problems where the right shape is not yet clear
  - Brainstorming a feature that has not been spec'd
  - Audits whose role file explicitly demands deep analysis (Engineering,
    Security, Criticism)
  - Plans that touch 5+ files with non-trivial logic
- **Sonnet** for normal feature work:
  - Standard implementer subagents executing a well-scoped plan task
  - Targeted refactors with a clear before/after
  - Test writing for an existing function whose behavior is settled
  - Most code review subagents (the "spec reviewer" role in the two-stage
    review loop)
  - Most audit roles when the surface is small and the rubric is clear
    (UX, Design, Marketing, Legal on a single page)
- **Haiku** for small mechanical tasks:
  - File renames and moves
  - Single-line config changes
  - Formatting fixes
  - Doc edits where the content is dictated, not invented
  - Simple lint/type-error cleanups where the fix is obvious
  - Routing/triage decisions ("which file does this belong in")

**When in doubt, step down a tier and observe.** Sonnet handles more than
people give it credit for. Haiku handles more than people give it credit
for. If a smaller model produces a wrong answer, the cost of stepping up
and retrying is much smaller than the cost of having defaulted to Opus on
hundreds of tasks where Sonnet would have been fine.

**Subagent dispatch must specify the model explicitly.** Do not rely on
inheritance or defaults. The dispatch prompt or the agent definition's
frontmatter should name the model. A subagent dispatched without an
explicit model is a dispatch that is silently defaulting to whatever the
parent uses, which is almost always wrong-by-default for trivial tasks.

**Audit roles should declare their preferred model in the role file.**
The role file at `~/.claude/audits/<role>.md` is the right place to
record "this audit needs Opus" or "this audit runs fine on Sonnet."
Without that declaration, every audit invocation re-litigates the
question.

**Related rules:**
- `feedback_parallel_agents.md` has the original (narrower) version of
  this rule scoped to parallel dispatch. This file is the broader,
  authoritative version that applies to every model invocation, parallel
  or serial.
- The "Cost discipline" section of `~/.claude/CLAUDE.md` references this
  file as the canonical model-routing rule.
