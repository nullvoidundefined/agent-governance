# Spec template

**Purpose:** the fixed headings a behavioral spec carries so the test author (R-705, R-707) and `agents/spec-conformance-review.md` have explicit requirements to work from. Copy the headings below into `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md` (the `brainstorming` skill's path) or into an externally written spec during `spec-grounding`. `hooks/spec-glossary-check.sh` reminds when a design doc lacks `## Acceptance criteria`, `## Non-goals`, or the `## Domain vocabulary` glossary (R-330). Delete a heading only with a one-line reason under it; an absent heading reads as "not considered".

**How to use:** keep prose short under each heading. The load-bearing section is `## Acceptance criteria`: one numbered behavior per line, each one a slice the harness runs as RED then GREEN (R-412). A criterion a test cannot fail is not a criterion; move it to `## Non-goals` or rewrite it.

---

# <Feature name>

## Goal

One paragraph: what changes for the user or the system, and why now.

## Inputs

What arrives, from where, in what shape (request body, event, file, CLI args). Name the schema module when one exists.

## Outputs

What leaves, in what shape, with which status codes or events. Name the response envelope.

## Acceptance criteria

Numbered, one behavior each, each mechanically assertable. Order them the way the implementation needs them.

- B-1: <subject> <verb> <observable result> when <condition>.
- B-2: ...

## Invariants

Properties that hold before and after every behavior above (a total never goes negative, a row is never orphaned, an ID is stable across retries).

## Failure modes

For each: the trigger, the visible outcome, and whether the caller can retry. Cover invalid input (R-406), the dependency being down or slow (timeout, R-346), partial failure mid-operation, and a concurrent second call.

## State transitions

Only when the feature owns state: the states, the allowed transitions, and who triggers each. Otherwise write "none".

## Non-goals

What this spec deliberately does not do, so the critic does not report it and the implementer does not build it.

## Dependencies

Existing modules this reuses (R-308, with paths), third-party packages it needs (each one justified), and migrations it requires.

## Observability

The log lines, request-ID propagation (R-341), analytics events from the registry (R-343), and health-check changes (R-345) the behavior adds.

## Security

Who may call it, what is validated at the boundary, what is never logged (R-104).

## Harness rules

How the harness will run this work, decided while the spec is written rather than discovered mid-build. Read `~/.claude/CLAUDE.md` and the rule's entry in `~/.claude/rulebook/reference.md` for each row; answer every row, writing "not applicable" with a reason where one does not apply.

| Rule | What the spec states |
|---|---|
| R-110 risk | Each slice's risk, `high` or `standard`, with the reason. High is money, concurrency (locks, leases, races, retries, idempotency), security controls, or data that cannot be rebuilt. The plan copies it to a `**Risk:**` line per slice. |
| R-907 test author | Who writes each slice's failing test: the session (standard risk), the `test-author` agent (high risk), or Codex (only when the owner opts in). Note that `codex-test-author-guard` reads the task tier, not the risk, so a session-written test in a Complex or Saga task asks the owner on every test file; when that friction is not wanted, say who writes the tests instead of leaving it to the guard. |
| R-412 lock | Whether `tdd.sh red` can run each slice's test. It runs the project's default test config only, so a test that needs another config (integration suites, a separate Playwright project) cannot record RED under the lock; name those slices and how their RED is evidenced instead. |
| R-212 scope | Every path the work will write, as the globs `task-tier.sh set --scope` will record, including docs, tests, and new directories. A path missing here prompts the owner on every edit. |
| R-109 security review | Whether the range touches a security control (auth, session, CSRF, CORS, rate limit, input validation, SQL construction, secrets, redirects), so the plan budgets the review on `securityReviewModel` and its JSON artefact. |
| R-361 to R-365 data access | Query budget tests for every collection read, transactions for multi-statement writes, atomic read-modify-write, bounded reads with a unique final sort column, and identifiers never built from input. |
| R-341 to R-346 observability | The request ID path, the logger, analytics events, swallowed-error checks, health endpoints, and outbound instrumentation the work adds or, when the repository lacks them, the ticket that will. |
| R-406 negative input | One negative-input test per new input handler, and an insecure-value test for every security control touched. |
| R-607, R-608 docs | The product-doc rows and stories, and the `docs/stack.md` and `docs/observability.md` entries, the work changes, or the `.enforce.json` opt-out that applies. |
| R-517, R-514 review and merge | The pre-merge reviewer and model, and the merge mode (the owner merges, or merge on green when the owner opted in). |

## Assumption ledger (optional)

For specs grounded on external research or another session's claims: one row per load-bearing assumption, so verification is work someone owns rather than a hope. Delete the section when the spec rests only on code in this repo.

| Claim | Source | Verification command or check | Status (unverified/confirmed/refuted) | Owner | Next action |
|---|---|---|---|---|---|

## Assumption ledger (optional)

For specs grounded on external research or another session's claims: one row per load-bearing assumption, so verification is work someone owns rather than a hope. Delete the section when the spec rests only on code in this repo.

| Claim | Source | Verification command or check | Status (unverified/confirmed/refuted) | Owner | Next action |
|---|---|---|---|---|---|

## Domain vocabulary

- <term> - <meaning in this domain> - chosen over: <alternatives> because <reason>.
