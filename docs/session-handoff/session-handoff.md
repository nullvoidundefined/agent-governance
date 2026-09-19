# Session Handoff: 2026-09-19, R-517 trivial exemption (#77) and ticket at task start (#78)

## 1. Last commit

- This session's last code commit: `2ec6662 fix(hooks): admit only an allowlist of git subcommands to the untracking exemption`, on `feat/ticket-at-task-start` (PR #78, IAN-149). This handoff and the PR document ship in the same PR, which squash-merges onto `main`.
- Earlier this session: PR #77 merged as `5ff7b39` (R-517 trivial exemption, IAN-147).

## 2. Production state

- The live `~/.claude` is synced from the primary checkout, which was still at `1aca2e6` when this session started, before #71, #73, #74, #75, #76, #77 and #78. None of the R-517, R-518, or R-605-at-start hooks are live until the primary checkout is fast-forwarded and `./sync.sh` runs (pending item 1).
- Carried from the 2026-09-18 handoff and still observed at this session's start: the hook-integrity guard warned about `hooks/llm-rule-judge.sh` and `enforce/tests/llm-rule-judge.test.sh` in the live tree (orphan files only the owner can delete by hand).
- Codex is over its usage limit until 2026-09-21 02:26 local; every review this session ran on the fallback reviewer (a Claude subagent on fable).

## 3. Session metrics

- `session-metrics.sh` sees only this worktree's last commit (it reported 1 commit, 6 files), so the numbers below come from git.
- PR #77: 5 branch commits, 18 files; squash `5ff7b39`.
- PR #78: 14 branch commits plus this handoff, 32 files, +1608/-76; 18 files touched by two or more commits (the hook, its fixture, hashes, ports, reference.md).
- Velocity flag: HIGH rework. PR #78 went through 12 fallback-review rounds and 3 Copilot rounds; 10 of them sent work back.

## 4. What shipped

- **R-517 trivial exemption (#77, IAN-147, `5ff7b39`).** `git-workflow-guard.sh` lets a PR merge without a `## Codex review` section only when the untracked `.claude/task-tier.json` in the merging checkout records the trivial tier for the PR's own head branch, the PR is in the checkout's origin repo, and its head is not a fork. A marker in the PR body is never read.
- **Ticket at task start (#78, IAN-149).** `task-tier.sh set <tier> "<reason>" --ticket <KEY>` records the key and refuses a tier above trivial without one while a tracker is configured. The new `ticket-at-start-gate.sh` denies the first Write/Edit, and every `git commit`, until the ledger names the branch and carries the key (or the trivial tier). Commits are read with the shared quote-aware scan: cd/pushd, wrappers, keywords, branch switches, git's -C/--work-tree/--git-dir, heredocs to shells, and an untracking-recovery path for a ledger committed by mistake. Threat model stated: a forgotten ticket, not deliberate hiding.
- **Retroactive tickets:** IAN-147 (#77) and IAN-148 (#71), both of which had shipped under the unrelated IAN-101, with correction comments on the PRs.

## 5. Pending (by urgency)

1. **Sync the live harness** (5 minutes): in the primary checkout run `git pull --ff-only && ./sync.sh`. After it, every session in a repo on a branch needs `task-tier.sh set ... --ticket <KEY>` (or `set trivial`) before its first edit; a session already mid-task is denied once and told the exact command.
2. **IAN-153** (Backlog): the deliberately hidden commit shapes answered as out of scope on #78 (coproc, env -S, env GIT_DIR=, popd, "$(git commit)" in quotes, an inherited $SCRIPT, Codex `sed -i` edits, and a staging command wrapped in `bash -c` during the untracking recovery). About an hour once the tokenizer chip below lands.
3. **Task chip: keep `$(...)` in one word in `shell-command-tokens.sh`** (about an hour): closes `$(which git) commit` here and `$(which gh) pr merge` in git-workflow-guard.
4. **Task chip (owner started it in another session): commit-message-guard reads heredoc and argument text as a commit.** It blocked a `gh api ... -f body=` reply containing "git commit" this session; the workaround was `-F body=@file`.
5. Carried, unverified this session: the orphan `llm-rule-judge` files in the live tree, and the `ANTHROPIC_API_KEY` repository secret for the `rule-judge` CI check.

## 6. Next session

1. Run pending item 1 and confirm the session-start hook-integrity line is clean.
2. Pick up IAN-153 only after the tokenizer chip merges; read `claude/hooks/ticket-at-start-gate.sh` (header, then `inspect_commit_words`) and `docs/prs/2026-09-19-ticket-at-task-start.md` first.
3. Load the Linear tools by the exact names in `~/.claude/TICKET-TRACKER.json` (a keyword search for "linear" finds nothing), and check any reused `Refs:` key with `get_issue` before trusting it.
