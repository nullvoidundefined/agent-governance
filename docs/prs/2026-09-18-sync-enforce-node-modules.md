# PR: Install the enforce dependencies whenever a sync ships a changed lockfile

Branch: `fix/sync-enforce-node-modules`. Found 2026-09-18 by the Voyager 2.0 session; no tracker ticket was opened because the tracker connectors were unauthenticated in this session.

## Summary

Slice 01 PR 5 (#43, `ea13cfc`) added `vue-eslint-parser` and `eslint-plugin-vue` to `claude/enforce/package.json` and its lockfile, and `eslint.config.mjs` imports both. `sync.sh` copies only git-tracked files, so the new lockfile reached `~/.claude/enforce` while `~/.claude/enforce/node_modules` kept the old set. `node ~/.claude/enforce/lint.mjs` then crashed with `ERR_MODULE_NOT_FOUND`, and the ESLint push gate could lint no TypeScript or Vue repository until someone ran `npm ci --prefix ~/.claude/enforce` by hand. The harness-sync hook did not catch it either, because its install step ran only when `node_modules` was absent altogether, never when it was present but stale. This PR makes every sync bring the live install in line with the synced lockfile, and it makes the push gate name a broken bundle as a broken bundle.

## What changed

- **`claude/enforce/install-enforce-dependencies.sh` (new).** Given an enforce directory, it decides whether the install is current and runs `npm ci --prefix <dir>` when it is not. The install counts as current when a stamp written after the last successful install (`node_modules/.enforce-installed-lock`) matches the lockfile byte for byte, and every non-optional locked package directory exists. When npm is missing or `npm ci` fails, it exits 1 with a `FAILED:` line on stderr that names the exact command to run. `SYNC_NPM` overrides the npm executable so the fixtures run offline.
- **`sync.sh`** runs that script against the live enforce directory after the copy and after the `.sync-source` stamp. The files therefore stay synced even when the install fails, and `set -e` turns the failure into a nonzero exit.
- **`claude/hooks/harness-sync.sh`** replaces its old `npm install`-when-absent block. When files drifted, `./sync.sh` performs the install, and the hook now relays `sync.sh`'s stderr when the failure happened after the copy instead of claiming a JSON refusal. When nothing drifted, the hook runs the install script itself, so a stale install from before this change, or a package deleted by hand, is repaired at the next session start. It reports both an install and a failure in its context.
- **`claude/hooks/push-eslint-gate.sh`** recognizes `ERR_MODULE_NOT_FOUND` and "Cannot find package/module" in the linter output. It still denies the push, but the reason and a stderr line now say that the bundle is broken, not the diff, and they name `npm ci --prefix <enforce dir>`.
- **CI** gains a `Sync fixture` step, because `sync-tests/sync.test.sh` sits outside `claude/` and neither fixture runner reached it.
- The R-003 manifest note, the enforce README's harness-sync paragraph, `sync.sh`'s header, and `hook-hashes.txt` are updated to match.

## Architectural decisions

- **One script, called from both entry points, instead of logic inside `sync.sh`.** The harness-sync hook runs `./sync.sh` only when a tracked file drifted, so a check that lived only in `sync.sh` would never repair a stale install once the files already matched, which is exactly the state every machine that synced #43 is in now. A shared script keeps the staleness rule in one place. The alternative, duplicating the check in the hook, would let the two copies drift apart.
- **A lockfile stamp plus a directory check, rather than comparing against npm's hidden `node_modules/.package-lock.json`.** npm's hidden lockfile omits and reshapes fields relative to `package-lock.json`, so an exact comparison would be fragile across npm versions. The stamp catches version bumps, and the directory check catches a deleted package. The cost is one extra `npm ci` on each machine the first time this runs, since existing installs carry no stamp yet.
- **`npm ci`, never `npm install`.** The old hook ran `npm install`, which can resolve differently from the committed lockfile. CI already moved to locked installs for the same reason (2026-09-18 audit, finding 8).
- **The push gate was not failing open.** The crash text filled `REPORT`, so the gate denied every push. The defect was the message, which told the pusher to fix ESLint violations that did not exist. The fix keeps the deny and changes only what it says.
- **No separate Cursor or Codex change.** Neither port carries its own enforce bundle; both adapters invoke the `~/.claude/hooks` scripts, including `harness-sync` and `push-eslint-gate`, so they share the one live `~/.claude/enforce` install that this PR repairs. Both `translate/*.mjs --check` runs are clean.

## Testing

- `sync-tests/sync.test.sh` gains cases for a first install, an unchanged complete install that must not rerun npm, the regression itself (the source lockfile adds `vue-eslint-parser` and the destination lacks it), a locked package missing from an unchanged install, npm unavailable (nonzero exit, the command named, the files still synced), and npm failing (nonzero exit, then recovery on the next sync). The first case failed before the fix with `FAIL: first sync did not install the locked enforce dependencies`.
- `claude/hooks/tests/harness-sync.test.sh` gains cases for the drift path installing, the no-drift path repairing a missing package and reporting it, and an unavailable npm reported with the command. All three failed before the fix.
- `claude/enforce/tests/push-eslint-gate.test.sh` gains a case that copies the harness without `node_modules`, pushes a change, and requires a deny whose reason names `npm ci --prefix` and does not say "Fix the violations". The last two assertions failed before the fix.
- The full enforcement suite and the full hook suite pass, `shellcheck --severity=error` is clean, and both port `--check` runs are clean.

## Reflection

The root cause was a boundary that the sync design stated explicitly and correctly, "only tracked files ship", without anything on the far side of it owning the untracked state that the tracked files depend on. The hook's install step looked like that owner, but it keyed on the directory's existence rather than on its contents, so it could only ever handle a fresh machine. The first version of the plan put the whole check inside `sync.sh`, and it was only when reading the hook's drift logic that it became clear the machines already affected would never trigger a sync again, which is why the check moved into a script the hook can call on its own. Implementation took roughly forty minutes from the first failing fixture to a green suite.
