# Task wall time: push gates, trivial fast path, targeted turn-end tests

**Ticket:** IAN-98
**Tier:** complex
**Branch:** `feat/cut-task-wall-time`

## Problem

A transcript analysis of 31 sessions between 2026-09-04 and 2026-09-18 measured about 83 hours of tool wait time against about 5.4 hours of model generation. The edits themselves (`Edit` and `Write`) accounted for roughly 150 minutes. The rest was process:

| Cost | Total | Calls | Average |
|---|---|---|---|
| `git push` | 931 min | 326 | 171 s |
| `sleep` and polling (CI, Copilot review) | 739 min | 327 | 136 s |
| Test suite runs | 694 min | 1,323 | 32 s |
| `gh` calls | 603 min | 803 | 45 s |
| `AskUserQuestion` | 382 min | 187 | 123 s |

Three mechanisms produce most of this. First, every push runs the full fixture suite locally through `hooks/pre-push.sample` and sends the diff to the Anthropic API through `hooks/llm-rule-judge.sh`, and CI then runs the same full suite again. Second, a trivial change goes through the same PR ceremony as a feature: a ticket, a `docs/prs/` document, a Copilot review request, and polling until that review arrives. Third, `hooks/verification-gate.sh` runs the project's entire suite at the end of every turn that left the tree dirty, which is almost every turn of an editing session.

## Decisions

The user chose each of these on 2026-09-18.

1. **The LLM rule judge and the full suite run in CI only.** A local push keeps the fast deterministic guards: secret scan, conflict markers, commit format, destructive-command guards, and the linters on changed files. The alternatives were to skip the gates only on docs-only diffs, which leaves code pushes at about three minutes, or to do both, which adds moving parts for little extra saving.
2. **A trivial-tier change gets its own PR with no ceremony.** It needs no ticket, no `docs/prs/` document, and no wait for a Copilot review, and it merges once CI is green. The alternatives were a daily batch PR, which delays each fix until the batch ships, and a direct push to `main`, which skips CI before the change lands.
3. **The turn-end gate runs only the tests related to the changed files, and the full suite runs in CI.** A required CI status check stands in for R-509's local pre-push sweep. The alternatives were to run the full suite once locally before each push, which brings back one to three minutes per push, or to escalate to the full suite when shared paths change, which adds a path list that has to be maintained.

## Domain vocabulary

- push gate - a PreToolUse hook that fires on `git push` and can block it - chosen over: push hook, because "hook" alone does not say that it can block.
- fast guard - a push gate that runs in under a second and needs no network access - chosen over: cheap check, because "guard" is the word the existing hook names already use.
- CI judge - the LLM rule judge when it runs as a GitHub Actions job against a pull request's diff - chosen over: remote judge, because the job runs in CI and not on any other remote.
- related tests - the tests that the test mapping selects for a set of changed files - chosen over: affected tests and changed tests, because vitest's own `related` subcommand already uses the word.
- test mapping - the per-stack rule that turns a list of changed files into a related-tests command - chosen over: test selector, because a selector suggests a single pattern and not a per-stack rule.
- full-suite fallback - the full suite when it runs because the test mapping cannot produce a related-tests command - chosen over: safe mode, because the name should say what actually runs.
- trivial fast path - the reduced PR process for a change whose `task-tier.json` tier is `trivial` - chosen over: lite PR, because the tier name is the trigger.

## Acceptance criteria

1. B-1: running the PreToolUse `Bash` chain on `git push` invokes no network call and no fixture suite, and `pre-push.sample` exits 0 without running `run-tests.sh`.
2. B-2: the judge core, called with an explicit base and head, exits nonzero on an error-severity finding, exits 0 on a warn-severity finding, and exits 0 with a notice when `ANTHROPIC_API_KEY` is unset.
3. B-3: for each stack row in the mapping table, the verification gate runs exactly the related-tests command for a fixture change set, and it runs the full suite for each fallback trigger.
4. B-4: `reference.md` R-514, the `task-start` Trivial block, and `task-cleanup` state the trivial fast path, and `task-cleanup` skips the ticket close when the tier is `trivial`.
5. B-5: the R-509 wording in `CLAUDE.md`, `reference.md`, and the generated Cursor and Codex rules matches the new text.

## Behavior

### B-1: the push path drops the judge and the local full suite

- `llm-rule-judge.sh` is removed from the PreToolUse `Bash` chain in `claude/settings.json`, and the Cursor and Codex hook configurations are regenerated through `translate/` so that they match.
- `hooks/pre-push.sample` no longer runs the fixture suites. The `fixtures` job in `.github/workflows/enforce.yml` is the full-suite gate and is named as a required status check.
- The fast guards stay registered exactly as they are.
- `enforce/manifest.json` changes the enforcer of each rule it currently lists as `hook:llm-rule-judge` to `ci:llm-rule-judge`, and `enforcement-guard-check.sh` accepts that enforcer prefix.

