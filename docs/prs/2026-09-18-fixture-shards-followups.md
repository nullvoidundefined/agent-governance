# Fixture shard runner: close the late review of #42

## Summary

#42 was merged from `a29980a` about three minutes after that head was pushed, before Copilot's review of it arrived. That review raised nine comments, seven of them new, and CI on `main` then failed once in `fixture-implementation-root.test.sh`, with a report whose last three lines were all passing cases. This PR fixes the valid review points, and makes the runner print every failure line of a failing fixture, so the next occurrence of that CI failure can be read from the log.

## What changed

- `claude/enforce/run-fixture-shards.sh`:
  - `--jobs <n>` and `--settle-seconds <n>` replace `FIXTURE_SHARD_JOBS` and `FIXTURE_SERIAL_SETTLE_SECONDS`, for the reason the earlier test options became arguments: an exported `FIXTURE_SERIAL_SETTLE_SECONDS=0` could skip the quiet period that `hook-latency.test.sh` depends on. The runner now reads neither variable.
  - The ESLint bundle's `package.json`, `package-lock.json`, `eslint.config.mjs`, `eslint-options.mjs`, and `lint.mjs` joined the shared files, so a change to any of them runs everything. Before, a lockfile change was mapped to the one fast fixture that names it, and every slow lint-driven fixture was skipped.
  - A failing fixture's report now carries all of its `FAIL` lines before its last three lines.
- `claude/enforce/tests/run-fixture-shards.test.sh`: cases for each of the above, and for change detection against an upstream (a pushed commit is not counted, an unpushed one is) and against `origin/main` (the branch's own commit is counted). Before, only the root-commit path was exercised.
- `claude/CLAUDE-GO.md`: the affected-package instruction now describes the reverse lookup. `go list … .Deps` lists what each package imports, so the packages affected by a change are those whose dependency list contains a changed package, plus the changed packages themselves. The command as printed does not compute that selection.
- `claude/README.md`, `claude/enforce/README.md`, the R-509 Spec, and the runner's header now say that affected mode selects a slow or serial fixture when a change names or watches it. They previously said slow only, although `hook-latency.test.sh` is serial and is selected that way.
- Regenerated Cursor ports and hash manifest.

## Architectural decisions

- **Arguments over environment for every runner control,** not only the test-only ones. The job count and settle pause change what a gate run measures, so an inherited value must not be able to change them silently.
- **Toolchain files as shared, rather than watched by each lint fixture.** Every lint-driven fixture loads the same bundle, and a shared entry covers fixtures added later without anyone remembering to add a watch line.

## Testing

- Every new case failed before its fix. Most failed at first because the runner refused the new arguments; the upstream case failed because the test's copied repository no longer mapped `hooks/alpha.sh`. That was a setup bug in the test, and it was fixed in the setup.
- The `fixture-implementation-root.test.sh` failure on `main` did not reproduce in three local runs that mirrored the CI layout: `~/.claude` symlinked to the checkout, 4 jobs. The failed job has been re-run.
- Full sharded runs of both suites, read green before committing.

## Reflection

- #42's last round of fixes and this follow-up both come from merging before the latest head's review arrived, the same pattern as #36 and #39. The runner work was sound in outline, but each review round found a real way for it to under-select or report a false green, so the time between push and merge was where the remaining defects were.

## Load-aware sharding (added at the maintainer's request)

- The first full run for this PR failed only `hook-latency.test.sh`. Two other worktrees were running the sharded suites at the same time, each with up to 8 jobs, and the load average reached 105; during a retry it climbed from 31 to 124 while the suite ran. `hook-latency` passed twice when run alone with normal baselines. Every session sharding with a fixed 8 jobs on a 14-CPU machine is what overloaded it.
- **Idle-CPU job count.** Without `--jobs`, the runner now uses the CPU count minus the one-minute load, from a quarter of the CPUs up to 8. The floor started at 1, and a Stop-gate run on a loaded machine then went one fixture at a time past the gate's 600-second timeout; a quarter of the CPUs keeps a busy machine moving.
- **Load-aware settle.** `--settle-seconds` is now the minimum pause before the serial fixtures. After it, the runner waits until the one-minute load falls below the CPU count, for at most `--settle-max-seconds` (default 60), and says so when the cap is reached with the machine still loaded.
- `--load-from <file>` lets the fixture set the load reading, so every case is independent of how busy the machine running it is. The new cases:
  - a load that falls after three seconds holds the serial fixture back about that long;
  - a load that never falls releases it at the cap, and the run still finishes and reports it;
  - two idle CPUs give two jobs, and a saturated machine gives one.

## Change detection from the branch point

- The same timed-out gate run exposed a selection bug. This branch was created from `origin/main`, so git set `origin/main` as its upstream, and the runner diffed `@{u}` against `HEAD` with two dots. That compares the two trees, so once `main` moved ahead, every file `main` had gained, such as a spec added by another PR, appeared as a change here. The unknown file then triggered the unmapped-change fallback and a full run at each turn end. The diff now uses three dots (`@{u}...HEAD`), which counts only this branch's own commits since the branch point. A case pushes a new file to the upstream after the branch point and asserts it is not counted.
- `main` meanwhile gained `--results-dir` in the runner for `tdd.sh`. The merge keeps it alongside this branch's options, and `tdd.sh`'s call is unchanged.
- Both full suites passed after the merge in 187 seconds, with the runner choosing 4 and 3 jobs while the machine's load was still settling.

## Review round 1 (Copilot)

- **Settle limits.** `--settle-max-seconds` below `--settle-seconds` was accepted, and then the wait always ran the full minimum, so the maximum was not honoured. The runner now refuses the combination as a usage error.
- **Failure-line filter.** The report printed lines starting with `FAIL`, while the verdict counts the marker anywhere in a line, so a line such as `assertion failed: FAIL: ...` failed the fixture but was left out of its report. The report now uses the verdict's own test.
- **A slow case in the fixture.** The saturated-load job-count case inherited the 60-second settle cap and waited it out on every run. It now passes a zero cap.
- **`enforce/README.md`** now says that editing a slow or serial fixture selects it.
- The two behaviour cases failed before the fix and pass after it.
- CI's `pull_request` run of the `enforce` workflow never started for this PR, so the required `fixtures` check had no run. It was started by `workflow_dispatch` on the branch, which attaches its result to the same commit.

## Merge with IAN-98

- `main` gained #54 (IAN-98), which moved the full suite off pre-push: pre-push now runs only the port checks, and CI is the one full run, as the required check before merge. The merge keeps that policy. It corrects the comments #42 had left saying pre-push runs the full suite, in the Stop gate, the runner, both `run-tests.sh` wrappers, and the Frontend guide. The Go guide keeps IAN-98's "not at pre-push" together with this PR's reverse-dependency correction.
- The earlier merge in this PR had also created a conflict with `main` that stopped GitHub from starting the `pull_request` run of `enforce`; with the conflict resolved the run triggers normally.

Ticket: IAN-94.
