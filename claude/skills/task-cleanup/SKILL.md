---
name: task-cleanup
description: Use at the end of every task, before calling the work done or merging a feature branch. Pairs with task-start.
---

# Task Cleanup

Examine what shipped. Run required cleanup. Close out the work.

**Announce at start:** "I'm using the task-cleanup skill to verify and close out this work."

## Why This Exists

Every task has a tail: feature list updates, user stories, E2E tests, squash merges, session handoffs. Without this skill, those steps are forgotten or done inconsistently. This skill makes them mechanical.

## Who Does What

Split by owner decision 2026-09-24 (IAN-345, amending IAN-333): tracker writes are direct calls from the main session, and a subagent is worth its start-up cost only for large doc bookkeeping.

- **Main session:** the scan, the verification gate, the feature list, the user story, the PR body (summary, what changed, decisions, testing, and a short reflection, replacing the retired per-PR document file), committing the edits, the one pre-merge review, the merge, every tracker write (findings tickets and the ticket close, as direct MCP calls), and the handoff.
- **Background subagent, Complex and Saga only** (`haiku` or `sonnet`, Agent tool `run_in_background: true`, dispatched as soon as the diff is final): the feature list, the user story, the PR body, and the handoff, when they read enough files to be worth it. The subagent edits files but never commits and never writes to the tracker; the main session commits its edits before the review runs.

## Step 1: Determine What Shipped

Run the scan; it answers six of the seven questions from the diff, names the files behind each answer, and prints the Step 4 table with N/A pre-filled where the answer is no:

```bash
bash ~/.claude/skills/task-cleanup/scripts/scan.sh [--range <a>..<b>]
```

The range is the merge base with the default branch on a feature branch, the session-start SHA on the default branch, else the last five commits. Read the answers (in writing, in the response); do not re-derive them by eye:

1. **Did this task ship user-facing behavior?** (a new route, handler, page, feature slice, or deploy surface was added; the same list `git-workflow-guard` uses for R-508)
2. **Did this task create new components?** (files added under a `components/` tree)
3. **Did this task create or modify API endpoints?** (files under `routes/`, `handlers/`, `api/`, or a `route.ts`)
4. **Did this task introduce new query parameters?** (added lines reading `searchParams`, `req.query`, or `useSearchParams`)
5. **Did this task create a spec or plan?** (files under `docs/superpowers/`, or an existing one named for the branch slug)
6. **Is this task on a feature branch?** (needs merge decision)
7. **Is this a session-ending task?** (needs handoff; the scan prints the task-start ledger beside it, the tier that scales Step 2)
8. **Does this task have a tracker ticket?** (needs closing with actuals; the key is on the spec's or user story's `**Ticket:**` line, the handoff, or the last `Refs:` trailer on the branch)

The scan surfaces the evidence; a surface it cannot see (a CLI flag, an extension-only flow) is still yours to name.

## Step 2: Run Required Actions

Based on the answers above, run only the applicable actions. Skip any that do not apply.

### If user-facing behavior shipped:

This block is R-607; the document shapes are the templates in `~/.claude/prompts/` (`feature-list-template.md`, `user-story-area-template.md`). Skip this block in a repository whose `.enforce.json` sets `"productDocs": false`.

**Feature list update:**
```bash
# Check current feature list
cat docs/feature-list/features.md
```
Find the feature's row in its area's `## ` section; `feature-create` or `task-start` added it as **Planned** when the work began. Set it to **Complete** when every criterion of its stories shipped, or to **Partial** with the gap named in the notes. Keep the story ids in the notes. Rewrite the `Last updated:` line with today's date and what changed. If no row exists, add one to the matching section now.

**User story:**
Find the story in `docs/user-stories/<area>.md` by its `US-<AREA>-NNN` id.
- If none exists: append one to the area file with the next free number in the area and criteria derived from the implementation; index a new area file in `docs/user-stories/README.md`.
- If one exists: tick (`- [x]`) each criterion that shipped, leave the rest unticked, and edit a criterion that no longer matches what shipped.
- The `**E2E test:**` line must reference the actual file path under `e2e/`.

