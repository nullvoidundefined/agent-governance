# Session Handoff: 2026-09-20, the scope/provenance/findings rules (#96)

## 1. Last commit

- `9218cf4` on `main`: `feat(rules): scope, provenance and findings rules plus the root-uid tdd.sh unblock (#96)`. Squash-merged; presence verified by reading `main` directly.
- Squashed rather than rebase-merged: this repository allows **neither rebase nor merge commits**, only squash, so R-512's bundle exception is not exercisable here at all. Tracked as IAN-253. Four tickets therefore share one commit on `main`.
- `./sync.sh` has been re-run, so the live `~/.claude` carries R-212, R-213 and R-214.

## 2. Production state

- Three new rules are live and enforced: R-212 (scope), R-213 (provenance), R-214 (findings).
- `tdd.sh red` works in cloud containers again. The blocker was `run-fixture-shards.test.sh` using `chmod 000` on `.git/index`, which asserts nothing as uid 0.
- `claude/enforce/tests` is **101 of 101 green**. `claude/hooks/tests` has one pre-existing failure, `session-end.test.sh` (IAN-200).
- The `enforce` workflow does **not** run on PRs pushed from Claude Code sessions, and a manual dispatch is refused with 403. PR #96's fixtures run had to be dispatched by the owner by hand. IAN-222, urgent.

## 3. Session metrics

- PRs merged: 1 (#96), 5 commits across 4 tickets.
- Tickets opened: 12. Closed: 0 (IAN-193, IAN-196, IAN-199, IAN-201 are shipped but not yet closed with actuals per R-606).
- One R-517 review, 8 findings, 1 blocking; 5 fixed, 3 ticketed.

## 4. What shipped

- **R-212 (IAN-193).** `task-tier.sh --scope <glob>[,...]` records the files a request implies; `scope-widening-gate.sh` turns a Write or Edit outside them into an `ask`. `ask` not `deny`, because a deny is bypassable by re-recording a wider scope.
- **R-213 (IAN-199).** Task subjects lead with `[requested]`, `[required]` or `[self]`; `task-provenance-gate.sh` denies anything else; `task-provenance.sh summary` prints whether the original task is done and how much since was self-assigned.
- **R-214 (IAN-201).** `finding.sh` records a discovery before any decision about acting on it; `commit-message-guard.sh` denies a commit staging files outside the declared scope unless `Refs:` names another ticket. Scope reading and matching live in the shared `hooks/scope-match.sh` so the write gate and the commit gate cannot disagree.
- **IAN-196.** The fixture now corrupts the index rather than chmod-ing it, which reproduces for every uid.

## 5. Pending (by urgency)

1. **IAN-222** (URGENT): `enforce.yml` never runs on PRs pushed from Claude Code sessions, and the session token cannot dispatch it either. Every such PR has been silently skipping the required fixtures check. Fix by requiring the check under branch protection, or by having `rule-judge.yml` assert an `enforce` run exists for the head SHA.
2. **IAN-253**: R-512's bundle exception mandates rebase-merge, which this repository forbids. Either enable rebase merging or amend the rule.
3. **IAN-255, IAN-256**: convert R-506's commit-body ask and R-513's changed-constant ask into non-blocking advisories. R-506 is what made `git commit` prompt on nearly every commit this session; `Bash(git *)` was already allowed, and a hook's `ask` overrides an allow rule.
4. **IAN-224, IAN-225**: the R-214 commit gate reads the index, so `git commit -a` bypasses it and a pathspec commit false-fires; it also does not follow a `cd` or `git -C` inside the command.
5. **IAN-200, IAN-197, IAN-198, IAN-221**: the pre-existing `session-end` failure, two `protected-path-guard` defects, and the new-enforcer TDD deadlock.

## 6. Next session

1. **R-606 is outstanding for four shipped tickets.** IAN-193, IAN-196, IAN-199 and IAN-201 need closing with `completed_at`, attributable `actual_minutes`, `rework_count` and `estimate_ratio`.
2. **Do not trust `list_workflow_runs` filtered by branch.** It does not return `workflow_dispatch` runs, which led to reporting a green run as missing. Query unfiltered and read `head_branch`.
3. **Check `mergeable_state` before attempting a merge.** Three rebase attempts were spent before noticing the PR was `dirty`; `main` had moved four commits ahead.
4. **Adding a new enforcer needs the close-reopen-stub route** (IAN-221): land the manifest row, the settings registration and a no-op hook stub first, then open the slice and prove RED against the stub.
5. **Fixtures that invoke a hook must pass `cwd`.** The R-214 gate reads the payload's `cwd`; a fixture omitting it made three unrelated fixtures read the live repository's staged diff.
