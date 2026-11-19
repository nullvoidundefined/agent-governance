---
name: qwen-implementer-dispatch
description: Use when tdd-gated-dispatch routes a standard-risk GREEN to the secondary agent (`route.sh implement --risk standard` prints qwen) and the owner agreed to delegate for this plan. Runs one GREEN attempt on the local Qwen model with enforce/qwen-implementer-dispatch.sh and reads its verdict.
---

# Qwen implementer dispatch

One command runs one GREEN attempt on the local model and reports a result you do not have to take on trust. Use it only when all three hold: the RED commit exists, `bash ~/.claude/enforce/route.sh implement --risk standard` printed `qwen`, and the owner said yes to delegating for this plan. Otherwise the primary `implementer` agent does the GREEN.

## 1. Build the prompt file

Write a prompt file in the scratchpad. It holds, in this order:

- The `implementer` agent's contract: make the RED tests pass with the minimum change, reuse existing code before adding any, never edit tests, specs or the lock, and raise `DISPUTE: <test>: <why>` instead of changing a test.
- The failing test names and the exact test command.
- The branch and head sha.
- "Do not commit. Do not install packages. Do not touch anything outside this repository."

## 2. Run it

```bash
bash ~/.claude/enforce/qwen-implementer-dispatch.sh --repo <root> --red <RED sha> \
  --prompt <prompt file> --log <scratch>/qwen.log --test-cmd "<test command>"
```

Run it in the background with stdin closed; a run can take up to `QWEN_DISPATCH_TIMEOUT_SECONDS` (default 1800). Keep the log outside the repository. The script never commits and never moves `HEAD`.

## 3. Read the verdict

Line 1 is the status, line 2 the reason.

| Status | Exit | Meaning |
|---|---|---|
| `green` | 0 | The test command passed and no protected path changed. Review the diff, then continue the loop. |
| `failed` | 1 | `tests-failed` (the last 60 lines of test output follow), `touched-protected-path` (line 2 names it), `timeout`, `turn-limit` or `process-error`. |
| `unavailable` | 3 | `no-secondary-configured`, `server-unreachable` or `model-missing`. Claude was never started. |
| usage error | 2 | A bad flag or a `--red` that is not a commit. Fix the call. |

On `failed` with `touched-protected-path`, discard the attempt's changes (back to the RED commit) before retrying. After one more attempt that also fails, or on `unavailable`, discard Qwen's changes back to the RED commit and dispatch the primary `implementer`; name the fallback in the PR.
