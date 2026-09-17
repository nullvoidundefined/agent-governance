# Cost, Routing, and Estimation (R-9xx)

R-901: Tag every plan task before execution as `[trivial]`, `[standard]`, `[complex]`, or `[saga]`.
  Spec: the tier definitions and per-tier execution shapes (branch, TDD, worktree, which of the `test-author`/`implementer`/`slice-critic` roles dispatch) live in `skills/task-start/SKILL.md`, the canonical tier table; do not restate it here, the two copies drifted once already.
  Enforcement: manual

R-902: Execute inline work as brainstorm -> short spec -> execute; write full plans for subagent handoff only.
  Enforcement: manual

R-903: Route work to the cheapest capable model: Opus for hard, ambiguous, security-sensitive, or audit work; Sonnet for well-scoped feature work; Haiku for mechanical edits and lookups.
  Spec: the activity-by-activity routing table (planning, test author, implementer, critic, audits, doc edits) lives in `skills/task-start/SKILL.md` under Model Routing, the canonical routing surface.
  Enforcement: hook:model-switch-guard (PreModelSwitch; warns via systemMessage on any switch up the price ladder, silent otherwise; the event has no ask channel and exit 2 would veto rather than confirm, so the warning is the mechanical assist and the routing decision stays with the human). PreModelSwitch confirmed as a documented event 2026-09-17

R-904: Verify the signal condition (R-801) before running any audit.
  Enforcement: hook:audit-signal-check (advisory; surfaces the commit-count signal at push time); manual for verification before dispatch

R-905: Hold retrospectives only after real incidents (recovery > 30 min or a pattern repeated across commits); normal sessions get handoff docs.
  Enforcement: manual

R-906: Divide time estimates by 3-5x; pad only for external dependencies, first-of-a-kind work, or research tasks; recalibrate after every task.
  Spec: the division is the fallback, not the method. Recalibration reads the tracker history R-605 and R-606 accumulate: `/ticket-lifecycle` `estimate <tier>` returns the median and 80th percentile of `actual_minutes` over closed tickets matching that `tier` and `assist`, with the sample size stated. Five or more samples: take the median for a task resembling the sample and the 80th percentile for one carrying an unknown dependency, and say which. Fewer than five, or a sample whose date range is older than a quarter: fall back to the 3-5x division, label it a heuristic, and say `n` so the number is not mistaken for evidence. At close, R-606 reports `estimate_ratio` and the direction the tier's next estimate moves; that report is the recalibration this rule asks for, and before the ticket history existed there was nothing to recalibrate against.
  Enforcement: manual

R-907: Write implementation code and the tests that verify it with a different author than the one that wrote the code; never let the author of the implementation also write its own tests.
  Scope: inline authoring, where the session (or agent) writing tests also writes implementation. The dedicated `test-author` subagent (R-705/R-707) already satisfies the different-author intent: R-411 confines it to test and fixture trees, so it can never be the implementation's author, and the guard exempts it by `agent_type`.
  Spec, when authoring inline:
  | Step | Actor |
  |---|---|
  | Implementation | Claude (this session) |
  | Tests for that implementation | `codex` CLI (OpenAI), dispatched as a separate process, not written inline by Claude |
  Enforcement: hook:codex-test-author-guard (PreToolUse Write/Edit; asks whenever Claude targets a test file, since codex writes tests from its own process and never trips it; silent for `agent_type` test-author; CODEX_TEST_GUARD=off silences harness-internal work). The `codex` CLI is installed (`/opt/homebrew/bin/codex`); invoke it explicitly for test authoring rather than writing the tests in the same Claude session that wrote the implementation. Verified 2026-09-10 end-to-end: Claude wrote a buggy implementation, `codex exec` independently wrote tests from the docstring contract and caught the bug. Billing is guarded mechanically by R-908. Model routing: dispatch codex with a cheap-but-capable model (`codex exec -m gpt-5.1-codex-mini`, or low reasoning effort) for routine test authoring; the account is a $20 ChatGPT membership with tight rate limits, so reserve the default top model for genuinely hard slices (queue concurrency, transactions)

R-908: Warn before any `codex` CLI invocation that would bill the metered OpenAI API instead of the ChatGPT subscription R-907 assumes.
  Spec:
  - Two things flip billing: an `OPENAI_API_KEY` the codex CLI can see (inline in the command, exported earlier in the same command, or already present in the calling environment) and a `codex login --with-api-key`/`--with-access-token` re-auth.
  - Absent either, `codex login status` is the live authority; anything other than "Logged in using ChatGPT" warns.
  - Asks, never blocks: API billing may be a deliberate choice, but never a silent one.
  Enforcement: hook:codex-billing-guard (PreToolUse Bash; fires only on commands that invoke `codex`)
