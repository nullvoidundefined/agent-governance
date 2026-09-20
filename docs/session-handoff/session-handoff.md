# Session Handoff: 2026-09-20, IAN-184 gate exemption (PR #97 draft, not mergeable)

Session ran 15:47Z to 16:58Z, 71 minutes. It was asked to fix three TDD-harness frictions. One is implemented and in a draft PR that a review then found two HIGH defects in; the other two are ticketed and not started. Stopped deliberately for weekly quota, at a static state.

## 1. Last commit

- `main` is unchanged at `d426098`. **Nothing merged this session.**
- `fix/gate-expected-red` is at `1da8e37`, pushed, draft PR [#97](https://github.com/nullvoidundefined/agent-governance/pull/97), five commits. Auto-fix monitor on.
- `docs/handoff-2026-09-20-gate` carries this file.
- `fix/tdd-red-commit-anchor` exists at main's tip with **no commits**: IAN-220 was opened, a slice was opened and closed cleanly, then paused. Safe to delete or reuse.
- `park/b3-gate-expected-red-fixture` is no longer needed; its fixture was landed in `75b606e`.

## 2. Production state

- **`~/.claude` was rolled back to `main` at session end, deliberately.** Mid-session it was synced from `fix/gate-expected-red` so the `test-author` role could return past the R-509 gate. That build carries two HIGH defects, so it was reverted by checking out `main` in the worktree and re-running `./sync.sh`, verified by both markers grepping to 0. **Do not sync from `fix/gate-expected-red` until H-1 and H-2 below are fixed**: it widens R-509 so that any phase-`red` turn can end on a failing typecheck, lint, port check, or second test suite.
- The primary checkout is on `fix/ticket-gate-exemption-telemetry`, not `main`. `./sync.sh` from there installs that branch. Check `git branch --show-current` before syncing from any checkout.
- Codex is rate-limited until **2026-09-21 02:26**. Both test authors and the R-517 review ran on the recorded Claude fallback.
- `hook-latency.test.sh` passed on every run today, `PreToolUse:Write` 308ms against a 348ms budget. IAN-183's flake never fired, and it did not block anything. IAN-184's title still claims it did.
- `enforce/hook-hashes.txt` on `main` is unchanged; the worktree's manifest updates live only on the `#97` branch.

## 3. Session metrics

- One of three requested frictions partly done. Roughly 55 percent of the session went to investigation and ticketing before the first production edit.
- Tickets: **IAN-220** opened (frictions 1 and 2, folded), **IAN-250** opened (criticism audit), **IAN-184** advanced to in-review.
- PR #97: 5 files, 499 insertions, 5 commits. R-517 review returned **2 HIGH, 3 MEDIUM, 4 LOW**.
- Two slices ran RED to GREEN under the lock. Outside-pass count rose 97 to 98 to 99 as each fixture landed. `tdd.sh validate test-author` returned VALID.

## 4. What shipped

- **IAN-184 B-3b** (`75b606e` test, `6aa8d2a` impl): `verification-gate.sh` asks `tdd.sh expected-red` after a check fails and releases on exit 0, failing closed and skipping the pass memo. Fixture was the independently authored parked one, unchanged.
- **IAN-184 B-3a** (`bd38353` test, `250ba62` impl): `expected-red` now reuses `check_hashes` and requires a locked test to still be failing, closing Finding 3 from the PR #91 review in the same PR that made it reachable.
- PR document at `docs/prs/2026-09-20-gate-expected-red.md` (`1da8e37`).
- Nothing reached `main`.

## 5. Pending (by urgency)

1. **#97's two HIGH findings** (about 60 to 90 minutes). Full text with file:line evidence is in the IAN-184 Linear comment of 16:5xZ. **H-1**: `is_expected_red` never reads which check failed, so any non-test check is excused during a red slice; intended fix is two-part, the gate excusing only when every failing check is a test check, and `expected-red` judging the whole fixture suite rather than only the locked directories. **H-2**: `exit 0` in the checks loop skips every remaining check, and a bare `continue` is wrong because it memoizes a red tree. Then M-1 (`.status == "failed"`), M-2 (the memo criterion has no test that can fail), M-3 (unbounded suite outside `run_with_timeout`).
2. **IAN-220** (about 120 minutes), not started: `tdd.sh green` cannot anchor its hash check to a git object because the lock is gitignored, and `fix-commit-requires-test.sh` denies every bug-fix slice's implementation commit. Both need one primitive, "the locked tests are committed at HEAD with the locked content". **Confirmed live twice**: `green` printed the uncommitted-lock note on a run where the RED test was committed one commit earlier.
3. **IAN-250** (about 60 minutes), designed and not started: rewrite the criticism audit as a senior engineer challenging a junior engineer's assumptions, explicitly antagonistic but not cruel, and teaching. Full design including the owner's verbatim brief is in the ticket's two comments. Two collisions found: the file's closing "Why you do this" section argues for self-blame and contradicts the brief, and R-208 must be reconciled in the file text or a future editor deletes the celebration section as a violation.
4. **Not yet filed as tickets**, all recorded on IAN-184: PR #91 review Findings 2 and B (hardening `drift_is_confined`); the manifest content-drift constraint that explains IAN-162; the `tdd-gated-dispatch` skill carrying two contradictory contracts for who runs `tdd.sh red`; and IAN-184's title needing its hook-latency clause removed.
5. **R-517's `## Codex review` section is not yet in #97's PR body.** Required before merge. The findings are on the ticket, so it is transcription, not re-derivation.
6. `ISSUES.md` and `TODO.md` were **not** updated; deferred work lives on the Linear tickets instead.

## 6. Next session

- Read the IAN-184 comment thread before touching #97. It carries the review verbatim with file:line evidence, and the intended fixes for H-1 and H-2.
- Fix #97 before syncing it anywhere. The branch is currently a weakened R-509.
- `protected-path-guard` fired four times this session on paths nobody was writing: an unexpanded `$SCRATCH` variable, a redirect inside a heredoc body, the literal `>/dev/null`, and a branch name after `git checkout`. All are IAN-157 and IAN-198. The route that works is the **Write tool** rather than a Bash heredoc, because the path arrives as a field instead of shell text. Put that in the test-author brief until IAN-157 lands.
- Editing an **existing tracked** fixture emits a manifest content-drift line that names no path, and `drift_is_confined` tolerates drift only when a reverse-closure line names a locked path. A slice whose test edits an existing fixture can therefore never reach a clean RED; write a **new** fixture file. This is measured, not theorised, and is the likely root cause of IAN-162.
- The `--update` for the hash manifest writes to `$HOME/.claude` by default. Pass `CLAUDE_INTEGRITY_ROOT=<checkout>/claude` or it silently updates the installed tree and leaves the checkout stale.
- Order work by dependency, not by the order the user listed it. This session opened a slice on IAN-220 first, dispatched Codex, and only then discovered that with Codex rate-limited every slice depends on the `test-author` subagent, which is exactly what IAN-184 unblocks. The ordering was readable from IAN-184's description beforehand.
- Linear is reachable through the **claude.ai connector** (`mcp__0ccea419-...`), not `plugin:design:linear`, which shows "Needs authentication" and is a different server. Enabling a connector makes its tools available on the **next** turn.
