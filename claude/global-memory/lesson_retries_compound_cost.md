---
name: Retries after mistakes compound the token cost of the original task
description: Every retry after a diagnosable error (wrong cwd, wrong worktree, wrong branch, broken tool call) spends diagnosis turns, fix turns, and re-apply turns on top of the original work
type: feedback
---

**Rule:** Treat each retry as a multiplier on the cost of the task, not
a free do-over. Before re-attempting any failed action, stop and ask
what the root cause was and whether the new attempt will hit the same
class of failure.

**Why:** Observed pattern on 2026-04-07 during a billing-doc edit.
Edits were applied to the wrong worktree's copy of the file because
the Edit tool's path resolution diverged from the shell cwd. Recovering
cost three extra rounds: a confused `git diff` interpretation, a
second Read of the correct file, and a full re-apply of four edits to
the correct path. The original task was a single one-cell table
update. The retry path spent roughly five to ten times the tokens of
the clean path.

**Common compounders:**

- Running a command from the wrong directory, then running the same
  command again without fixing the directory assumption.
- Applying an Edit that fails because the `old_string` is not unique,
  then widening the context and retrying without first checking
  whether the file is the one you actually intended.
- Dispatching a subagent whose shell cwd resets between calls, then
  re-dispatching with the same prompt instead of chaining the cwd
  check and the action into a single Bash call.
- Re-running a flaky test without diagnosing the flake; if the flake
  has a pattern, the rerun will flake again and you will have paid
  twice.

**How to apply:**

- Always verify the target of destructive or stateful operations
  (cwd, branch, file path, database, env) with a quick read-only
  check before the operation, not after.
- If a tool call fails, read the error carefully before retrying. A
  literal rerun without a change almost never succeeds; if it does,
  it was a flake and the flake is a bug worth recording.
- On multi-step workflows (git commit, push, PR, merge), chain the
  verification and the action in a single tool call where possible.
  See the "Subagent dispatch prompts must specify the worktree path
  explicitly" rule in `~/.claude/CLAUDE.md` for the canonical
  pattern.
- When a retry is unavoidable, make the retry cheaper than the
  original attempt (narrower scope, targeted Grep instead of
  whole-file Read, smaller diff) so the compounding does not get
  out of hand.