**E2E test:**
Check if a Playwright spec covers the new flow.
- If none exists and the flow is testable: open a slice (`tdd.sh open`) and write it as a RED test now, or record in the user story why it waits for the next session. Never a skipped placeholder (R-401 item 9).
- If one exists: verify it covers the acceptance criteria.
- If the flow is not E2E-testable (extension-only, requires manual browser): document why in the user story.

### If the stack or what the app dispatches changed:

This block is R-608; the document shapes are `~/.claude/prompts/stack-template.md` and `~/.claude/prompts/observability-template.md`. Skip each half in a repository whose `.enforce.json` sets `"stackDoc"` or `"observabilityDoc"` to `false`.

**Stack doc:**
```bash
git diff --stat "$(git merge-base origin/main HEAD)"..HEAD -- '*package.json' '*pyproject.toml' '*Gemfile' '*go.mod'
```
For every dependency, runtime, service, or tool the branch added, removed, replaced, or upgraded across a major version, `docs/stack.md` has a matching `### <Name>` entry under its layer with all six fields filled (version, what it is, docs link, role here, why chosen, configured in), or no entry when it was removed. The push gate only sees dependency names in the four manifests; a major upgrade, a new hosted service, or a CI tool is yours to check. Rewrite the `Last updated:` line.

**Observability doc:**
Every analytics event, log event, and error code the branch added, renamed, or removed has its row in `docs/observability.md` (added, renamed, or deleted), with the trigger, fields or properties, and level or HTTP status. Check the error-tracker, request-ID, health, and metrics sections against the diff as well, since the push gate cannot see them. Rewrite the `Last updated:` line.

### If new components were created:

**Storybook story:**
Where the project's own `CLAUDE.md` defines a Storybook convention, verify every new component has a co-located `.stories.tsx` file and create any that are missing. If the project defines no such convention, skip.

### If query parameters changed:

**Query params doc:**
Update `docs/query-params.md` with the new/changed params. Same commit as the code change.

### If a spec or plan exists for this work:

**Shipped spec/plan cleanup:**
Check if the spec and plan are fully shipped (all tasks done, all acceptance criteria met).
- If fully shipped: delete both files. The code is the spec now.
- If partially shipped: leave them, but update checkboxes to reflect current state.

### If on a feature branch:

**Verification gate:**

Run the project's test, build, and lint commands (whatever `package.json`, `Makefile`, or the project `CLAUDE.md` defines). All three must pass before any merge decision.

**PR loop** (R-514, R-515, R-517). On a trivial tier recorded in the task-tier ledger for this branch, run only step 1 (open the PR) and step 3 (the ledger note), then merge on green CI; steps 2, 4, and 5 apply only above the trivial tier. The trivial tier is the one path that still merges on green CI without a recorded opt-in (owner decision 2026-09-19), and it is a standalone task rather than a slice of a plan, so no `**Merge mode:**` line governs it; every PR above that tier follows the merge decision below:
1. Open the PR. The separate `/code-review` pass before opening the PR is retired; one R-517 review per PR is enough, and a security-touching range also requires the R-109 security review.
2. Commit the bookkeeping edits (feature list, user story, handoff), then run the R-517 review (below) on the finished head. It is the review every PR above trivial gets.
3. Start the next ticket while CI and the review run (CI alone on a trivial PR). Return to this PR when they finish; do not block the session on a poll loop. A trivial PR's exemption from R-517 lives in the checkout's one task-tier ledger: merge the trivial PR first, or use one worktree per in-flight ticket to avoid a ledger swap.
4. Fix each valid review comment (failing case first when behavior changes), reply in its thread naming the fix commit, and resolve the thread (R-515). A commit that moves the head triggers a re-review on the new range.
5. After the review, change only the PR body, title, or labels, which move no commit, so one review per PR stays sufficient.
6. For 2 to 5 small related tickets, one bundle PR may replace separate PRs: label it `bundle`, keep one commit per ticket with its own `Refs:` trailer, and merge with `--rebase` (R-512). Never bundle deletion, security, sync, or migration changes.

