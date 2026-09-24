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

R-907: Keep the failing test's author separate from the implementer in Complex and Saga: the `test-author` subagent writes each slice's failing test, and Codex does only when the owner opts in; in Standard and Trivial the implementing session writes the test itself, before the implementation, under the R-412 lock.
  Scope: every RED step of a `tdd-gated-dispatch` slice. Owner decision 2026-09-23 (IAN-333, "Drop the PR ceremony") replaced the 2026-09-19 decision that Codex writes every test in every tier: measured Codex test-authoring calls cost 70,000 to 82,000 tokens each, about 25,000 of that fixed startup cost, plus sandbox setup and a three-check validation per call. The R-412 lock already proves the test fails before any production write, so in Standard the separate author bought independence at a price the owner rejected; Complex and Saga keep it through the cheaper subagent. Trivial work has no slices, and a trivial bug fix still follows R-403.
  Spec:
  | Step | Actor |
  |---|---|
  | Failing test, Standard | the implementing session, under the R-412 lock |
  | Failing test, Complex and Saga | the `test-author` subagent (R-705, R-707) |
  | Failing test, when the owner opts in to Codex | `codex exec` (OpenAI's Codex CLI), dispatched by the orchestrating session as a separate process; the `test-author` subagent is its fallback |
  | Implementation | the implementing session (Standard) or the `implementer` subagent (Complex and Saga) |
  - Codex invocation, when opted in: `codex exec -s workspace-write -C <repo root> --skip-git-repo-check -o <final-message file> "<prompt>" </dev/null > <log file> 2>&1`, run in the background and polled through the log file. The prompt is the test-author prompt in `skills/tdd-gated-dispatch/SKILL.md`. Test authoring needs write access to the test tree, so it runs with `-s workspace-write`; reviews run with `-s read-only`.
  - Close stdin with `</dev/null`, or codex blocks on "Reading additional input from stdin". Never pipe its output through `tail`, which buffers until exit and looks exactly like a hang; read the log file instead.
  - uv's cache lives outside the `workspace-write` sandbox, so a Python slice's `uv run pytest` fails with `Operation not permitted` until the cache is redirected into the workspace or `$TMPDIR`; `skills/tdd-gated-dispatch/SKILL.md` gives the exact forms.
  - Omit `-m` so the account's default model applies. `-m gpt-5.1-codex-mini` is rejected on the owner's ChatGPT-login account (found 2026-09-17), so no model override is recommended.
  - Before the run the orchestrator records `git rev-parse HEAD` and the hash of `.claude/tdd-lock.json`; after it, before anything else runs, both must be unchanged (validate reads only uncommitted changes and leaves the lock out of its path check, so a Codex commit or a lock edit would otherwise pass). Codex is told not to run `tdd.sh`, since `tdd.sh red` rewrites the lock's phase; the orchestrator runs it only after the hash check. Then it runs `tdd.sh red` until it prints `RED:`, naming a new test file whole and each new test in a file that already held passing tests as `<test file>::<test id>` from the ids Codex reported, then `tdd.sh validate test-author`, which fails unless every changed path is a test or fixture path (R-411). A Codex run that wrote anything else is discarded with `git checkout`/`git clean` on those paths and re-run or replaced by the fallback; it is never committed.
  - The owner's Codex account is a $20 ChatGPT plan with tight usage limits (one unfocused spec review used 115k tokens and hit the limit on 2026-09-19). Keep every prompt focused on named files, and treat a usage-limit error as "rate-limited", which is exactly when the fallback applies.
  Degradation: when an opted-in codex CLI is missing, unauthenticated, or rate-limited, do not stall the slice: dispatch the `test-author` subagent with the same slice prompt and name the fallback in the PR body's test section.
  Related: the other two Codex steps in the pipeline, the adversarial spec review (`skills/task-start/SKILL.md`, Complex and Saga) and the blocking pre-merge review (R-517), use the prompt templates in `prompts/` and fall back to a separate Claude agent rather than to the main session.
  Enforcement: hook:codex-test-author-guard (PreToolUse Write/Edit; asks whenever Claude targets a test file, except when the task-start ledger records Standard or Trivial for the checked-out branch (IAN-333); silent for `agent_type` test-author, which is the recorded fallback, and silent when `CLAUDE_HOOK_RUNTIME` is `codex`, the marker `codex/hooks/codex-hook-adapter.sh` exports into every hook child; CODEX_TEST_GUARD=off silences harness-internal work). Codex does run the harness hooks through that adapter, and until 2026-09-20 the guard asked there too, which the adapter turns into a deny, so the rule denied its own named author. The marker names the runtime, not the role, so the silence is wider than this rule's invariant: any codex run may write a test file, including one doing implementation rather than the orchestrated test-author dispatch, where `tdd.sh validate test-author` is the only thing proving the paths. Narrowing it needs a slice marker the orchestrator sets and the adapter forwards. The `codex` CLI is installed (`/opt/homebrew/bin/codex`). Verified 2026-09-10 end-to-end: Claude wrote a buggy implementation, `codex exec` independently wrote tests from the docstring contract and caught the bug. Billing is guarded mechanically by R-908. Recording the fallback on the slice stays manual.

R-908: Warn before any `codex` CLI invocation that would bill the metered OpenAI API instead of the ChatGPT subscription R-907 assumes.
  Spec:
  - Two things flip billing: an `OPENAI_API_KEY` the codex CLI can see (inline in the command, exported earlier in the same command, or already present in the calling environment) and a `codex login --with-api-key`/`--with-access-token` re-auth.
  - Absent either, `codex login status` is the live authority; anything other than "Logged in using ChatGPT" warns.
  - Asks, never blocks: API billing may be a deliberate choice, but never a silent one.
  Enforcement: hook:codex-billing-guard (PreToolUse Bash; fires only on commands that invoke `codex`)
