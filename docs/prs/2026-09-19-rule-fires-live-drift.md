# Stop tracking the live-written rule fire and miss logs

Refs: IAN-114

## Summary

`claude/hooks/session-end.sh` appends to the live `~/.claude/global-memory/rule_fires.md` at every session end, and the same path was tracked under `claude/`. The live copy therefore never matched the checkout, so `claude/hooks/harness-sync.sh` saw drift at every SessionStart and ran a full `./sync.sh` (about 1.5 seconds per session), and each of those syncs overwrote the live roll-up with the committed copy, discarding every fire recorded since the last commit. `rule_misses.md` has the same shape: session-end appends a line to the live copy whenever a project memory file carries a new `miss:` line. This change stops tracking both logs so the harness can match its checkout and the logs keep what the hooks write.

## What changed

- `claude/global-memory/rule_fires.md` and `claude/global-memory/rule_misses.md` are removed from the index and listed in `claude/.gitignore` with a comment explaining why.
- `claude/hooks/session-end.sh` already created each log with its header when the file was absent; its header comment now says so and records that both logs are live-only.
- `claude/hooks/tests/harness-sync.test.sh` gains case 3e. The sandbox checkout copies exactly the files the real checkout tracks under `claude/global-memory/`, the real `session-end.sh` then rolls a fixture fire and a fixture miss into the synced live tree, and the next harness-sync run must report no drift and must leave both entries in place.
- `claude/README.md` and `claude/SETUP.md` describe the two logs as live-only rather than as tracked files a new owner truncates.
- `claude/enforce/hook-hashes.txt` is regenerated for the changed hook.

## Architectural decisions

- **Chosen: stop tracking the logs.** A file a hook appends to at runtime is state, not configuration, so it belongs with the other runtime state `claude/.gitignore` already lists. **Alternative:** teach harness-sync's drift check an exclusion list of live-written paths. **Why not:** the tracked copy would still be synced over the live one whenever any other file drifted, so the data loss would remain, and a hand-kept exclusion list is the same shape that once made sync.sh delete live state.
- **Scope of the audit for other live-written tracked files.** Every hook and enforce script was searched for writes under `$HOME/.claude` or relative to its own directory. The only other writes into the live tree are `telemetry/`, `.session-locks/`, `.verify-memo/`, `global-memory/judge_usage.log`, and `global-memory/retirement_candidates.md`, none of which is tracked, plus `enforce/hook-hashes.txt`, which `hook-integrity-check.sh` writes only on an explicit `--update`. So `rule_misses.md` is the only other file fixed here.
- **Existing history.** The committed log contents stay in git history and in every live `~/.claude` that sync.sh populated, because sync.sh never deletes a live file. An install that is itself a git checkout (the clone-in-place layout `claude/SETUP.md` still documents) would lose its logs on `git pull`, since git deletes a file that stops being tracked; Copilot's review pointed this out, and `claude/SETUP.md` now gives the copy-aside, pull, copy-back steps for that layout and lists both logs among the files that do not ship.

## Testing

- Red first: with only the new case added, `bash claude/hooks/tests/harness-sync.test.sh` failed with `FAIL: a live-written roll-up is not drift`, `FAIL: a live-written roll-up survives the next SessionStart`, and `FAIL: a live-written miss log survives the next SessionStart`, while the two setup checks (`session-end wrote the live roll-up`, `session-end wrote the live miss log`) passed.
- Green: after untracking and ignoring both logs, the file reports `harness-sync.test.sh PASS`.
- `bash sync-tests/sync.test.sh` passes, which confirms a gitignored path does not disturb sync, since sync copies only tracked files and never deletes.
- `bash claude/enforce/tests/run-tests.sh` and `bash claude/hooks/tests/run-tests.sh` pass; `shellcheck --severity=error` is clean; both translator `--check` runs are clean.

## Reflection

The drift and the data loss were one bug seen from two sides: harness-sync was right that the trees differed, and sync.sh was right to copy what was tracked, so the defect was the tracking itself. The first version of the new test only covered `rule_fires.md`, the file the ticket named; reading `session-end.sh` in full showed that `rule_misses.md` is appended to in the same way, just more rarely, so the test now covers both.
