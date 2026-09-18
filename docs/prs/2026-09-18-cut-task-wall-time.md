# Cut per-task wall time: CI rule judge, a lighter pre-push, related tests in application repos, and a trivial fast path

**Ticket:** IAN-98
**Branch:** `feat/cut-task-wall-time`
**Spec:** `claude/docs/superpowers/specs/2026-09-18-task-wall-time-design.md`
**Plan:** `docs/slices/slice-03-task-wall-time.md`

## Summary

A transcript analysis of 31 sessions between 2026-09-04 and 2026-09-18 measured about 83 hours of tool wait time against about 5.4 hours of model generation. `git push` alone averaged 171 seconds across 326 pushes, because every push ran the full fixture suite locally and sent the diff to the Anthropic API through the LLM rule judge. CI then ran the same full suite again. Polling for CI and Copilot added 739 minutes, and the turn-end gate reran the full suite 1,323 times. This PR removes the parts of that wait that duplicate work done elsewhere:

- The LLM rule judge moves off the push path. It now runs as the `rule-judge` GitHub Actions check on each pull request.
- The pre-push hook stops running the fixture suites. It keeps only the Cursor and Codex port checks, which take seconds, and the full suite remains the required `fixtures` CI check.
- In application repositories, the turn-end gate now runs only the tests related to the changed files (vitest, jest, pytest, Go). PR #42 already did the same for this repository's fixtures.
- A trivial-tier PR skips the ticket, the PR document, and the Copilot review, and it merges on green CI.

## What changed

- `claude/enforce/judge-diff.sh` (new) holds the judge's diff-and-verdict core, moved verbatim from `hooks/llm-rule-judge.sh`. It is called as `judge-diff.sh <base> <head>`. It exits 1 and prints one `<rule> [<file>]: <why>` line per error-severity finding, and it prints warnings as `::warning::` annotations under GitHub Actions. With no API key it passes with a notice. The PreToolUse hook `hooks/llm-rule-judge.sh` is deleted and unregistered from `settings.json`, and the manifest's five judge rules now name the enforcer `ci:llm-rule-judge`.
- `.github/workflows/rule-judge.yml` (new) runs the judge on `pull_request`. It is also callable from other repositories through `workflow_call`, in which case it checks this repository's judge out beside the caller's code.
- `hooks/enforcement-guard-check.sh` no longer warns at session start when no local judge key exists. The judge's key is now a repository secret, so a missing local key no longer degrades anything, and the warning told users to provision a key nothing would read.
- `hooks/pre-push.sample` drops the fixture-suite loop and keeps the port checks. `hooks/tests/pre-push-sample.test.sh` and `install-git-hooks.test.sh` pin the new contract: red suites do not block a push, and a red port check does.
- `claude/enforce/related-tests.sh` (new) is the related-test mapping for application stacks:
  - vitest uses `vitest related --run`, and jest uses `--findRelatedTests`. Both pass `--passWithNoTests`.
  - pytest runs the matching `test_<module>.py` or `<module>_test.py`.
  - Go runs `go test` and `go vet` on the changed packages.
  - It falls back to the full suite when it cannot place a changed file, or when a manifest, lockfile, or test config changed. Every file name is shell-quoted, and a fixture proves that a hostile name is never executed.
- `hooks/verification-gate.sh` routes the package.json, pytest, and Go branches through that mapping. The governance branch keeps PR #42's `--affected`.
- The rule text changes to match:
  - R-509 in `CLAUDE.md` and `rulebook/reference.md` drops "at pre-push" from #42's wording.
  - R-514 gains the trivial fast path.
  - `[judge]` now names the CI judge.
  - The task-start and task-cleanup skills describe the trivial path.
  - The READMEs and the Go, Ruby, and Python convention files describe the judge as a CI check.
  - `enforce/tests/wall-time-rule-text.test.sh` pins that wording in the source files and in the generated Cursor rules.

## Decisions

| Decision | Chosen | Alternatives | Why |
|---|---|---|---|
| Where the judge and the full suite run | CI only | Skip them only on docs-only diffs; both | Code pushes would still pay about three minutes under the skip option, and CI already runs the full suite as a required check. |
| Trivial-tier PRs | Own PR, no ticket, no PR doc, no Copilot wait | A daily batch PR; direct pushes to `main` | The batch delays each fix until it ships. A direct push skips CI before the change lands on `main`. |
| Where the full suite runs after turn-end targeting | CI only | Once before each push; escalate on shared paths | Running it once per push brings back one to three minutes per push. The shared-path list would need its own maintenance. |
| Reconciling with PR #42 | Rebase and keep #42's `--affected` for this repository | Keep this branch's basename mapping | #42's `# Watches:` globs select fixtures more precisely than a basename grep, and #42 had already merged. |
| Node stacks with no related test | Pass (`--passWithNoTests`) | Fall back to the full suite | The runner resolves the import graph at run time, so the helper cannot know the set is empty in advance. The CI full suite catches whatever is missed. |
| Making `rule-judge` a required check | Not yet | Required now; never | A required check that has never reported blocks every PR. It becomes required once the secret is set and it has run green. |

## Testing

- `claude/enforce/tests/judge-diff.test.sh`: every case from the former `llm-rule-judge.test.sh` is kept, with each one's intent preserved. The translation: "ask" became exit 1 plus the finding on stdout, and "allow" became exit 0 with empty stdout. New cases cover the stdout finding line and the `::warning::` annotation.
- `claude/enforce/tests/related-tests.test.sh`: seven cases for vitest, jest with pnpm, pytest (both a match and a fallback), Go, a hostile filename, and an unknown stack.
- `claude/enforce/tests/verification-gate.test.sh`: invariants 13 and 14. A vitest project runs `vitest related` on the changed file and not `npm test`, and a changed `package.json` runs the full suite.
- `claude/enforce/tests/enforcement-guard-check.test.sh` asserts silence when no local key exists.
- The pre-push fixtures are described under "What changed".
- Both full sharded suites were run after the final rebase onto `b6a2ebc`. 104 of 105 fixtures pass. The one failure is `hook-latency.test.sh`, which times the installed `~/.claude` hook chain, not this checkout. It failed only while the machine's load average was between 62 and 142, with several sessions running suites at once. It passed alone at 266 ms against a 400 ms budget. It also failed and passed alternately when this branch and a clean `main` checkout were run back to back, which confirms that it measures load, not this change.
- `actionlint` is not installed on this machine, so the workflow was checked only by parsing it with Ruby's YAML loader.

## Reflection

Time since implementation started: about 68 minutes. The executing-plans start was at 2026-09-18T14:26Z, and this document was written at 15:34Z.

What I understand now: most of the wait around a task was the same verification running in two or three places, and the fix was to choose one place for each check. Choosing CI for the expensive checks is only safe because branch protection requires `fixtures`. I verified that before removing the local suite.

What I got wrong first:
- I built this repository's related-test mapping without checking what had landed on `main` since the branch was cut. PR #42 had already solved that half, and more precisely, which cost a rebase and a rework of three commits.
- The Task 5 commit changed the pre-push contract but ran only the installer fixture. The sample's own fixture, which pinned the old contract, failed later on the full run.
- The first plan assumed that `tdd.sh` could record RED for shell fixtures. It cannot, so every slice here was proved by hand, and the gap is filed as a follow-up.
