# tdd.sh runs bash `*.test.sh` fixtures, and an untouched slice can close

## Summary

`claude/enforce/tdd.sh` is the harness that writes `.claude/tdd-lock.json` and proves the RED and GREEN steps of an R-412 slice. Until this PR it could run only Vitest or Jest. Every fixture in this repository is a bash `*.test.sh` file, so `tdd.sh red claude/enforce/tests/<name>.test.sh` reported that the file "was not run by vitest", and R-412 slices could not run in the repository that defines R-412. A slice that reached that refusal was also stuck, because `tdd.sh close` worked only from `green`, and the lock is a protected gate input (R-410) that only the user can delete.

This PR adds a shell-fixture runner to `tdd.sh`, and lets `close` end a slice from `open` when no test was ever locked. The request came out of the IAN-98 session on 2026-09-18.

## What changed

- `claude/enforce/tdd.sh`:
  - The runner is chosen from the test paths. When every named file ends in `.test.sh`, the suite is every `*.test.sh` in those files' directories. Any other path, or no path at all, keeps the existing Vitest or Jest resolution. Naming both kinds in one slice is refused, with the counts of each.
  - The shell suite runs through `run-fixture-shards.sh` in the same directory as `tdd.sh`, so the verdict is exactly the fixture suite's own: a fixture passes on exit 0 with a PASS line and no FAIL line. Each fixture becomes one record in the same JSON report shape that Vitest and Jest emit (`testResults[].name`, `status`, `message`, `assertionResults[]`), so `red`, `green`, `open --refactor`, the baseline count, and the hash checks all run unchanged.
  - A fixture that passed is one passing test. A fixture that exited 0 printing neither PASS nor FAIL has no tests, and `red` refuses it as "contains no tests". A fixture that `bash -n` rejects has no tests and a `syntax error` message, which `red` refuses as not parsing. Any other outcome is one failed test whose failure message is the fixture's FAIL lines, or its last five lines plus the exit code when it printed no FAIL line.
  - RED classification for shell fixtures: a FAIL line is the assertion RED, and bash's own `: No such file or directory` or `: command not found` for a script that does not exist yet is the missing-module RED. Anything else is refused as unclassified, as before.
  - `tdd.sh close` now also works from phase `open` when the lock's `tests` list is empty.
- `claude/enforce/run-fixture-shards.sh` gains `--results-dir <dir>`, which keeps each fixture's `.out`, `.verdict`, and a new `.status` (the exit code) in an existing directory instead of deleting a temporary one. `tdd.sh` builds its report from these files.
- Tests:
  - `claude/enforce/tests/tdd-red-green.test.sh` gains a second throwaway project with bash fixtures. It covers the refusals (a passing fixture, a silent fixture, a syntax error, a red sibling named by path, and a mix of runners), the missing-module and assertion REDs, the baseline counting only the named files' directory while a failing fixture in another directory is ignored, GREEN, a deleted sibling dropping below the baseline, a sibling that prints PASS but exits non-zero, `open --refactor` on a shell fixture, and `close` from `open`.
  - `claude/enforce/tests/run-fixture-shards.test.sh` gains the `--results-dir` cases.
- `claude/enforce/README.md` and the `tdd-gated-dispatch` skill's stack assumption describe the new runner and the new `close` rule; the Codex and Cursor ports are regenerated.

## Architectural decisions

- **Reuse `run-fixture-shards.sh` rather than write a second fixture loop.** The alternative was a loop inside `tdd.sh` that runs each fixture and applies the verdict itself. That would have been a second copy of the verdict rule, and the two could disagree: `tdd.sh green` could call a slice green that `run-tests.sh` calls red. Reusing the runner also brings parallelism and the `# Shard: serial` handling for free, which matters because the enforce tree has more than eighty fixtures. The cost is one new option on the runner, which is argument-only like its other test-facing options.
- **The suite verdict treats any FAIL substring as a failure, not only a line that starts with FAIL.** The request described the failure condition as a line starting with FAIL. The existing runner's rule is the stricter substring match, and `tdd.sh` follows the runner so that the two cannot disagree. A fixture that prints FAIL mid-line fails in both places.
- **The suite is the named files' directories, not the whole repository.** This is what the request specified, and it keeps a RED run proportional to the tree being changed. A slice on `claude/enforce/tests/` does not run `claude/hooks/tests/`, and the full suite still runs at pre-push and in CI.
- **`close` from `open` only while no test is locked.** In phase `open`, the lock denies production writes, and the tests list is empty until `red` succeeds, so nothing can have been written under that lock. Once a test is locked, the existing rule still applies and `close` needs `green`. The alternative, leaving the rule alone, keeps the stuck-slice failure that this PR exists to remove.

## Testing

- Both new fixture sections were written and committed first (`4e4ef7d`). Before the implementation, `tdd-red-green.test.sh` failed at its first shell case ("a passing shell fixture must be refused as passing"), and `run-fixture-shards.test.sh` failed its four `--results-dir` cases. Both pass after the implementation.
- An end-to-end run against this repository's real `claude/enforce/tests/` directory: `tdd.sh open`, then `tdd.sh red claude/enforce/tests/dangling-refs.test.sh` ran every enforce fixture through the shard runner in 1 minute 56 seconds and refused the fixture as already passing, and `tdd.sh close` then removed the lock from `open`.
- Full suites before the push: the hooks suite passed. The enforce suite failed on two fixtures. `hook-hashes-closure.test.sh` failed because the four edited enforce files were not yet re-hashed in `claude/enforce/hook-hashes.txt`; `hook-integrity-check.sh --update` changed exactly those four lines, and the fixture passes. `hook-latency.test.sh` measures the live install's SessionStart hook chain, which this PR does not touch, and it missed its budget by 4 to 18ms with a machine load average near 97; run alone three times it passed once and failed twice by those margins.
- After rebasing onto #47: `tdd-red-green.test.sh`, `run-fixture-shards.test.sh`, `hook-hashes-closure.test.sh`, and both translator `--check` runs pass.

## Reflection

- The end-to-end run left an untracked `apps-console.ts` at the repository root. `observability-rules.test.sh` writes that file into the current directory and deletes it only when it passes, and it was failing because this worktree's `claude/enforce/node_modules` predated the `eslint-plugin-vue` dependency added in #43. `npm ci --prefix claude/enforce` fixed the install. The fixture writing into its working directory, rather than its temporary directory, is a separate problem: `tdd.sh` runs fixtures from the repository root, so any failure of that fixture during a RED run leaves the same file behind.
- The first design ran the fixtures inside `tdd.sh` directly. Reading `run-fixture-shards.sh` showed that the verdict rule already existed there, and that a second copy would have been the only way the two could drift.

## Ticket

The Linear MCP server needed authorization in this session, so no ticket could be opened. Intended fields, to be entered when the tracker is reachable:

- title: tdd.sh: shell-fixture runner so R-412 slices work in agent-governance
- tier: standard; assist: llm; model: claude-opus-5
- repo: agent-governance; branch: feat/tdd-shell-fixture-runner
- started_at: 2026-09-18T14:40:31Z
