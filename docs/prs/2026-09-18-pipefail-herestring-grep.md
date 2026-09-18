# Replace `printf | grep -q` membership checks with here-strings

## Summary

Many fixtures and hooks in this repo check whether a variable contains a pattern by writing `printf '%s\n' "$VAR" | grep -q PATTERN`. When `grep -q` finds its match it exits at once, and if `printf` is still writing at that point, `printf` receives SIGPIPE. Under `set -o pipefail` the pipeline then returns the writer's non-zero status, so a match reads as a miss. The output only has to be larger than what the pipe and grep's first read can hold, roughly 64KB, for this to happen. On 2026-09-18 it falsely failed `hook-hashes-closure.test.sh` in CI once the suites began running in parallel, and PR #42 fixed three files by moving to here-strings (`grep -q PATTERN <<< "$VAR"`).

This PR converts the remaining 175 sites in 70 files. With a here-string, bash supplies the input itself before grep starts, so no writer process exists that could be killed. The same bug was live in hooks as well as fixtures, and two of those hooks are security guards. `redact-output.sh` runs under `set -euo pipefail` and decided whether to redact with `if printf '%s' "$RESPONSE" | grep -qE "$PATTERN"`, so a leaked token in the first lines of a tool output over about 64KB went unreported. `secret-scan.sh` had the same shape on the text it scans before a write.

## What changed

- Every `printf '%s' "$VAR" | grep -<flags with q> ARGS` and `printf '%s\n' "$VAR" | grep -<flags with q> ARGS` under `claude/` is now `grep -<flags> ARGS <<< "$VAR"`. That covers 38 files in `claude/enforce/tests/` and `claude/hooks/tests/`, 27 hooks in `claude/hooks/`, `claude/enforce/tdd.sh`, `claude/enforce/settings-permission-rules.sh`, and three skill scripts. Negations keep their `!` (`! printf ... | grep -q X` became `! grep -q X <<< "$VAR"`), and line continuations keep the `\` at the end of the line, after the here-string.
- `claude/enforce/tests/redact-output.test.sh` gains the regression case. It builds a tool response of about 300KB with a runtime-built fake token on the first line, confirms the payload exceeds 64KB, runs the hook under the fixture's `set -euo pipefail`, and asserts that the output carries `[REDACTED]` and not the raw token.
- `codex/` and `cursor/` are regenerated with `node translate/codex.mjs --write` and `node translate/cursor.mjs --write`, because the three skill scripts are copied into both ports. `claude/enforce/hook-hashes.txt` is regenerated for every changed file.

## Architectural decisions

- **Here-string over `grep -q ... || true`-style workarounds or dropping pipefail.** Removing pipefail from a fixture would hide real failures elsewhere in the fixture, and switching to `grep ... >/dev/null` (reading all input) keeps a writer process that can still fail for other reasons. The here-string removes the writer entirely, it is the form PR #42 already chose, and it keeps every call site a single command.
- **The regression case lives in `redact-output.test.sh` rather than in a synthetic pipe demo.** A fixture that only pipes a large string into `grep -q` would prove a fact about bash, not about this repo. Testing the hook shows that the fix changes behaviour a user relies on: the hook now reports a leaked credential in long output where it previously stayed silent.
- **Converted `enforce/tdd.sh`, `settings-permission-rules.sh`, and the skill scripts too, although the task named only the test trees and hooks.** They carry the identical defect, `tdd.sh` runs under pipefail on test-runner output that can be large, and splitting a mechanical conversion of one pattern across two PRs would leave the same bug class half-fixed on `main`.

## Semantics check

The here-string appends exactly one newline, which is what `printf '%s\n'` writes, so those sites are byte-for-byte equivalent. `printf '%s'` writes no newline, which differs in only two cases: an empty variable (zero lines against one empty line), and a pattern that can match an empty line or a `-v` inversion. Every `printf '%s'` site was checked for both. No pattern can match an empty line, including the variable patterns (`PLACEHOLDER_VALUE`, `PATTERN`, `MUTATE`, `HOME_RE`, the `tdd.sh` classifiers), and the one `-v` site (`verification-gate.test.sh:149`) runs on output already asserted non-empty on the line before.

## Testing

- The new case was run five times against the pre-fix `redact-output.sh` (a copy served through `CLAUDE_HARNESS_ROOT`) and failed all five with `a token on the first line of output over 64KB went undetected`. Against the fixed hook it passed all five times.
- `bash -n` passes on every changed file.
- `bash claude/enforce/tests/run-tests.sh </dev/null`: `ALL ENFORCEMENT TESTS PASS`.
- `bash claude/hooks/tests/run-tests.sh </dev/null`: `ALL HOOK TESTS PASS`.
- `node translate/codex.mjs --check` and `node translate/cursor.mjs --check` both exit 0.

## Reflection

- The task framed this as a fixture flake, and most sites are fixtures, but the more serious instances were in the hooks. A secret-detection hook that misses secrets in long output is a silent security gap rather than a false CI failure, and nothing flagged it because every existing fixture used short inputs.
- The first conversion pass treated a trailing `\` line continuation as a grep argument and placed the here-string after it, which broke six files. `bash -n` over every changed file caught all six before anything ran.
- The first enforcement run failed every ESLint-backed fixture because this worktree's `claude/enforce/node_modules` predated the dependency change in #43. `npm ci --prefix claude/enforce` fixed it. The second run failed `skills-lint.test.sh` because the three skill scripts are mirrored into `cursor/` and `codex/`, and the translators regenerate those mirrors.
- 117 other `| grep -q` pipelines remain in which the upstream command is not `printf` of a variable, for example `jq ... | grep -q` and `head -1 | grep -q`. Most upstream commands there produce small output, but the ones that can emit more than 64KB under pipefail carry the same risk. They are out of this PR's scope and are recorded as follow-up work.
