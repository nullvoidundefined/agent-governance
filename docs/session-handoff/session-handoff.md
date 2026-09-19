# Session Handoff: 2026-09-19, ECC audit, hook-bypass guard (#83), Copilot removed (#86)

## 1. Last commit

- Last commit on `main` from this session: `1f14fbe` (chore(rules): remove Copilot review; CI and the R-517 review are the checks before merge, #86). This handoff ships in its own trivial PR after it.
- Earlier this session: #76 as `6895b25` (ECC audit and maintenance-tax answer), #84 as `2602481` (fixture HOME isolation), #83 as `3bcd846` (hook-bypass guard).

## 2. Production state

- The primary checkout is on `main` at `1f14fbe`. `./sync.sh` has not run since #83, #84, and #86 merged, so the live `~/.claude` still has the old guard, the old Copilot rules, and the old fixtures until the owner runs `git pull --ff-only && ./sync.sh`.
- The repository ruleset `copilot-review-main-and-slice` (id 23605283) is `disabled`, not deleted. No PR gets an automatic Copilot review any more.
- Copilot spend for September is $21.55, all billed after the allowance ran out on the 18th. Only the owner can stop it at the source: turn off Copilot code review in GitHub settings, or set a $0 Copilot budget with "stop usage". A $2.23 Copilot Cloud Agent charge on the 18th is unexplained.
- Codex is over quota until 2026-09-21; every review and test author this session ran on the Claude fallback.

## 3. Session metrics

- PRs merged: 4 (#76, #84, #83, #86). #83 alone carried 15 TDD slices, 419 fixture cases, and about 40 commits before its squash.
- Rework: #83 went back 4 times (two adversarial review rounds with 43 findings, two Copilot rounds with 3 findings). #76 had 16 review corrections before merge.
- Velocity flag: over. IAN-141 closed at 519 minutes against a 120-minute estimate (ratio 4.3); IAN-163 at 17 against 45 (0.38).

## 4. What shipped

- **ECC audit (#76).** Do not install ECC's hooks: fail-open error paths, a hook that executes a repository's own MCP config, and secret capture. 24 features ranked for porting; the P1 ports are IAN-140 and IAN-142 to IAN-144. The maintenance-tax report answers "is this bureaucracy" with numbers.
- **Hook-bypass guard (#83, IAN-141).** `destructive-command-guard.sh` denies the common ways the agent can skip git hooks, on a bash-style parse from the new `hooks/shell-command-segments.py`. It covers skip flags, hook-manager variables, `core.hooksPath` and config channels, aliases, hook-file tampering, and wrappers. It fails closed when the parser is missing and decides a 1500-argument command in under 300ms. Known gaps are listed in `docs/prs/2026-09-19-hook-bypass-deny.md` and IAN-155.
- **Fixture isolation (#84).** `git-workflow-guard` and `task-cleanup-scan` run `task-tier.sh` under a tracker-free `HOME`, so they pass on a machine with a tracker configured. This closes the previous handoff's pending item 2.
- **Copilot removed (#86, IAN-163).** R-514, R-517, the task-cleanup and build-by-slice skills, and the review prompt never request Copilot. CI and the R-517 review are the checks before merge. The personal `CLAUDE.md` and the merge memory match.

## 5. Pending (by urgency)

1. **Sync** (2 minutes): `git pull --ff-only && ./sync.sh` in the primary checkout, so the live harness gets #83, #84, and #86.
2. **Stop Copilot billing at GitHub** (owner, 5 minutes): see section 2.
3. **IAN-157** (about 3 hours): three guards still match substrings instead of parsing. `protected-path-guard`, `push-ruff-gate`, and `ticket-at-start-gate` each denied a command this session because quoted text mentioned a path or `git commit`. Consolidate on one parser; #79 and #80 added a second quote-aware scan.
4. **IAN-156** (about 90 minutes): the R-509 stop gate blocks a test-author subagent on its intended RED; every one of 15 test-author runs hit it.
5. **IAN-140, IAN-142 to IAN-144**: the remaining ECC P1 ports (about 9 hours together).

## 6. Next session

1. Run pending item 1, then check `~/.claude/hooks/shell-command-segments.py` exists: the guard denies every git command when the parser is missing.
2. Never pipe `tdd.sh red`, `green`, or `validate` through `tail` in an `&&` chain: it hides the exit status. Twice this session a commit landed past a refused step. Capture the status first (`cmd > log; rc=$?`).
3. Classify any guard that parses untrusted shell text as Complex, and design its parser before its rules.
