# PR: Keep the observability fixture's scratch file out of the working directory

Branch: `fix/observability-fixture-scratch-file`.

## Summary

The observability rules fixture wrote a scratch file named `apps-console.ts` into the current working directory, copied it into its temp tree, and deleted it only on the last line of the script. The fixture runs under `set -e` from the repository root, under both `run-fixture-shards.sh` and `enforce/tdd.sh`, so any failing assertion exited before the cleanup line and left an untracked `apps-console.ts` in the repository root. One such file was sitting untracked in the main checkout when this work started.

## What changed

- `claude/enforce/tests/observability-rules.test.sh` writes the `console.log` sample straight to `$TMP/apps/server/src/services/getNote.ts` and copies it from there to the client path, so nothing is written outside the fixture's `mktemp -d` directory.
- The fixture registers `trap 'rm -rf "$TMP"' EXIT` right after creating the temp directory, so the temp tree is removed on success and on failure alike; the trailing `rm -f apps-console.ts` is gone.

## Architectural decisions

- **Write into the temp tree instead of cleaning up the cwd with a trap.** A trap that deletes `apps-console.ts` from the cwd would also fix the leak, but it would still write into whatever directory the runner happens to use, and it could delete a real file of that name. Writing under `$TMP` removes the cwd from the picture entirely.
- **Audit of the other fixtures.** Every other relative-path write in `claude/enforce/tests` and `claude/hooks/tests` (`conflict-markers`, `convention-rules`, `naming-lexicon`, `push-eslint-gate`, `push-ruff-gate`, `fix-commit-requires-test`, `session-start`, and others) runs after a `cd` into a `mktemp -d` directory, so none of them share the defect and this PR leaves them unchanged.

## Testing

- The fixture failed at its first assertion in a worktree without `claude/enforce/node_modules` (ERR_MODULE_NOT_FOUND from `lint.mjs`), and that failing run left no `apps-console.ts` behind, which is the failure path this PR fixes.
- After `npm ci --prefix claude/enforce`, the fixture passes and again leaves no file in the cwd.
- Fixtures are hash-pinned, so the first full run failed `hook-hashes-closure` on the edited fixture; `hook-integrity-check.sh --update` against the checkout regenerated `claude/enforce/hook-hashes.txt`, and the branch was rebased onto #46 with the manifest regenerated again rather than hand-merged.
- `bash claude/enforce/tests/run-tests.sh` then passed every fixture except `hook-latency`, which failed intermittently by 5 to 10 percent over its budget and passed on the pre-push run. That fixture times the installed `~/.claude` hooks, which this diff does not touch, so the flake is machine load rather than this change.

## Reflection

A few minutes passed between the edit and this document. The fix itself was small; the part worth recording is that the first run of the patched fixture failed for an unrelated reason (missing dependencies), which turned out to be a useful accidental check that the failure path no longer leaks the file.
