# Audit the remaining pipefail grep -q pipelines

Refs: IAN-120

## Summary

Under `set -o pipefail`, a pipeline of the shape `producer | grep -q X` can report a match as a miss. `grep -q` exits at the first matching line, the producer then writes into a closed pipe and dies of SIGPIPE (status 141), and pipefail makes the whole pipeline return that nonzero status. The failure needs the producer to still have output to write after grep exits, which in practice means more than the 64KB pipe buffer after the match. PR #46 (IAN-99) removed the `printf '%s' "$VAR" | grep -q` form of this bug. This change audits every remaining `| grep -q` pipeline under `claude/hooks/`, `claude/enforce/`, and `claude/skills/**/scripts/` (89 sites), converts the six grep calls whose producer can realistically exceed 64KB (one in `protected-path-guard.sh`, two in `session-end.sh`, and three in `check.sh`, one class per file), and adds a regression case per class that drives the real hook or script with more than 64KB of producer output.

## What changed

- `claude/hooks/protected-path-guard.sh`: the package.json Edit check fed `jq -r` over the tool input's `old_string` and `new_string` into `grep -qE`. A large Edit that also changed the `test` script therefore passed silently instead of asking (R-410). The grep now reads the jq output through process substitution.
- `claude/hooks/session-end.sh`: the two dedupe checks fed `sed` over the whole `rule_fires.md` and `rule_misses.md` logs into `grep -qFx`. Once a log passed 64KB, a line the log already held read as absent and was appended again at every session end, so the logs would have grown by one duplicate per session per memory line. Both checks now read the sed output through process substitution.
- `claude/skills/spec-grounding/scripts/check.sh`: the Conflicts, Domain vocabulary, and Acceptance criteria checks fed the awk `section` extract into `grep -q`. On a section over 64KB, a present B-1 line or `chosen over:` entry was reported missing, and an uncited conflict bullet went unreported. All three now read the section through process substitution. The translated copies under `codex/` and `cursor/` are regenerated.
- Fixtures: `claude/enforce/tests/protected-path-guard.test.sh`, `claude/hooks/tests/session-end.test.sh`, and `claude/enforce/tests/spec-grounding-check.test.sh` each gain a case with more than 64KB of producer output after the match.
- `claude/enforce/hook-hashes.txt` is regenerated for the two changed hooks.

## Inventory

Method: every line under `claude/` (excluding `enforce/node_modules`) with a `| grep` whose flags include `q` or `--quiet`, plus pipelines that continue onto a `| grep -q` line. A `grep -q` that reads a named file rather than a pipe has no producer to kill and is not listed; a `grep -q ... <<< "$VAR"` here-string is already the IAN-99 form and is not listed. The ticket's figure of about 117 predates the exact count; this search finds 89 pipelines. None of the files the concurrent sync work owns (`sync.sh`, `claude/hooks/harness-sync.sh`, `claude/enforce/install-enforce-dependencies.sh`, `sync-tests/sync.test.sh`) contains such a pipeline; `claude/hooks/tests/harness-sync.test.sh:33` does, but its producer is a small hook context string, so nothing is deferred.

### Hooks and scripts (production code)

