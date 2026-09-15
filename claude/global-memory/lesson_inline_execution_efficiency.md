---
name: Inline execution efficiency, 6 cost lessons from a 2026-04-08 UI cleanup session
description: When executing a plan inline (not via subagents), cut plan-writing ceremony, scope test runs, trust pre-commit hooks, skip deep task lists, keep commit bodies short
type: feedback
---

These lessons came from an inline execution of a 13-task UI cleanup pass on a dedicated branch on 2026-04-08. Everything worked; the work shipped; but roughly 30% of the session's tokens were spent on ceremony that bought nothing. Apply these whenever executing a plan inline in the same session that wrote the plan.

**When this does NOT apply:** when dispatching to a fresh subagent, OR when the task is a production incident where slow-and-careful beats fast.

## The six lessons

### L1. Parallel sessions on the same working tree are the single biggest tax

**Rule.** Before starting any inline execution, check whether a parallel Claude Code (or other agent) session is active on the same working tree. If yes, move to a git worktree for isolation before the first edit.

**Why.** In a 2026-04-08 session, a parallel session switched branches out from under the main session twice, reverted in-progress edits, caused a misplaced commit on main, forced a rebase, and cost two full recovery cycles plus one task redo. None of the recovery was avoidable once the drift had started.

**How to apply.**
- At session start, ask or check: is another session editing this repo?
- If yes, create a worktree immediately: `git worktree add ../<project>-<feature> -b <branch>` and `cd` into it.
- If a parallel session appears mid-session, stop and move to a worktree before the next commit.
- If a commit lands on the wrong branch, treat it as a dispatch bug, not a fluke. Recover with cherry-pick plus reset (both require user approval per global rules).

**Companion rule.** `feedback_parallel_agents.md` covers parallel *agents dispatched from the same session*. This lesson is about parallel *independent sessions*. Both point to the same fix: worktree isolation.

### L2. Skip the full implementation plan when executing inline

**Rule.** The `superpowers:writing-plans` skill produces detailed plans because it assumes the executor is a fresh subagent with no context. When the same session that ran brainstorming is also going to execute the work inline, a 200-line plan is enough; an 1800-line plan is duplicate work.

**Why.** In the 2026-04-08 session, the plan was 1883 lines with complete code snippets for every step. The session that wrote it then executed it. Every snippet was already in my context from writing the plan; re-reading it during execution added nothing.

**How to apply.**
- **Inline execution flow:** brainstorm → short spec (what and why, not how) → go. No full plan.
- **Subagent handoff flow:** brainstorm → full spec → full plan (every code snippet, every command, every verification step) → dispatch.
- The deciding question: "Will a different model invocation execute this plan?" If yes, write the full plan. If no, the spec is enough.
- If you find yourself writing a plan step that quotes back code you already know, you are writing for a subagent that is not coming. Stop and shorten.

### L3. Scope test runs to the files touched in the current commit

**Rule.** For a commit that touches one component, run `test -- <filename>` or `test -- <pattern>`, not the full suite. Run the full suite only at the end of a feature branch or before push. The pre-push hook enforces the full run; per-commit runs can be targeted.

**Why.** 4 to 6 seconds per test run times 13 commits in the UI cleanup session was about 60 to 80 seconds of wall clock and a noticeable chunk of tool-call tokens. Most runs covered 400+ tests that had nothing to do with the one file I had just touched.

**How to apply.**
- After a single-file change: `pnpm --filter <pkg> run test -- <filename> --run`.
- After a multi-file change in one feature: scope to the feature directory.
- Before push (and therefore before the pre-push hook runs it for you): the full suite is already about to run anyway; one extra manual run is redundant.
- If the targeted run fails because of cross-file regression, broaden the scope once, not every commit.

### L4. Trust pre-commit hooks for format/lint/tsc; do not duplicate

**Rule.** If the pre-commit hook already runs `format:check`, `lint`, and `tsc` (via the test runner or a type-check step), do not manually run those same checks before every commit. The hook is the enforcement layer; running them twice per commit doubles the cost for zero new signal.

**Why.** Lefthook runs `format:check` + `lint` + `test` on every commit. Running `pnpm build` on top was duplicate work for any commit that did not change structural types.

**How to apply.**
- Trust the pre-commit chain. If it is green, the code is format+lint+test clean.
- Run `pnpm build` manually only when: (a) you changed build config, (b) you changed something that could break type resolution across files the per-file test did not cover, (c) you are about to push and want the full pre-push verification.
- For targeted bug fixes in a single component: pre-commit chain only. Skip the manual build.

### L5. Do not create granular task list entries for every sub-step of an inline plan

**Rule.** Use `TaskCreate`/`TaskUpdate` for top-level workstreams the user wants visibility into. Do not create one task per implementation step when executing an inline plan. The plan itself is the task list.

**Why.** In the 2026-04-08 session, I created 13 task-list entries matching the 13 plan tasks. Each task had a create call, an in_progress update, and a completed update. That is 39 tool calls spent on task bookkeeping for work the user was already watching me execute. The plan doc was the task list.

**How to apply.**
- **Good use of TaskCreate:** "Brainstorm nav redesign", "Write spec", "Execute UI cleanup pass" (three top-level workstreams).
- **Bad use:** "Task 1: component alignment fix", "Task 2: add a dependency", etc. (13 entries mirroring the plan).
- When in doubt, ask: does the user gain new information from seeing this task separately, beyond what the plan already shows? If no, skip it.

### L6. Keep commit bodies to one sentence unless the change deserves more

**Rule.** A two-line refactor does not need a five-line commit body. Write the body only when: (a) the change is non-obvious from the diff, (b) the rationale would be lost without context, (c) there is a future-bisect case you want to preempt.

**Why.** In the 2026-04-08 session, every commit had a 5-to-8-line body including commits as small as "move a directory" or "add a dependency". Those bodies were tokens the user did not need and that added no bisect value beyond what the subject line and the diff already convey.

**How to apply.**
- Default: subject line only, or subject + one sentence of why.
- Exceptions: business-logic bug fixes (pin the incident), architecture refactors (explain the invariant), security-sensitive changes (explain what is protected).
- The Co-Authored-By trailer is still required per project convention.

## What is NOT ceremony to cut

These all earned their keep in the 2026-04-08 session and every session before it. Do not touch them:
- **No em dash scan.** PreToolUse hook enforces. Zero marginal cost.
- **TDD for business logic (R-403).** Fix-commit gate enforces. Prevented real bugs in this session.
- **Pre-commit format/lint/test chain.** The safety harness. Caught a format drift in Task 10 that would have failed in CI otherwise.
- **Brainstorm before touching code.** Caught real design issues (a mode-inference threshold, tab bar vs single-page) that would have been expensive to find during execution.

## Meta

If a future session is tempted to "be thorough" by running full test suites per commit, writing 1800-line plans for inline work, or creating 13 granular task entries, read this memory and ask whether the thoroughness is buying anything. Default to inline-execution discipline; escalate to full ceremony only when subagent handoff or incident-severity risk actually calls for it.
