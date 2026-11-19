---
name: qwen-implementer-dispatch
description: Use when tdd-gated-dispatch routes a standard-risk GREEN to the secondary agent (`route.sh implement --risk standard` prints qwen) and the owner agreed to delegate for this plan. Runs one GREEN attempt on the local Qwen model with enforce/qwen-implementer-dispatch.sh and reads its verdict.
---

# Qwen implementer dispatch

One command runs one GREEN attempt on the local model and reports a result you do not have to take on trust. Use it only when all three hold: the RED commit exists, `bash ~/.claude/enforce/route.sh implement --risk standard` printed `qwen`, and the owner said yes to delegating for this plan. Otherwise the primary `implementer` agent does the GREEN.

## 1. Build the prompt file

Write a prompt file in the scratchpad. It holds, in this order:

- The `implementer` agent's contract: make the RED tests pass with the minimum change, reuse existing code before adding any, never edit tests, specs or the lock, and raise `DISPUTE: <test>: <why>` instead of changing a test.
- The failing test names and the exact test command. Write the stack's linter into the command after the tests, joined with `&&`, with an explicit list of target files or a glob that covers files Qwen may add (for shell, `<test cmd> && shellcheck enforce/*.sh`), so a lint failure comes back as `tests-failed` with its output.
- The branch and head sha.
- The standards checklist, copied verbatim:
  - Before adding a helper, constant or environment variable, search the repository for an existing one and reuse it.
  - After fixing a bug, search the whole repository for the same pattern. Fix every occurrence the failing tests exercise. Do not edit the others; list them in your final message (it lands in the log).
  - Match the neighboring files: naming, comment style, how they print or return values.
  - Every comment and message must be true in every case the code can reach, for example for each tier or each missing input.
  - Change nothing the failing tests do not ask for.
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
| `unavailable` | 3 | `no-secondary-configured`, `server-unreachable`, `model-missing` or `rules-missing` (the implementer rules file is absent). Claude was never started. |
| usage error | 2 | A bad flag or a `--red` that is not a commit. Fix the call. |

On `failed` with `touched-protected-path`, discard the attempt's changes (back to the RED commit) before retrying. After one more attempt that also fails, or on `unavailable`, discard Qwen's changes back to the RED commit and dispatch the primary `implementer`; name the fallback in the PR.

## 4. Fixing review findings

Use this when Qwen wrote the GREEN and the one review left a HIGH or MEDIUM that needs a code change. It is one attempt, not a loop.

1. Commit Qwen's GREEN first, so the fix is a separate ordinary `fix:` commit.
2. Build a new prompt file with the same contract, standards checklist, test command (linter included) and branch and head as in section 1, plus a "Findings to fix" block: for each finding its severity, `file:line`, the defect, the failure scenario or evidence, and any fix the reviewer suggested, copied verbatim. Add: "Fix only these findings. Change nothing else. List any you decline, with the reason, in your final message."
3. Run the script as in section 2 with the same `--red` sha, so the protected-path check covers everything since RED.
4. On `green`, read the diff: confirm each finding is fixed and nothing else changed, then commit and rerun only the checks the fix affects. On `failed` or `unavailable`, discard Qwen's changes back to the committed GREEN and have the primary `implementer` make the fix; name the fallback in the PR.

A finding answered with a reason, and every LOW, is never sent to Qwen. A LOW the owner asked to fix from its ticket is a new slice, with its own prompt built this way.
