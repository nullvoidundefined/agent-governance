---
name: task-cleanup
description: Use at the end of every task to verify completeness, update docs, and close out the work. Examines what shipped and runs only the relevant cleanup steps. Pair with task-start.
---

# Task Cleanup

Examine what shipped. Run required cleanup. Close out the work.

**Announce at start:** "I'm using the task-cleanup skill to verify and close out this work."

## Why This Exists

Every task has a tail: feature list updates, user stories, E2E tests, squash merges, session handoffs. Without this skill, those steps are forgotten or done inconsistently. This skill makes them mechanical.

## Step 1: Determine What Shipped

Read the git log since the task started. Classify the changes:

```bash
git log --oneline main..HEAD  # if on a feature branch
git log --oneline -N           # if on main, where N = commits this task
git diff main --stat           # files changed
```

Answer these questions (in writing, in the response):

1. **Did this task ship user-facing behavior?** (new page, new flow, new UI, changed interaction)
2. **Did this task create new components?** (in any client surface)
3. **Did this task create or modify API endpoints?**
4. **Did this task introduce new query parameters?**
5. **Did this task create a spec or plan?** (that may now be shipped)
6. **Is this task on a feature branch?** (needs merge decision)
7. **Is this a session-ending task?** (needs handoff)

## Step 2: Run Required Actions

Based on the answers above, run only the applicable actions. Skip any that do not apply.

### If user-facing behavior shipped:

**Feature list update:**
```bash
# Check current feature list
cat docs/feature-list/features.md
```
Add or update the relevant row. Set status to **Complete** with today's date. Include story IDs if applicable.

**User story:**
Check if a user story exists in `docs/user-stories/` for this flow.
- If none exists: create one with acceptance criteria derived from the implementation.
- If one exists: verify acceptance criteria match what shipped. Update if needed.
- The `**E2E test:**` line must reference the actual file path under `e2e/`.

**E2E test:**
Check if a Playwright spec covers the new flow.
- If none exists and the flow is testable: create a placeholder spec in `e2e/` with `test.skip` and a TODO referencing the user story.
- If one exists: verify it covers the acceptance criteria.
- If the flow is not E2E-testable (extension-only, requires manual browser): document why in the user story.

### If new components were created:

**Storybook story:**
Verify every new component has a co-located `.stories.tsx` file. If any are missing, create them now. This is non-negotiable per project rule 13.

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
```bash
pnpm test          # unit tests
pnpm build         # build check
pnpm lint          # lint check
```

All three must pass before any merge decision.

**Merge decision:**
- Squash merge onto main: `git checkout main && git merge --squash feat/<slug>`
- Write a squash commit message that summarizes the whole feature, not just the last change.
- Delete the feature branch after merge: `git branch -d feat/<slug>`
- If worktree was used: `git worktree remove <path>`

### If session is ending:

**Session handoff:**
Write `docs/session-handoff/session-handoff.md` per R-302:
1. Last commit SHA + subject
2. Production state verified
3. Session metrics (commits, files changed, rework count, velocity flag)
4. What shipped (grouped by topic, traceable to commits)
5. Pending work (by urgency, with rationale and effort estimate)
6. Recommended next session (ordered task list with files to read first)

### If files changed in a project-specific documented surface:

**Surface doc refresh:**
Some projects define surface-anchor directories with co-located `CLAUDE.md` documentation and a slash-command (e.g., `/update-the-big-brain-on-brad` or similar) that regenerates those per-surface docs. If the current project defines surfaces and a refresh skill in its own `CLAUDE.md`, invoke the refresh for any surface where 3+ files changed in this task. If fewer than 3 files changed, or the project does not define surface docs and a refresh skill, skip.

## Step 3: Final Commit

If any cleanup actions produced file changes (feature list, user story, E2E placeholder, story file, query params doc, spec/plan deletion), commit them:

```bash
git add <specific files>
git commit -m "chore: task cleanup for <feature-slug>"
```

## Step 4: Report

Output a summary table:

```
| Action              | Status  | Notes                        |
|---------------------|---------|------------------------------|
| Feature list        | Updated | Row added for <feature>      |
| User story          | Created | docs/user-stories/<slug>.md  |
| E2E test            | Exists  | e2e/<slug>.spec.ts           |
| Storybook stories   | Verified| 2 new stories created        |
| Query params doc    | N/A     | No new params                |
| Spec/plan cleanup   | Deleted | Both fully shipped           |
| Tests               | Pass    | 412 passing, 0 failing       |
| Build               | Pass    | Exit 0                       |
| Squash merge        | Done    | feat/<slug> merged to main   |
| Session handoff     | Written | docs/session-handoff/...     |
```

## Scope-Dependent Behavior

The cleanup intensity scales with the task tier (from task-start):

### Trivial cleanup
- Commit the change (if not already committed)
- No feature list, no user story, no E2E, no handoff
- Just verify tests still pass

### Standard cleanup
- Commit per task
- Feature list update if user-facing
- User story if new flow
- Squash merge if on feature branch

### Complex cleanup
- Everything in standard, plus:
- E2E test verification (must exist, not just placeholder)
- Storybook stories verification
- Spec/plan deletion if shipped
- Session handoff if ending

### Saga cleanup
- Everything in complex, plus:
- Cross-surface verification (all surfaces tested)
- Full audit consideration (has enough shipped to warrant an engineering audit?)
- Session handoff is mandatory (sagas always span intent boundaries)

## Common Mistakes

- Skipping cleanup on trivial tasks and accumulating drift in the feature list
- Writing a squash commit message that says "final cleanup" instead of summarizing the feature
- Leaving shipped specs/plans in docs/superpowers/ (they become noise for future sessions)
- Creating E2E placeholders and never filling them in (the placeholder must reference the user story so it is discoverable)
- Updating the feature list but not the user story (or vice versa)
- Forgetting to delete the feature branch after squash merge

## Integration

- **Paired with:** task-start (run at the beginning of every task)
- **Composes with:** cleanup-specs-plans (for bulk cleanup), finishing-a-development-branch (for merge decisions), update-the-big-brain-on-brad (surface doc refresh)
- **Replaces:** manual feature completion checklist (CLAUDE.md rule 10)
