---
name: cleanup-specs-plans
description: Use when specs and plans folders contain stale files from completed work, at session end after shipping features, or when starting a new development phase. Also use when the user says "clean up specs", "audit plans", or "what's stale in docs"
---

# Cleanup Specs and Plans

## Overview

Audit spec and plan files against git history and codebase state. Delete files whose work has fully shipped. Extract remaining incomplete tasks into a consolidated backlog. Checkboxes in plan files go stale; git history is the source of truth.

**Core principle:** A spec or plan file exists to guide future work. Once the work has shipped, the file is noise. The git history and the code are the durable records.

## When to Use

- End of a session that shipped multiple features
- Start of a new development phase
- When specs/plans directories have 10+ files
- When you notice specs referencing work that already landed
- When the user asks what's left to build

## Process

### Step 1: Inventory

Find all files in the project's spec and plan directories. The conventional locations are:

```
docs/superpowers/specs/    # Design specs (*-design.md or *-spec.md)
docs/superpowers/plans/    # Implementation plans (step-by-step with checkboxes)
```

Pair specs with plans by name: `YYYY-MM-DD-feature-name-design.md` pairs with `YYYY-MM-DD-feature-name.md`.

### Step 2: Classify each file

**Do NOT trust checkbox status.** Checkboxes go stale. Instead, for each file:

1. Read the file to understand what it specifies
2. Check `git log --oneline --all` for commits that implement the described work
3. Grep for key artifacts named in the spec (migrations, handlers, components, routes, tests)
4. Check the most recent session handoff doc for "what shipped" lists

Classify as:

| Classification | Criteria |
|---|---|
| SHIPPED | All described work is verifiably in the codebase. Commits exist. Artifacts exist. |
| SUPERSEDED | A newer spec explicitly replaces this one (e.g., four-tier replaced by two-tier). |
| PARTIAL | Some work shipped, some remains. The remaining work is still planned. |
| UNSTARTED | No evidence of implementation in git or codebase. |
| STALE | Was planned but the product direction has changed; remaining work is no longer relevant. |

### Step 3: Act on classification

| Classification | Action |
|---|---|
| SHIPPED | Delete spec and its paired plan |
| SUPERSEDED | Delete spec and its paired plan |
| PARTIAL | Extract incomplete items to backlog, then delete originals |
| UNSTARTED | Keep if still relevant; move to STALE if direction changed |
| STALE | Delete after confirming with user |

### Step 4: Build or update the backlog

Create or update `docs/superpowers/backlog.md` with extracted incomplete items. Structure:

```markdown
# Backlog

Items extracted from completed/partial specs during cleanup on YYYY-MM-DD.

## Feature Area Name

### Item title
- **From:** original-spec-filename.md
- **Priority:** P1/P2/P3
- **Description:** One-line summary of remaining work
- **Key artifacts needed:** migration, handler, component, test (list what's missing)
```

Group by feature area, not by original spec file. Multiple specs may contribute items to the same area.

### Step 5: Commit and report

1. `git rm` the deleted files
2. Commit with subject: `chore: clean up shipped specs and plans`
3. Output a summary table:

```
| File | Status | Action |
|---|---|---|
| feature-design.md | SHIPPED | Deleted |
| feature.md | SHIPPED | Deleted (paired plan) |
| other-design.md | PARTIAL | 3 items moved to backlog |
```

## Dispatch Pattern

For projects with 15+ spec/plan files, dispatch a Sonnet subagent to do the read-and-classify pass. The subagent reads every file and cross-references git log, then returns the classification table. The primary agent reviews the table, confirms with the user if any STALE classifications need judgment, then executes deletions inline.

Prompt template for the subagent:

```
Read every file in {specs_dir} and {plans_dir}. For each file:
1. Read the full content
2. Run `git log --oneline --all --grep="<keyword>"` for 2-3 key terms from the spec
3. Grep for key artifacts (migration files, handler files, component files) named in the spec
4. Classify as SHIPPED, SUPERSEDED, PARTIAL, UNSTARTED, or STALE

Return a table with columns: File, Classification, Evidence, Incomplete Items (if PARTIAL).
```

## Prevention

To keep specs/plans from going stale in the first place:

1. **Mark checkboxes during execution.** When a plan task is completed and committed, update the checkbox in the same commit or the next one.
2. **Delete the spec in the session that ships the last task.** The session handoff doc captures what shipped; the spec's job is done.
3. **Run this cleanup at the start of every new development phase.** It takes 5 minutes and prevents 30+ stale files from accumulating.

## Common Mistakes

- Trusting checkbox status instead of git history
- Deleting specs with partial work without extracting the remainder to backlog
- Keeping superseded specs because they have "incomplete" checkboxes for work that was redesigned
- Classifying PARTIAL files as SHIPPED because the core feature works (remaining edge cases still matter)
- Not pairing specs with plans (deleting one but leaving the other as an orphan)
