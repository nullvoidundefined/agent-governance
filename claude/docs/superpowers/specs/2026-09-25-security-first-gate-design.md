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

## Observability

Every deny from the new hooks logs its rule ID through `log-rule-fire.sh`, so misses and fires feed the existing rule-fire log.

## Security

The gate fails closed on every error path. The security reviewer is read-only. Neither the findings table nor the artifact may contain secret values; evidence cites `file:line` only (R-104, R-202).
