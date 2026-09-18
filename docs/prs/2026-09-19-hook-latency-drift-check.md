# Batch harness-sync's drift check instead of one cmp per tracked file

Refs: IAN-115

## Summary

IAN-115 asked why `hook-latency.test.sh` flakes and whether the `rule_fires.md` drift fixed in IAN-114 (#64) was the cause. Measuring `claude/hooks/harness-sync.sh` in a sandbox (`HARNESS_SYNC_HOME` and the `SYNC_*_HOME` variables pointed at a temporary directory, synced from a real checkout) showed that the drift was only part of the SessionStart cost. Even with nothing drifted, the hook spent about 0.8 seconds (1.2 seconds at a load average of 8) on every SessionStart, because its drift check ran one `cmp` process per tracked file across 531 files. That is more than the rest of the SessionStart chain together, which costs about 180 ms. This change compares all tracked files in one batch, which brings the no-drift run on the real checkout from about 770 ms to about 120 ms.

## Measurements

All timings are wall-clock milliseconds for one `harness-sync.sh` run against a sandbox live tree, taken on 2026-09-18 at load averages between 4 and 8.

| State | Before IAN-114 (`fd5e905`) | After IAN-114 (`72e650d`) | This branch |
|---|---|---|---|
| No drift | 1160 to 1215 | 760 to 835 | 120 to 170 |
| One live file edited (full `./sync.sh`) | 1890 to 2050 | 1265 to 1295 | not remeasured; the sync itself dominates |
| After a `session-end.sh` roll-up | 1580 to 1795 (drift, full sync) | 765 to 780 (no drift) | same as no drift |

The first two columns differ in their no-drift rows only because the machine's load fell between the runs. IAN-114 removed the roll-up's drift, so a session end no longer forces the next SessionStart into a full sync; the no-drift cost itself was untouched by it.

Per-hook costs of the three chains `hook-latency.test.sh` times, measured over 20-run loops against the installed hooks at a load average of about 5 (a bare bash+jq spawn costs about 6 ms):

- SessionStart (sandboxed as the test does it): `session-start.sh` about 80 ms and `parallel-session-check.sh` about 60 ms dominate; `harness-sync.sh` costs about 5 ms there, because the test's sandbox HOME has no `.sync-source` and the hook exits before its drift check. The test therefore never measured the 0.8 seconds this change removes.
- PreToolUse Write|Edit: `protected-path-guard.sh` 63 ms, `content-gate.sh` 40 ms, `secret-scan.sh` 37 ms, `structure-gate.sh` 35 ms, the other four 12 to 16 ms each. The chain runs at about 5.5 times its control against a multiplier of 6, the thinnest margin of the three.
- PreToolUse Bash: about 3.6 times its control, well inside the multiplier.

Three consecutive runs of the installed `hook-latency.test.sh` at a load average of about 8 passed: Bash 424 to 432 ms (budget 708 to 732), Write 280 to 287 ms (budget 300 to 312), SessionStart:resume 234 to 261 ms (budget 400). Starting 800 idle processes did not change the SessionStart hooks' cost, so process count alone does not explain the failures the handoff recorded at load averages of 62 to 228.

## What changed

- `claude/hooks/harness-sync.sh`: `countDriftedPayloadFiles`, which ran once per payload and spawned one `cmp` per tracked file, is replaced by `countDriftedFiles`, which lists all three payloads with one `git ls-files`, counts files missing on either side with the shell's own `[ -f ]` test, and hands every remaining pair to `countDifferingPairs`. That function hashes each side with one `git hash-object --no-filters --stdin-paths` and counts differing lines with `paste` and `awk`. When either hash batch fails or returns fewer lines than it was given, it falls back to one `cmp` per pair, so an unreadable file can cost time but never hide drift.
- `claude/hooks/tests/harness-sync.test.sh`: case 3f adds 1000 tracked files to the sandbox checkout, times a no-drift run (median of three) against 60 bare bash+jq spawns timed beside it, and checks that the batched path still reports no drift, still counts one edited plus one missing file as 2, and still repairs both.
- `claude/enforce/hook-hashes.txt` is regenerated for the changed hook.

## Architectural decisions

- **Chosen: two `git hash-object --stdin-paths` processes per SessionStart.** Git is already required by the hook, the command exists on every git version the harness supports, and `--no-filters` hashes the raw bytes, which is exactly what `sync.sh` copies and what `cmp` compared. **Alternative:** an `rsync --dry-run --checksum --itemize-changes` over the tracked list. **Why not:** the drift check runs before the hook knows whether rsync is installed (a fresh cloud container installs it only when drift is found), so the check must not depend on it. **Alternative:** `shasum` or `sha256sum` through `xargs`. **Why not:** the two tools differ between macOS and Linux, and git is uniform.
- **One pass over all three payloads, not one per payload.** The first batched version kept the per-payload function and measured 245 ms against a 300 ms budget in the new case, because each pass paid its own `git ls-files`, two hash processes, and several subshells. Routing each tracked path to its live tree by its first path component brought the same case to 163 ms.
- **Plain newline-separated strings, not arrays.** macOS runs the hooks under bash 3.2, which has no namerefs, and an empty array under `set -u` is an error there.
- **The budget in the new case is expressed in bare spawns.** A per-file loop costs roughly one spawn per file (the case measured 1400 ms against a 270 ms budget before the fix), while the batched check costs a handful, so the case separates the two shapes under any load without timing an absolute number.
- **Out of scope, reported instead:** the Write|Edit chain's thin margin, where `protected-path-guard.sh` issues about a dozen `jq`, `dirname`, and `basename` spawns before it knows the path lies outside any repository. That is a separate change to a guard with its own fixture suite, and it belongs in its own PR.

## Testing

- Red first: with only case 3f added, `bash claude/hooks/tests/harness-sync.test.sh` printed `no-drift check over 1000+ tracked files: 1400ms (budget 270ms, 60 bare spawns)` and `FAIL: the no-drift check does not spawn once per tracked file`.
- Green: after the change it printed `no-drift check over 1000+ tracked files: 163ms (budget 270ms, 60 bare spawns)` and `harness-sync.test.sh PASS`.
- `bash sync-tests/sync.test.sh`, `bash claude/enforce/tests/run-tests.sh`, and `bash claude/hooks/tests/run-tests.sh` pass; `shellcheck --severity=error` is clean; both translator `--check` runs are clean.
- `hook-latency.test.sh` times the installed chain, so it cannot see this branch; it will measure the change only after `./sync.sh` installs it, and even then its sandboxed SessionStart never reaches the drift check.

## Reflection

The ticket's hypothesis was that the `rule_fires.md` drift made SessionStart slow, and it did add a full sync after every session end, but measuring the no-drift case showed a larger fixed cost underneath that nothing had ever timed, because the latency test sandboxes HOME in a way that makes `harness-sync.sh` exit early. The first batched version still paid its process cost three times over, which the new case caught at 245 ms against a 300 ms budget before it could ship.
