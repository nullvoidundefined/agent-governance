# tdd.sh names the failing test at green and runs shell fixtures from a scratch directory

## Summary

This PR follows up on #49, which added the bash `*.test.sh` runner to `claude/enforce/tdd.sh`. Copilot's review of #49 raised two findings, and both were real. #49 was merged before the fixes were pushed, so they arrive here as a separate PR. Ticket: IAN-100.

## What changed

- `claude/enforce/tdd.sh`:
  - **Green names the failing test.** `tdd.sh green` read the file-level `.message` to explain a failing locked file, but that field is empty whenever the file ran and a test inside it failed. This was already true on the Vitest path before #49, so a still-failing slice was reported as `failed to run: ` with nothing after it. Green now says "failed to run" only when a file produced no test results at all. Otherwise it names each failing test with the first line of its failure message.
  - **Shell fixtures run from a scratch directory.** Before, the shard runner ran with the repository root as its working directory. A failing fixture that wrote a relative path left files in the slice's tree, which is how `apps-console.ts` appeared during #49's end-to-end run. `tdd.sh` now starts the runner in a scratch directory and deletes it afterwards. Fixture paths are absolute, so nothing else about the run changes.
- Six enforce fixtures resolve `REPO_TOP` from their own location: `codex-adapter-contract`, `cursor-adapter-contract`, `doctor`, `settings-permission-rules`, `translate-codex`, and `translate-cursor`. Each used a bare `git rev-parse --show-toplevel`, which reads the working directory rather than the fixture's location. Running the enforce tree from a scratch directory made `translate-codex` and `translate-cursor` fail outright. The other four passed only because they tolerate a wrong `REPO_TOP`. All six now use `git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel`, the same binding #20 applied to the harness root. Without this change, `tdd.sh red` on any fixture in `claude/enforce/tests/` would refuse every slice, because those two siblings would be red.
- `claude/enforce/tests/tdd-red-green.test.sh`:
  - The Vitest green refusal must name the failing test.
  - The shell green refusal must carry the fixture's FAIL line.
  - A new sibling fixture writes a relative file, and the test asserts that the file never appears in the project during `open --refactor` or `green`.
- `claude/enforce/README.md` notes the scratch directory, and `claude/enforce/hook-hashes.txt` is re-hashed for the eight edited files.

## Architectural decisions

- **A scratch working directory, not a before-and-after `git status` comparison.** The alternative was to keep the repository root as the working directory, compare the tree before and after the run, and refuse or clean up any new files. Cleaning up could delete a file the user created while the suite was running. Refusing would block a slice for a fixture bug unrelated to it. A scratch directory prevents the write from reaching the tree at all.
- **Fix the six fixtures rather than keep the repository root for them.** Those fixtures break a binding the repository already relies on: since #20, a fixture resolves its subject from the tree it lives in. Keeping the repository root as the working directory would have hidden that bug instead of fixing it.
- **Fix green's message for both runners.** The review reported it for shell fixtures. The same code path gave the same empty message for Vitest, so the fix and its test cover both.

## Testing

- The Vitest green-message assertion failed before the fix, which confirmed the problem predates #49.
- The containment case failed when only the scratch-directory `cd` was removed from `tdd.sh`, and passes with it.
- From a scratch working directory, before the `REPO_TOP` change, the enforce tree failed `translate-codex` and `translate-cursor`, and the hooks tree passed all 20. After the change, all six re-rooted fixtures pass from a scratch directory.
- `tdd-red-green.test.sh`, `hook-hashes-closure.test.sh`, and both translator `--check` runs pass. The pre-push hook ran both full suites green on the fix commit. An earlier attempt failed `verification-gate.test.sh`'s 1-second timeout case at a load average of 195; that fixture passed three runs out of three alone, and this PR does not touch the gate.

## Reflection

- #49's end-to-end run already showed that a fixture could leave a file in the repository root. That was treated as a separate fixture bug and handed off, and #51 fixed it. The review pointed out that the problem was also in `tdd.sh`, which had inherited the fixture's working directory. The same evidence supported both conclusions, and only one of them was drawn at the time.
- The review fixes were pushed to #49's branch after #49 had merged. The push output said `[new branch]`, which showed that the remote branch was already gone. The fix commit was then moved onto this branch from `main`.

## Review round 1 (Copilot)

- **Green accepted a file marked failed whose assertions all passed.** Vitest and Jest report a suite-level error, such as a throwing `afterAll`, as a failed file whose individual tests passed. The first version of this PR reported "failed to run" only for a file with no test results, so that case slipped through and green advanced the lock. Green now refuses any file still marked failed after its tests pass, and the refusal carries the file's message. Real Vitest cannot produce that report without editing the locked test, which the hash check refuses, so the new case in `tdd-red-green.test.sh` drives `tdd.sh` with a stub runner that writes the exact report shapes for RED, the suite-level failure, and GREEN. The case failed before the fix and passes after it.
