# Let a test author return on its slice's intended RED

Ticket: IAN-184. Branch: `fix/gate-expected-red`. Written 2026-09-20T16:39Z, about 35 minutes after the first commit on the branch and one minute after the last.

## Summary

`hooks/verification-gate.sh` enforces R-509 by refusing to let a turn, or a writing subagent, end on a red test suite. That is exactly the outcome the `test-author` role exists to produce: it writes the failing test and stops. The gate's only existing exemption covers roles whose `enforce/role-policy.json` entry is `deny ["any"]`, and `test-author` necessarily has a write boundary (`allow: ["tests"]`) rather than that entry, so no amount of correct behavior could get it past the gate. Every escape available to a blocked test author was a rule violation: editing the locked test breaks R-410, implementing the fix breaks R-411, weakening the assertion breaks R-204, and `CLAUDE_SKIP_VERIFY=1` is a blanket skip rather than a bounded exemption.

This PR gives the gate a bounded exemption and, in the same PR, closes the hole that exemption would otherwise have opened.

## What changed

Two slices, four commits, alternating test and implementation.

**B-3b, the wiring** (`75b606e`, `6aa8d2a`). After a check has genuinely failed, including its automatic retry, the gate asks `enforce/tdd.sh expected-red` and releases the turn only on exit 0. It asks only after a failure, so a green turn never pays for a second suite run. It resolves `tdd.sh` from its own `BASH_SOURCE` as `<hook dir>/../enforce/tdd.sh`, the way `RELATED_HELPER` and `PORT_CHECKS_HELPER` beside it already do. It discards the subcommand's own output, because stdout is the decision channel and a stray `tdd.sh: EXPECTED RED: ...` line would be read as a malformed decision. It fails closed: a `tdd.sh` that is absent, not executable, or erroring has not said yes. And the release path exits before the pass memo is written, so a red tree is never remembered as a tree the checks passed on.

**B-3a, the soundness fix** (`bd38353`, `250ba62`). `expected-red` previously answered a membership question only: does anything outside the locked files fail? It never looked at the locked files themselves. It now also requires that every locked file still matches the sha256 recorded at its RED, reusing `check_hashes` rather than restating the comparison (R-308), and that at least one locked test is still failing.

## Architectural decisions

**The gate asks `tdd.sh` rather than judging for itself.** The alternative was to have the gate parse the test output directly. Rejected: the gate would have to understand Vitest, Jest, pytest and bash-fixture output, and `tdd.sh` already normalizes all four into one report shape and owns the slice lock. The gate asks a question; it does not learn a second copy of the answer.

**The exemption fails closed, and that asymmetry is deliberate.** A broken, missing, or non-executable `tdd.sh` must never become a way to end a turn on a red suite, because that is precisely what R-509 exists to prevent. The cost is that a genuinely broken `tdd.sh` blocks test authors, which is the right direction to fail in.

**B-3a shipped in the same PR rather than as a follow-up.** This is the decision I would most expect to be challenged. Wiring the gate to `expected-red` makes an existing, known, medium-severity hole reachable: an R-517 review of PR #91 had already shown that a locked fixture could be rewritten to `echo garbage; exit 3`, deleted, or made to pass, and `expected-red` still answered yes. While nothing called the subcommand that was harmless. The moment the gate ends turns on the answer, a test author that mangled its own fixture after proving RED would be released. Shipping B-3b alone would have merged a known-unsound exemption to `main`, so both slices land together and the hole never reaches `main`.

**The ordering inside the PR is backwards from the risk, on purpose.** B-3b was implemented first even though it is the slice that creates the exposure. The reason is a bootstrap: fixing `expected-red` requires an independently authored failing test, Codex was rate-limited (its usage limit resets 2026-09-21 02:26), and the only available fallback author was the very `test-author` subagent the gate was blocking. B-3b's own test did not need a live author because it had been written in an earlier session and parked, unpushed, on `park/b3-gate-expected-red-fixture`. So B-3b was landed from the parked fixture, the fix was synced into `~/.claude`, the role became usable, and it then authored B-3a's test. The exposure existed only on a local branch.

**A new fixture file rather than added cases in the sibling.** `tdd-expected-red-integrity.test.sh` is deliberately separate from `tdd-expected-red.test.sh`. Editing the tracked sibling makes `hook-hashes-closure.test.sh` report *content* drift, and that line names no path, while `drift_is_confined` in `tdd.sh` tolerates drift only when a reverse-closure line names a path the lock records. An edit could therefore never reach a clean RED: the turn-end gate would block the test author and `expected-red` would refuse the drift for the same reason. A new file produces the reverse-closure line naming that new path, which is the tolerated case. This constraint was discovered empirically during this PR and is the likely root cause of IAN-162.

## Testing

Two new bash fixtures, 408 lines together, both driving real git repositories in `mktemp -d` rather than stubs, because both behaviors are about git objects and on-disk state.

`verification-gate-expected-red.test.sh` (249 lines, 9 cases) runs a sandbox copy of the hook beside a stand-in `tdd.sh` whose answer a file selects and whose invocations are logged with the directory they ran in. It pins: a confirmed RED releases with no output at all; a refused one still blocks with the R-509 reason and the check's own output; a passing check never asks; a missing, non-executable, or erroring `tdd.sh` still blocks; `test-author` is released on `SubagentStop` and `implementer` is not; and a `deny ["any"]` role is still exempted before any check runs, so nothing is asked.

`tdd-expected-red-integrity.test.sh` (159 lines) opens a real slice and proves a real RED in a throwaway repository, then mutates it three ways: the locked fixture starts passing, is rewritten after its RED, and is deleted. All three satisfy membership vacuously and so all three exited 0 before this change. A control case on the untouched RED runs first, so a refusal in the three cases can only be the mutation each one makes. Every invocation is additionally checked for writing nothing: the lock's bytes and the untracked-inclusive `git status` must be identical before and after, refusals included.

Verified by the harness rather than by assertion: `tdd.sh red` printed `RED: ... [assertion, 1 test(s)]` for both slices, and `tdd.sh green` printed GREEN with the outside count rising 97 to 98 to 99 as each fixture landed. The full affected suite is green.

## Reflection

What I understand now that I did not at the start: this was filed as the third of three frictions from one session and treated as the last item of work, and it is actually the prerequisite for the other two. With Codex rate-limited, every TDD slice in this repository depends on the `test-author` subagent, and this gate is what blocks that role. The other ticket (IAN-220) was opened, started, and paused once that became clear.

What I got wrong first: I ordered the work by the order the frictions were reported rather than by dependency, opened a slice on IAN-220, dispatched Codex, and only discovered the circularity when Codex came back rate-limited and I reached for the fallback. Nothing was lost, because the discovery happened before any production edit and `HEAD`, the working tree and the lock hash were all verified unchanged. But the ordering was available from the ticket text before any of that, and reading IAN-184's description first would have shown it.

The second thing I got wrong is smaller and more interesting. I briefed the test author not to run `tdd.sh red`, carrying over the convention the skill states for Codex, where the orchestrator runs it after checking that Codex touched nothing. For a subagent the skill says the opposite: the agent runs it. The consequence was that `tdd.sh validate test-author` refused on its first call, because it expects phase `red` and found `open`. Harmless, and it cost one command, but the skill has two different contracts for the same step and I applied the wrong one.

What the fixture author found that I would not have: the manifest content-drift constraint above. It came out of a blocked turn rather than from reading, and it explains a separate open ticket.