| Site | Producer | pipefail | Can exceed 64KB | Action |
|---|---|---|---|---|
| `hooks/protected-path-guard.sh:182` | `jq -r` over an Edit's `old_string` and `new_string` | yes (`set -uo pipefail`) | yes: an Edit's strings are unbounded | converted to `grep -qE ... < <(printf \| jq)` |
| `hooks/session-end.sh:90` | `sed` over `rule_fires.md` | yes (`set -euo pipefail`) | yes: an append-only log | converted to `grep -qFx ... < <(sed ...)` |
| `hooks/session-end.sh:103` | `sed` over `rule_misses.md` | yes | yes: an append-only log | converted, same form |
| `skills/spec-grounding/scripts/check.sh:76` | `section` (awk over the spec) piped through `grep -E '^- '` into `grep -vqE` | yes (`set -uo pipefail`) | yes: a user-written spec section | converted to `grep -vqE ... < <(section ... \| grep -E ...)` |
| `skills/spec-grounding/scripts/check.sh:84` | `section "Domain vocabulary"` | yes | yes | converted |
| `skills/spec-grounding/scripts/check.sh:91` | `section "Acceptance criteria"` | yes | yes | converted |
| `hooks/destructive-command-guard.sh:65` | `printf '%s' "$norm"` | yes (`set -uo pipefail`) | yes, but cannot fail | safe: `$norm` has every newline translated to `;`, so it is a single line, and grep must read to the end of a line before it can report that line as a match. The producer has finished writing by the time grep exits. Checked empirically with a 200KB command whose `curl \| sh` sits at the start: the hook denies. |

Line numbers are those on `main` before this change.

### Fixture tests

Every fixture under `claude/enforce/tests/` and `claude/hooks/tests/` runs under `set -uo pipefail` or `set -euo pipefail`, so the pipefail column is yes for every row below. In each, the producer is a hook's JSON output, a jq field of it, `tdd.sh` output, or an awk or head over a sandbox file the fixture itself wrote in a few lines, so none can approach 64KB. The one fixture that does drive more than 64KB through a hook (`redact-output.test.sh`, the IAN-99 regression) reads the result with here-strings. Every row is therefore safe and unchanged. Line numbers are those after this change.

