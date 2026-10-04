# Spec: governance recovery (IAN-568 baseline)

Status: proposal, not implemented. Baseline: agent-governance `main` at `afa13a6` (post-IAN-568 plus #183 and #184). PR #187 (`claude/streamline`) is treated as a reference, not the baseline: it should be closed, and the parts this spec keeps are ported from it.

Evidence: five research reports in this folder.

- `evidence-A-tdd-verification.md`: test-first development and verification.
- `evidence-B-review-security.md`: review and security review.
- `evidence-C-pruning-meta.md`: what IAN-568 changed, the recursion pathologies, and every hook and rule.
- `evidence-D-stack-backend.md`: per-rule tables for the backend stack files.
- `evidence-E-stack-frontend.md`: per-rule tables for the frontend stack files.

Citations in this spec point to those reports.

## 1. Goal

The harness is a disciplined engineering harness. It biases agents strongly toward correct, tested, reviewed and maintainable software, and every process has a hard stopping point. It must not be able to optimize recursively for its own process.

Success means:

1. **Behavioral changes start from a failing test,** and that RED is observed and recorded before the code is written.
2. **Every meaningful PR gets one fresh-context review.** The review has a fixed end.
3. **Nothing is called done without evidence:** the command that ran and its result.
4. **High-risk work gets stronger mechanics,** and those mechanics are bounded too.
5. **The stack files keep the owner's durable opinions,** and SCSS Modules over Tailwind holds at the moment a component is written.
6. **Harness maintenance is a small, visible cost.** It is not most of the commit history.

## 2. What the evidence says

These findings drive the decisions in the rest of the spec:

- **Only three controls have recorded product catches:**
  - The R-517 pre-merge review. It found PII in Voyager #16. On #183 it found tests that could not fail, and a masking bug that six security rounds had missed.
  - The R-109 security review. It found the `sync.sh` issue, the `--upload-pack` injection (#161), and the failing-closed Semgrep step (#160). That last one was found by R-517 after R-109 had passed it.
  - The R-401 rule that tests must fail when the code is wrong (A, B).
- **The TDD lock caught no product bug on record.** It had 88 denies; R-410 had 68 and R-411 had 175. Its cost was 20 to 32 minutes per four-slice PR. Voyager PR 2 took 6 hours for about 250 lines, including 2 hours of DISPUTE rounds (A).
- **The value of the lock came from practices, not the mechanism:**
  - observing RED
  - keeping the test unchanged while implementing
  - an author for the test who is not the implementer

  All three survive without the lock.
- **The slice-critic and spec-conformance review have no recorded catch (B).**
- **IAN-568 moved standard-risk work** from "failing test under the lock" to "tests written alongside the code". Nothing observes RED there now, and the IAN-568 proposal accepted that tests "may be shaped to pass" (A). The owner's hypothesis is confirmed.
- **Security review looped for structural reasons (B):**
  - Each new control required its own insecure-value test, so a fix that added a control created a new MEDIUM.
  - The review range had to end at the head, so any LOW fix forced another full round.
  - LOWs could never be deferred.

  The result was 69 rounds across 17 PRs, and at least 4 of the artefacts were keyword false positives. Ten HIGHs were found, and they were almost all in the harness's own gate code.
- **Maintenance outweighed the rules:**
  - 73% of `main` commits touch hooks or enforce code.
  - 35,900 lines of fixtures cover 17,200 lines of hooks.
  - 9 fixtures only check that rule prose contains certain words.
  - Gates exist to guard other gates (C).
  - Regrowth continued after IAN-568: R-708 came the next day, at 837 lines for one incident.
- **The styling rule fails where it matters.** `CLAUDE-STYLING.md` loads only on `.scss` files, so it is absent while `.tsx` and `.vue` components are written. It also has none of the owner's two exceptions (E §1).

## 3. Anti-recursion principles (global, in CLAUDE.md)

1. **No recursive restart.**
   - A finding is fixed in an ordinary commit on the same PR.
   - It does not restart planning, test authoring, the review, ticketing, or verification unrelated to the fix.
   - The exception is a finding that invalidates the approved design. That one goes to the owner.
2. **No governance-generated governance.**
   - Never create a ticket, ledger entry, artefact, manifest row, closure test or rule only because another process artifact exists or asks for one.
   - Tickets exist when the owner asks for them, or for deferred work the owner should see.
3. **Bounded review.**
   - General review is one round, at most two.
   - Security review is at most three rounds.
   - Each round reviews only what changed since the last one (§6).
4. **Proportional verification.**
   - Verification depth follows product risk and changed behavior.
   - Run the affected tests and checks locally; CI runs the full suite.
5. **Prefer simple enforcement.**
   - The order of preference is: compiler, formatter or linter; then an ordinary test; then a CI check; then a simple stateless hook; then a stateful subsystem.
   - Before adding a hook or gate, answer five questions:
     1. What real, cited failure does it prevent?
     2. Could a cheaper tier catch it?
     3. What false positives will it produce?
     4. How much test infrastructure does the guard itself need? Fixtures should be no larger than the guard.
     5. Is it simpler than the failure it prevents?
   - A stateful subsystem needs the owner's approval.
6. **Maintenance counts toward the budget.**
   - Process time includes harness maintenance: hooks, fixtures, adapters, translation, review machinery, governance CI, and debugging all of these.
   - If a useful practice costs too much, simplify how it is enforced before deleting the practice.
7. **Gates do not guard gates.**
   - No integrity manifest, closure test or registration check exists only to protect other harness files.
   - Git history and the owner's review of harness PRs are the protection.
8. **No mandatory rule from a single incident.**
   - An incident gets a fix and a test in the affected code.
   - A new global rule or hook needs the owner's approval, and must pass the five questions.
9. **Optimize for the product.**
   - The goal is correct, useful and maintainable software, not "every check satisfied".
   - When a check and that goal disagree, say so and ask the owner. Do not satisfy the check by shaping the work around it.

Process budget: keep the IAN-568 1:1 rule (process time does not exceed implementation time), with principle 6 added. The security exception is now bounded as well (§6).

## 4. Risk classification

Every PR gets one line, `**Risk:** standard | high`, which picks the execution model.

**High risk** means the change touches one of these:

- authentication, sessions or cookies
- handling of secrets or PII
- payments or money
- validation of network-facing input at a trust boundary
- SQL built from input
- destructive data operations or migrations
- concurrency primitives in production services (locks, queues, retries)
- CORS, CSP or security headers

Everything else is standard, including most product UI, internal tooling, docs, and local CLIs whose only input is the owner.

The security-surface detector becomes advisory only. It may suggest "high" in the plan, but it never forces a review. Its path patterns are anchored to cut false positives. The owner can override the classification either way.

## 5. Execution models

### 5.1 Standard risk (the default)

1. **Understand** the requirement.
2. **Write acceptance criteria:** one numbered behavior per line in the plan or PR.
3. **Write the failing tests.** The test author is the model that did not write the implementation: Codex writes tests for Claude's code, and Claude writes tests for Codex's code.
   - If Codex is unavailable (it is not installed in cloud containers), rate-limited, or would bill the API, a fresh-context Claude `test-author` subagent writes them.
   - One test-writing pass per behavior.
4. **Observe RED.** Run the new tests once against the unchanged code. Each must fail for the expected reason, not because of a typo or import error. Commit the tests on their own as `test(<scope>): ...`, with the failing command and the failure line in the commit body.
5. **Implement** the smallest coherent change. The implementer does not edit the RED tests.
   - If a test looks wrong, the implementer states one `DISPUTE: <test>: <why>`.
   - The test author amends it once, or the owner decides.
   - No second dispute round.
6. **Observe GREEN.** Run the affected tests, lint and typecheck.
7. **Review:** one fresh-context review (§6.1).
8. **Fix material findings** with ordinary commits.
9. **Targeted verification:** rerun the checks affected by the fixes.
10. **STOP.** Open or update the PR and wait for the owner (§5.4).

Exceptions to steps 3 and 4 need a one-line reason in the PR:

- exploratory spikes
- non-behavioral config
- scaffolding a behavior needs before it can run
- changes that genuinely cannot be tested first

Bug fixes are always test-first:

1. Reproduce the bug.
2. Encode the reproduction as a failing test.
3. Fix the root cause.
4. Show the regression test passing.

Test immutability is checked by review, not by a lock. The reviewer compares the RED commit's tests with the final tests, and any change needs a stated reason.

Nothing hard-blocks a commit for lacking a new test.

### 5.2 High risk

Same as standard, plus:

- **Threat model first.** One owner tile per control that has no natural endpoint (rate limits, redaction, allow and deny lists). It sets the acceptance and failure boundaries, and the severity ceiling.
- **The TDD lock** (`tdd.sh`, kept) proves RED mechanically and keeps the locked tests read-only until GREEN. The I1, I2, I3, I5 and I8 interlock fixes stay.
- **Separated test author** (cross-model or `test-author`). The implementer may be a subagent.
- **Integration verification,** for example real PostgreSQL where the behavior depends on it.
- **The R-517 review, then the R-109 security review** (§6.2).
- **Targeted verification, then STOP.**

The per-slice critic and the spec-conformance review are retired (folded into R-517).

### 5.3 Verification before "done"

- No message, PR or commit says "done", "works" or "fixed" without evidence: the command, and the passing result or output line.
- The PR body has a `## Verification` section listing the RED commit, the GREEN commands and what was checked by hand.
- CI is the backstop.
- Mechanism: the rule in `CLAUDE.md`, plus the reviewer checking the section. The Stop-hook gate retires: it had 320 blocks, no recorded catch, and cost 5 to 15 minutes a turn.

### 5.4 PR approval

- One PR per slice.
- After opening a PR, stop. The owner approves or merges it before the next slice starts.
- `gh pr merge` no longer asks (owner, 2026-10-04: Claude merges without a prompt). The guard still denies a merge whose PR body has no `## Review` section, and the `gh api` merge endpoints still ask.

## 6. Review

### 6.1 General review (R-517, kept as a first-class control)

- **Who:** a read-only `pr-reviewer` on Sonnet, in a fresh context. It receives the diff, the acceptance criteria and the risk line, and never the implementer's transcript.
- **What it checks, in order:**
  1. correctness and edge cases
  2. acceptance conformance: each criterion has a test that would fail without the change (this replaces the separate spec-conformance review)
  3. weak or misleading tests, including changes to the RED tests
  4. failure handling at external boundaries
  5. regression risk to callers
  6. violations of the stack rules, citing the section
  7. inappropriate abstractions (at most 2 findings)
  8. security implications
- **What it must not do:**
  - comment on style or wording
  - suggest scope additions or speculative hardening
  - report findings outside the diff
  - re-grade dispositions already answered
  - report more than 10 findings
  - harden inputs only the owner controls
- **Severity handling:**
  - HIGH blocks the merge.
  - MEDIUM is fixed, or answered with a reason in the PR.
  - LOW is fixed when it takes under 5 minutes, otherwise noted. LOWs never trigger another review.
- **A second round** happens only if:
  - round 1 found a HIGH, or
  - the fixes add more than max(100 lines, 25% of the diff) of new production code, or
  - the fixes materially change the design.

  It reviews only the fix diff. There is never a third round; an unresolved HIGH goes to the owner.
- **Codex as reviewer:** optional, chosen by the owner per PR. Not required.
- **Mechanism:** the PR body carries `## Review` with the reviewer, the commit range and the findings with their dispositions. The merge guard checks only that the heading exists. There is no range grammar, no docs-only tail logic and no ledger. The owner's per-merge ask is the real gate.

### 6.2 Security review (R-109, strong but bounded)

- **When:** high-risk PRs that touch a real security control (the §4 list).
- **Who:** `security-reviewer` on `securityReviewModel` (claude-fable-5-1), in a fresh context.
- **Order:** it runs after R-517, never before, and never reopens R-517, tests, CI or planning.
- **Round 1** freezes the list of controls in scope.
- **Round 2** runs only for a HIGH or CRITICAL, or a MEDIUM fixed in code. It covers the fix diff and the frozen controls.
- **Round 3** runs only for an open HIGH or CRITICAL.
- **Hard stop after round 3.** The owner then waives, accepts or splits the remaining work. Continuing needs the owner's yes.
- **The "rounds continue while MEDIUM+" exception** applies inside this 3-round cap, and only to new MEDIUM+ findings.
- **A missing insecure-value test** is a MEDIUM only once per control, and only for controls the PR added or changed.
- **Severity ceiling:** LOW when the only input source is the owner's own environment, config or CLI. Network-facing CORS, cookie and header settings are not capped.
- **LOW security findings:** fixed or noted, never a new round. *Owner decision D1:* this changes the current "never deferred" rule.
- **The record:** a `## Security review` section in the PR body, written once at the end. The ledger, the artefact JSON and the `fixed <sha>` tail grammar all retire.

## 7. Control-by-control classification

Practice and mechanism are classified separately.

| Control | Practice | Mechanism | Why |
|---|---|---|---|
| R-401: tests fail when the code is wrong | KEEP | KEEP the rule. MODIFY: the reviewer checks it; content-gate's suppression check moves to project lint | One of three controls with real catches |
| R-403: bug fix test-first | KEEP | MODIFY: the rule and the review only. RETIRE the fix-commit hook (a warning with ~50 fires and no specific catch) | The practice is cheap and valuable |
| Lightweight RED for standard work (was R-412 for all tiers) | REINSTATE | NEW: a RED commit plus its failure line, with no lock | Closes the IAN-568 gap at 1 to 3 minutes a slice |
| Cross-model test authorship | REINSTATE as the default (owner decision) | MODIFY: Codex when available, otherwise a `test-author` subagent | Test independence without the three-agent cost |
| R-412 TDD lock (`tdd.sh`) | KEEP for high risk | KEEP for high risk only, with I1/I2/I3/I5/I8 | No product catch; real cost on standard work |
| R-410: test immutability | KEEP | High risk: the lock. Standard: reviewer diff of the RED commit | Keeps the value without the mechanism |
| R-411: role boundaries (`role-policy.json`) | KEEP for high risk | KEEP (`protected-path-guard` keeps only the lock and role parts) | Backs read-only reviewers too |
| Three-agent triad | MODIFY | Test author separated; implementer is the main session; critic retired | The critic has no recorded catch |
| R-509: verification before done | KEEP and strengthen | RETIRE the Stop hook. NEW: a `## Verification` section, reviewer check, and CI | 320 blocks, no catch, minutes per turn |
| R-517: independent review | KEEP | MODIFY: §6.1 bounds; heading check only | Real catches; the old mechanism was 1,535 lines with no catch |
| spec-conformance review | RETIRE as a stage | Folded into R-517 item 2 | No recorded catch |
| slice-critic | RETIRE | Optional for high-risk PRs, once, on the owner's request | No recorded catch |
| R-109: security review | KEEP | MODIFY: §6.2 bounds; ledger and artefact retired | Real catches; loops were structural |
| Security-surface detector | MODIFY | Advisory, anchored patterns | 103 of 553 files matched |
| R-110: risk tiers | KEEP | MODIFY: the narrower §4 list; the owner can override | Picks the process |
| R-514: owner merges | KEEP | Every merge asks (the slim guard from #187) | Owner approval is the gate |
| R-512: squash only | KEEP | Slim guard denies `--merge` | Cheap |
| build-fast | RETIRE | Delete | Owner decision |
| build-by-slice | KEEP | MODIFY: §5 loop per slice; stop for owner approval | Owner decision |
| Antagonistic audits (9 agents, gof) | KEEP, on demand | No hook nudges them (`audit-signal-check` retired) | Useful before launches |
| Ticket per finding (R-214, `finding.sh`, ticket gates) | RETIRE | Delete | Governance generating governance |
| Provenance and bookkeeping (R-213, R-503, close fields, report risk) | RETIRE | Delete | No consumer |
| 1:1 budget | KEEP | MODIFY: add principle 6 (maintenance counts) | Owner decision |
| R-708: subagent watchdog | KEEP, narrow | KEEP `agent-dispatch-guard` and the watchdog. Drop the rule line from mandatory | A real 6.5-hour stall; needed for cross-model dispatch |
| Integrity manifests (hook hashes, `manifest.json`, R-516, closure tests) | RETIRE | Delete | Gates guarding gates; 73% of commits touch the hashes |
| Harness profiles | RETIRE | Delete | Not needed once the tree is right |
| Translator and Codex/Cursor ports | KEEP | KEEP (owner decision); simplify inputs | Owner decision |
| Rule IDs and the rulebook | RETIRE | Fold the needed specs into skills; plain prose in `CLAUDE.md` | IDs and indexes created bookkeeping |

The full hook list is in §8.4, the stack files in §9, and the remaining R-0xx to R-9xx lines in C §4. That report found no reason to reinstate any of the 13 rules IAN-568 deleted.

## 8. Diff plan by file

### 8.1 `claude/CLAUDE.md` (rewrite, about 90 lines, no rule IDs)

Base it on the #187 version (owner preferences, code rules, git habits, models, writing) and add:

- the §3 principles, in short form
- the §4 risk line, and §5.1 and §5.2 in five lines each, pointing to `tdd-gated-dispatch`
- bug-fix test-first, and verification before done (§5.3)
- review bounds (§6, three lines), and the owner's per-PR approval
- the security posture (§6.2, three lines)
- the process budget with maintenance counted
- the memory index via `@import`

Drop the defaults index, the enforcer tags and the rulebook pointers.

### 8.2 `claude/PROTOCOL.md` (rewrite, about 80 lines, not auto-loaded)

Make it a short history: why the harness has this shape.

- the 2026-09 TDD harness
- the recursion failures, with numbers from §2
- IAN-568
- the #187 over-prune
- this recovery

End with the principles, so future sessions see why the gates are small. Delete the per-rule origin entries.

### 8.3 Skills

- **`tdd-gated-dispatch`** (rewrite, about 80 lines). Two modes:
  - *Standard:* the §5.1 loop, with the cross-model author and the Codex command (the current "Codex as test author" block becomes the default path), the RED commit, the one-dispute rule, and the fallback to `test-author`.
  - *High:* the §5.2 loop with `tdd.sh`.

  Delete the triad orchestration and the critic step.
- **`build-by-slice-require-review`** (rewrite, about 40 lines): plan the slices once, get owner approval, run the §5 loop per slice, one PR per slice, then stop until the owner approves or merges.
- **Retire:** `build-fast`, `task-start`, `task-cleanup`, `ticket-lifecycle`, `feature-create`, `repo-setup`, `add-stack-track`, `cleanup-specs-plans`, `resolve-user-feedback`, `all-hands`. *Owner decision D5:* keep any of these?
- **Keep:** `bug-hunt`, `documentation-create`, `spec-grounding` (strip IDs) and `gof` (on demand). `structure-conventions` is trimmed per §9.

### 8.4 Hooks

- **Keep:** `secret-scan`, `destructive-db-guard`, `mcp-action-guard`, `codex-billing-guard`, `global-repo-push-guard`, `harness-sync`, `agent-dispatch-guard`, `agent-watchdog-instruction`.
- **Modify:**
  - `destructive-command-guard`: trim from 910 to about 300 lines, keeping the git-hook-skip and `gh api DELETE` parts.
  - `destructive-ops-guard`: port from #187, with Docker allowed-list, `rm` tiers, the repo-root deny and the bash 3.2 fix.
  - `git-workflow-guard`: port the 116-line version from #187 and add the `## Review` heading check.
  - `dependency-add-guard`: ask message names the styling-library policy.
  - `no-em-dash`: Write and Edit only.
  - `conflict-markers`: use `git diff --check`.
  - `redact-output`: kept as is.
  - `protected-path-guard`: lock and roles only.
- **Retire:**
  - `verification-gate`
  - the push eslint, ruff and semgrep gates (CI runs these)
  - `commit-message-guard`, `constant-change-guard`, `pr-ticket-ref-gate`, `linear-todo-label-gate`
  - `fix-commit-requires-test`
  - `content-gate` and `structure-gate` (their valuable checks move to project lint and Semgrep)
  - `migration-defaults-guard` (the rule moves into DATABASE text)
  - every reminder hook
  - `session-start` (CLAUDE.md imports the memory index) and `session-end`
  - `task-state-tracker`, `draft-pr-on-first-push`, `pr-monitor-reminder`
  - `hook-integrity-check`, `enforcement-guard-check`, `redaction-guard-check`, `settings-change-guard`, `hookspath-drift-check`
  - `parallel-session-check`, `model-switch-guard`, `audit-signal-check`, `build-cheatsheets`
- **Infrastructure to retire:** `hook-hashes.txt`, `manifest.json`, `harness-profiles.json` and `apply-profile.mjs`, the fixture shard runner, the rule-judge workflow, `build-lane.sh`, task tiers, the security ledger.
- **Fixture budget:** each kept hook gets fixtures no larger than the hook, testing decisions only. Rule-prose fixtures are deleted.

### 8.5 Agents and prompts

- **`pr-reviewer`:** rewrite to §6.1, including the must-not list and the severity handling.
- **`security-reviewer`:** rewrite to §6.2 (frozen controls, round scope, severity ceiling, once-per-control test MEDIUM).
- **`test-author`:** keep. Prompt: acceptance criteria only, never the implementation plan's code; report the RED.
- **`implementer`:** keep for high-risk subagent use.
- **Retire:** `slice-critic`, `spec-conformance-review`. The 9 audit agents stay on demand.
- **Prompts:** keep `codex-pr-review-prompt` (renamed `review-prompt`), `security-review-prompt` and `spec-template`. Retire the rest.

### 8.6 Verification and CI

- **CI workflow** (from #187): the remaining hook fixtures, the sync fixture, and the port `--check` runs, on Linux and macOS.
- **`security.yml`:** Semgrep and CodeQL kept.
- **Delete:** `rule-judge` and `security-self`.

## 9. Stack convention files

Full per-rule tables are in D and E. Rule IDs, enforcer tags, "Moved from PL" headers, and anything an existing linter, formatter or type checker enforces are removed everywhere. The "existing repository wins" frame becomes explicit: layouts and library choices are defaults for new code, not migrations.

### CLAUDE-STYLING.md and the styling policy (most important)

Put this block at the top of `CLAUDE-STYLING.md` and in the Stack section of `CLAUDE-FRONTEND.md`:

```
## Styling policy

- SCSS Modules (`.module.scss`) plus CSS custom properties are the default for all JS/TS frontend styling.
- Do not introduce Tailwind or any utility-first CSS framework, CSS-in-JS (styled-components, emotion, vanilla-extract, inline style objects), or any other styling framework or component-styling library, unless the owner explicitly asks for it. A new styling package is an owner decision.
- If the repository already uses a different styling system, keep using it and match it. Do not migrate it, mix a second system in, or convert it to SCSS Modules without an explicit owner request.
- Extend the existing design tokens, custom properties, mixins and partials. Do not replace them, fork a parallel token set, or hardcode a value a token already names.
- No BEM, no plain `.css` for new component styles, no `classnames`/`clsx`.
```

- **Loading:** widen the STYLING `paths:` to include `**/*.tsx`, `**/*.jsx` and `**/*.vue`. REACT and VUE get the one-line pointer "Styling follows the Styling policy in CLAUDE-FRONTEND.md."
- **Fix a real defect:** the rule "`outline: none` on inputs" becomes "never remove a focus indicator without an equally visible replacement".
- **Delete:** the 2-level nesting rule (it contradicts the file's own 3-level line), the 100-line section separators, and the px, type and radius scales (these are design values).
- **Review:** the reviewer checklist cites the styling policy.
- **Target:** about 25 lines.

### CLAUDE-FRONTEND.md (257 lines to about 35)

- **Keep:**
  - strict TypeScript with no gratuitous `any`
  - the existing state-management and server-state layers (no Redux or Zustand added)
  - the styling policy block
  - avoiding unnecessary dependencies
  - server/client boundary discipline
  - the existing architecture wins
  - small coherent components, with no line-count rule
  - the incident lessons: no flow ships without E2E (merged from PL3 and PL20), three-browser Playwright (PL12), and the stale-dev-server lesson (PL11, reworded)
- **Remove:** import order, the eslint lists, and the Prettier text.
- **Move:** negative-input tests and test cadence to global.

### Framework files

- **REACT** (158 lines to about 15):
  - function components
  - server state through the query layer, never in effects
  - the styling pointer
  - native elements or the existing primitives library
  - test by role
- **REACT removals:** `useCallback` everywhere, `displayName`, `React.FC`.
- **NEXT** (117 lines to about 20):
  - App Router default and the `'use client'` boundary
  - thin pages
  - the `NEXT_PUBLIC` rule
  - Known traps: Vercel and pnpm (PL5 to PL9)
- **VITE** (95 lines to about 14): router default, env boundary, global styles.
- **VUE** (195 lines to about 25):
  - `<script setup lang="ts">` and `vue-tsc`
  - vue-query, never copied into app state
  - SSR safety
  - no `v-html`
  - the styling pointer
- **NUXT** (163 lines to about 25):
  - SSR default and boundaries
  - the auth-gating principle
  - a per-request API client with header forwarding (one `X-Forwarded-For`)
  - the proxy forwards the query string
  - cookie-presence-only Nitro gate
  - Sentry setup moves to OBSERVABILITY

### CLAUDE-BACKEND.md (811 lines to about 80)

- **Keep:**
  - the layers and their direction
  - startup order (secrets before dynamic import, `validateEnv`, middleware order)
  - router-level auth, `safeParse`, and the error envelope
  - catching 23505 locally
  - session `Secure` unless development, from the 2026-09 audit
  - the CORS wildcard and `null` rule, from the same audit
- **Move:** staged migrations to DATABASE; test cadence to global; a shared container block; the file-naming table to `structure-conventions`, fixing its contradiction with the directory tree.
- **Remove:** import order, the export tables, Prettier, the `.js` extension text, TS pattern notes, the code samples, and the 400-character port regex.
- *Owner decision D2:* the error envelope becomes `{error:{code,message}}`, the same in BACKEND and PYTHON.

### CLAUDE-DATABASE.md (603 lines to about 120)

Three parts.

1. **Engine-neutral PostgreSQL conventions:**
   - naming, UUID primary keys, `timestamptz` and `updated_at`
   - foreign keys and delete semantics, indexes, tenant scoping
   - `pg` returns `numeric`, `bigint` and `COUNT(*)` as strings
2. **Query discipline,** with one short example each:
   - N+1 avoidance via `= ANY`, JOIN, lateral `json_agg` and `unnest` writes
   - transaction boundaries: no network calls inside a transaction; an outbox for side effects; consistent lock order; one connection used serially
   - atomic read-modify-write
   - bounded reads
   - parameters, plus an allowlist for identifiers
   - query-budget tests and the `queryCount` warn threshold
   - an idempotency key under a unique constraint
3. **Migration safety:**
   - staged expand, backfill, contract
   - a Neon-branch rehearsal that checks row counts, foreign keys, CHECK constraints and the test suite
   - never a one-shot destructive change against production; additive changes are exempt
   - post-deploy endpoint verification (PL15)
   - the destructive-migration code sweep (PL2, and PL19 generalized to removing any feature)
   - the removed-column bug a mocked test missed (PL1)
   - migration defaults (from the retired hook)
   - a three-line node-pg-migrate section

Optional additions (*owner decision D3*): `CREATE INDEX CONCURRENTLY`, `lock_timeout` on DDL, and staged NOT NULL.

### CLAUDE-OBSERVABILITY.md (282 lines to about 90)

- **Keep:**
  - request ID: validated against `^[A-Za-z0-9._-]{1,64}$`, minted when absent, echoed, bound to the log context
  - one structured logger, with its field conventions
  - no secrets or PII in logs
  - error logging (500 handler logs and reports; expected failures at warn with a fallback)
  - the analytics registry
  - outbound calls with a timeout and request-ID forwarding
  - health and readiness as the single home: readiness timeout and 503 body
  - `show_locals=False` (an incident leaked the database password)
  - `ProcessorFormatter` routing
  - the streamed-body 413
- **Fix:** the TypeScript `pino-http` sample accepts any `X-Request-Id`; it gets the same validation as Python.
- **Remove:** the lint-code mentions.

### CLAUDE-PYTHON.md (411 lines to about 145)

- **Keep:**
  - typed boundaries
  - the FastAPI app factory and lifespan; nothing runs at import time
  - pure ASGI middleware, with the order listed
  - one transaction per request, with `scope="function"` because a commit can fail after a 201
  - never share a connection across asyncio tasks
  - repositories never commit
  - bcrypt in `asyncio.to_thread`
  - explicit error behavior
  - real PostgreSQL integration tests
  - structured logging
  - the security pitfalls: rate limit keyed on `client.host` with full `/v1` paths, `FORWARDED_ALLOW_IPS` never `*`, the atomic password reset, the webhook ledger, TLS verify-full
- **Restore** the data-access text the trim dropped, in SQLAlchemy Core form:
  - no query per element
  - one transaction per unit of related writes, with no client calls inside
  - guarded read-modify-write (`with_for_update`, conditional `UPDATE ... RETURNING`)
  - keyset pagination
  - a query-count test via `before_cursor_execute`
- **Remove:** the Tooling and Enforcement sections, the 60% coverage floor, naming and module-order heuristics, and the samples. The idempotency-key spec shrinks to a 3-line invariant.
- **Fix:** "a failing test is fixed or deleted" becomes "fixed, never deleted to get green".
- **Verify** in Voyager: whether httpx's `ASGITransport` skips the lifespan, so the engine is never created in tests.
- *Owner decision D4:* fail startup in production when the Resend key is missing.

### CLAUDE-GO.md (290 lines to about 40) and CLAUDE-RUBY.md (256 lines to about 35)

- **Keep:** the layer rule, error handling, env fail-fast, the CORS parse and its traps (go-chi empty origin means allow-all; Ruby's `\A...\z` anchors), session `Secure`, and real-DB integration tests.
- **Remove:** the code dumps and the linter duplication.
- *Owner decision D6:* keep them trimmed (recommended) or archive them to `docs/`.

### `skills/structure-conventions` (57 lines to about 20)

- **Keep:** the directory layouts for new code (Express, FastAPI, web client, Nuxt), tests in a sibling directory (Go excepted), the build-smoke test, and one public function per module in services, API and clients.
- **Remove:** everything a lint rule states.

## 10. Owner decisions needed

1. **D1. Security LOWs:** may a LOW be noted for later instead of fixed before merge? Recommended: yes.
2. **D2. Error envelope:** `{error:{code,message}}` in both BACKEND and PYTHON. Recommended: yes.
3. **D3. Database additions:** add `CREATE INDEX CONCURRENTLY`, `lock_timeout` and staged NOT NULL? Recommended: yes, marked as additions.
4. **D4. Missing Resend key:** fail startup in production. Recommended: yes.
5. **D5. Retired skills:** keep any of them (`feature-create`, `repo-setup`, `add-stack-track`, `all-hands` and so on)? Recommended: retire all.
6. **D6. Go and Ruby:** keep them trimmed, or archive them? Recommended: keep trimmed.
7. **D7. #187:** close it as superseded, and port the guards from it? Recommended: yes.

## 11. Implementation plan

Each PR comes from `main` and follows this spec's own standard loop: RED where code changes, one review, verification, then stop for owner approval. Docs-only PRs (1, 4 and 5) get one review with no tests. Estimates assume no surprises.

| # | PR | Files | Verification | Estimate |
|---|---|---|---|---|
| 1 | Rules and principles | `claude/CLAUDE.md` rewrite; `claude/PROTOCOL.md` rewrite; delete `claude/rulebook/`; regenerate the ports | Port `--check`; read-through review against §3 to §6 | 1.5 h |
| 2 | Workflow: skills and agents | `tdd-gated-dispatch` and `build-by-slice` rewrites; retire the §8.3 skills and `slice-critic`/`spec-conformance-review`; rewrite `pr-reviewer`, `security-reviewer`, `test-author` and the review and security prompts; port regen | Port `--check`; a dry-run of one standard slice on a toy change (RED commit, GREEN, review) | 2.5 h |
| 3 | Hooks and infrastructure | Retire the §8.4 hooks and infrastructure; trim `destructive-command-guard`; port `destructive-ops-guard` and the slim `git-workflow-guard` from #187 plus the heading check; `dependency-add-guard` message; `protected-path-guard` to lock and roles; CI workflow; `settings.json`; fixture trim | Remaining fixtures on Linux and macOS CI; sync fixture; port checks | 3.5 h |
| 4 | Backend stack files | BACKEND, DATABASE, OBSERVABILITY, PYTHON per §9 and D | One review for accuracy against D; no tests | 2 h |
| 5 | Frontend stack files | FRONTEND, REACT, NEXT, VITE, VUE, NUXT, STYLING, GO, RUBY and `structure-conventions` per §9 and E, including the styling block and the `paths:` change | One review against E; check that the STYLING `paths:` include `.tsx` and `.vue` | 2 h |

Totals and follow-ups:

- **Total:** about 11.5 hours across 5 PRs.
- **Order:** 1 and 2 first (they set the loop the others follow), then 3, then 4 and 5, which can run in parallel.
- **After PR 3 merges:** close #187; resolve #185 against the new tree and merge it.
- **Then:** resume quota PRs 3 to 5 under the new loop.

## 12. How we'll know it worked

After the next 10 product PRs on Voyager:

- **Process time** is at or under implementation time.
- **No PR** has more than 2 general review rounds or 3 security rounds.
- **Every behavioral PR** has a RED commit, or a stated exception.
- **Harness commits** are under 20% of all commits.

Count escaped bugs per PR. If they rise, add one control, choosing the cheapest tier that would have caught them.
