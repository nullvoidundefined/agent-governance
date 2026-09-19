# tdd.sh red classifies each test of a whole-file red on its own

Refs: IAN-160

## Summary

`tdd.sh red <test file>` is the R-412 check that a new test is RED for a legitimate reason: it fails because the unit it tests is missing (missing-module) or because the unit gives the wrong answer (assertion), and nothing else. The whole-file path, `classify_red` in `claude/enforce/tdd.sh`, joined the failure messages of every test in the file into one string and grepped that string for the missing-module and assertion patterns. A single classified failure anywhere in the file therefore vouched for every other test in it: a file where one test failed its assertion and another raised a `RuntimeError` or hit a timeout was locked as an `assertion` RED, and the broken test could later go green for the wrong reason. PR #74 (IAN-139) fixed exactly this in `classify_named`, the path that names tests by id, and left the whole-file path as it was. This change gives the whole-file path the same per-test classification.

## What changed

- `claude/enforce/tdd.sh`: the per-test loop that PR #74 wrote inside `classify_named` moves into a new function, `classify_failures <rel>`. It reads one `{key, failures}` object per failing test on stdin, refuses the first test whose messages match neither class with `<rel>::<test id> fails for a reason this script does not classify: <first line>`, and prints `missing-module` when any test is missing-module and `assertion` otherwise. `classify_red` and `classify_named` both call it through a process substitution, so a refusal's `die` still exits the `$(...)` that `cmd_red` captures the class with. The only difference between the two callers is which tests they feed in: every test of the file for `classify_red`, and the matched tests for `classify_named`. When it reads no result at all, which happens when the producer's `jq` fails on a report it cannot read, it refuses instead of defaulting to `assertion` (review finding 1).
- `claude/enforce/tests/tdd-pytest.test.sh`: a whole-file red on a file where `test_asserts` fails `assert 1 == 2` and `test_raises` raises `RuntimeError("boom")` must be refused naming `<file>::test_raises`, and the phase must stay `open`.
- `claude/enforce/tests/tdd-red-green.test.sh`: the same case under the real Vitest, where one test fails `toBe` and one throws `new Error("boom")`, must be refused as `src/__tests__/score.test.ts::throws boom fails for a reason this script does not classify: Error: boom`. A new Jest-stub mode reports the named failing test with `failureMessages: null`, and `tdd.sh red` must refuse it with `no failing test result to classify`.
- `claude/enforce/README.md`: the `tdd.sh` paragraph now says that each test is classified on its own and how an unclassified one is refused.
- `claude/enforce/hook-hashes.txt` is regenerated. The Codex and Cursor ports regenerate with no changes.

## Architectural decisions

- **Chosen: one shared `classify_failures` for both paths.** The two paths now differ only in which results they select, which is the only place they should differ. **Alternative:** copy PR #74's loop into `classify_red`. **Why not:** two copies of the classification rule are how the whole-file path was missed in PR #74 in the first place, and the next change to the rule (a new class, a new pattern) would have to find both.
- **Chosen: the refusal names the test as `<file>::<test id>` on the whole-file path too.** The previous whole-file message named only the file and the first line of the joined messages, which, once messages are joined, could come from a different test than the one that was actually unclassifiable. The id form is the one `tdd.sh red` already accepts as an argument, so the message tells the author exactly which test to fix or split out.
- **Unchanged: the zero-test branch of `classify_red`.** A file that fails to load (a missing import at module level, a syntax error) has no per-test results, and its file-level message is still classified as before. That is the missing-module RED for a brand-new test file, and there is only one message to classify.

## Testing

- RED: both new cases failed at `c9d125c`, a local commit holding only the tests, before the fix was written. That commit was then folded into the fix commit, because `fix-commit-requires-test` (R-403) refuses a `fix:` commit whose staged diff carries no test, so the branch has one commit and `c9d125c` exists only locally. Run directly against a throwaway Vitest project, the unfixed `tdd.sh red` accepted the mixed file as `assertion, 2 test(s)` and exited 0, which is the bug; after the fix it exits 1 with `src/__tests__/score.test.ts::throws boom fails for a reason this script does not classify: Error: boom`.
- `claude/enforce/tests/run-tests.sh` and `claude/hooks/tests/run-tests.sh` were run with HOME pointed at a temporary directory whose `.claude` links to the worktree's `claude/`, and both pass: `ALL ENFORCEMENT TESTS PASS` across 94 fixtures, and `ALL HOOK TESTS PASS`.
- `shellcheck -S warning claude/enforce/tdd.sh` is clean.

## Codex review

Reviewer: a separate Claude agent (fable), used as the fallback because Codex returned its usage limit (it resets 2026-09-21). The reviewer confirmed that both new cases fail against `origin/main`'s `tdd.sh` and pass on the branch, and it probed a throwaway Vitest project for: an unclassified test ahead of an assertion, missing-module beside assertion (locked as missing-module), a Vitest timeout (refused), the named path (still refuses), `throw undefined` (refused), and `die` propagation through the process substitution into `cmd_red` (exit 1, phase left `open`).

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | LOW | `classify_failures` printed `assertion` when it read no results. Because the producer runs in a process substitution under `set -uo pipefail` with no `-e`, a `jq` error there (a result whose `failureMessages` is `null`) left the loop empty, and the file was locked as an assertion RED. | Fixed test-first: a Jest-stub mode with `failureMessages: null` on the named test was refused by nothing before the fix, and `classify_failures` now counts results and refuses with `no failing test result to classify` when there are none. |
| 2 | LOW | The `ASSERTION` pattern contains the bare word `expected`, so a plain error whose text contains it (`throw new Error("timeout: expected reply")`) is an assertion RED in both paths. | Deferred to a follow-up task: this was already true before this change, the per-test change does not touch it, and tightening the pattern needs its own fixture sweep across the three runners. |

## Reflection

The bug was the same shape as the one PR #74 fixed, one function over, and the review of #74 caught it only in the path that PR was changing. What I understand now is that `classify_red` and `classify_named` were two implementations of one rule ("every test in scope is RED for a classified reason") that had drifted because each was written for its own entry point, so the durable fix was to make the rule one function and let the entry points differ only in what they select. What I got wrong first was the expectation that the existing whole-file tests would need rewording for the new `path::id` message; none of them asserted on the old `<file> fails for a reason` text, so the only tests that changed are the two new ones. Time from the start of this task to this document was about fifteen minutes.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