| Site | Producer |
|---|---|
| `enforce/tests/pr-ticket-ref-gate.test.sh:41` | `jq -r '.hookSpecificOutput \| (.permissionDecisionReason // "") + (....` |
| `enforce/tests/observability-reminder.test.sh:23` | `ctx "$OUT"` |
| `enforce/tests/observability-reminder.test.sh:33` | `ctx "$OUT"` |
| `enforce/tests/observability-reminder.test.sh:34` | `ctx "$OUT"` |
| `enforce/tests/observability-reminder.test.sh:39` | `ctx "$OUT"` |
| `enforce/tests/task-cleanup-scan.test.sh:17` | `printf '%s' "$OUT" \| grep -E "$1"` |
| `enforce/tests/redact-output.test.sh:13` | `printf '%s' "$OUT" \| jq -r '.hookSpecificOutput.additionalContext'` |
| `enforce/tests/redaction-guard-check.test.sh:16` | `printf '%s' "$OUT" \| jq -r '.hookSpecificOutput.additionalContext'` |
| `enforce/tests/cursor-adapter-contract.test.sh:112` | `printf '%s' "$2" \| jq -r '.user_message // ""' 2>/dev/null` |
| `enforce/tests/cursor-adapter-contract.test.sh:169` | `printf '%s' "$2" \| jq -r '.additional_context // ""' 2>/dev/null` |
| `enforce/tests/cursor-adapter-contract.test.sh:171` | `[ "$(start_records` |
| `enforce/tests/cursor-adapter-contract.test.sh:172` | `[ "$(find "$SANDBOX_HOME/.claude/projects" -name '*.jsonl' 2>/dev/null` |
| `enforce/tests/cursor-adapter-contract.test.sh:173` | `start_records \| head -1` |
| `enforce/tests/cursor-adapter-contract.test.sh:207` | `[ "$(start_records \| sed -E 's#/session-start\.[^/]*$##' \| sort -u` |
| `enforce/tests/push-feature-docs-gate.test.sh:26` | `printf '%s' "$OUT" \| jq -r '.hookSpecificOutput.permissionDecisionR...` |
| `enforce/tests/clean-code-reminder.test.sh:17` | `printf '%s' "$OUT" \| jq -r '.hookSpecificOutput.additionalContext'` |
| `enforce/tests/clean-code-reminder.test.sh:31` | `printf '%s' "$OUT" \| jq -r '.hookSpecificOutput.additionalContext'` |
| `enforce/tests/clean-code-reminder.test.sh:45` | `printf '%s' "$OUT" \| jq -r '.hookSpecificOutput.additionalContext'` |
| `enforce/tests/translate-codex.test.sh:21` | `head -1 "$1"` |
| `enforce/tests/translate-codex.test.sh:25` | `awk 'NR>1 && /^---$/ {getline; print; exit}' "$1"` |
| `enforce/tests/convention-track-invariants.test.sh:50` | `' "$root/rules/session-types.md"` |
| `enforce/tests/convention-track-invariants.test.sh:54` | `' "$root/CLAUDE-FRONTEND.md"` |
| `enforce/tests/tdd-red-green.test.sh:56` | `expect_fail "red without open" bash "$TDD" red src/__tests__/score....` |
| `enforce/tests/tdd-red-green.test.sh:67` | `expect_fail "red on a passing test" bash "$TDD" red src/__tests__/s...` |
| `enforce/tests/tdd-red-green.test.sh:72` | `expect_fail "red on a skipped test" bash "$TDD" red src/__tests__/s...` |
| `enforce/tests/tdd-red-green.test.sh:76` | `expect_fail "red on a syntax error" bash "$TDD" red src/__tests__/s...` |
| `enforce/tests/tdd-red-green.test.sh:80` | `expect_fail "red on an empty test file" bash "$TDD" red src/__tests...` |
| `enforce/tests/tdd-red-green.test.sh:85` | `expect_fail "red with a red suite" bash "$TDD" red src/__tests__/sc...` |
| `enforce/tests/tdd-red-green.test.sh:97` | `bash "$TDD" validate test-author` |
| `enforce/tests/tdd-red-green.test.sh:98` | `expect_fail "validate implementer while red" bash "$TDD" validate i...` |
| `enforce/tests/tdd-red-green.test.sh:100` | `expect_fail "validate test-author with a production write" bash "$T...` |
| `enforce/tests/tdd-red-green.test.sh:102` | `expect_fail "validate an unknown role" bash "$TDD" validate nobody` |
| `enforce/tests/tdd-red-green.test.sh:111` | `expect_fail "green while the test still fails" bash "$TDD" green` |
| `enforce/tests/tdd-red-green.test.sh:124` | `bash "$TDD" validate implementer` |
| `enforce/tests/tdd-red-green.test.sh:126` | `expect_fail "validate implementer after a test write" bash "$TDD" v...` |
| `enforce/tests/tdd-red-green.test.sh:129` | `bash "$TDD" validate slice-critic` |
| `enforce/tests/tdd-red-green.test.sh:131` | `expect_fail "validate slice-critic after any write" bash "$TDD" val...` |
| `enforce/tests/tdd-red-green.test.sh:136` | `expect_fail "green on a tampered test" bash "$TDD" green` |
| `enforce/tests/tdd-red-green.test.sh:141` | `expect_fail "green with a deleted baseline test" bash "$TDD" green` |
| `enforce/tests/tdd-red-green.test.sh:159` | `expect_fail "open --refactor on a red tree" bash "$TDD" open --refa...` |
| `enforce/tests/tdd-red-green.test.sh:181` | `expect_fail "green after tampering a refactor-locked test" bash "$T...` |
| `enforce/tests/tdd-red-green.test.sh:191` | `bash "$TDD" status` |
| `enforce/tests/tdd-red-green.test.sh:224` | `expect_fail "green with a file-level failure" bash "$TDD" green` |
| `enforce/tests/tdd-red-green.test.sh:258` | `expect_fail "shell red on a passing fixture" bash "$TDD" red tests/...` |
| `enforce/tests/tdd-red-green.test.sh:260` | `expect_fail "shell red on a silent fixture" bash "$TDD" red tests/s...` |
| `enforce/tests/tdd-red-green.test.sh:262` | `expect_fail "shell red on a syntax error" bash "$TDD" red tests/sco...` |
| `enforce/tests/tdd-red-green.test.sh:268` | `expect_fail "shell red with a red sibling" bash "$TDD" red tests/sc...` |
| `enforce/tests/tdd-red-green.test.sh:273` | `expect_fail "red mixing runners" bash "$TDD" red tests/score.test.s...` |
| `enforce/tests/tdd-red-green.test.sh:290` | `expect_fail "shell green while failing" bash "$TDD" green` |
| `enforce/tests/tdd-red-green.test.sh:296` | `expect_fail "shell green with a deleted sibling" bash "$TDD" green` |
| `enforce/tests/tdd-red-green.test.sh:300` | `expect_fail "shell green with a sibling exiting non-zero" bash "$TD...` |
| `enforce/tests/prose-flags.test.sh:45` | `check "count line last" bash -c "printf '%s' \"\$0\" \| tail -1` |
| `enforce/tests/feature-create-scaffold.test.sh:26` | `awk -v h="## $2" '$0 == h { on = 1; next } on && /^## / { exit } on...` |
| `enforce/tests/feature-create-scaffold.test.sh:63` | `check "B-21 row not in the Account section" bash -c "! awk '/^## Ac...` |
| `enforce/tests/feature-create-scaffold.test.sh:81` | `check "B-21 new section after the existing ones" bash -c "awk '/^##...` |
| `enforce/tests/spec-inventory.test.sh:13` | `printf '%s' "$OUT" \| grep -F "$1 \|"` |
| `enforce/tests/protected-path-guard.test.sh:40` | `printf '%s' "$out" \| jq -r '.hookSpecificOutput.permissionDecisionR...` |
| `enforce/tests/flat-directory-reminder.test.sh:13` | `printf '%s' "$OUT" \| jq -r '.hookSpecificOutput.additionalContext'` |
| `enforce/tests/flat-directory-reminder.test.sh:25` | `printf '%s' "$OUT" \| jq -r '.hookSpecificOutput.additionalContext'` |
| `enforce/tests/dependency-add-guard.test.sh:17` | `"$HOOK" \| jq -r '.hookSpecificOutput.permissionDecisionReason // ""'` |
| `enforce/tests/codex-adapter-contract.test.sh:174` | `printf '%s' "$2" \| jq -r '.hookSpecificOutput.permissionDecisionRea...` |
| `enforce/tests/codex-adapter-contract.test.sh:175` | `printf '%s' "$2" \| jq -r '.hookSpecificOutput.additionalContext // ...` |
| `enforce/tests/dockerfile-reminder.test.sh:28` | `ctx "$OUT"` |
| `enforce/tests/dockerfile-reminder.test.sh:38` | `ctx "$OUT"` |
| `enforce/tests/dockerfile-reminder.test.sh:39` | `ctx "$OUT"` |
| `enforce/tests/dockerfile-reminder.test.sh:45` | `ctx "$OUT"` |
| `enforce/tests/dockerfile-reminder.test.sh:53` | `ctx "$OUT"` |
| `enforce/tests/dockerfile-reminder.test.sh:66` | `ctx "$OUT"` |
| `enforce/tests/dockerfile-reminder.test.sh:67` | `ctx "$OUT"` |
| `enforce/tests/dockerfile-reminder.test.sh:68` | `ctx "$OUT"` |
| `enforce/tests/dockerfile-reminder.test.sh:80` | `ctx "$OUT"` |
| `enforce/tests/dockerfile-reminder.test.sh:95` | `ctx "$OUT"` |
| `enforce/tests/repo-setup.test.sh:155` | `check "B-16 check names $f" bash -c "printf '%s' \"\$0\" \| grep -E ...` |
| `hooks/tests/migration-defaults-guard.test.sh:42` | `[ -n "$(run_hook "$@")" ] && run_hook "$@"` |
| `hooks/tests/harness-sync.test.sh:33` | `context` |
| `hooks/tests/new-file-header-reminder.test.sh:26` | `run_hook "$@"` |
| `hooks/tests/hookspath-drift-check.test.sh:35` | `run_in "$1"` |
| `hooks/tests/global-repo-push-guard.test.sh:65` | `run_guard "$@"` |
| `hooks/tests/spec-glossary-check.test.sh:26` | `run_hook "$@"` |
| `hooks/tests/spec-glossary-check.test.sh:27` | `shift; run_hook "$@" \| jq -r '.hookSpecificOutput.additionalContext'` |
| `hooks/tests/spec-glossary-check.test.sh:28` | `shift; ! run_hook "$@" \| jq -r '.hookSpecificOutput.additionalConte...` |
| `hooks/tests/spec-glossary-check.test.sh:90` | `run_hook "$@" \| jq -r '.hookSpecificOutput.additionalContext'` |

