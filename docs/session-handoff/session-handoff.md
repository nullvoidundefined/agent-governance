# Session Handoff: 2026-09-18, IAN-98 per-task wall time (#54, #58), merged with the R-607 close-out handoff

## 1. Last commit

- This session: `7522be1 fix(enforce): related-test mapping falls back on unknowable or unmapped changes; per-command related note`, on `fix/pr54-review-followups` (PR #58). This handoff ships in the same PR.
- `main` has `2135149 feat(enforce): cut per-task wall time ... (#54)`, which the owner merged at 16:12Z. This handoff replaces the R-607 close-out file and keeps every open item from it.

## 2. Production state

- The live `~/.claude`, `~/.cursor`, and `~/.codex` are synced from the primary checkout at `ab3596d` (#57), so they include #54. The judge hook is unregistered in the live `settings.json`, and `enforce/related-tests.sh` is installed.
- The pre-push hook in the primary checkout's `.git/hooks` was reinstalled from the new sample. It runs only the port checks, and a push measured 4 s.
- Two orphan files remain in the live tree, because `sync.sh` never deletes files and `destructive-command-guard` hard-denies removing them from a session: `~/.claude/hooks/llm-rule-judge.sh` and `~/.claude/enforce/tests/llm-rule-judge.test.sh`. They make the hook-integrity guard warn at every session start until the owner deletes them by hand.
- The `rule-judge` CI check runs on `pull_request_target` from `main`'s workflow file. It passed on #58 with the "no secret" notice, because the `ANTHROPIC_API_KEY` repository secret is not set yet.

## 3. Session metrics

- Branch and PR statistics, not live session metrics: parallel sessions merged #42, #44, #46, #49 to #53, #55 to #57 into `main` during this session.
- #54: 12 commits, including two rebases and one merge of `main`. #58: 1 commit, plus this handoff. Rework count: 3. The first Copilot review sent back 12 comments, the second sent back 7, and a pre-push fixture went red after Task 5.
- Ticket IAN-98: closed at merge of #58 with actuals. Its estimate was a 150-minute heuristic.

## 4. What shipped

- #54: the LLM rule judge moved from a push hook to `enforce/judge-diff.sh` plus `.github/workflows/rule-judge.yml`. The workflow runs on `pull_request_target`, uses a trusted checkout of the judge, and treats the PR head as data only.
- #54: pre-push runs only the port checks, and the full suites stay the required `fixtures` CI check.
- #54: the turn-end gate runs related tests for vitest, jest, pytest, and Go (`enforce/related-tests.sh`). The governance repository keeps #42's `--affected`.
- #54: R-509 no longer names pre-push. R-514 gained a trivial-tier path that skips only the Copilot review. `task-start` and `task-cleanup` document it.
- #58: the related-test mapping falls back when there is no base commit, on an unmapped non-doc file, and on a deleted file. Docs-only changes still run nothing. The "related tests only" note attaches per command. The judge fetch works in private repositories. The convention files list the five judged rules.
- Outside the repository: `personal/.claude/CLAUDE.md` exempts trivial-tier PRs from the PR document and the Copilot review, and the `claude-handles-merges` memory records the same exception.
- Design: `claude/docs/superpowers/specs/2026-09-18-task-wall-time-design.md`. Plan: `docs/slices/slice-03-task-wall-time.md`. PR docs: `docs/prs/2026-09-18-cut-task-wall-time.md` and `docs/prs/2026-09-18-pr54-review-followups.md`.

## 5. Pending, by urgency

- **Owner, 1 minute:** delete the two orphan judge files listed in section 2.
- **Owner, 1 minute:** run `gh secret set ANTHROPIC_API_KEY --repo nullvoidundefined/agent-governance`. After `rule-judge` has run green with the secret, decide whether to make it a required check.
- **`sync.sh` never deletes files removed from the repository.** A task chip, "Make sync.sh delete files removed from the repo", was offered. About 45 minutes, Standard tier.
- **Close IAN-99** (#46, here-string conversion). It is still In Progress in Linear, although `b6a2ebc` merged. About 5 minutes.
- **`global-memory/rule_fires.md` is tracked but written live, so the harness never matches its checkout.** `claude/hooks/session-end.sh` rolls the rule-fire log up into the live `~/.claude/global-memory/rule_fires.md`, and the same path is tracked in `claude/`. After the first roll-up, the live copy differs from the checkout for good. As a result, `harness-sync.sh` finds drift and runs a full `./sync.sh` at every SessionStart (measured at about 1.5 s per resume on 2026-09-18). Each sync also overwrites the live roll-up with the checkout's copy, which discards fires recorded since the last commit. A `./sync.sh` on 2026-09-18 left the live file identical to the checkout. Fix: stop tracking the file (gitignore it and seed it on first write), or exclude it from both the drift check and the copy; test first in `hooks/tests/harness-sync.test.sh`. This is the likely cause of the next item. About 45 minutes, Standard tier.
- **`hook-latency.test.sh` flakes under load.** It times the installed chain, not the checkout, so a branch cannot fix or break it. This session saw it fail and pass alternately on the same installed hooks at load averages of 62 to 228. Profile the per-edit hooks rather than widen the budget (R-204). About an hour.
- **R-607 follow-up 1: CI templates.** The four `claude/skills/repo-setup/scripts/template-ci-*.yml` files do not run `scripts/require-feature-checklist.sh`. About 30 minutes.
- **R-607 follow-up 2: the R-508 surface list.** `claude/hooks/git-workflow-guard.sh:165` lacks the Nuxt `app/pages/**/*.vue`, `server/(api|routes)/`, and FastAPI `app/routers/*.py` patterns. About 30 minutes, test first.
- **Carried three times:** 117 `| grep -q` pipelines under `claude/` read from `jq`, `head`, or `git`. Audit the ones whose output can exceed 64 KB under pipefail. About two hours.
- **Voyager 2.0:** its first `feature-create` call needs `--area`.

## 6. Next session

1. Confirm that the owner deleted the orphan files. `echo '{}' | bash ~/.claude/hooks/hook-integrity-check.sh` should print nothing.
2. Close IAN-99 through `/ticket-lifecycle close`.
3. `sync.sh` deletion: read `sync.sh` and `compute_hashes` in `claude/hooks/hook-integrity-check.sh`.
4. The R-607 follow-ups, as listed in section 5.
5. `rule_fires.md` drift (section 5): check `git ls-files claude/global-memory/rule_fires.md` and the roll-up in `claude/hooks/session-end.sh`, then rerun `hook-latency.test.sh` once it is fixed.
6. A new worktree needs `npm ci --prefix claude/enforce` before the lint-backed fixtures run.
