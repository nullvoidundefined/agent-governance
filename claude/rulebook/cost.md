# Cost, Routing, and Estimation (R-9xx)

R-901: Tag every plan task before execution.
  Spec:
  | Tag | Definition | Execution |
  |---|---|---|
  | `[trivial]` | Single-file edit, one-line config, doc tweak, env var rename | Inline, no subagents |
  | `[standard]` | Multi-file change, real logic, new function with tests, schema migration | One implementer + one reviewer |
  | `[complex]` | Cross-cutting refactor, new subsystem, security/auth-sensitive change | Implementer + spec reviewer + code-quality reviewer |
  Enforcement: manual

R-902: Execute inline work as brainstorm -> short spec -> execute; write full plans for subagent handoff only.
  Enforcement: manual

R-903: Route work to the cheapest capable model.
  Spec:
  | Model | Use for |
  |---|---|
  | Opus | Complex refactors, security-sensitive logic, ambiguous design, audits, multi-step planning |
  | Sonnet | Targeted features, well-scoped refactors, normal feature work |
  | Haiku | File moves, doc edits, single-line config, formatting, simple lookups |
  Enforcement: manual. hooks/model-switch-guard.sh exists and is unit-tested, but PreModelSwitch is not a real Claude Code hook event, so it is never invoked by the harness. Routing stays honor-system until a real event exists

R-904: Verify the signal condition (R-801) before running any audit.
  Enforcement: hook:audit-signal-check (advisory; surfaces the commit-count signal at push time); manual for verification before dispatch

R-905: Hold retrospectives only after real incidents (recovery > 30 min or a pattern repeated across commits); normal sessions get handoff docs.
  Enforcement: manual

R-906: Divide time estimates by 3-5x; pad only for external dependencies, first-of-a-kind work, or research tasks; recalibrate after every task.
  Enforcement: manual

R-907: Write implementation code and the tests that verify it with different model providers; never let the model that wrote the code also write its own tests.
  Spec:
  | Step | Actor |
  |---|---|
  | Implementation | Claude (this session) |
  | Tests for that implementation | `codex` CLI (OpenAI), dispatched as a separate process, not written inline by Claude |
  Enforcement: manual. The `codex` CLI is installed (`/opt/homebrew/bin/codex`); invoke it explicitly for test authoring rather than writing the tests in the same Claude session that wrote the implementation. Verified 2026-09-10 end-to-end: Claude wrote a buggy implementation, `codex exec` independently wrote tests from the docstring contract and caught the bug. Billing is guarded mechanically by R-908

R-908: Warn before any `codex` CLI invocation that would bill the metered OpenAI API instead of the ChatGPT subscription R-907 assumes.
  Spec:
  - Two things flip billing: an `OPENAI_API_KEY` the codex CLI can see (inline in the command, exported earlier in the same command, or already present in the calling environment) and a `codex login --with-api-key`/`--with-access-token` re-auth.
  - Absent either, `codex login status` is the live authority; anything other than "Logged in using ChatGPT" warns.
  - Asks, never blocks: API billing may be a deliberate choice, but never a silent one.
  Enforcement: hook:codex-billing-guard (PreToolUse Bash; fires only on commands that invoke `codex`)
