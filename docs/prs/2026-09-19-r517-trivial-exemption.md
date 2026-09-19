# Exempt ledger-verified trivial-tier PRs from R-517

Refs: IAN-101 (follow-up to PR #71, which introduced R-517).

## Summary

R-517, merged earlier on 2026-09-19 as `afaea90`, made `claude/hooks/git-workflow-guard.sh` deny every `gh pr merge` whose PR body lacks a non-empty `## Codex review` section, trivial PRs included. Later the same day the owner decided that trivial PRs are exempt. This PR implements that exemption in a form that cannot be claimed by typing something into the PR: the only authority is task-start's own tier ledger, `.claude/task-tier.json`, which is untracked session state written by `task-tier.sh set trivial "<reason>"` on the branch being worked.

## What changed

- `claude/hooks/git-workflow-guard.sh` asks `gh pr view` for three more fields in the same call it already makes (`headRefName`, `isCrossRepository`, and `url`), and adds `is_trivial_tier_pr`. A PR with no Codex review section now passes R-517 only when all of the following hold: the ledger exists at the top of the checkout the merge runs from; the ledger is not tracked by git; it records `tier: "trivial"`; its `branch` equals the PR's head branch; the PR's head is not a fork; and the PR's URL names the same GitHub `owner/repo` as the checkout's `origin` remote. Every existing fail-closed path (gh error, timeout, garbage output, `cd`, `GH_REPO`, unparseable merges) runs before the exemption and is unchanged, and R-512's strategy checks and R-514's ask still apply to a trivial PR.
- `claude/enforce/tests/git-workflow-guard.test.sh` gains a block that builds a real git repository with an `origin` remote and writes the ledger through task-start's own `task-tier.sh`. It covers the three required cases (trivial ledger allowed, non-trivial branch denied, forged body marker with no ledger denied) plus four spoofing routes (a ledger for another branch, a fork PR with the same branch name, a PR in a different repository, and a ledger committed to the branch) and confirms the exemption never waives `--merge`, `--rebase`, a failing gh, or a `cd`. The existing selector stub now expects the longer `--json` field list.
- `claude/CLAUDE.md` (R-517 norm line), `claude/rulebook/reference.md` (R-517 Scope and Enforcement, and the R-514 cross-reference), and `claude/enforce/manifest.json` (R-517 note) describe the exemption and its conditions.
- `claude/skills/task-start/SKILL.md` changes the trivial path: record the tier on the branch with `task-tier.sh set trivial`, skip the Codex review, and reclassify if the change grows. `claude/skills/task-cleanup/SKILL.md` drops the "never the Codex review" wording for the trivial tier.
- The `codex/` and `cursor/` ports and `claude/enforce/hook-hashes.txt` are regenerated.

## Architectural decisions

- **Chosen: the ledger is the sole authority, and a body marker is never read.** The alternative was to accept an explicit trivial marker in the PR body when the ledger corroborates it. Because the ledger has to be checked either way, the marker adds no security and only adds a parse surface, so the hook ignores it; a PR body marker with no ledger is denied by the fixture.
- **Chosen: require the ledger's `branch` to be non-empty and equal to the PR's head branch.** `pr-ticket-ref-gate.sh` accepts a ledger with an empty branch, which is fine for the ticket rule but would let a ledger written on a detached HEAD exempt any PR. The R-517 check is deliberately stricter.
- **Chosen: bind the exemption to the checkout's `origin` repository and to non-fork heads.** Without this, `gh pr merge 42 --repo other/repo` or a fork PR whose branch happens to share the ledger's branch name would be exempted by a ledger that says nothing about them.
- **Chosen: reject a tracked ledger.** The ledger is session state that task-start tells every project to gitignore. A ledger that arrives by being committed to a branch was written by whoever authored the branch, not by this session's task-start, so it does not count.
- **Rejected: requiring the current checkout to be on the PR's branch.** Merges are commonly run after switching back to `main`, and the ledger already names the branch, so this would add friction without closing a gap.

## Testing

- Red first: the new fixture block was added before the hook change. With the old hook, the trivial-ledger assertion (`ask` expected) failed at line 227 while the deny cases already held, which is what the unchanged rule should do.
- Green: `git-workflow-guard.test.sh` passes, and both full suites pass with `HOME` pointed at a temporary directory whose `.claude` symlinks to this worktree's `claude/`: `enforce/tests/run-tests.sh` prints `ALL ENFORCEMENT TESTS PASS` and `hooks/tests/run-tests.sh` prints `ALL HOOK TESTS PASS`.
- `node translate/codex.mjs --check` and `node translate/cursor.mjs --check` pass after regeneration.
- Each review fix was red first: the `git -C` redirect case failed before `c8e13ed`, and the unreadable-ledger case failed before `5540975`. Both suites were re-run green after each commit.

## Codex review

- Reviewer: Claude subagent (fable), fallback: Codex usage limit reached ("You've hit your usage limit", reset at 6:00 PM), with the filled `claude/prompts/codex-pr-review-prompt.md`.
- Round 1, range `origin/main...8cb5595`, four findings:
  - MEDIUM, the ledger is one file per checkout, so the next task's `task-tier.sh set` replaces the trivial record before the PR merges: fixed in `c8e13ed`. The deny reason now names the tier and branch the ledger holds, and task-start, task-cleanup, and the R-517 Scope say to merge the trivial PR first or re-record the tier on its branch.
  - LOW, a `git -C`/`--work-tree` push or commit in the same command redirected which checkout's ledger, origin, and PR view a merge was judged by: fixed in `c8e13ed` (the merge path reads everything from the tool call's own cwd, `MERGE_CWD`), with a fixture.
  - LOW, no fixture covered an absent `isCrossRepository`: fixed in `c8e13ed` (fixture asserts deny).
  - LOW, the Scope said the exemption was "proven", which overstated what the hook can check: fixed in `c8e13ed` by narrowing the wording. The suggested alternative (deny when the ledger has `reclassifiedFrom`) is declined because `task-tier.sh` writes `reclassifiedFrom` whenever any earlier ledger differs, including a leftover from another branch, so that check would deny honest trivial PRs.
- Round 2, range `8cb5595...c8e13ed`: all four dispositions verified; one new LOW, a non-JSON ledger was reported as "no ledger": fixed in `5540975`, with a fixture.
- Round 3, range `c8e13ed...5540975`: no findings. It checked the three ledger states in the deny reason, the fail-closed paths, hashes, ports, and bash 3.2 portability.
- Range note: the branch was then rebased onto `98ece73` (R-518, PR #73). Conflicts fell only on the adjacent R-518 norm line and on generated files (ports, hook hashes), which were regenerated; none of this branch's hook or test lines changed, and both suites pass on the rebased head, so the review was not re-run. Commit IDs in this document are the rebased ones.

## Reflection

The residual trust in this design is local: anyone who can run `task-tier.sh set trivial` in the checkout that performs the merge can exempt that branch. That is the same actor the harness already trusts to classify tiers, so the exemption moves the decision to where the classification is recorded rather than to where anyone can type. My first draft copied `pr-ticket-ref-gate.sh`'s `is_trivial_tier`, which accepts an empty ledger branch and checks only the checked-out branch; reading it against the PR's own head branch showed that it would have exempted the wrong PR in the `--repo` and fork cases, which is why the check reads the head branch, fork flag, and URL from `gh` instead.

Time since implementation: 29 minutes, from `8cb5595` (16:25:43 +07:00) to this document (16:54 +07:00), covering `c8e13ed`, `5540975`, and three review rounds.
