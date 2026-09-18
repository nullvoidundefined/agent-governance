# Keep Cursor synthetic session ids distinct when sanitizing collides

## Summary

#39 gave the Cursor adapter a synthetic `transcript_path` so that `session-start.sh` records an R-503 start per Cursor conversation. Copilot's review of #39 found that the session id in that path reused `SAFE_ID`, the findings-file name component, which replaces every character outside `A-Za-z0-9_.-` with `_`. Two conversation ids such as `conv/a` and `conv_a` therefore named the same write-once record, and the second conversation would have inherited the first conversation's `started_at`. #39 was merged before this fix was pushed, so it lands here on its own.

## What changed

- `cursor/hooks/claude-hook-adapter.sh`: an id that sanitizing leaves unchanged is still used as it is, so the `## Session start (R-503)` block keeps naming a readable conversation. An id that sanitizing changed gets a 16-character digest of the raw id appended, which keeps two colliding ids apart. The digest code that already hashed the workspace root is now a shared `digest_text` helper.
- `claude/enforce/tests/cursor-adapter-contract.test.sh`: starts `conv/gamma` and `conv_gamma` in one workspace and asserts two records. It also starts `conv-alpha` under a second workspace root and asserts a second `cursor-<hash>` directory with its own record. Copilot noted the contract only ever used one workspace, so a constant hash would have passed.

## Architectural decisions

- **Append a digest only when sanitizing changed the id**, rather than always hashing the id. Always hashing would also be collision-free, but it would turn every readable conversation id in the context block into an opaque digest, and the common case (an id that is already filename-safe) needs no protection.
- **A separate PR rather than a follow-up commit on #39's branch.** #39 had already been squash-merged, so a commit on its branch could never reach `main`.

## Testing

- The collision case failed before the fix, with three records where four were expected, and passes after it. The second-workspace case passed before the fix, because the workspace hash was already correct. It exists so a regression to a constant hash cannot pass.
- `claude/hooks/tests/run-tests.sh` and `claude/enforce/tests/run-tests.sh`, both run with stdin closed and `CLAUDE_PROJECT_DIR` set as the Stop gate sets it: all pass.

## Reflection

- The fix was first committed on #39's branch after that PR had merged. The push output said `[new branch]`, which was the signal that the branch had been deleted on merge. It was re-landed here by cherry-pick onto `main`.
- That first push also went out while an enforce-suite run was red, on a hook-latency margin in a hook chain this change does not touch. The suite was printed and the push chained in one command, so the result was never read. The latency case passes when run alone, and the suite for this branch was read green before pushing.

Ticket: IAN-91.