## Architectural decisions

- **Chosen: process substitution, `grep -q X < <(producer)`.** Bash does not fold a process substitution's exit status into the command's status, so the producer's SIGPIPE is invisible, and the grep keeps its early exit. The rewrite is one line per site and changes nothing else about the check. **Alternative: capture then here-string, `out=$(producer); grep -q X <<< "$out"`,** the form IAN-99 used. **Why not here:** the producers here are commands, not variables already in memory, so capturing would buffer a whole log or spec just to search it, and at `check.sh:76` it would change behavior, because a here-string of an empty capture is one empty line, which `grep -v` selects, so a spec with no conflict bullets would start failing. **Alternative: make the producer decide the match itself** (for example `jq -e` with a `test()` filter). **Why not:** that works for the jq site only, rewrites the match logic in a second regex dialect, and leaves the sed and awk classes needing a different fix anyway.
- **Converted only what can fail.** A site was converted when it runs under pipefail, its producer can emit more than 64KB, and the output can continue past the match. The destructive-command-guard site meets the first two but not the third, because its producer is a single line; converting it would be harmless but would not be backed by a failing test, so it is recorded as safe instead.
- **One regression case per class, on the real hook or script.** Each case pushes at least 128KB of producer output past an early match, and two of them first assert the fixture really exceeds the pipe buffer, so a later edit that shrinks the fixture cannot turn the case into a silent pass.

