---
name: feature-create
description: Use when starting implementation of a planned feature to create an isolated git worktree, scaffold docs (feature-list row, user story, E2E spec), and transition into an execution skill. Trigger on "start feature", "create feature", "kick off", or after /write-plan completes.
---

# Feature Create

Sets up an isolated workspace for a new feature and scaffolds the required documentation before implementation begins. Bridges the gap between planning and execution.

**Announce at start:** "I'm using the feature-create skill to set up an isolated workspace for this feature."

## Invocation

The user provides a slug and optionally a plan path:

- `/feature-create <slug>` -- auto-discovers the plan
- `/feature-create <slug> <plan-path>` -- uses the explicit plan path

The slug determines:
- Branch name: `feat/<slug>`
- Worktree directory: `<project>-worktrees/<slug>/`
- Doc filenames: `US-<SLUG>.md`, `e2e/<slug>.spec.ts`

## Checklist

Work through each step in order. Stop and report if any step fails.

### Step 1: Parse inputs and validate

Extract the slug from the first argument. Convert to uppercase for doc IDs (e.g., `voice-presets` becomes `VOICE-PRESETS`). Convert to title case for display names (e.g., `voice-presets` becomes "Voice Presets").

If a plan path is provided as the second argument, verify it exists. If not provided, auto-discover:

```bash
ls -t docs/superpowers/plans/*<slug>* 2>/dev/null
```

Take the most recent match (first result from date-sorted listing). If zero matches, ask the user to provide the path. If multiple matches, show them and ask which one.

### Step 2: Check refusal conditions

All three checks must pass before proceeding:

```bash
git branch --list "feat/<slug>"
```

If the branch exists, refuse: "Branch feat/<slug> already exists. Use a different slug or delete the existing branch."

```bash
test -d ../<project>-worktrees/<slug>
```

If the directory exists, refuse: "Worktree directory already exists at <path>. Remove it or use a different slug."

Verify the plan file was resolved in Step 1. If not, refuse: "No plan file found for '<slug>'. Provide the path explicitly."

### Step 3: Create worktree

Derive the project name from the current directory basename (e.g., `my-app`). The worktree parent is `../<project>-worktrees/`.

```bash
mkdir -p ../<project>-worktrees
git worktree add ../<project>-worktrees/<slug> -b feat/<slug> main
```

Announce: "Created worktree at `../<project>-worktrees/<slug>/` on branch `feat/<slug>` from `main`."

### Step 4: Install dependencies and verify baseline

```bash
cd ../<project>-worktrees/<slug>
pnpm install
pnpm test
```

If `pnpm test` fails, stop: "Baseline tests failed in the new worktree. The worktree is preserved at `<path>` for debugging, but scaffolding will not proceed. Fix the failing tests on main first."

Do not proceed to Step 5 if tests fail.

### Step 5: Scaffold documentation

Create three files inside the worktree. All work happens in the worktree directory.

**5a. Feature-list row**

Append a row to `docs/feature-list/features.md` in the appropriate section. Find the section that best matches the feature, or add to the end if no section fits:

```markdown
| <Feature Name> | **Planned** | US-<SLUG> |
```

**5b. User story file**

Create `docs/user-stories/<slug>.md`:

```markdown
# <Feature Name> User Stories

## US-<SLUG>-001: <Primary user flow>

**As** a user
**I want to** <action from plan>
**So that** <benefit from plan>

**Acceptance criteria:**

1. <!-- Derive from the plan's task descriptions -->
2. <!-- One criterion per testable behavior -->

**E2E test:** `e2e/<slug>.spec.ts`
```

Populate the acceptance criteria by reading the plan file. Each task that produces user-visible behavior becomes a criterion.

**5c. E2E spec file**

Create `e2e/<slug>.spec.ts`:

```typescript
import { expect, test } from '@playwright/test';

test.describe('<Feature Name>', () => {
    test.skip('placeholder: implement per US-<SLUG>-001 acceptance criteria', async ({ page }) => {
        // TODO: implement after feature is built
    });
});
```

**5d. Query params check**

Ask the user: "Does this feature introduce new query parameters? (y/n)"

If yes, tell the user to add entries to `docs/query-params.md` and wait for confirmation before committing.

### Step 6: Commit scaffolding

```bash
cd ../<project>-worktrees/<slug>
git add docs/feature-list/features.md docs/user-stories/<slug>.md e2e/<slug>.spec.ts
git commit -m "chore: scaffold docs for feat/<slug>"
```

Verify the commit succeeded with `git log --oneline -1`.

### Step 7: Transition to implementation

Read the plan file. Count the total tasks and identify which are independent (no dependency on prior tasks' output).

Present the recommendation:

- If 5+ independent tasks: "This plan has N tasks (M independent). I recommend **subagent-driven-development** for parallel execution. Want to go with that, or use **executing-plans** (step-by-step)?"
- If mostly sequential or <5 independent: "This plan has N tasks, mostly sequential. I recommend **executing-plans** for step-by-step execution. Want to go with that, or use **subagent-driven-development** (parallel)?"

If the user says "not yet" or "later": "Workspace is ready at `<path>` on branch `feat/<slug>`. Pick it up anytime."

Otherwise, invoke the chosen skill with:
- Plan file path
- Worktree path (so the execution skill knows where to work)

## Common Mistakes

- Proceeding after baseline test failure. Stop means stop.
- Creating the worktree off the current branch instead of main. Always branch from main.
- Forgetting to cd into the worktree before scaffolding. All file creation happens inside the worktree.
- Hardcoding a project name instead of deriving it from the directory.

## Integration Points

- **Called after:** brainstorming, writing-plans
- **Calls:** executing-plans OR subagent-driven-development
- **Paired with:** feature-cleanup (teardown)