### B-2: the CI judge

- A new workflow, `.github/workflows/rule-judge.yml`, runs on `pull_request`. It calls the existing judge logic with the PR's base and head, so the prompt, the manifest selection, and the vocabulary collection stay in one implementation.
- The job reads `ANTHROPIC_API_KEY` from a repository secret. When the secret is absent, the job passes with a notice and does not fail, which matches the current fail-open posture.
- A finding on a rule with `error` severity fails the job. A finding on a rule with `warn` severity is posted as an annotation and does not fail the job.
- The judge script is refactored so that the diff-and-judge core can be called without a `tool_input` payload, and the PreToolUse wrapper is deleted.

### B-3: turn-end verification runs related tests

`verification-gate.sh` gains a test-mapping step that runs before discovery. The mapping is computed from the files changed against the upstream branch, plus the working-tree changes:

| Stack marker | Related-tests command |
|---|---|
| `vitest` in `package.json` | `<pm> vitest related --run <changed source files>` |
| `jest` in `package.json` | `<pm> jest --findRelatedTests <changed source files>` |
| `pyproject.toml` or `pytest` available | `pytest -q` on the test files whose names match the changed modules, together with any changed test files |
| `go.mod` | `go test` and `go vet` on the packages containing the changed `.go` files |
| This repo (`claude/enforce/tests/run-tests.sh` present) | the `*.test.sh` fixtures whose name matches a changed hook or enforce script, together with any changed fixtures |

The mapping falls back to the full suite in each of these cases:
- no mapping matches the stack;
- the mapping produces an empty set while source files did change;
- `.claude/verify.sh` exists (it keeps precedence);
- the changed files include a test harness file, meaning `run-tests.sh`, a vitest or jest config, or `conftest.py`.

The retry, timeout, dirty-tree gating, and SubagentStop role handling are unchanged. The gate's output names the related tests it ran, so a reader can tell a targeted pass from a full pass.

### B-4: the trivial fast path

- `rulebook/reference.md` R-514: the default merge path for a trivial-tier PR is CI green, with no Copilot review step. Standard tier and above keep the Copilot step.
- `skills/task-start` Trivial block: it names the fast path, meaning its own branch and PR, no ticket, no `docs/prs/` document, and merge on green CI.
- `skills/task-cleanup`: it skips the ticket close and the PR-doc check when the ledger's tier is `trivial`.
- Outside this repo, the user edits two files, or approves the edit in a session rooted there: `personal/.claude/CLAUDE.md`, whose "Every PR gets a document" rule gains the exemption "except trivial-tier PRs", and the auto-memory `claude-handles-merges.md`, whose Copilot polling gains the exemption "for trivial-tier PRs, merge on green CI without requesting Copilot".

### B-5: R-509 text

R-509 becomes: "Run related tests at turn end and per commit; the full suite runs in CI as a required check; neither a turn nor a writing subagent ends on red related tests." `CLAUDE.md`, `rulebook/reference.md` lines 485, 581, and 586, and the generated Cursor and Codex rule files change to match.

## Non-goals

- The one-question-per-turn rule (R-211). It cost about 382 minutes, but that time buys decisions the user wants to make, so it is not a speed defect.
- The per-tool latency of hooks, which measured 0.5 to 1.4 seconds per call.
- Adding the CI judge to repositories other than this one. `rule-judge.yml` is written so that another repository can call it as a reusable workflow, but adopting it elsewhere is a follow-up ticket. Until a repository adopts it, the semantic naming rules in that repository depend on recall.

## Risks

- **The semantic naming rules lose local enforcement.** In a repository without the CI judge, a naming violation now reaches `main` unless a reviewer catches it. The follow-up ticket for CI adoption is the mitigation.
- **Related tests miss cross-file breakage.** The required CI check catches it before merge, but a turn can end green locally while the full suite is red. The full-suite fallback covers changes to the test harness.
- **Branch protection must actually require `fixtures`.** If it does not, dropping the local full suite leaves no full-suite gate at all. The plan's first task verifies the protection setting through `gh api` before B-1 lands.

## Testing

Each behavior ships with fixture tests under `claude/enforce/tests/` or `claude/hooks/tests/`:
- B-1: the push chain no longer contains the judge, and the pre-push sample runs no suite.
- B-2: the judge core called with an explicit base and head, a missing key, an error-severity finding, and a warn-severity finding.
- B-3: one fixture per stack row, one per fallback trigger, and a negative input consisting of a changed filename that contains spaces and shell metacharacters.
- B-4 and B-5: text fixtures that assert the new rule wording is present in `CLAUDE.md`, `reference.md`, and the generated ports.
