# Subagent branch setup snippet

**Purpose:** Reusable block to paste into any subagent dispatch prompt whose work involves git. Enforces R-702 in `~/.claude/CLAUDE.md` (lock the worktree before any `git add` or `git commit`).

**How to use:** When writing a dispatch prompt for a subagent that will run git commands, paste the block below near the top of the prompt, substituting `<ABSOLUTE_WORKTREE_PATH>` with the actual path and `<EXPECTED_BRANCH>` with the branch name the work should land on. Do not change the structure of the block; the branch-verification chain is what prevents cwd drift between sequential Bash calls.

---

## CRITICAL BRANCH SETUP (always read first)

Before you run any `git add` or `git commit`, you MUST do the following. These steps are chained in a single shell invocation with `&&` so that cwd cannot drift between calls.

1. Your absolute worktree path is `<ABSOLUTE_WORKTREE_PATH>`. Every git command runs inside that path.
2. Your expected branch is `<EXPECTED_BRANCH>`. Before any stage or commit, confirm you are on it.
3. Chain the verification and any commit into a single `Bash` call with `&&`. Do NOT split the verification and the commit across sequential `Bash` calls; the cwd can reset between calls and the commit will land on the wrong branch.

**Template for your first git operation:**

```bash
cd <ABSOLUTE_WORKTREE_PATH> && \
  BRANCH=$(git branch --show-current) && \
  if [ "$BRANCH" != "<EXPECTED_BRANCH>" ]; then \
    echo "ERROR: expected branch <EXPECTED_BRANCH> but got $BRANCH; aborting" >&2; \
    exit 1; \
  fi && \
  git add <files> && \
  git commit -m "<subject>"
```

**Template for subsequent operations in the same dispatch:**

```bash
cd <ABSOLUTE_WORKTREE_PATH> && \
  [ "$(git branch --show-current)" = "<EXPECTED_BRANCH>" ] && \
  <your git command>
```

**Why this matters.** Subagent shell cwd can reset unexpectedly between sequential `Bash` calls. A "cd into worktree" in one call followed by a "git commit" in the next can silently land the commit on the wrong branch (typically `main`). Recovery means cherry-picking back onto the feature branch and reverting on main, which is expensive and easy to botch.

**Do NOT:**

- Run `cd <path>` in one Bash call and `git commit` in a later one.
- Skip the branch verification because "you already cd'd earlier."
- Use relative paths inside the chain (they resolve against whatever cwd the shell started in).
- Attempt to fix a wrong-branch commit by amending; use the cherry-pick-and-revert path instead (see R-702 for context).

**Do:**

- Keep the verification and the commit in a single `&&` chain.
- Absolute path every `cd`.
- If the branch check fails, abort the entire chain and surface the failure to the dispatching session rather than trying to recover unilaterally.
