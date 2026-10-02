# Cost, Routing, and Estimation (R-9xx)

R-901: Tag every plan task before execution as `[trivial]`, `[standard]`, `[complex]`, or `[saga]`.
  Class: D; delivery: this file, read on demand.
  Spec: the tier definitions and per-tier execution shapes (branch, spec, plan, TDD, worktree) live in `skills/task-start/SKILL.md`, the canonical tier table; do not restate it here, the two copies drifted once already. Whether the `test-author`/`implementer`/`slice-critic` roles dispatch is decided per slice by its R-110 risk, not by this tag.
  Enforcement: manual

R-902: Execute inline work as brainstorm -> short spec -> execute; write full plans for subagent handoff only.
  Class: D; delivery: this file, read on demand.
  Enforcement: manual

R-903: Route work to the cheapest capable model: Opus for hard, ambiguous, security-sensitive, or audit work; Sonnet for well-scoped feature work; Haiku for mechanical edits and lookups.
  Class: D; delivery: this file, read on demand.
  Spec: the activity-by-activity routing table (planning, test author, implementer, critic, audits, doc edits) lives in `skills/task-start/SKILL.md` under Model Routing, the canonical routing surface.
  Enforcement: hook:model-switch-guard (PreModelSwitch; warns via systemMessage on any switch up the price ladder, silent otherwise; the event has no ask channel and exit 2 would veto rather than confirm, so the warning is the mechanical assist and the routing decision stays with the human). PreModelSwitch confirmed as a documented event 2026-09-17

R-904: Verify the signal condition (R-801) before running any audit.
  Class: D; delivery: this file, read on demand.
  Enforcement: hook:audit-signal-check (advisory; surfaces the commit-count signal at push time); manual for verification before dispatch

R-905: Hold retrospectives only after real incidents (recovery > 30 min or a pattern repeated across commits); normal sessions get handoff docs.
  Class: D; delivery: this file. Consistent with the 1:1 budget (IAN-568): a retrospective is process time, so it runs only where an incident's cost justifies it, and a normal session writes a handoff only when work is left open.
  Enforcement: manual

R-906: Deleted 2026-10-02 (IAN-568): its input, `estimate_ratio`, became optional on the ticket and no consumer acted on the recalibration; `/ticket-lifecycle` `estimate <tier>` remains available for an estimate from history.

R-907: Deleted 2026-10-02 (IAN-568): 421 owner asks with no recorded catch; a high-risk slice's separate test author is now R-707's, and the Codex invocation details live in `skills/tdd-gated-dispatch/SKILL.md`.

R-908: Warn before any `codex` CLI invocation that would bill the metered OpenAI API instead of the ChatGPT subscription the Codex steps assume.
  Class: M; delivery: hook.
  Spec:
  - Two things flip billing: an `OPENAI_API_KEY` the codex CLI can see (inline in the command, exported earlier in the same command, or already present in the calling environment) and a `codex login --with-api-key`/`--with-access-token` re-auth.
  - Absent either, `codex login status` is the live authority; anything other than "Logged in using ChatGPT" warns.
  - Asks, never blocks: API billing may be a deliberate choice, but never a silent one.
  Enforcement: hook:codex-billing-guard (PreToolUse Bash; fires only on commands that invoke `codex`)