**Pre-merge review (R-517)** (blocking, every PR above the trivial tier; a trivial PR is exempt only when `.claude/task-tier.json` records the trivial tier for its head branch):

The default reviewer is a fresh subagent of the read-only `pr-reviewer` type on `sonnet` (it carries only Read, Grep, Glob, and Bash, so it should start from about half the context of `general-purpose`, as IAN-349 measured on `slice-critic`, which has the same tool set), given the filled `~/.claude/prompts/codex-pr-review-prompt.md`, reviewing the PR's diff against the spec and the acceptance criteria the PR claims, before merge (a different context from the one that wrote the code). Use Codex, or a stronger subagent (`opus`/`fable`), only when the owner opts in or the diff touches auth, money, or concurrency.

1. Copy `~/.claude/prompts/codex-pr-review-prompt.md` below its line into a scratch file and fill every placeholder: the base and head refs, the spec path (or "none" in Standard), the requirement text itself (the slice plan's PR block, the `B-n` lines, the rule entry, or the ticket's scope), only the convention files the diff touches, and the diff itself, with generated trees and lock files excluded and named (the template's step 2 says how, and records what that saves).
2. Dispatch a fresh Claude subagent (Agent tool, `subagent_type: "pr-reviewer"`, `model: "sonnet"`) with the filled prompt, and use its final message as the review.

**Codex (opt-in).** Run Codex instead when the owner asks or the diff touches auth, money, or concurrency. Keep it focused: the owner's Codex account is a $20 ChatGPT plan with tight usage limits.
```bash
codex exec -s read-only -C <repo root> --skip-git-repo-check \
  -o <scratch>/codex-pr-<n>-final.md "$(cat <scratch>/codex-pr-<n>-prompt.md)" \
  </dev/null > <scratch>/codex-pr-<n>.log 2>&1
```
Run it in the background (the Bash tool's `run_in_background`) and poll the log file until the process exits. Close stdin with `</dev/null`, or codex blocks on "Reading additional input from stdin". Never pipe it through `tail`, which buffers until exit and looks like a hang. Omit `-m`: `gpt-5.1-codex-mini` is rejected on the owner's ChatGPT account, so the account default applies. R-908's billing guard applies to the call.
**Fallback.** When Codex is missing, unauthenticated, or out of quota, do not wait for the quota to reset: dispatch a Claude subagent on a model at least as strong as this session's and ideally stronger (the Agent tool's `model: "fable"` when available, else `opus`), with the same filled prompt, and use its final message as the review.
3. Fix each finding (test-first when behavior changes) or answer it with a reason in the PR. A HIGH finding is never merged over with a bare "won't fix".
4. Add a `## Codex review` section to the PR body (`gh pr edit <n> --body-file <file>`) carrying three labelled lines and then the findings:
   ```
   ## Codex review
   - reviewer: Claude subagent (sonnet)
   - model: claude-sonnet-5
   - range: <base sha>..<head sha>
   - MEDIUM: <finding> - fixed in <sha>
   ```
   The `reviewer` line names the reviewer that ran and why, for example `Claude subagent (sonnet)` or `Codex, owner opt-in`; the `model` line names the model it ran on; the `range` line names the diff it read as a `<base>..<head>` expression, and its head endpoint must be the PR's head commit as GitHub reports it, which means a review run before the last push is re-run rather than re-typed. The head must be on the right of the `..`: a range whose base is the head reviewed everything except the head, and the gate denies it. Then one line per finding with its severity and disposition, or "No findings" with the areas checked. Each label may be bulleted and emphasised (`- **Reviewer:** Codex`) but never left without a value. The heading keeps the name "Codex review" whichever reviewer ran; `git-workflow-guard` denies `gh pr merge` while the section is missing, empty, duplicated, missing one of the three lines, carrying a `range` line with no `<base>..<head>` expression, or naming a range whose head endpoint is not the head commit.

**Merge decision:**
- Merge on green CI and a passed R-517 review when an owner-approved plan covers the work and that plan's `**Merge mode:**` line records the merge-on-green opt-in (R-514). Under a plan recording the default, or none, hand the PR to the owner with its findings and their dispositions and let them merge it. Otherwise confirm in the current turn; "merge when ready" from an earlier turn is not confirmation. `git-workflow-guard` gates `gh pr merge` and not a local `git merge`.
- `gh pr merge --squash --delete-branch` is the primary path; write a squash commit message that summarizes the whole feature, not just the last change.
- If worktree was used: `git worktree remove <path>`

### Always, before the ticket is closed (main session):

Run `bash ~/.claude/skills/task-start/scripts/finding.sh open`. It lists every finding recorded during this task that still carries no tracker key (R-214). The task is not finished while that list is non-empty: open a ticket for each remaining finding through `/ticket-lifecycle` and attach it with `finding.sh ticket <id> <KEY>`, so nothing noticed during the work is lost when the session ends. Once every finding carries a key, `finding.sh clear` removes the per-repo ledger, the same way `task-tier.sh clear` removes the tier ledger; the tickets are the durable record and the ledger is only what carried them there.

### If a tracker ticket exists:

**Close the ticket (main session, direct tracker call, after the merge):**

Run `/ticket-lifecycle` `close` after the verification gate and the merge decision, never before: a `done` ticket asserts the work shipped (R-606). Resolve the key from the spec's or user story's `**Ticket:**` line, the handoff doc, or the last `Refs:` trailer on the branch.

One update carries all of it: `done`, `completed_at`, `actual_minutes`, `rework_count`, `estimate_ratio`, and `pr_link`. `actual_minutes` is attributable working time inside the sessions that worked the task, measured from the R-503 start timestamp: not the calendar gap between open and close; a ticket opened Monday and closed Friday is not four days of work, and recording it that way distorts every future estimate for that tier. `rework_count` is the number of times a green slice went back to red or a review sent the work back, counted from the git log and the session's own history, not from memory.

Then state the recalibration R-906 asks for, in one line: the ratio, and which direction the tier's next estimate moves. That line is the only reason the estimate was stored in the first place. Work abandoned rather than shipped closes as `dropped` with the reason in the comment, never as `done` and never left open.

### If session is ending:

**Session handoff (main session; the bookkeeping subagent on a Complex or Saga task):**
Write `docs/session-handoff/session-handoff.md` per R-602, in this order:
1. Last commit SHA + subject
2. Production state verified
3. Session metrics: paste the output of `bash ~/.claude/hooks/session-metrics.sh` (commits, files changed, rework count, velocity flag, computed live from the session-start SHA; the SessionEnd copy of the same block fires after the handoff is committed, so never read the temp file)
4. What shipped (grouped by topic, traceable to commits)
5. Pending work (by urgency, with rationale and effort estimate)
6. Recommended next session (ordered task list with files to read first)

`hooks/handoff-check.sh` reminds on the Write when the file is over 8 KB, a section is missing or out of order, or the recorded SHA does not resolve; fix what it names before the final commit.

Carry the key of any ticket still open beside the pending item it belongs to (R-605), so the next session advances that ticket instead of opening a second one for the same work.

### If files changed in a project-specific documented surface:

**Surface doc refresh:**
Some projects define surface-anchor directories with co-located `CLAUDE.md` documentation plus a command that regenerates those per-surface docs. If the current project defines both in its own `CLAUDE.md`, invoke that refresh for any surface where 3+ files changed in this task. Otherwise skip.

## Step 3: Final Commit

If any cleanup actions produced file changes (feature list, user story, story file, query params doc, spec/plan deletion), commit them:

```bash
git add <specific files>
git commit -m "chore: task cleanup for <feature-slug>"
```

## Step 4: Report

Output the summary table the scan printed, with every TODO resolved to its outcome, then clear the task-start ledger (`bash ~/.claude/skills/task-start/scripts/task-tier.sh clear`) so the next task starts clean:

```
| Action              | Status  | Notes                        |
|---------------------|---------|------------------------------|
| Feature list        | Updated | Row added for <feature>      |
| User story          | Updated | docs/user-stories/<area>.md  |
| E2E test            | Exists  | e2e/<slug>.spec.ts           |
| Storybook stories   | Verified| 2 new stories created        |
| Query params doc    | N/A     | No new params                |
| Spec/plan cleanup   | Deleted | Both fully shipped           |
| Tests               | Pass    | 412 passing, 0 failing       |
| Build               | Pass    | Exit 0                       |
| Squash merge        | Done    | feat/<slug> merged to main   |
| Ticket              | Closed  | PROJ-123, 94m actual vs 120m estimate (0.78) |
| Session handoff     | Written | docs/session-handoff/...     |
```

## Scope-Dependent Behavior

Cleanup intensity scales with the task tier (from task-start, read off the ledger line the scan prints; `task-tier.sh get` when it is absent from context). Each tier adds to the one above it.

| Tier | Adds |
|---|---|
| **Trivial** | Commit, open the PR, merge on green CI with no R-517 review (R-517 exempts a branch the task-tier ledger records as trivial) and without the recorded merge-mode opt-in every other tier needs, this tier being the standing exception: no PR doc (R-514). Close the ticket only if one was opened. |
| **Standard** | Feature list if user-facing; user story if a new flow; squash merge if on a branch; ticket closed with actuals |
| **Complex** | E2E test must exist and pass; Storybook stories verified; shipped spec/plan deleted; ticket closed with actuals and the recalibration line; handoff if the session is ending |
| **Saga** | Every surface tested; handoff is mandatory; ticket closed with actuals per stage that shipped; consider whether enough shipped to warrant an engineering audit |

## Common Mistakes

- Skipping cleanup on trivial tasks and accumulating drift in the feature list
- Writing a squash commit message that says "final cleanup" instead of summarizing the feature
- Leaving shipped specs/plans in docs/superpowers/ (they become noise for future sessions)
- Deferring the E2E test without a line in the user story saying why and when
- Updating the feature list but not the user story (or vice versa); the push gate refuses a new route without both (R-607)
- Leaving a shipped row at **Planned**, or ticking criteria that did not ship
- Adding a dependency or an analytics event, error code, or log event without its `docs/stack.md` entry or `docs/observability.md` row, or writing a stack entry with no docs link or no plain explanation (R-608)
- Forgetting to delete the feature branch after squash merge
- Merging before the R-517 review ran, or with a `## Codex review` section that lists findings without their dispositions
- Closing the ticket as `done` before the verification gate passes
- Writing the calendar gap between open and close as `actual_minutes`
- Closing with the actuals missing, which leaves a `done` row that no estimate can ever be drawn from
- Doing bookkeeping inline in the main session, or committing docs after the review (it forces a second review)

## Integration

- **Paired with:** task-start (run at the beginning of every task)
- **Calls:** ticket-lifecycle (`close`, or `advance` to `dropped` for abandoned work)
- **Uses:** `prompts/codex-pr-review-prompt.md` for the blocking pre-merge review (R-517)
- **Composes with:** cleanup-specs-plans (bulk cleanup), superpowers:finishing-a-development-branch (merge decisions), and the project's own surface-doc refresh command where one is defined
- **Replaces:** the manual feature-completion checklist
