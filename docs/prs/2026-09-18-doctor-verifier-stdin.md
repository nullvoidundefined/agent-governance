# PR: doctor.sh runs its verifiers with stdin closed

Branch: `fix/doctor-verifier-stdin`.

## Summary

`claude/enforce/doctor.sh` ran each SessionStart verifier as `OUT=$(bash "$V" 2>&1)`, so the verifier inherited doctor.sh's stdin. `claude/hooks/enforcement-guard-check.sh` begins by draining stdin with `cat`, and when the caller's stdin never closes, that `cat` blocks forever. `claude/enforce/tests/doctor.test.sh`, and with it the whole enforcement suite, then hung indefinitely. This happened on 2026-09-18 when the suite was started from a background shell that kept stdin open: two suite runs sat for 28 and 88 minutes in doctor.sh, then enforcement-guard-check.sh, then `cat`. This PR closes stdin for every child process that doctor.sh starts without feeding it input.

## What changed

- `claude/enforce/doctor.sh`: the verifier call is now `OUT=$(bash "$V" </dev/null 2>&1)`, and a comment beside the loop says why. The translator `--check` call and the `--release` fixture-suite call also gained `</dev/null`, because both start child processes that would otherwise inherit the same open stdin. The statusLine probe already pipes a sample payload into its command, so it needed no change.
- `claude/enforce/tests/doctor.test.sh`: a new case runs doctor.sh against a stub HOME whose `enforcement-guard-check.sh` drains stdin the way the real one does. The case feeds doctor.sh a FIFO that a sleeping writer holds open, and a portable watchdog polls for exit for up to 10 seconds, since macOS ships no `timeout`. Killing the writer afterwards closes the FIFO, so a hung run unwinds instead of outliving the suite.
- `claude/enforce/hook-hashes.txt`: regenerated, because both changed files are hashed.

## Architectural decisions

- **Close stdin at the call site, not in the verifier.** The alternative was to make `enforcement-guard-check.sh` skip its drain when stdin is a terminal or not a pipe. That would fix one verifier but leave doctor.sh exposed to the next hook that reads stdin. The caller knows it has no input to give, so the caller closes stdin.
- **A FIFO holds stdin open instead of `sleep 60 | doctor.sh`.** In a backgrounded pipeline the test cannot easily get the writer's PID, and killing only doctor.sh leaves its grandchild `cat` alive. Owning the writer's PID lets the test close the FIFO and unwind every process in the chain.
- **No `tdd.sh` slice lock.** `tdd.sh` drives Vitest or Jest reports, and this fix lives in a shell fixture suite, so the RED and GREEN evidence below comes from running the suite directly.

## Testing

- RED: with the new case and no fix, `doctor.test.sh` printed `FAIL: verifiers never block on an inherited stdin that stays open` after the 10-second watchdog and finished in about 14 seconds instead of hanging.
- GREEN: with the fix, the same file prints `doctor.test.sh PASS` in about 4 seconds.
- Full suites with stdin closed: `bash claude/hooks/tests/run-tests.sh </dev/null` ends with `ALL HOOK TESTS PASS`, and `bash claude/enforce/tests/run-tests.sh </dev/null` ends with `ALL ENFORCEMENT TESTS PASS`.
- `node translate/codex.mjs --write` and `node translate/cursor.mjs --write` produced no diff, so the ports did not need regenerating.

## Reflection

The bug was invisible in interactive runs because a terminal's stdin reaches EOF or is never read, so every earlier test run passed. The hang only appeared when a background shell held stdin open, which means the existing tests never exercised the condition at all. The first draft of the test used a pipe from `sleep`, which would have reproduced the hang but left an orphaned `cat` after the watchdog fired; the FIFO version fixes that. Time from the first commit on `main` this branch builds on to this document is about 10 minutes.
