# verification-gate case 12 no longer depends on npm starting within one second

## Summary

Case 12 of `claude/enforce/tests/verification-gate.test.sh` proves that the R-509 verification gate never retries a check that hit its hard timeout (exit 124). The fixture ran an `npm test` script that appended a line to a run log and then slept for 2 seconds, with `CLAUDE_VERIFY_TIMEOUT=1`, and asserted that the log held exactly one line. On 2026-09-18 the case failed pre-push twice with "expected 1 run, got 0" while the machine's load average was about 147, and it passed three runs out of three in isolation. Under that load npm did not reach the script body before the gate killed it at one second, so the log stayed empty even though the gate had behaved correctly. The case was measuring npm startup speed, not retry behavior.

## What changed

- `claude/enforce/tests/verification-gate.test.sh`, case 12:
  - The check is now a `.claude/verify.sh` rather than an npm script. The gate runs `.claude/verify.sh` ahead of any discovery (invariant 7), and plain bash reaches the script's first statement far faster than npm does.
  - The script's first statement logs the run, and it then runs `exec sleep 30`, so the process the gate kills on timeout is the sleep itself and no orphaned sleep outlives the case.
  - `CLAUDE_VERIFY_TIMEOUT` rises from 1 to 5 seconds, which leaves a large margin for a slow bash start under heavy load while keeping the script's sleep far above the timeout.
  - The assertions are unchanged: the block reason must be a timeout block, it must not mention an automatic retry, and the run log must hold exactly one run.
- `claude/enforce/hook-hashes.txt` carries the fixture's new hash.

## Architectural decisions

- **Keep a real timeout rather than have the script exit 124 by itself.** A script that exits 124 would make the case independent of timing, but the case would then stop exercising `run_with_timeout`, the polling fallback that is the only timeout path on macOS, which ships neither `timeout` nor `gtimeout`. The chosen fix keeps that path under test.
- **Keep the exact "1 run" assertion rather than loosen it to "at most 1 run".** A gate whose attempts never start would log zero runs whether it retried or not, so "at most 1" would pass a retrying gate under load. The exact count still fails on a retry, and the fixture change removes the reason the count could read zero.
- **Five seconds, not three.** The case now costs about 7 seconds instead of about 3, in a fixture already tagged `# Shard: slow`. The extra margin was judged worth that cost because the failure being removed occurred during pre-push, when the load is highest.

## Testing

- Reproduced the flake before the fix: a standalone copy of case 12, run with 100 CPU-bound busy loops in the background (load average about 195), failed three runs out of three with "expected 1 run, got 0". The same copy passed at idle.
- After the fix, the same copy passed five runs out of five under the same artificial load.
- Mutation checks under the same load, each reverted afterwards:
  - A gate that retries after a timeout and reports the retry fails the case on the reason assertion.
  - A gate that retries after a timeout silently, without the retry note, fails the case with "expected 1 run, got 2", so the run count catches a retry on its own.
- The full `verification-gate.test.sh` passes, and `hook-hashes-closure.test.sh` passes with 216 entries.

## Reflection

The first attempt at an artificial-load harness captured the busy loops' process IDs through a command substitution, which waited for the loops to close their inherited standard output and therefore never returned; the loops ran for five minutes with no case executed until they were killed. Detaching the loops from standard output fixed it. The underlying lesson for the fixture itself is that an assertion about how many times something ran must count the runs at a point that every attempt is guaranteed to reach, and an npm script body is not such a point under load.
