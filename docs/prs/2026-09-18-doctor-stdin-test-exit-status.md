# PR: the open-stdin doctor.sh test also checks the run succeeded

Branch: `fix/doctor-stdin-test-exit-status`. Follow-up to PR #37.

## Summary

PR #37 added a regression case to `claude/enforce/tests/doctor.test.sh` that runs `doctor.sh` with an stdin held open and asserts the run exits inside a 10-second watchdog. A review on PR #37 pointed out that the case treats any exit as success, so a regression that makes `doctor.sh` fail immediately would still pass it. This PR makes the case also check that the run succeeded.

## What changed

- `claude/enforce/tests/doctor.test.sh`: the open-stdin run now writes its output to a file in the case's temporary directory instead of discarding it, and the case captures the exit status from `wait`. Two new assertions require exit status 0 and a `pass hook-registration: clean` line, which is how `doctor.sh` reports the stub verifier that drains stdin.
- `claude/enforce/hook-hashes.txt`: regenerated, because the test file is hashed.

## Architectural decisions

- **Assert the verifier's own report line as well as the exit status.** An exit status of 0 alone would also pass if `doctor.sh` stopped running the verifier loop at all, so the case also requires the line that shows the draining stub ran and was judged clean. The alternative, asserting exit status only, was the smaller change but would leave that gap open.

## Testing

- The full `doctor.test.sh` passes with stdin closed.
- Mutation check: changing the stub verifier to exit 3 makes both new assertions fail (`open-stdin run exits 0` and `open-stdin run reports the draining verifier clean`), which shows they catch a fast failure that the exit-within-bound check alone would miss.
- Both suites run with stdin closed at pre-push.

## Reflection

The first version of the test checked only the property the bug broke, which was termination, and it did not check the property every other case in the file checks, which is the reported verdict. The bound on elapsed time showed that doctor.sh no longer hangs, but only the exit status and the report line show that it still does its job. Time from the PR #37 merge to this document is about 15 minutes.
