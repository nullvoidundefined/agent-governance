# Global Memory Index

Cross-project memories consolidated from 14 per-project memory directories on 2026-04-06 (spanning production, development, and template projects). These apply to every project unless a project-level memory explicitly overrides.

## Feedback (collaboration rules)
- [`feedback_be_proactive.md`](./feedback_be_proactive.md): Act, don't delegate back to the user
- [`feedback_deploy_at_end.md`](./feedback_deploy_at_end.md): Batch deploys; hold push until explicitly asked
- [`feedback_model_routing.md`](./feedback_model_routing.md): **Canonical** model-routing rule. Opus for hard tasks, Sonnet for medium, Haiku for simple.
- [`feedback_audit_autonomy.md`](./feedback_audit_autonomy.md): Audit agents autonomous; never suppress finding categories
- [`feedback_no_tls_bypass.md`](./feedback_no_tls_bypass.md): Never disable TLS verification to unblock a deploy
- [`feedback_mock_third_party_services.md`](./feedback_mock_third_party_services.md): Wrap SaaS in service interfaces with mocks
- [`feedback_mjs_prettier_config.md`](./feedback_mjs_prettier_config.md): Prettier configs use `.mjs` extension
- [`feedback_process_learnings_20_rules.md`](./feedback_process_learnings_20_rules.md): PL1 through PL20 incident-backed rules from 2026-04-05 and 2026-04-06
- [`feedback_no_empty_praise.md`](./feedback_no_empty_praise.md): Never compliment Ian's work without specific, falsifiable reasoning. Default to critical analysis.
- [`feedback_no_fluff.md`](./feedback_no_fluff.md): Ban all LLM filler patterns per R-009.
- [`feedback_pr_constant_value_check.md`](./feedback_pr_constant_value_check.md): When a constant value changes, grep tests for the old value before pushing and update all stale assertions in the same commit.
- [`feedback_validate_tech_task_fit.md`](./feedback_validate_tech_task_fit.md): When a learning goal is paired with a product idea, validate the technology fits the task/data on day one before building.
- [`feedback_gh_cli_bot_review_false_negative.md`](./feedback_gh_cli_bot_review_false_negative.md): `gh pr view --json reviews` can omit bot reviews; confirm via the REST API before asserting none exist.

## Efficiency lessons (incident-backed)
- [`lesson_no_reread_auto_injected_context.md`](./lesson_no_reread_auto_injected_context.md): Do not Read files already present in the session's auto-injected context (claudeMd, system-reminder blocks)
- [`lesson_avoid_giant_tool_outputs.md`](./lesson_avoid_giant_tool_outputs.md): Broad scans that produce hundreds of kilobytes of output bill against context even when 95% is noise; scope the query or dispatch to a subagent
- [`lesson_retries_compound_cost.md`](./lesson_retries_compound_cost.md): Every retry after a diagnosable error multiplies the token cost of the task; verify target (cwd, branch, path) before stateful operations
- [`lesson_inline_execution_efficiency.md`](./lesson_inline_execution_efficiency.md): 6 lessons from a 2026-04-08 UI cleanup session. L1 parallel-session worktree default, L2 skip full plan for inline execution, L3 scope test runs to touched files, L4 trust pre-commit don't duplicate, L5 no granular task entries for inline plans, L6 one-sentence commit bodies by default
- [`lesson_format_before_commit.md`](./lesson_format_before_commit.md): Run `prettier --write` on newly created/edited files before the first commit attempt. Avoids a doubled pre-commit cycle
- [`lesson_hold_large_file_in_context.md`](./lesson_hold_large_file_in_context.md): Plan edits to large files to avoid a second full read in the same session. External tools (prettier, linters) modify files and force a re-read
- [`lesson_hook_runtime_budget.md`](./lesson_hook_runtime_budget.md): Pre-commit hooks cost ~7-10s per run. Plan commits to land in one pass; batch coordinated files into one commit
- [`lesson_batch_file_creation_then_commit.md`](./lesson_batch_file_creation_then_commit.md): When a task requires multiple coordinated files (hook + registration + test), do all the file work first and commit once. Never commit incrementally within one logical unit
- [`lesson_zsh_no_word_splitting.md`](./lesson_zsh_no_word_splitting.md): zsh does not word-split unquoted `$var`; `cmd $list` passes one giant arg. Iterate with while-read, an explicit array, or verified NUL xargs

## Cost discipline (2026-04-08 quota-burn retrospective)

- [`feedback_default_sonnet_proactive_switch.md`](./feedback_default_sonnet_proactive_switch.md): **HARD RULE.** Default every session to Sonnet. Opus is the exception the user asks for. When the main session drifts into mechanical work, Claude proactively tells the user to `/model sonnet` rather than silently burning Opus. Cannot switch mid-session; must prompt user.
- [`lesson_subagent_first_for_multi_file.md`](./lesson_subagent_first_for_multi_file.md): Default to subagent dispatch for any task that reads >5 files, explores a codebase, or produces a focused report. Pass `model: "sonnet"` explicitly unless Opus-level reasoning is genuinely required. Keeps main session context clean
- [`lesson_break_sessions_at_task_boundaries.md`](./lesson_break_sessions_at_task_boundaries.md): Context accumulates geometrically per turn. End session at natural task boundaries, write the handoff doc, start fresh for the next task. Past ~60 turns the cost curve dominates
- [`lesson_calibrate_investigation_depth.md`](./lesson_calibrate_investigation_depth.md): Calibrate audit/investigation depth to stakes and to prior context. The second audit of the same session can reuse prior findings instead of re-investigating at full depth. Set a token budget upfront and stop when evidence is sufficient

## Source coverage

Consolidated from 29 feedback memories across 14 per-project memory directories (production, development, and template projects), 2026-04-06.

## How to use

These files are NOT auto-loaded by Claude Code. The memory system is project-scoped. To surface them in a project session, add a reference in that project's `memory/MEMORY.md`:

```
## Global memory
See ~/.claude/global-memory/INDEX.md for cross-project memories.
```

Or, for active projects where global context matters, copy-reference specific files:

```
## Inherited global rules
- feedback_be_proactive -> ~/.claude/global-memory/feedback_be_proactive.md
- feedback_model_routing -> ~/.claude/global-memory/feedback_model_routing.md
```