## Testing

- Red first: with only the new cases added, `protected-path-guard.test.sh` failed with `package.json Edit over 64KB touching the test script asks: expected ask, got allow`; `session-end.test.sh` failed `fire not duplicated in a log over 64KB` and `miss not duplicated in a log over 64KB` while its size guard passed; `spec-grounding-check.test.sh` failed `grounded spec with sections over 64KB passes`, `B-1 found in an Acceptance criteria section over 64KB`, `chosen-over found in a Domain vocabulary section over 64KB`, `uncited conflict in a section over 64KB fails`, and `uncited conflict in a section over 64KB named`, while its size guard passed.
- Green: after the conversions, all three fixtures pass in full.
- `bash claude/enforce/tests/run-tests.sh` and `bash claude/hooks/tests/run-tests.sh` pass; `shellcheck --severity=error` over the hooks, the enforce scripts, `sync.sh`, and `check.sh` is clean; `node translate/codex.mjs --check` and `node translate/cursor.mjs --check` are clean after `--write`.

## Reflection

The first reproduction attempts passed when they should have failed, for two reasons worth recording. A filler built with `$(... | tr '\0' '\n')` was all newlines, and command substitution strips trailing newlines, so the "large" input was empty. And the destructive-command-guard probe never failed at any size, which is what showed that a single-line producer is immune: grep cannot call a line a match until it has read the whole line. The count also came out lower than the ticket's estimate of about 117, because most of the remaining sites live in fixtures whose producers are a few hundred bytes of hook output; the defect that mattered sat in three production files. A related shape, `producer | head -n 1` under pipefail, has the same SIGPIPE mechanics; it was not audited here because this ticket covers `grep -q` membership checks, and it would be a separate follow-up if any such site feeds a condition.
