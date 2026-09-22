# Session Handoff: 2026-09-20 to 09-23, the harness evaluation and the IAN-268 instrumentation program

One session. A falsifiable evaluation of the harness, then a spec, a plan and 16 tickets to close what it found.

## 1. Last commit

- `main` is at `021c8fa`, `fix(hooks): replace mapfile so the scope guards run under bash 3.2 (#105)`. It merged mid-session and nothing has moved main since.
- Open from this session: **#109** (`feat/harness-instrumentation`, the spec, draft), **#110** (`fix/ticket-gate-path-walk`, the fifth path-walk hook, draft).
- **#104 is owned by another session.** It was force-pushed (rebased) while this session held it. Do not push to `fix/hook-latency-flake` without checking `git log origin/fix/hook-latency-flake` first.
- Also open: `#94`, `#97`, `#100`, `#101` from earlier sessions, unchanged.

## 2. Production state

- **Linear is at its free issue limit.** The seventeenth ticket was refused. Facet 4's content is a comment on IAN-268 and needs promoting to its own ticket once there is room. Every new ticket will fail until then.
- **`hook-latency.test.sh` measures the installed `~/.claude/hooks`, deliberately, not the checkout.** It therefore stays red on any branch until `./sync.sh` runs. That is why it failed all session with the fix sitting in the checkout. `./sync.sh` from `main` is still pending and is the first thing to do.
- **#104 fails its own new fixture on macOS, at its own head, before any merge.** `hook-path-walk-budget.test.sh` reports 9 spawns of growth against a budget of 6. CI is green because `enforce.yml` runs only on `ubuntu-latest`. This is the **second instance in one day** of ubuntu-only CI hiding a defect on the machine the work happens on; IAN-267's `mapfile` was the first. A bash 3.2 or macOS CI leg is now the obvious missing coverage and has no ticket.
- The offending hook was `ticket-at-start-gate.sh`, a fifth hook #104 never touched. #110 fixes it and drops chain growth from 9 to 0.
- **Three guard false positives hit in one hour**, all one root cause (guards match shell text rather than parsing it): `no-em-dash` denied a `grep` for the em dash (IAN-270); `protected-path-guard` read `$S/pre-head.txt` as a production path because it cannot expand a variable; the same guard read the `>` inside the quoted regex `'^[<>]'` as a redirection to a file named `]`. IAN-157's parser would close all three.
- **A Bash call containing `git commit` is denied whole** by the ticket gate before any part of it runs, so a compound command that sets the ledger and then commits never sets the ledger. Split them.
- Codex quota reset at 02:26 and it is available again; it was exhausted for the whole 09-20 leg.

## 3. Session metrics

- Commits: 3 (one spec, one spec amendment, one hook fix). Two draft PRs.
- Tickets opened: 16. Refused by the issue limit: 1.
- **Waste: about 40 minutes**, IAN-271, a full diagnose-branch-Codex-test-author cycle duplicating IAN-267 which had already merged as #105. Root cause in section 6.
- R-906: no closed ticket this session, so no recalibration. Complex/llm still has only n=2 attributable samples (30 and 17 minutes), both narrower than anything estimated here.

## 4. What shipped

- **The evaluation.** 136 of 7,297 recorded rule fires (1.9%) happened in a real product repository; 743 came from `tmp.*` fixture scratch directories; R-517 logged 2,459 fires across 73 distinct minutes. 173 harness commits since 2026-08-21 against roughly 81 across the three active product repositories.
- **IAN-268 spec**, `claude/docs/superpowers/specs/2026-09-21-harness-instrumentation-design.md`, 26 acceptance criteria, committed on #109.
- **The plan**, `claude/docs/superpowers/plans/2026-09-23-harness-instrumentation.md`, 13 tasks, gitignored and local only.
- **#110**, the fifth path-walk hook, with a PW-1 assertion that names the file so the next regression costs a grep.

## 5. Pending (by urgency)

1. **Sync** (2 min): `git pull --ff-only && ./sync.sh` from `main` in the primary checkout. Until it runs, `hook-latency` is red everywhere and the live tree lacks #105.
2. **#110** (15 min): review and merge. Self-contained, one hook plus its test.
3. **#104** (owned elsewhere): it still fails its own fixture on macOS without #110's hook. Coordinate rather than push.
4. **IAN-275** (50 min): fixture telemetry isolation. **First task of the program**; every other task's fixtures keep polluting the log until it lands.
5. **IAN-281** (50 min): the SessionStart handoff becomes a pointer. This is the fix for the failure that cost this session 40 minutes; worth doing early for its own sake.
6. **IAN-276, IAN-277** (50 min each): ledger fields, then the rollup that produces the program's baseline table. IAN-277 step 5 pastes that table onto IAN-268.
7. **IAN-288** (60 min): the `claude plugin eval` path-target spike. Run it right after IAN-277; Phase 2 is deliberately unplanned until it answers.
8. **IAN-279** (120 min): the decision log. Highest risk: step 1 is a spike on whether the transcript exposes the permission decision, and the privacy fixture asserting no credential substring reaches the log is not optional.
9. **IAN-278, IAN-280** then the Phase 1 cuts: **IAN-282** (30), **IAN-283**, **IAN-284**, **IAN-285**, **IAN-286**, **IAN-287** (50 each), independent of each other and of Phase 0.
10. **IAN-273** (50 min): `tdd.sh red` and `doctor.sh` exit 0 while refusing. Bit this session twice.
11. **IAN-269** (high): a Bash heredoc write bypasses five `Write|Edit`-only gates. Answers IAN-181's open question.
12. **Blocked on data:** IAN-289 (adversaries), IAN-290 (gates), and Facet 4 on IAN-268's comment. Each carries its decision rule written before the data; do not act on them from the evaluation's judgement alone.
13. **No ticket yet:** a macOS or bash 3.2 CI leg; the Linear issue limit; `physical_path` and `nearest_existing_directory` are now duplicated across five hooks and want a shared helper (R-308).

## 6. Next session

1. **Read this file in full before anything else.** The 09-20 leg did not: the SessionStart block exceeded the inline limit, was saved to a file with a 2 KB preview, and the preview was treated as the content. Everything in that leg's 40 wasted minutes was already written here. R-001's "read only if the block is absent" does not cover a truncated block; IAN-281 fixes the mechanism.
2. **`git log HEAD..origin/main` after every fetch, not just `gh pr list`.** A squash-merge deletes the branch and closes the PR, so a branch-name grep and an open-PR list both come back clean. That is exactly how #105 was missed.
3. **Re-check `main` after any long step** (a subagent dispatch, a background Codex run, a full suite). It moved twice inside such gaps this session, and a branch was force-pushed under an active edit.
4. `hook-integrity-check.sh --update` writes to `$HOME/.claude` unless `CLAUDE_INTEGRITY_ROOT=<checkout>/claude` is set.
5. Prefer Write and Edit over a Bash heredoc: five gates run on `Write|Edit` only (IAN-269), and `protected-path-guard` misreads shell text.
6. Never put `git commit` in a compound Bash call with setup it depends on; the guard denies the whole call.
7. Read the printed verdict, never the exit status, for `tdd.sh`, `doctor.sh` and `codex exec`. Never pipe a gate through `tail` and read `$?`; that is tail's status. This session did it again.
8. When a fixture passes in CI and fails locally, suspect the platform before suspecting the branch. Twice today the answer was ubuntu-versus-macOS.
