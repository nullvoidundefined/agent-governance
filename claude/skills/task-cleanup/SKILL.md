---
name: task-cleanup
description: Use at the end of every task, before calling the work done or merging a feature branch. Pairs with task-start.
---

# Task Cleanup

Examine what shipped. Run required cleanup. Close out the work.

**Announce at start:** "I'm using the task-cleanup skill to verify and close out this work."

## Why This Exists

Every task has a tail: feature list updates, user stories, E2E tests, squash merges, session handoffs. Without this skill, those steps are forgotten or done inconsistently. This skill makes them mechanical.

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

**Merge decision:**
- Confirm with the user before merging. `git-workflow-guard` gates `gh pr merge` (R-514) and not a local `git merge`, so the ask here is the skill's, and "merge when ready" from an earlier turn is not it.
- Squash merge onto main: `git checkout main && git merge --squash feat/<slug>`
- Write a squash commit message that summarizes the whole feature, not just the last change.
- Delete the feature branch after merge: `git branch -d feat/<slug>`
- If worktree was used: `git worktree remove <path>`

### If a tracker ticket exists:

**Close the ticket:**

Run `/ticket-lifecycle` `close` after the verification gate and the merge decision, never before: a `done` ticket asserts the work shipped (R-606). Resolve the key from the spec's or user story's `**Ticket:**` line, the handoff doc, or the last `Refs:` trailer on the branch.

One update carries all of it: `done`, `completed_at`, `actual_minutes`, `rework_count`, `estimate_ratio`, and `pr_link`.

`actual_minutes` is attributable working time inside the sessions that worked the task, measured from the R-503 start timestamp. It is not the calendar gap between open and close; a ticket opened Monday and closed Friday is not four days of work, and recording it that way distorts every future estimate for that tier.

`rework_count` is the number of times a green slice went back to red or a review sent the work back. Count it from the git log and the session's own history, not from memory.

Then state the recalibration R-906 asks for, in one line: the ratio, and which direction the tier's next estimate moves. That line is the only reason the estimate was stored in the first place.

Work abandoned rather than shipped closes as `dropped` with the reason in the comment, never as `done` and never left open.

### If session is ending:

**Session handoff:**
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
| **Trivial** | Commit the change; verify tests still pass. Close the ticket only if one was opened. |
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
- Forgetting to delete the feature branch after squash merge
- Closing the ticket as `done` before the verification gate passes
- Writing the calendar gap between open and close as `actual_minutes`
- Closing with the actuals missing, which leaves a `done` row that no estimate can ever be drawn from

## Integration

- **Paired with:** task-start (run at the beginning of every task)
- **Calls:** ticket-lifecycle (`close`, or `advance` to `dropped` for abandoned work)
- **Composes with:** cleanup-specs-plans (bulk cleanup), superpowers:finishing-a-development-branch (merge decisions), and the project's own surface-doc refresh command where one is defined
- **Replaces:** the manual feature-completion checklist
