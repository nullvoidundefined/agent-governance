---
name: feature-create
description: Use when starting implementation of a feature that already has an approved plan, before any code is written. Triggers on "start feature", "create feature", "kick off", or immediately after a plan is finished.
argument-hint: <slug> --area <area> [plan-path]
disable-model-invocation: true
---

# Feature Create

Sets up an isolated workspace for a new feature and scaffolds the required documentation before implementation begins. Bridges the gap between planning and execution.

**Stack assumption:** the scaffold script detects the install and test commands from the lockfile and `package.json` (pnpm, npm, or yarn) and seeds `docs/feature-list/features.md` and `docs/user-stories/README.md` from the harness templates in `~/.claude/prompts/` when the project does not have them yet (R-607). Override the commands with `FEATURE_CREATE_INSTALL_CMD` and `FEATURE_CREATE_TEST_CMD` (`skip` omits one) for any other stack.

**Announce at start:** "I'm using the feature-create skill to set up an isolated workspace for this feature."

## Invocation

The user provides a slug and optionally a plan path:

- `/feature-create <slug> --area <area>` -- auto-discovers the plan
- `/feature-create <slug> --area <area> <plan-path>` -- uses the explicit plan path

The area is the product area the feature belongs to (R-607): one `## ` section of `docs/feature-list/features.md` and one story file `docs/user-stories/<area>.md`. Choose it from the existing sections, slugified (`## Authentication & Account` is `authentication-account`); run the script without `--area` to have it list the known areas. Ask the user when the feature fits no existing area rather than inventing a near-duplicate one.

The slug determines:
- Branch name: `feat/<slug>`
- Worktree directory: `<project>-worktrees/<slug>/`, a sibling of the project (the same location `hooks/parallel-session-check.sh` points at; Claude Code's own worktree tool uses `.claude/worktrees/` inside the repo, and a project uses one or the other, never both)
- Story: the next free `US-<AREA>-NNN` appended to `docs/user-stories/<area>.md`; the E2E path `e2e/<slug>.spec.ts` is recorded, not created

## Step 1: Resolve the ticket, then run the scaffold script

Resolve the ticket key first, from the plan's or spec's `**Ticket:**` line. If neither carries one, open the ticket now through `/ticket-lifecycle` before creating the worktree (R-605); a feature whose ticket is opened after the fact has no usable `started_at`. Then run the script, which does everything mechanical in this skill with an exit code per stop:

```bash
bash ~/.claude/skills/feature-create/scripts/scaffold.sh <slug> --area <area> [plan-path] --ticket <ticket-key>
```

In order, it: validates the slug; resolves the plan (explicit path, else the newest `docs/superpowers/plans/*<slug>*`); refuses when `feat/<slug>` or the worktree directory already exists; resolves the default branch from `origin/HEAD` (else `main`, else `master`), fetches it, and creates the worktree from it; installs and runs the baseline suite inside the worktree; seeds any absent product doc from the templates, appends the story skeleton to the area file (a new area file is created from the template and indexed in the README), inserts a **Planned** feature row carrying the story id into the area's section of the features list, and rewrites its `Last updated:` line; commits them as `chore(docs): scaffold docs for feat/<slug>` with a `Refs: <ticket-key>` trailer (an accepted trailer in `hooks/commit-message-guard.sh`, carried on every commit for this feature); and prints a summary ending with whether the plan mentions query parameters.

Report each stop verbatim to the user; do not work around it:

| Exit | Meaning | What to say |
|---|---|---|
| 2 | Bad slug, missing or malformed `--area`, or usage | Ask for a lowercase hyphenated slug, or pick the area from the list the script printed |
| 3 | No plan matches the slug | Ask for the plan path |
| 4 | Several plans match (candidates printed) | Show them and ask which one |
| 5 | Branch `feat/<slug>` exists | "Use a different slug or delete the existing branch." |
| 6 | Worktree directory exists | "Remove it or use a different slug." |
| 7 | Baseline tests failed | "The worktree is preserved at `<path>` for debugging, but scaffolding will not proceed. Fix the failing tests on `<base>` first." Stop means stop. |
| 8 | A git or install step failed | Paste the script's last line |

## Step 2: Fill the user story

The script leaves the new story at the end of `docs/user-stories/<area>.md` with its id, the E2E path line, the ticket line, and placeholder "As / I want to / So that" lines and acceptance-criteria checklist. Read the plan file and replace the placeholders: each task that produces user-visible behavior becomes one unchecked criterion (`- [ ]`), one per testable behavior; `task-cleanup` ticks them as they ship. Replace the story title placeholder (the feature title) with the user flow it describes, and add notes to the feature row when the plan gives any. Amend nothing; commit the filled story on the feature branch as `docs(<slug>): acceptance criteria for US-<AREA>-NNN` with the `Refs:` trailer.

**E2E test.** Do not scaffold a skipped placeholder (R-401 item 9: a test that cannot fail protects nothing, and PROTOCOL Layer 5 bans `test.skip` outright). The first user story's E2E test is written as a RED slice when implementation starts (R-412, tdd-gated-dispatch). The `**E2E test:**` line the script wrote records the intended path so it is discoverable; the file itself does not exist until it fails for a real reason.

**Query params.** Only when the script's summary says `query params: yes`, ask the user: "The plan mentions query parameters. Add the entries to `docs/query-params.md` now?" and wait for confirmation before committing. When it says `no`, do not ask.

## Step 3: Transition to implementation

Read the plan file. Count the total tasks and identify which are independent (no dependency on prior tasks' output).

Present the recommendation:

- If 5+ independent tasks: "This plan has N tasks (M independent). I recommend **subagent-driven-development** for parallel execution. Want to go with that, or use **executing-plans** (step-by-step)?"
- If mostly sequential or <5 independent: "This plan has N tasks, mostly sequential. I recommend **executing-plans** for step-by-step execution. Want to go with that, or use **subagent-driven-development** (parallel)?"

If the user says "not yet" or "later": "Workspace is ready at `<path>` on branch `feat/<slug>`. Pick it up anytime." Leave the ticket where it is; the work has not started.

Otherwise, advance the ticket through `/ticket-lifecycle` to `in-progress` and write `branch` and `plan_link` onto it, recording the workspace as the branch name and never as a local filesystem path (R-106). Then invoke the chosen skill with:
- Plan file path
- Worktree path (so the execution skill knows where to work)
- Ticket key (so every commit carries the `Refs:` trailer)

## Common Mistakes

- Proceeding after exit 7. The worktree is for debugging the baseline, not for building on a red suite.
- Re-running the shell steps by hand instead of the script, and branching from a stale local `main` or from the current branch: the script fetches the default branch and branches from `origin/<base>`.
- Leaving the acceptance criteria placeholder in the user story.
- Asking the query-params question when the summary said `no`.
- Creating the worktree before the ticket exists, which leaves `started_at` later than the work it is supposed to bound.
- Writing the worktree's absolute path onto the ticket. The branch name is the join key; the path is local and unpublishable (R-106).

## Integration Points

- **Called after:** brainstorming, writing-plans
- **Calls:** executing-plans OR subagent-driven-development, ticket-lifecycle (`advance` to `in-progress`)
- **Paired with:** task-cleanup (teardown, merge decision, worktree removal)
