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

R-907: Have Codex author the failing test for every slice in Standard, Complex, and Saga, so the tests never come from the author of the implementation; the `test-author` subagent writes the test only when Codex is unavailable or rate-limited, and that fallback is recorded on the slice.
  Scope: every RED step of a `tdd-gated-dispatch` slice in the Standard, Complex, and Saga tiers (owner decision, 2026-09-19). Before that decision only Standard dispatched Codex and Complex and Saga used the `test-author` subagent; the subagent is now the fallback in every tier. Trivial work has no slices, and a trivial bug fix still follows R-403.
  Spec:
  | Step | Actor |
  |---|---|
  | Failing test for the slice | `codex exec` (OpenAI's Codex CLI), dispatched by the orchestrating session as a separate process |
  | Fallback test author, only when Codex is unavailable or rate-limited | the `test-author` subagent (R-705, R-707) |
  | Implementation | the implementing session (Standard) or the `implementer` subagent (Complex and Saga) |
  - Invocation: `codex exec -s workspace-write -C <repo root> --skip-git-repo-check -o <final-message file> "<prompt>" </dev/null > <log file> 2>&1`, run in the background and polled through the log file. The prompt is the test-author prompt in `skills/tdd-gated-dispatch/SKILL.md`. Test authoring needs write access to the test tree, so it runs with `-s workspace-write`; reviews run with `-s read-only`.
  - Close stdin with `</dev/null`, or codex blocks on "Reading additional input from stdin". Never pipe its output through `tail`, which buffers until exit and looks exactly like a hang; read the log file instead.
  - Omit `-m` so the account's default model applies. `-m gpt-5.1-codex-mini` is rejected on the owner's ChatGPT-login account (found 2026-09-17), so no model override is recommended.
  - After Codex returns, the orchestrator runs `tdd.sh red <test file>` until it prints `RED:`, then `tdd.sh validate test-author`, which fails unless every changed path is a test or fixture path (R-411). A Codex run that wrote anything else is discarded with `git checkout`/`git clean` on those paths and re-run or replaced by the fallback; it is never committed.
  - The owner's Codex account is a $20 ChatGPT plan with tight usage limits (one unfocused spec review used 115k tokens and hit the limit on 2026-09-19). Keep every prompt focused on named files, and treat a usage-limit error as "rate-limited", which is exactly when the fallback applies.
  Degradation: when the codex CLI is missing, unauthenticated, or rate-limited, do not stall the slice: dispatch the `test-author` subagent with the same slice prompt, and record the fallback on the slice as `Test author: test-author subagent (fallback: <reason>)` in the slice plan document's execution record (`docs/slices/`) or, when there is no slice plan, in the PR body's test section, so the gap is visible rather than silent.
  Related: the other two Codex steps in the pipeline, the adversarial spec review (`skills/task-start/SKILL.md`, Complex and Saga) and the blocking pre-merge review (R-517), use the prompt templates in `prompts/` and fall back to a separate Claude agent rather than to the main session.
  Enforcement: hook:codex-test-author-guard (PreToolUse Write/Edit; asks whenever Claude targets a test file, since codex writes tests from its own process and never trips it; silent for `agent_type` test-author, which is the recorded fallback; CODEX_TEST_GUARD=off silences harness-internal work). The `codex` CLI is installed (`/opt/homebrew/bin/codex`). Verified 2026-09-10 end-to-end: Claude wrote a buggy implementation, `codex exec` independently wrote tests from the docstring contract and caught the bug. Billing is guarded mechanically by R-908. Recording the fallback on the slice stays manual.

R-908: Warn before any `codex` CLI invocation that would bill the metered OpenAI API instead of the ChatGPT subscription R-907 assumes.
  Spec:
  - Two things flip billing: an `OPENAI_API_KEY` the codex CLI can see (inline in the command, exported earlier in the same command, or already present in the calling environment) and a `codex login --with-api-key`/`--with-access-token` re-auth.
  - Absent either, `codex login status` is the live authority; anything other than "Logged in using ChatGPT" warns.
  - Asks, never blocks: API billing may be a deliberate choice, but never a silent one.
  Enforcement: hook:codex-billing-guard (PreToolUse Bash; fires only on commands that invoke `codex`)
