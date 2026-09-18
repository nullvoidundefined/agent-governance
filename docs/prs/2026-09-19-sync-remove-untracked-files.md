# sync.sh removes live files the repository stopped tracking, safely

Refs: IAN-116

## Summary

`sync.sh` never deleted anything, by design: an earlier version ran `rsync --delete` guarded by a hand-kept exclude list, and its first real run wiped live runtime state the list did not name. The cost of that choice was that a file the repository stopped tracking stayed in the live directory until someone removed it by hand, and orphaned hook and enforce files kept being reported by the live integrity check. This change adds removal that is an allowlist rather than a denylist: sync records what it installed, and it only ever removes a file it can prove it installed, that the repository no longer tracks, and that nobody has edited since.

## What changed

- `sync.sh` writes `<target>/.sync-manifest` on every run, one `<sha256>  <path>` line per installed file, sorted so an unchanged tree writes an identical manifest. Regular files are hashed in batches with `find -exec`; a tracked symlink is recorded as the hash of `symlink:<target>`, so it is compared by where it points.
- On the next run, `removeUntrackedInstalledFiles` looks only at paths the previous manifest lists and the new one does not. It removes such a live file only when its current hash equals the manifest's, prints each removal on stdout, and keeps any file whose hash differs, reporting it on stderr with a `KEPT:` line. A path that is absolute or has a `..` component is ignored, and after a removal `pruneEmptiedDirectories` walks up with `rmdir`, which refuses any directory that still holds something, so only directories the removal emptied can go.
- A run with no previous manifest removes nothing and writes the first manifest.
- The new manifest replaces the old one only after the copy succeeded, so a refused or failed run leaves the previous manifest in place for the next one.
- The header comment of `sync.sh` now describes the removal rule and its limits (R-332), and the statements that sync "never deletes" in `README.md`, `AGENTS.md`, `.cursor/rules/000-harness-bootstrap.mdc`, `claude/rulebook/reference.md` (and its generated Cursor port), `claude/SETUP.md`, and `claude/ISSUES.md` now say what it does instead.
- `claude/hooks/harness-sync.sh` carries sync.sh's `KEPT:` lines into the SessionStart context. The hook discards a successful sync's stderr, and harness-sync is how most syncs run, so without this the report would reach nobody. Its drift check compares only tracked files, so the untracked manifest never counts as drift and needed no change; `claude/enforce/README.md` says both.
- `claude/hooks/tests/harness-sync.test.sh` asserts the bootstrap writes the manifest, that the next run still reports no drift, and (case 3a) that a hook file edited live and then untracked is kept and named in the context.

## Architectural decisions

- **Chosen: a manifest allowlist with a content check.** A file is removed only when three independent facts agree, and each one fails safe: no manifest means no removals, an entry the repository still tracks is never a candidate, and a hash mismatch keeps the file. **Alternative:** `rsync --delete` with a better exclude list. **Why not:** that is the design that already deleted live state, because the list has to name every runtime path of three evolving tools. **Alternative:** remove any live file whose path the repository's history ever tracked. **Why not:** it would delete a file a tool or the user later wrote at the same path, which the content check rules out.
- **Kept files are reported once, then forgotten.** A live-edited file is left out of the new manifest, so later runs neither remove it nor repeat the warning; it has become the user's file. The alternative, carrying it forward in the manifest, would let a later run delete it if the user happened to restore the installed content.
- **The manifest lives in each target, not in the checkout.** Each live directory can then be checked against what was actually installed into it, whichever checkout did the installing, and a checkout moved or recloned does not lose the record.
- **The orphans that exist today are out of reach.** Files left behind before this change (the four named in `claude/ISSUES.md`, and the two judge files the ticket mentions) were installed before any manifest existed, so the first run cannot prove it installed them and removes nothing. They still need removing by hand once.
- **Not done here:** harness-sync does not treat "a manifest entry is no longer tracked" as drift, so a commit whose only change is a removal is applied at the next sync that something else triggers, or at a manual `./sync.sh`. In practice a removal commit also regenerates `claude/enforce/hook-hashes.txt` for hook and enforce files, which is itself drift.

## Testing

- Red first: with only the new cases in `sync-tests/sync.test.sh`, the file failed at its first new assertion with `FAIL: sync did not write .../live/claude/.sync-manifest`.
- The cases check that the manifest carries the exact `<sha256>  CLAUDE.md` line; that a removed tracked file at the top level, one in a nested directory, and one beside a live-only file are removed; that the emptied nested directories go while the directory holding the live-only file and that file stay; that a live-edited removed file is kept and named on stderr; that removals are named on stdout; that the new manifest no longer lists removed files; that a run with no previous manifest removes nothing and writes one; and that a manifest line naming `../outside.txt` does not remove the file outside the target. The existing cases (live-only runtime state survives, JSON refusal writes nothing, a second run is idempotent, untracked source content never ships) still pass.
- Case 3a in `claude/hooks/tests/harness-sync.test.sh` failed with `FAIL: a kept live-edited file is named in the context` before the hook forwarded `KEPT:` lines.
- Green: `bash sync-tests/sync.test.sh` prints `sync.test.sh PASS`, and `bash claude/hooks/tests/harness-sync.test.sh` passes with the new assertions.
- A sync of the real checkout into temporary targets wrote manifests of 365, 96, and 72 lines for `claude/`, `cursor/`, and `codex/`, 533 in total, which matches `git ls-files` for the three payloads.
- `bash claude/enforce/tests/run-tests.sh` and `bash claude/hooks/tests/run-tests.sh` pass; `shellcheck --severity=error` is clean; `node translate/cursor.mjs --check` was stale after the rulebook edit, so `--write` regenerated the port and both translator checks are now clean.

## Reflection

The earlier incident made "never delete" look like the only safe answer, but the danger was deleting on the strength of a guess about what a path was for. Recording what sync itself put there replaces the guess with a fact, and the content hash covers the one case the record cannot, a file changed after it was installed. The first version of the manifest filter used a `{64}` regex interval, which older mawk releases, Ubuntu's default awk, do not support, so the filter now checks the hash's length and characters without one.
