---
name: resolve-user-feedback
description: Use when the user wants to process outstanding feature requests and bug reports from the app_feedback table. Retrieves open entries, generates a fix spec, executes the fixes, marks entries as closed, and commits.
---

# Resolve User Submitted Feedback

End-to-end workflow for triaging, fixing, and closing user-submitted feedback (bugs and feature requests) from the `app_feedback` database table.

## When to Use

- User asks to address feedback, feature requests, or bug reports
- User asks to resolve user feedback or triage feedback
- Periodic triage of accumulated user feedback

## Process

### Step 1: Retrieve open feedback

Query the staging/production database for all open entries:

```sql
SELECT id, type, description, page_url, created_at
FROM app_feedback
WHERE status = 'open'
ORDER BY created_at DESC;
```

Run this via the server's `.env` database connection. Use `dotenv/config` to load credentials.

Present findings as a table:

| # | Type | Summary | Page |
|---|------|---------|------|
| 1 | bug/feature | One-line description | Route |

### Step 2: Classify entries

For each entry, classify as:

| Classification | Criteria | Action |
|---|---|---|
| **Actionable** | Can be fixed with code changes in the current codebase | Include in spec |
| **Aspirational** | Requires new subsystem, major feature, or product decision | Skip, leave open |
| **Duplicate** | Already addressed by another entry or existing code | Close with note |
| **Invalid** | Cannot reproduce, user error, or outdated | Close with note |

Present the classification to the user and ask which entries to include. Default: all actionable entries.

### Step 3: Investigate root causes

For each actionable entry, dispatch parallel Explore agents (Sonnet model) to investigate:

- Trace the user's described action through the codebase
- Identify the specific files, functions, and lines involved
- Determine root cause (missing code, wrong logic, missing UI, etc.)
- Note any secondary issues discovered during investigation

Each agent returns: file paths, line numbers, root cause analysis, and proposed fix.

### Step 4: Generate the spec

Write a spec to `docs/superpowers/specs/YYYY-MM-DD-feedback-fixes.md` containing:

- Table of feedback IDs with type and summary
- For each entry: root cause, fix description, files to modify, and test plan
- Execution order (bugs before features, quick fixes before complex ones)

Tag each item:
- `[trivial]` - one-file fix, config change
- `[standard]` - multi-file, real logic
- `[complex]` - cross-cutting, multiple components

### Step 5: Execute fixes

Work through the spec in order:

1. For each entry, make the code changes
2. Run the relevant test suite after each fix
3. Verify all tests pass before moving to the next entry

Follow project conventions:
- Test-first for bugs (R-201)
- Alphabetical ordering for props, types, keys
- Named exports only
- SCSS modules for styling (no Tailwind)

### Step 6: Mark entries as closed

After all fixes pass tests, update the database:

```sql
UPDATE app_feedback
SET status = 'closed'
WHERE id = ANY($1)
RETURNING id, type, status;
```

Only close entries whose fixes are verified. Leave aspirational/skipped entries as `open`.

### Step 7: Commit

Commit all changes together with a descriptive message:

```
fix: address N user feedback items (bugs and feature requests)

- FB-XX: one-line summary
- FB-XX: one-line summary
...
```

Include the spec file in the commit.

## Model Routing

| Task | Model |
|---|---|
| DB queries, classification | Inline (no subagent) |
| Root cause investigation | Sonnet (parallel Explore agents) |
| Spec writing | Inline |
| Code fixes (trivial/standard) | Inline |
| Code fixes (complex) | Opus |
| Test verification | Inline |

## Common Mistakes

- **Fixing aspirational items.** If it needs a new subsystem or product decision, it is not actionable. Leave it open.
- **Closing without verifying.** Run tests after every fix. Only close entries with passing tests.
- **Forgetting the DB update.** The workflow is not complete until closed entries are marked in the database.
- **Not presenting the table.** Always show the user the feedback table and classification before executing. They decide scope.
- **Skipping the spec.** Even for a single entry, write the spec. It documents what was found and why it was fixed.

## Edge Cases

- **Empty table.** If no open entries exist, report "No open feedback" and stop.
- **DB connection failure.** Ask the user to verify `.env` has the correct `DATABASE_URL`.
- **Migration not run.** If the `status` column does not exist, run `npx node-pg-migrate up` first.
- **Mixed environments.** Confirm with the user whether to query staging or production. Default to whichever `.env` points to.
