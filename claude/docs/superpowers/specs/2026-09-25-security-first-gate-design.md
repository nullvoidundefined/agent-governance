# Security-first gate

**Ticket:** IAN-381
**Status:** draft, awaiting owner review
**Date:** 2026-09-25

## Goal

Make security a first-order, mechanically enforced concern, so that a security defect cannot reach `main` on a model's attention alone.

The incident behind this spec is template-fastapi-nuxt #27 (IAN-170). It shipped a `Settings.cors_origin` that accepted any string, `*` included, and passed it to Starlette's `CORSMiddleware` with `allow_credentials=True`. Starlette reads `*` as allow-all and, with credentials on, echoes every caller's `Origin`, so the session cookie's single-origin boundary was gone. The authoring session, its R-517 reviewer, and every later Claude review passed it. A Copilot review comment caught it, and #45 (IAN-370) fixes it.

The investigation found three root causes, and each component below answers one of them:

1. `claude/CLAUDE-PYTHON.md` teaches the vulnerable shape (`cors_origin: str | None`, `allow_origins=[settings.cors_origin]`, no value validation), and the authoring agent followed it faithfully.
2. `hooks/content-gate.sh` (R-405) denies a wildcard origin written literally in code, but a dangerous value that arrives from configuration never appears in code.
3. `prompts/codex-pr-review-prompt.md` makes security item 4 of 6 in a generic checklist on a sonnet reviewer. The reviewer confirmed that CORS was restricted to the configured origin without asking what values the configuration admits.

## Domain vocabulary

- Security surface - the changed files and added lines in a PR range that touch a security control, as the security-surface detector decides - chosen over: "sensitive files" because the detector also reads added lines and rule-pack findings, not only paths.
- Security control - code that enforces a trust boundary: CORS, cookie flags, authentication and authorization checks, CSRF guards, CSP and security headers, rate limits, password hashing and other cryptography, TLS verification, and query construction - chosen over: "protection" because R-405 already uses "protection" for the narrower set a failure might tempt an agent to weaken.
- Security-surface detector - the shared helper `hooks/security-surface.sh` that decides whether a PR range touches a security surface - chosen over: "classifier" because it matches patterns deterministically and scores nothing.
- Security rule pack - the custom Semgrep rules in `claude/enforce/semgrep/`, each with a failing and a passing fixture - chosen over: "Semgrep config" because the unit that is versioned and tested is the set of rules, not the tool's configuration.
- Security review - the review a `security-reviewer` agent performs on the security review model, recorded under `## Security review` in the PR body - chosen over: "security audit" because `audit-security` already names the whole-project audit role.
- Security finding - one row of the security review's findings table: severity, evidence, fix, and finding status - chosen over: "issue" because an issue is a tracker ticket here.
- Finding status - one of `open`, `fixed <sha>`, or `waived by owner <date>` - chosen over: a free-text disposition because a free-text "not exploitable" is the rationalization path this spec closes.
- Security review model - the value of the `securityReviewModel` key, the strongest model available (today `claude-fable-5-1`) - chosen over: naming a model in each hook because the strongest model changes and one key changes once.
- Security merge gate - the check in `hooks/git-workflow-guard.sh` that denies `gh pr merge` on a security-touching PR until B-9 holds - chosen over: a separate hook because `git-workflow-guard` already owns the merge decision and the R-517 range parser.
- Worst value - the most dangerous value an input source will accept for a given control, such as `*`, `null`, empty, oversized, mixed case, or an injection payload - chosen over: "malicious input" because many worst values (`*` from an operator's env file) come from a trusted source making a mistake.

## Inputs

- A PR range (`merge-base..HEAD`), resolved through `resolve_pr_base` in `hooks/pr-range-checks.sh`.
- The PR body as `gh pr view` returns it.
- `.enforce.json` in the app repository, which gains `securitySurfaceExclude` (a list of globs).
- `claude/enforce/security-surface.json`, the detector's path and content patterns.
- `claude/enforce/security-review-model.json`, which holds `securityReviewModel`.
- The security reviewer's raw output, saved as an artifact beside the PR range so the gate can compare severities.

## Outputs

- A deny from `push-semgrep-gate.sh` at pre-push when the security rule pack reports a finding in the pushed range.
- A failing required CI check from the reusable `security.yml` workflow (Semgrep plus CodeQL).
- A deny from the security merge gate on `gh pr merge`, naming each condition that fails.
- A `## Security review` section in the PR body with `reviewer`, `model`, and `range` lines and a findings table.
- One tracker ticket per finding from the one-time sweep.

## Components

Delivered in this order, one PR each under IAN-381:

1. **Convention fixes.** The CORS, cookie, and settings examples in `CLAUDE-PYTHON.md`, `CLAUDE-BACKEND.md`, `CLAUDE-GO.md`, and `CLAUDE-RUBY.md` validate security-relevant values: CORS takes one exact browser-serialized origin, refuses `*` and `null` in every environment, and each example carries its negative test.
2. **Security rule pack and pre-push gate.** `claude/enforce/semgrep/` rules plus `hooks/push-semgrep-gate.sh`, modeled on `push-ruff-gate.sh`.
3. **Security-surface detector.** `hooks/security-surface.sh` plus `claude/enforce/security-surface.json`.
4. **Security reviewer.** `claude/agents/security-reviewer.md` and `claude/prompts/security-review-prompt.md`.
5. **Security merge gate.** New checks in `hooks/git-workflow-guard.sh`, with the `## Codex review` parser generalized to take a heading name.
6. **Rule R-109 and the R-406 extension.** `CLAUDE.md`, `rulebook/reference.md`, and `enforce/manifest.json`.
7. **Reusable CI workflow.** `.github/workflows/security.yml` in agent-governance, called from the templates first.
8. **Sweep.** One run of the security rule pack over `production/` and `templates/`, templates first, filing one ticket per finding.

## Acceptance criteria

Convention files:

- B-1: The CORS example in `CLAUDE-PYTHON.md` refuses `*`, `null`, a list, a path, and userinfo in every environment, and the file shows the test that feeds it each of those values.
- B-2: `CLAUDE-BACKEND.md`, `CLAUDE-GO.md`, and `CLAUDE-RUBY.md` carry the same validation and test for their CORS and cookie examples.

Security rule pack and pre-push gate:

- B-3: The rule pack reports a finding on a fixture that passes an unvalidated settings value to `CORSMiddleware(allow_origins=..., allow_credentials=True)`, which is the #27 shape.
- B-4: The rule pack reports no finding on the #45 shape, where the value passes a validator that refuses `*` and `null`.
- B-5: The rule pack reports findings on literal wildcard or `null` origins with credentials, `SameSite=None` without `Secure`, disabled TLS verification, and bcrypt cost below the floor, each proven by a failing and a passing fixture.
- B-6: `push-semgrep-gate.sh` denies a push whose range contains a rule-pack finding, and allows the same push once the finding is fixed.

Security-surface detector:

- B-7: The detector marks a range as security-touching when a changed path matches a path pattern, an added line matches a content pattern, or the rule pack reports a finding in the range, and each trigger is proven separately by a fixture.
- B-8: The detector skips files that match `securitySurfaceExclude` in `.enforce.json`, and a write to that key is refused by `protected-path-guard.sh` (R-410).

Security merge gate:

- B-9: On a security-touching PR, `gh pr merge` is denied unless all of the following hold: the Semgrep and CodeQL checks are green; a `## Security review` section exists whose `model` line equals `securityReviewModel` and whose `range` head equals the PR head commit; the diff adds at least one test that feeds a security control an insecure value; and no finding has status `open`.
- B-10: The gate denies a PR whose findings table shows a severity lower than the one in the reviewer's saved artifact for the same finding.
- B-11: The gate accepts `fixed <sha>` only when that SHA is inside the PR range.
- B-12: A finding marked `waived by owner <date>` never lets the merge through silently: the gate returns an `ask` decision naming each waived finding, so the owner confirms the waiver in the harness permission prompt, the same channel R-514 uses for merge authorization.
- B-13: A replay of #27 is blocked twice: at pre-push by the rule pack, and at merge for the missing security review.
- B-14: A PR that touches no security surface passes the gate unchanged, so the gate adds no cost to unrelated work.

Security reviewer:

- B-15: The security review prompt requires, for each control in the flagged hunks, a list of every input source that reaches it, the worst value tried per source, the resulting behavior, and the test that feeds the insecure value; a missing test is reported as MEDIUM.
- B-16: A "nothing found" line is accepted only when it names the values it tried; the gate rejects a section whose "nothing found" line names none.

Rules:

- B-17: R-109 exists in `CLAUDE.md` and `reference.md` and is registered in `enforce/manifest.json` with the hooks above as enforcers and a fixture test (R-516).

## Invariants

- No path through the gate lets an agent clear or downgrade a security finding without the owner's `approved` in the current turn.
- The security review's range head always equals the PR head at merge; any new commit makes the review stale.
- The security review model is read from one key; no hook or prompt hardcodes a model name.
- Every assertion in the new fixtures checks that the expected block happens, and each fixture is shown to go red when the implementation is broken (the fail-open lesson recorded in the handoff).

## Failure modes

- **Semgrep missing on the machine:** `push-semgrep-gate.sh` denies with the install command; it never passes silently.
- **Semgrep times out or crashes:** deny with the error; a crashed scan is not a clean scan.
- **`gh` fails or returns no head commit:** the gate denies and names the failure, as the R-517 check does today.
- **CodeQL unavailable on a private repo:** the workflow skips CodeQL with a visible notice and Semgrep still runs; B-9 then requires only the checks the repo can run.
- **Detector false positive:** costs one strongest-model review of the flagged hunks; the only exits are the protected exclude list and the owner's `approved`.
- **Oversized or malformed PR body:** the parser treats an unparseable findings table as `open` findings, which means the gate fails closed.

## State transitions

A security finding moves from `open` to `fixed <sha>` when a commit in the range fixes it, or from `open` to `waived by owner <date>` on the owner's `approved`. A new PR head moves the whole review to stale, which the gate treats as absent.

## Non-goals

- Replacing the R-517 review. The security review is an additional step, not a substitute.
- Requesting Copilot review. That stays off for cost (owner decision 2026-09-20).
- Wiring the CI workflow into every production repo in this rollout. The sweep files tickets, and each repo adopts the workflow in its own ticket.
- Mechanizing R-211's question-card rule. That is IAN-382.

## Dependencies

- Reuse: `resolve_pr_base` in `hooks/pr-range-checks.sh`; the `## Codex review` parser and range-head check in `hooks/git-workflow-guard.sh`, around line 430; `push-ruff-gate.sh` as the pre-push template; the R-203 `approved` check; `protected-path-guard.sh` for the exclude list.
- New third-party tools, justified under R-331: Semgrep OSS, because no existing linter here does language-aware dataflow across files and it runs fast enough for pre-push; CodeQL in CI, for deeper taint tracking on public repos, where it is free.

## Part 7 addendum: the reusable CI workflow (2026-09-27)

Part 7 moves the rule pack from a local pre-push hook, which `--no-verify` skips, to a CI check that the author does not control. The owner settled five choices on 2026-09-27: callers pin the workflow by full commit SHA; Semgrep runs the custom rule pack plus the free `p/default` registry ruleset; a pull request fails only on Semgrep findings in the files it changes; CodeQL blocks through GitHub's own code-scanning check rather than a custom SARIF reader; and all three template repositories adopt the workflow in this rollout.

### Vocabulary

- Security CI workflow - `.github/workflows/security.yml`, a `workflow_call` workflow that other repositories call - chosen over: "security action" because it is a reusable workflow with jobs, not a composite action.
- Caller workflow - the short workflow in an adopting repository that calls the security CI workflow with a pinned SHA - chosen over: "wrapper" because GitHub's own documentation calls it the caller.
- Harness checkout - the copy of agent-governance at the pinned commit that the workflow checks out beside the caller, holding the rule pack and the scripts - chosen over: "rules checkout" because it also carries the scripts.
- Scan targets - the files a run scans: in PR mode, every file the PR adds, copies, modifies, or renames into, relative to the merge base of the PR's base and head; in full mode, every file tracked at HEAD. No exclude list narrows either, because R-109 gives the rule pack none - chosen over: "changed files" because full mode is not about changes.
- PR mode and full mode - PR mode runs on `pull_request`; full mode runs on every other event (push to `main`, the weekly schedule, manual dispatch) - chosen over: "diff scan" and "baseline scan" to keep one word per mode.

### Components

1. `claude/enforce/security-ci-targets.sh` lists the scan targets. It does not read `securitySurfaceExclude`: R-109 scopes that list to the security-surface detector and gives the rule pack no exclude list, so a path can leave the security review's view but never the rule pack's (owner decision 2026-09-27). It diffs from `git merge-base <base> HEAD`, so a base branch that moved on adds nothing to the list; it lists every status except deletion, reads names NUL-separated, refuses a name holding a control character, and exits 2 whenever git fails, so a failed listing can never read as an empty one (B-25).
2. `claude/enforce/security-ci-semgrep.sh` runs the lister and exits 2 if the lister does. It exports the targets' HEAD content into a scratch directory with an empty `.semgrepignore`, runs Semgrep with the rule pack and `p/default`, `--error`, `--disable-nosem`, `--metrics=off`, and `--max-target-bytes=0`, and prints each finding as a GitHub `::error` annotation. The workflow installs Semgrep at the version `enforce.yml` pins (1.178.0). `p/default` itself stays a moving registry target: the Semgrep Rules License does not permit redistributing it in this public repository, so it cannot be vendored, and a registry change is visible as a new red, never as a silent pass.
3. `claude/enforce/security-ci-codeql-languages.sh` derives the CodeQL language list from the caller's tracked files (`python`, `javascript-typescript`, `go`, `ruby`, and `actions` for `.github/workflows/`), as a JSON array, and exits 2 on an empty list. The caller passes no language input, so a caller cannot soften the gate by listing fewer languages.
4. `.github/workflows/security.yml`:
   - takes no inputs;
   - exits 2 on `pull_request_target`, which would run fork code with a write token;
   - checks out the caller at `github.event.pull_request.head.sha` in PR mode, not the merge ref, so the scanned bytes are the ones the merge gate's `range` head names, with the full history the merge base needs;
   - checks out `job.workflow_repository` at `job.workflow_sha` into `$RUNNER_TEMP/harness`, outside the caller's workspace, so neither Semgrep nor CodeQL scans the harness's own bad samples; GitHub documents both properties for exactly this purpose (a reusable workflow checking out its own source), and a step asserts the repository is `nullvoidundefined/agent-governance` and the SHA is 40 hexadecimal characters before anything runs;
   - passes every event value to scripts through `env:`, never through `${{ }}` inside a `run:` line, so a branch name or PR title cannot inject shell;
   - pins every third-party action by commit SHA with its tag in a comment, and sets `persist-credentials: false` on every checkout;
   - runs three jobs: `semgrep`, `languages`, and `codeql (<language>)` as a matrix over the `languages` output. The `codeql` jobs run `init` and `analyze` over the caller's workspace and upload to code scanning; they carry the only elevated permissions, `security-events: write` and `actions: read`. On a private repository the `codeql` job is skipped and a `codeql-skipped` job prints a notice naming the reason.
5. GitHub's code-scanning check, named `CodeQL`, is what blocks a PR on CodeQL alerts. It fails on new alerts at high severity or above under each repository's default code-scanning settings. This is weaker than the Semgrep rule: an alert already present in a file the PR touches does not block it. The Part 8 sweep files those existing alerts as tickets.
6. `.github/workflows/security-self.yml` calls the workflow from agent-governance itself with `uses: ./.github/workflows/security.yml` on `pull_request` only, so every PR here exercises it. It runs no full mode, because this repository's `enforce/tests/testdata/semgrep/` bad samples are findings by design. The rule pack's samples carry a `.sample` suffix so a PR adding a rule and its bad sample is not turned red by its own fixture (owner decision 2026-09-27).
7. One caller workflow in each of template-express, template-express-next, and template-fastapi-nuxt, one PR per repository, granting `contents: read`, `security-events: write`, and `actions: read` and nothing else.

The checks Part 5b will require are `security / semgrep`, `security / codeql (<language>)` for each derived language, and `CodeQL`. The merge gate reads each check's conclusion, and it must treat a skipped or absent `security / semgrep` as a deny, and a skipped `codeql` job as acceptable only on a private repository, because branch protection counts a skipped job as passing.

Local and CI runs differ on purpose, and an author should expect it: the pre-push gate scans code files with the custom pack only while CI also runs `p/default` over every target type; neither reads an exclude list. `security-ci-semgrep.sh` runs locally with the same arguments CI uses, which reproduces a CI red.

### Acceptance criteria

- B-18: In PR mode the target list holds every added, copied, modified, or renamed-into file relative to the merge base, omits deleted files, includes files a `securitySurfaceExclude` glob covers, and exits 2 with nothing on stdout when the base is not a reachable commit.
- B-19: In full mode the target list holds every file tracked at HEAD, `securitySurfaceExclude` globs notwithstanding.
- B-20: The Semgrep step exits 1 and annotates each finding when the scan reports one, exits 0 on a clean scan or an empty target list, and exits 2, failing closed, when the target lister exits non-zero, Semgrep cannot be resolved, crashes, prints unreadable JSON, reports an error-level error, or leaves a code target unscanned. A `# nosemgrep` comment cannot silence a finding.
- B-21: A #27-shaped file (the `cors-unvalidated-setting` bad sample) in the targets makes the Semgrep step exit 1 with a real Semgrep run, not a stub.
- B-22: The language script prints the exact JSON array of CodeQL languages present in the tracked files, and exits 2 when there are none.
- B-23: `security.yml` is a `workflow_call` workflow with no inputs, whose every external `uses:` is pinned to a 40-character SHA, whose every checkout sets `persist-credentials: false`, whose caller checkout in PR mode reads `github.event.pull_request.head.sha`, whose harness checkout reads `job.workflow_repository` at `job.workflow_sha` into `$RUNNER_TEMP`, whose `run:` lines contain no `${{ }}` expression, which refuses `pull_request_target`, whose jobs grant no permission beyond `contents: read` except the `codeql` job's `security-events: write` and `actions: read`, which installs Semgrep 1.178.0, and which skips CodeQL only on a private repository, with a notice.

### Criteria added by the reviews of PR #160 (2026-09-27)

The R-517 review (opus) and the R-109 security review (fable) of the first implementation found that a PR author's file names and the calling event could still weaken the scan. These criteria close each finding:

- B-24: Scan targets reach Semgrep after `--`, so a file named `--severity=INFO` or `--exclude-rule=<id>` cannot switch the rule pack off; the #27 sample beside such a file still exits 1.
- B-25: In PR mode the target list includes type changes (a symlink replaced by a regular file), because every status except deletion is listed; and the lister exits 2 when any target's name holds a control character, so git's quoting can never substitute one path for another.
- B-26: Semgrep runs with `--no-git-ignore`, every `.semgrepignore` the PR supplies is removed from the scratch export before the scan, and any entry in `paths.skipped` fails the step closed, so no file the PR adds can take itself out of the scan.
- B-27: Every value from Semgrep's report that reaches stdout or stderr is escaped for GitHub's workflow-command parser, diagnostics included.
- B-28: The language script takes `--mode pr` or `--mode full`; in PR mode it never lists `go` and prints a notice saying so, because CodeQL can analyze Go only by running the repository's build, and PR code must never run beside the code-scanning write token (owner decision 2026-09-27). Every other language runs with `build-mode: none`; `go` runs with `autobuild` only in full mode, on already-merged code.
- B-29: The workflow runs only on `pull_request`, `push`, `schedule`, and `workflow_dispatch`, and exits 2 on any other event.
- B-30: The harness step refuses a repository other than `nullvoidundefined/agent-governance`, a SHA that is not 40 hexadecimal characters, and, except when the caller is agent-governance itself, a SHA that is not an ancestor of agent-governance `main`; the fixture executes the step's own shell with each of those values and asserts exit 2 before any fetch of the pinned commit.

Finding 6 of the security review has a residual this PR cannot close: GitHub resolves a `uses:` SHA from any fork of agent-governance, so a malicious pin brings its own copy of this workflow and skips the ancestry check. The real control is at the adopting repository: each template's caller PR adds a CODEOWNERS entry on `.github/workflows/`, and **Part 5b's merge gate must verify that the caller file's pin is an ancestor of agent-governance `main`** (owner decision 2026-09-27).

### Rollout checklist (not an acceptance criterion)

- A throwaway draft PR in template-fastapi-nuxt carrying the #27 shape turns `security / semgrep` red, and the same branch without it turns it green; the PR is closed afterwards. B-21 is the automated proof; this confirms the wiring end to end.

### Failure modes

- Registry unreachable (`p/default` cannot download): Semgrep exits with an error, the step exits 2, and the check is red. A scan that ran without its rulesets is not a clean scan.
- `job.workflow_sha` or `job.workflow_repository` empty or unexpected (a GitHub change, GitHub Enterprise Server, or a local `act` run): the assertion step exits 2 and the job is red.
- A fork PR: the harness checkout reads a public repository, so Semgrep still runs; CodeQL's upload needs `security-events: write`, which GitHub withholds from fork PRs, so the `codeql` job fails red there. None of the adopting repositories accepts fork PRs today.

### Spec review of this addendum

Reviewer: `pr-reviewer` subagent (fable), 2026-09-27, adversarial review of the first draft of this addendum. Eleven findings:

1. HIGH, rejected with evidence: the review said `job.workflow_sha` and `job.workflow_repository` do not exist. GitHub's contexts reference lists both, with a reusable-workflow example that checks out its own source through them; the suggested `github.workflow_sha` names the caller's workflow in a called workflow. The suggested assertion step was adopted.
2. HIGH, fixed: a skipped CodeQL job reads as passing. Languages are derived, not input; only a private repository skips; Part 5b's gate reads conclusions.
3. HIGH, fixed: the harness is checked out under `$RUNNER_TEMP`, outside the scanned workspace.
4. HIGH, fixed: a failed listing now exits 2 at both the lister and the Semgrep step (B-18, B-20).
5. MEDIUM, fixed: the lister no longer calls the helper; `git diff --diff-filter=d` omits deleted paths directly.
6. MEDIUM, fixed: PR mode checks out the head SHA; event values reach scripts through `env:` only (B-23).
7. MEDIUM, answered: a PR widening `securitySurfaceExclude` changes `.enforce.json`, which `security-surface.json` lists as a security-surface path, so it already needs a strongest-model security review before it merges. The question is also moot for CI: after this review the implementation was found to contradict R-109, which gives the rule pack no exclude list, and the owner chose on 2026-09-27 that CI reads no exclude list at all.
8. MEDIUM, fixed: the workflow refuses `pull_request_target`.
9. MEDIUM, partly fixed: Semgrep is pinned at 1.178.0; `p/default` cannot be vendored under its license, as component 2 records.
10. LOW, fixed: the local and CI difference is documented, and the script reproduces CI locally.
11. LOW, fixed: the live PR moved to the rollout checklist.

Build versus buy: the owner chose GitHub's code-scanning check over a custom SARIF gate on 2026-09-27, which removed the custom gate script and its criterion. `semgrep --baseline-commit` was not adopted, because it reports only findings new since the base, weaker than the settled any-finding-in-a-changed-file rule.

## Observability

Every deny from the new hooks logs its rule ID through `log-rule-fire.sh`, so misses and fires feed the existing rule-fire log.

## Security

The gate fails closed on every error path. The security reviewer is read-only. Neither the findings table nor the artifact may contain secret values; evidence cites `file:line` only (R-104, R-202).
