# C: Pruning (IAN-568) and recursive-process meta-analysis

Read-only research. Sources: /home/user/ag-main (main, post-IAN-568, 52 commits from #127), /home/user/nullvoidundefined/claude-global-rules (161 commits, 2026-05-27 to 2026-09-12), /home/user/agent-governance branch claude/streamline (PR #187, reference only). All counts below were computed from those trees on 2026-10-03.

"Five-question test" is not defined in any repo doc I could find. I used the five attributes the brief lists for hooks as the test: (1) purpose, (2) real failure prevented, (3) could a cheaper tier catch it, (4) false-positive risk, (5) fixture burden. Confirm that is what the owner means.

---

## 1. What IAN-568 (676f39b, #182, 2026-10-02) changed

Size: 200 files, +4,542 / -13,045. Of the deletions: about 3,400 lines generated ports (codex/ cursor/), about 3,300 fixtures, about 4,000 hook and enforce code. 16 commits squashed (proposal, owner decisions, then edits).

### Governing principle: the 1:1 budget
"Process time never exceeds work time": tickets, gates, reviews, fix rounds, PR bookkeeping, handoffs together. Only exception: the R-109 security review may run past budget while each round still finds MEDIUM or higher. Evidence cited: voyager IAN-82 PR 1 about 22 h for about 900 lines (10-15:1); PR 2 about 6 h active plus 5 h 18 min waiting on the owner for about 250 lines (7:1 to 13:1); a clean standard PR modelled at 100-170 min process vs 25-40 min work (about 4:1) before any interlock fires.

### Rules (CLAUDE.md 143 lines/30,085 B to 52 lines/7,992 B)
- 14 mandatory lines loaded: R-101, 102, 104, 109, 110, 201, 203, 204, 211, 308, 401, 403, 514, 517.
- Mandatory but hook-delivered only (text leaves CLAUDE.md): R-003, 105, 106, 107, 207, 507, 908.
- Everything else became a "default" indexed by ID (skip with a one-line reason).
- Deleted (13, tombstoned in rulebook): R-206, 213, 215, 322, 408, 409, 502, 503, 506, 510, 511, 906, 907. Earlier (IAN-518, #176): R-002.
- Merged: R-103, R-108, R-202 into R-102; R-405 into R-204.
- PL incident rules moved from global memory into stack convention files; PL4, PL10 deleted. CLAUDE-PYTHON.md trimmed to rules no linter checks.
- Risk tiers (R-110, landed 2026-10-01 in #177, kept): high-risk (security, money, concurrency; or R-109 detector flags the range) runs TDD lock + test-author/implementer/slice-critic triad; standard-risk runs a "lean tier" (tests alongside code, one sonnet review per PR). Unsure defaults to high. Owner tile per control with no natural endpoint (redaction, rate limits, allow/deny lists) before code.
- Review: R-517 one round, second only if round one finds a HIGH; fixes are ordinary commits with a test (not TDD slices); LOW findings become tickets after last round.

### Hooks removed (unregistered and deleted)
task-provenance-gate, codex-test-author-guard, push-golangci-gate, push-rubocop-gate (plus configs and Go/Ruby data-access checkers), clean-code-reminder (+ scan.mjs), ticket-at-start-gate, push-feature-docs-gate (R-607/608 push gate), scope-widening-gate, lexicon-gate; doc-sha-reachability (R-215). Registrations 62 to 52 (56 to 47 distinct commands); hook .sh files 93 to 84; fixture files 234 to 223.

### Hooks softened or fixed (not removed)
- fix-commit-requires-test: deny to non-blocking warning.
- structure-gate: R-311/R-312 directory checks to warnings (catch-all, test placement, Express root, components still deny).
- commit-message-guard: dropped R-214 and R-506 checks; only the subject is judged; heredoc bodies no longer asked.
- protected-path-guard (I1): collateral test outside the red slice is an ask, not deny.
- tdd.sh (I3): pytest classifier accepts any exception in body/setup as RED.
- git-workflow-guard (I6): R-517/R-109 review range may end before clean base merges and commits listed `fixed <sha>` in the findings table.
- security-surface: skips docs/ and *.md for path patterns (handoff PRs matched `session`).
- log-rule-fire (I9): skips scratch repos, appends session ID.
- task-tier.sh no longer refuses a tier without a ticket; judge drops R-315.

### Skills
ticket-lifecycle opens at PR time with six required fields (title, tier, branch, started_at, actual_minutes, risk); task-start/task-cleanup shortened to a lean checklist; tdd-gated-dispatch narrowed to high-risk with interlock fixes; build-by-slice-require-review runs one review round unless round one finds a HIGH. Skills total 1,690 lines across 17 skills remain.

### Explicitly kept
All security/secret/destructive guards, the R-109 security review and its semgrep/CodeQL CI, R-110 risk classification, the TDD lock and triad (high-risk only), R-517 review gate in git-workflow-guard (grammar moved to task-cleanup skill), hook-integrity manifest and hash file, generated ports for Codex/Cursor, the rule manifest and R-516, audits and audit agents, PROTOCOL.md history, verification-gate Stop hook (R-509, `expected-red` wiring I5 proposed), draft-PR hook, ticket gates (pr-ticket-ref-gate, linear-todo-label-gate), telemetry. IAN-565 (TDD "disputing" phase) dropped.

### What it did not do (important for the recovery proposal)
- Removed 10 of 62 hook registrations. About 47 distinct hooks, 17.2k lines of hook/enforce code and 35.9k lines of fixtures remain.
- Did not touch the structural tax sources named by the 09-19 and 09-26 audits: checked-in hash manifest, checked-in generated ports, copy-based sync. The prune itself had to edit three trees (claude/, codex/, cursor/) plus manifest, profiles, port maps and CI.
- Regrowth started within 24 h: #184 (2026-10-03) added R-708 as a MANDATORY rule: 2 hooks (agent-dispatch-guard 65 lines, agent-watchdog-instruction 51), a 165-line watchdog, a 269-line fixture, a manifest block, port updates, and a 186-line security-review record JSON: 837 inserted lines in 22 files for one incident (a foreground subagent silent for 6.5 h). #183 added a quota file and pace calculator (+1,388 lines, 6 files) the same day.
- The owner decision 1 ("wait for the full pruning; land as one planned change") concentrated all of it into one 200-file commit with 16 sub-commits, itself an example of governance cost.

### Reference: PR #187 claude/streamline
709 files, +5,496 / -99,596 vs main. CLAUDE.md 53 lines in 6 sections (Never, How to work, Code, Git and PRs, Models and cost, Writing). 15 hook registrations (secret-scan, conflict-markers, destructive-db/command guards, codex-billing, global-repo-push, git-workflow-guard shrunk 1,535 to 116 lines, destructive-ops-guard, mcp-action-guard, redact-output, harness-sync, agent dispatch/watchdog pair). Hook dir 19 files, 3,058 lines; fixtures 3,372 lines (about 1.1:1). Skills 5, agents 10. Contains the explicit line "Keep process proportional... Don't add gates, checklists, or fixtures the owner didn't ask for." Use as the lower bound; it removes risk tiers, TDD lock, ports, manifest, tickets, handoffs, audits.

---

## 2. Recursive process pathologies (evidence)

### 2.0 Size of the maintenance share (git logs)
| Measure | ag-main (52 commits, 09-24 to 10-03) | claude-global-rules (161 commits, 05-27 to 09-12) |
|---|---|---|
| Commits touching claude/hooks or claude/enforce | 38 (73%) | 82 (51%) |
| Commits touching hook-hashes.txt | 38 (73%) | 22 (14%) (manifest introduced mid-period) |
| Commits touching generated codex/ or cursor/ | 27 (52%) | 0 (ports not yet generated) |
| Commits touching fixtures/tests | 37 (71%) | 62 (39%) |
| Commits touching any plumbing (hashes, generated ports, port maps, manifest, tests, translate, CI) | 43 (83%) | 66 (41%) |
| File touches that are plumbing | 983 of 1,713 (57%) | 203 of 931 (22%) |
| fix commits | 8 (15%) | 25 (16%) |

Neither repo contains product code; "other work" is rules, skills, docs, handoffs. So the useful ratio is machinery-touching to pure rule/doc commits: ag-main about 6:1 (46 of 52 touch hooks/enforce/ports/records vs 6 pure prose); predecessor about 2:1 (107 of 161 vs 54).

Corroborating figures already in the audits: 89 of 282 commits (32%) touch hook-hashes.txt through 09-19; later 49 of 67 (73%) touch hashes or ports (2026-09-26 audit F3); about 64% (44 of 69) of fixes were harness repairing its own plumbing (2026-09-19 maintenance-tax); harness was 85% then 75% of all merged PRs across the owner's four repos (78 of 104); IAN-121 fix share 29% "inconclusive, composition structural"; all 8 fixes on 09-24 repaired machinery added in the prior 7 days. Seven of 52 ag-main commits (13%) are purely about making fixtures runnable: #129 (machine-wide lock), #133, #136, #154 (per-worktree queue), #169 (affected-only), #180 (CI once per PR), #181 (log the lock wait).

### 2.1 Review spawning review
- Five review layers can stack on one change: Codex/adversarial spec review in task-start, per-slice slice-critic (high-risk), R-517 pr-reviewer, R-109 security-reviewer, plus native /code-review, bug-hunt, spec-conformance-review (rulebook/agents.md precedence paragraph needed to say which one applies).
- Head-pinning: every commit, docs-only included, moved the head and forced a re-review (IAN-286, 2026-09-23). "Order" clause in R-517 exists only to stop "one review per PR from turning into two". PR #106's review described a tree that no longer existed. Later mitigated by IAN-516 and I6, which are more machinery on the gate.
- R-517 reviewer mechanics revised 5 times in 5 days (#71, #119, #121, #128, #130); Codex-as-blocking-reviewer added 09-19 and reversed 09-24 (2026-09-26 audit F4).
- Security review: sync.sh release validation needed 7 rounds, each finding one new path-escape hole (PR #159); 13- and 8-round reviews recorded. Only place the owner accepted unbounded rounds; PR #16 shows rounds 3+ producing only LOWs elsewhere.
- Voyager IAN-82 PR 1: 8 rework rounds, 22 h, 900 lines; a regex PII scrubber went through four critic rounds before anyone asked for its threat model.

### 2.2 Fixes reopening the lifecycle
- Before IAN-568 every review fix was a full TDD slice (open, red, RED commit, green, commit, close; two full-suite runs of about 95 s each per slice).
- Moving the head re-triggers R-517 range check, R-109 ledger (keyed by commit), bookkeeping commits ("must finish before review"), then PR body edits.
- TDD DISPUTE loop (I1): a schema migration broke older tests; the lock denied every test file; the only exit was owner deleting `.claude/tdd-lock.json` by hand (twice, then three times); 2 h on a one-hour migration; 5 h 18 min owner wait; once the lock stopped blocking the next three slices took 6, 5, 13 min. IAN-565 specified a new `disputing` phase plus approval-recording hook (high risk, spec + slice plan, no code) to fix the lock: governance feature to repair governance; dropped in decision 7.
- Formatter re-hash (I2): `tdd.sh red` hashes a test, pre-commit rewrites it, `green` reports tampering; black vs ruff mismatch cost 30 min; open since 09-26 as IAN-420.
- RED classifier (I3): 4 of 9 refusals on one PR, about 94 s each.
- R-509 verification gate blocks Stop on a red suite, including the deliberately red slice; `expected-red` was built and never called (320 real blocks).

### 2.3 Tests generated for process
- Nine fixtures (929 lines) assert that rule prose contains certain words (`*rule-text.test.sh`: r001 x2, r109 x2, r110, r334, build-fast, merge-authority, wall-time). IAN-568's own commit message says "the rule-text fixtures follow the moved text".
- Closure tests that check the bookkeeping: manifest-fixture-closure, hook-hashes-closure, index-settings-sync, lexicon-spec-sync, tdd-red-manifest-drift, harness-profile-closure, dangling-refs, claude-md-lint, skills-lint.
- Tests of the test infrastructure: run-fixture-shards x3, suite-wrappers lock, ci-fixture-scope x2, fixture-implementation-root(+sabotage), git-env-isolation, hook-latency, hook-path-walk-budget. Together with the closure and rule-text tests: about 5,140 lines of fixtures that test the harness's own plumbing; run-fixture-shards.sh itself is 765 lines.
- R-516: every mechanizable rule needs a manifest entry and a fixture, mechanized by a bidirectional `# Covers:` closure test whose own spec admits "a dishonest `# Covers:` line passes".

### 2.4 Tickets for findings
- R-214: every task/bug/optimization noticed becomes its own ticket; commit refused without a `Refs:` trailer (18 real denies, no catch). R-517: LOW findings after last round become tickets (`finding.sh add --kind --value low`), answered in the PR with the key. IAN-471 (#156) value-rates every finding; finding-ledger fixture. Ticket close records `findings_by_round`, `escaped_bugs`, `rework_count`, and `report risk` compares tiers "after ten PRs": data about the process, consumed only by process decisions.
- Process audit 2026-09-26 noted 14 non-trivial PRs without tickets, then the ticket-at-start gate (140 real denies, no catch) was added, then removed (silently off between PRs #78 and #80 with no harm), then replaced by pr-ticket-ref-gate and linear-todo-label-gate. A Todo-label hook exists because 31 of 32 Todo tickets lacked a label (IAN-473): hook to maintain tracker hygiene.
- 2026-09-18 criticism #5 "freeze new governance features" was not followed: seven new gates or rule blocks (#78, #83, #118, #124, #137, #140, #141) plus a detector and reviewer agent (#142, #143) landed within a week.

### 2.5 Provenance and bookkeeping
- R-213 task provenance tag (117 tokens, hook, 6 denies, no catch, deleted). R-503 percentage shares and timestamps (deleted). R-606 eight measured ticket fields (cut to six; estimate_ratio and human_speedup no consumer). `## Codex review` PR-body grammar: heading, reviewer, model, range lines, exactly one heading, fenced-code awareness, HTML-comment hardening, all parsed by git-workflow-guard (1,535 lines). security-review-ledger directory protected as a gate input. Session handoff with SHA verification, 8 KB cap, session metrics, task-state JSONL, rule_fires.md/rule_misses.md routing in session-end.sh (431 lines, 445 fixture lines). Handoff was 32,976 B against its own 8 KB cap and carried IAN-157 forward in 14 of 15 versions; handoff PRs were security-flagged because the path contained `session`.
- Telemetry (rule-fires.log, 20,312 lines): R-517's 8,663 denials and R-512's 3,239 were 99% and 98% fixture noise (up to 168 fires per minute); 38 hooks never log; 18 of 25 advisory hooks never call log_rule_fire; the retirement-candidates file read by session-start is never written. The measurement system measured its own tests.

### 2.6 Hooks needing fixture suites to prove the hooks (counts)
Whole-tree: 248 fixture files, 35,869 lines vs 11,237 lines in claude/hooks and 5,997 in claude/enforce scripts: 2.1 fixture lines per code line. For registered hooks only (named fixtures, excluding shared files): 9,297 hook lines vs 8,947 named-fixture lines, about 1:1; worst cases:
| Hook | Hook lines | Named fixture lines | Fixture lines mentioning it |
|---|---|---|---|
| git-workflow-guard | 1,535 | 1,600 (3 files) | +3,766 (13 files) = 5,366 total, 3.5:1; includes 8 security-merge-gate files, 2,808 lines |
| push-semgrep-gate | 271 | 944 (5 files) | 3.5:1 |
| commit-message-guard | 244 | 368 (6 files, incl. copilot-cases, round2, round3, review-cases) | 1.5:1 |
| spec-glossary-check | 70 | 249 | 3.6:1 |
| push-eslint-gate | 101 | 242 | 2.4:1 |
| pr-ticket-ref-gate | 148 | 233 | 1.6:1 |
| dependency-add-guard | 42 | 129 | 3.1:1 |
| new-file-header-reminder | 30 | 89 (+387 shared) | 3:1 |
| agent-watchdog + dispatch guard (R-708) | 116 + 165 script | 269 | 1:1 |
| protected-path-guard | 622 | 280 (+3,076 shared) | 5.4:1 |
Three commit-message-guard fixture files are named after review rounds ("copilot-round2/round3"): fixtures accreted per review round.

### 2.7 Governance maintenance excluded from cost
- The 1:1 budget is defined over a work PR's process (tickets, gates, reviews, fix rounds, bookkeeping, handoffs). It excludes: regenerating hash manifest/ports, fixing hooks and fixtures, audits and audit remediation (2026-09-16/18/19/26 audits each spawned a program: IAN-381 security, IAN-427 remediation, IAN-518 classification, IAN-568 pruning), proposals, and the tests of the rules themselves.
- The harness itself had destructive incidents: first `sync.sh --delete` wiped a live workspace, Codex config and a 696 KB state file (23592ae6); a test inside a pre-push hook rewrote shared doppelscript git config and broke every worktree (lesson now in global memory); 8 gates failed open when HOME was unset (2026-09-26 F6).
- Audits measure the system's own activity, never outcomes (2026-07-31 and 2026-09-18 criticism; 09-26 F14). No false-positive adjudication or override-with-reason path exists.

### 2.8 Gates protecting gates
hook-integrity-check (130 lines, warns only, never blocks) over a 324-line hook-hashes.txt that 73% of commits regenerate; enforcement-guard-check (verify each hook the manifest requires is registered); settings-change-guard (ConfigChange guard so a mid-session settings edit cannot drop a hook); redaction-guard-check (verify secret-scan and redact-output are active); hookspath-drift-check; protected-path-guard protecting `.enforce.json`, lock, verify.sh, baseline and the security ledger; destructive-command-guard denies tampering with ~/.claude/hooks; settings.json deny list repeats it; R-203 "approved" word; manifest-fixture-closure and hook-hashes-closure fixtures; R-516. Chain length: a single Bash call spawns 22 PreToolUse hooks (about 570 ms median sum). The only recorded catches of agent misbehaviour by R-203 were two guard evasions both triggered by guard false positives.

### 2.9 Regrowth timeline (the loop in action)
09-18 criticism audit "freeze governance" to ignored (7 new gates by 09-26) to 09-26 process audit (15 findings) to remediation program spec (#148) to 10-01 harness audit (IAN-518, 240 items classified) and "lean profile" switch (#175) and R-110 (#177) to 10-02 prune (IAN-568) to 10-03 R-708 mandatory rule + 2 hooks + watchdog (#184) and quota pace (#183). Each reform is itself a multi-file governance PR; e.g. #121 and #71 touched 33 files each and were reversed in hours or days.

---

## 3. Registered hooks (ag-main claude/settings.json): 52 registrations, 47 distinct

Order of preference: compiler/formatter/linter > ordinary test > CI check > simple hook > stateful governance subsystem. Fixture burden = named fixture lines vs hook lines. FP = false-positive risk (evidence where known).

### PreToolUse
| Hook (lines / fixture) | Purpose | Real failure prevented | Cheaper tier? | FP risk | Class |
|---|---|---|---|---|---|
| agent-dispatch-guard (65 / 269 shared w/ watchdog) | Deny foreground long-running subagents (R-708) | One foreground test author silent 6.5 h (voyager PR 5) | No (needs a tool boundary); but a 1-line rule + background default also works | Low | MODIFY: keep only if kept as a standalone 65-line hook; drop the watchdog subsystem (see PostToolUse). Post-prune regrowth, test case for the anti-recursion principles |
| secret-scan (214 / 56 named, +1,306 shared) | Deny secrets/credential literals in Bash, Write, Edit | 2026-04-08 production key on command line | Partly (gitleaks/GitGuardian in CI catches commits, not argv/transcript) | Medium: credential-shaped literal in fixtures; GitGuardian FPs | KEEP (safety floor). MODIFY: shrink fixture burden |
| no-em-dash (91 / 20) | Deny U+2014 (R-207) | Style only | Yes: Write/Edit-only check or markdown lint | High: 107 real denials, FPs on escapes | MODIFY: Write/Edit only; drop Bash scan (Bash text is command strings), or RETIRE and keep the prose line |
| fix-commit-requires-test (156 / 113) | Warn on fix: commit without staged test | Optimism-driven debugging | Reviewer/CI; 50 real denies pre-IAN-568 with one unspecific claimed catch | Medium (now warn only) | RETIRE (156 lines to emit a warning the CLAUDE.md line already says) |
| conflict-markers (51 / 42) | Deny commit with markers | Broken build | Yes: `git diff --check` / pre-commit / CI | Low; only recorded fire was a false positive | MODIFY: replace with git pre-commit or CI line; keep only if free |
| commit-message-guard (244 / 368 in 6 files) | Deny non-conventional subject, >2 triage IDs | Messy history | Yes: with squash-merge only the PR title lands on main; commitlint on PR title in CI | High: 72 real denies, heredoc FPs, 3 fixture files named for review rounds | RETIRE (move to CI PR-title check) |
| destructive-db-guard (156 / 58) | Deny prod destructive SQL; ask staging/remote | Staging wipe (integration test cleanup against remote DB) | No | Low | KEEP |
| destructive-command-guard (910 / 90, +881 shared) | Catch destructive forms globs cannot (gh api mutating, curl\|sh, hooksPath, --no-verify, ~/.claude/hooks tamper) | Bypassed permission globs | Partly (settings deny list covers literal forms) | Medium (long parser); 910 lines is 3x the next largest simple hook | MODIFY: keep core (curl\|sh, gh api mutation, hooksPath, rm of home/root), drop `--no-verify` and ~/.claude/hooks tamper (gate protecting gate); target under 300 lines |
| codex-billing-guard (48 / 53) | Ask before codex CLI would bill metered API | Silent API billing (money) | No | Low | KEEP |
| protected-path-guard (622 / 280 + 3,076 shared) | TDD lock: deny gate inputs, locked tests, ledger dir; ask for collateral tests | Agent weakening its own tests/gates | Ordinary test/CI (CODEOWNERS or required review for .enforce.json) | High: 331 real denials, no product catch; DISPUTE loop; manual lock deletion x3 | RETIRE the lock; MODIFY to a small deny list for gate inputs only (defer to TDD researcher) |
| global-repo-push-guard (142 / 119) | Scan outgoing diff of the public governance repo for secrets/home path | Leak via public remote | Partly (CI secret scan on repo) | Low | KEEP only if the repo stays public and CI does not scan; else CI |
| git-workflow-guard (1,535 / 5,366 incl. shared) | R-514 main push/merge ask, R-512 squash-only, R-517 PR-body "Codex review" grammar and range, R-109 security ledger, R-518, trivial ledger, docs/reviewed tails | Merging unreviewed; merge flags | Yes for most: GitHub rulesets (squash only, required review, required checks) + CI for security review record | High: R-517/R-512 denials mostly missing PR-body sections or wrong flag; the largest recursion engine | MODIFY heavily (streamline version is 116 lines): keep main-push ask and security-touching merge ask; RETIRE body grammar/range chase; move squash-only to a repo ruleset |
| push-eslint-gate (101 / 242) | Run enforcement ESLint over pushed TS | Style/AST rules (R-319,321,323,324,326,327) | It IS a linter; belongs in project CI/pre-commit, not a harness hook | Medium | MODIFY: delete the hook, ship the ESLint config for projects to run in CI |
| push-ruff-gate (166 / 146 +414) | Same for Python + data-access checker | N+1 (R-361), transaction misuse | Linter; CI | Medium: unpinned uvx fallback fails open | MODIFY: as above (CI) |
| push-semgrep-gate (271 / 944 in 5 files) | Local semgrep security pack on pushed code, fail-closed | Security holes (R-109 catches came from review, not this gate) | Yes: CI semgrep/CodeQL workflow already exists (security.yml) | High: fails closed when semgrep absent | RETIRE locally, rely on CI workflow (keep rule pack) |
| pr-ticket-ref-gate (148 / 233) | Deny `gh pr create` with no `Refs: KEY` | Untracked work | Yes: PR template + CI check, or nothing | Medium | RETIRE (ticket bookkeeping; tickets are optional) |
| constant-change-guard (71 / 67) | Ask when push removes a constant value still in tests | Stale assertions | Yes: those assertions fail the test run in CI | Low-medium (13 real asks) | RETIRE (CI test run catches it; keep the one-line prose reminder) |
| audit-signal-check (93 / 84) | Advisory: 5+ commits on a surface suggests an audit | Missed audit trigger | N/A advisory | n/a | RETIRE (audits are owner-invoked; advisory feeds the audit loop) |
| build-cheatsheets (46 / 71) | Auto-run repo's cheatsheet builder on push in trusted repos | Doc drift | CI/pre-push in that repo | Low | RETIRE (executes repo scripts from a hook; ancillary) |
| migration-defaults-guard (83 / 98) | Deny nested-quote/bare-string `now()` defaults in migrations (R-328) | Migration default bug | Yes: a test running migrations, or lint | Low | RETIRE (ordinary test) |
| structure-gate (252 / 168 +143) | Directory case, catch-all dirs, test placement, Express root, component pairing | Layout drift | Partly (eslint-plugin-boundaries/import rules, project lint) | High (R-311/312/324 100% fixture noise; R-319 FP on Next.js) | MODIFY: keep catch-all/utils dir deny only (matches owner rule), warnings for rest or RETIRE |
| content-gate (112 / 50 +143) | No .skip/.only, no TLS/CORS/CSP weakening, no escaping imports | Test suppression, weakened protection | Yes: eslint no-only-tests/no-disabled-tests; semgrep for TLS/CORS | Medium | MODIFY: move into lint + semgrep pack, delete hook |
| dependency-add-guard (42 / 129) | Ask on new third-party dependency | Supply chain, convenience deps | Partly (Dependabot/review) | Low (4 real asks) | KEEP (small, cheap; shrink fixture) |
| mcp-action-guard (152 / 179) | Ask before mutating MCP call | Sends/deletes through MCP | No (no other gate on MCP) | Medium: 174 real asks, 0 denies | KEEP, narrow to send/delete/transmit verbs |
| linear-todo-label-gate (87 / 117) | Deny moving a ticket to Todo without a label | Tracker hygiene (31 of 32 Todo tickets unlabeled) | Yes: fix the tracker config / one-time cleanup | Low | RETIRE |
| destructive-db-guard (MCP matcher) | same hook on mcp__ tools | Managed Postgres via MCP | No | Low | KEEP |

### PostToolUse
| Hook | Purpose | Failure prevented | Cheaper tier? | FP | Class |
|---|---|---|---|---|---|
| agent-watchdog-instruction (51 / shared 269) | Tell the model to start a watchdog | Silent stalled subagent | No hook can start it; model must act; the 165-line watchdog.sh plus TaskStop is a stateful subsystem | Low | RETIRE (reminder hook for a subsystem built for one incident); keep dispatch-guard at most |
| redact-output (103 / 31) | Warn after secret appears in output | Secret in transcript (cannot actually be removed: PostToolUse cannot rewrite) | No | Low | MODIFY/KEEP low priority (warning after the fact; documented "honest semantics") |
| draft-pr-on-first-push (338 / 272) | Opens a draft PR automatically (R-518) | Missing PR for pushed branch | Yes: agent opens PR; or CI | Medium: 52 errors, no catch | RETIRE |
| pr-monitor-reminder (53 / 81) | Tell model to turn on PR monitor | n/a | n/a | n/a | RETIRE (pure reminder) |
| new-file-header-reminder (30 / 89) | Nudge header comment on new files (R-320) | Style | Eslint file-header (exists) | Low | RETIRE |
| flat-directory-reminder (48 / 33) | Nudge regroup at >20 modules (R-310) | Style | Lint | Low | RETIRE |
| spec-glossary-check (70 / 249) | Remind spec docs to carry glossary and acceptance sections | Spec shape | Skill/template | Low | RETIRE (template belongs in the brainstorming skill) |
| handoff-check (139 / 118) | Remind handoff size/order | Handoff drift | Free-form handoff | Low | RETIRE |
| observability-reminder (76 / 91 +389) | Advisory for R-341/345/346 | Project-shape observability | Stack file, review | Low | RETIRE (never logs; no recorded effect) |
| dockerfile-reminder (121 / 97 +282) | Advisory R-351 | Missing Dockerfile | Review | Low | RETIRE |
| task-commit-reminder (22 / 44) | Remind commit per task (R-504) | Lost work | Agent habit | Low | RETIRE |
| task-state-tracker (199 / 230 +910) | Append-only task event log for resume | Interrupted-session task loss | Native TaskList/resume | n/a | RETIRE (stateful, feeds session-end handoff generator) |

### SessionStart / SessionEnd / Stop / ConfigChange / PreModelSwitch
| Hook | Purpose | Failure prevented | Cheaper tier? | FP | Class |
|---|---|---|---|---|---|
| harness-sync (228 / 306 +1,069) | Run sync.sh when live differs from checkout (R-003) | Cloud/laptop session without hooks; sync `--delete` incident | Plugin packaging or symlink | Medium (300 s timeout) | MODIFY (core delivery; replace copy-sync, hash manifest, generated ports) |
| session-start (611 / 647) | Inject INDEX + handoff | Lost context | Native memory/CLAUDE.md imports | Medium: 14 KB injected every session, handoff over cap | MODIFY: trim to INDEX pointer; drop SHA verification, retirement display |
| hookspath-drift-check (58 / 60) | Warn if core.hooksPath outside repo | Supply-chain | settings deny already blocks `git config core.hooksPath` | Low | RETIRE (duplicate of deny list + destructive-command-guard) |
| redaction-guard-check (67 / 28) | Verify secret hooks registered | Gate silently absent | doctor/CI | Low | RETIRE (gate protecting gate) |
| enforcement-guard-check (52 / 45 +810) | Verify manifest hooks registered both ways | Coverage drift | CI check | Low | RETIRE with the manifest |
| parallel-session-check (73 / 44) | Warn if another session edits same tree | Interleaved writes | git worktrees, native | Medium: 108 real warnings | RETIRE |
| hook-integrity-check (130 / 100 +809) | Compare live hooks to committed hash manifest | `exit 0` written into a guard | git blob hash vs sync source (audit's own proposal); warns only | Low, but drives 73% of commits | RETIRE manifest approach; if kept, git blob compare with no checked-in hash file |
| post-compact-rules (64 / 73) | Re-inject rules after compaction | Rules dropped on summary | CLAUDE.md reloads on compaction natively | Low | RETIRE or KEEP if CLAUDE.md does not auto-reload (verify first) |
| session-end (431 / 445 +889) | Route fired:/miss: memory lines, write resume snapshot, generate handoff Task state, metrics | Lost learnings, handoff drift | Manual handoff | Medium | RETIRE (stateful subsystem for bookkeeping) |
| verification-gate Stop/SubagentStop (369 / 431 +211, 660 s timeout) | Run project checks before turn may end | Turn ends on red suite | CI plus "run affected tests before pushing" | High: 320 real blocks, no recorded defect, transient failures, blocks deliberately-red slices | RETIRE (CI check is the right tier); or MODIFY to opt-in per repo |
| settings-change-guard (66 / 82) | Refuse a settings.json that drops a required hook or fails to parse | Typo drops a hook | JSON schema CI check | Low | RETIRE (gate protecting gate) |
| model-switch-guard (40 / 24) | Warn on model price step-up | Cost | Setting (opusplan) | Low (warn only, no ask channel) | RETIRE |

Summary: of 47 distinct hooks, KEEP about 8 (secret-scan, destructive-db-guard x2 matchers, codex-billing-guard, global-repo-push-guard, dependency-add-guard, mcp-action-guard, plus slimmed destructive-command-guard and git-workflow-guard), MODIFY about 8 (destructive-command-guard, git-workflow-guard, no-em-dash, conflict-markers, structure-gate, content-gate, harness-sync, session-start, redact-output, agent-dispatch-guard), RETIRE about 30. This matches the shape of claude/streamline's 15-registration set.

---

## 4. Rule classification

Key: REINSTATE (was cut or demoted; bring back as one line), KEEP, MODIFY, RETIRE. Per-rule one-line reasons.

### 4.1 CLAUDE.md mandatory lines
| Rule | Class | Reason |
|---|---|---|
| Budget line (1:1) | MODIFY | Keep principle; extend to count governance maintenance and fix rounds; drop the "exception" mechanism except security (bounded, see principles) |
| R-101 | KEEP | Irreversible harm; matches owner global Never rules |
| R-102 | KEEP | Merged secrets rule; trim to the global-rule wording (about 3 lines, not 1 long sentence) |
| R-104 | RETIRE | Manual, no recorded catch; fold the `[REDACTED]`/`[PII]` idea into R-102 in one clause |
| R-109 | MODIFY | Keep review practice and "test feeds control its insecure value"; replace ledger/range/strongest-model machinery with a CI semgrep job plus owner-read PR; bounded rounds |
| R-110 | MODIFY | Keep concept but two tiers decided by a short list; default standard (not "high when unsure"); drop owner tile per control and the plan `**Risk:**` line ceremony |
| R-201 | KEEP | Prompt-injection posture; also in owner global rules |
| R-203 | MODIFY | Keep "fix what fires, ask owner"; drop the "approved" keyword ritual and the gates that police gate bypass |
| R-204 | KEEP | Root cause, never weaken the gate (already merged with R-405) |
| R-211 | MODIFY | Keep "ask once, with a recommendation"; drop one-question-per-turn tile choreography and the long plan/merge-mode clause |
| R-308 | KEEP | Reuse first; unmechanizable and valuable (2 recorded misses) |
| R-401 | KEEP | One of three rules with a recorded real catch |
| R-403 | KEEP | Practice (reproduce first), line only; hook retired |
| R-514 | MODIFY | Owner merges security-touching PRs; everything else per a single repo setting; drop per-merge confirmation guard where GitHub branch protection can do it |
| R-517 | MODIFY | Keep one fresh-context review per PR scaled by risk (recorded catch); drop section grammar, range pinning, Codex naming |

### 4.2 Defaults index (grouped as in CLAUDE.md)
| Group | Class | Reason |
|---|---|---|
| R-003 harness sync | MODIFY | Needed as delivery, but it is the source of the structural tax (hash manifest, ports, copy sync) |
| R-105 | KEEP | Irreversible sends/deletes; hook is the rule |
| R-106 | KEEP | Public repo push is publishing |
| R-107 | RETIRE | Duplicated by settings deny list; warn-only hook |
| R-207 | MODIFY | Keep as prose preference; hook on Write/Edit only |
| R-507 | MODIFY | `git diff --check` in CI, not a harness hook |
| R-908 | KEEP | Money; simple hook |
| R-001, R-205 | MODIFY / REINSTATE | R-001 shrink to "read the handoff if one exists"; R-205 (verify "it exists" claims) is already an owner global rule: one-line REINSTATE |
| R-208, R-209, R-210 | MODIFY | Merge into one Writing block (as streamline does); R-209/R-210 conflict ("be short" vs "verbose") |
| R-212 | REINSTATE | One line "deliver what the turn asked; ask before widening"; the hook was right to go |
| R-214 | MODIFY | "Mention what you notice in the PR/report"; no ticket per finding, no commit refusal |
| R-301, 303, 307, 318, 325 to 329, 332 | MODIFY | Keep only what a linter cannot check, in stack CLAUDE-*.md; rest to project lint config |
| R-302, 306, 315 to 317 | KEEP (line) | One-line naming and dependency direction (streamline kept); RETIRE the LLM judge |
| R-320, R-334 | RETIRE | Header comments (reminder only) and aggregate-root naming (CI judge only, 139 tokens) |
| R-330 | MODIFY | Domain vocabulary belongs in brainstorming skill; no hook |
| R-331 | KEEP | Cheap ask on new dependency |
| R-304, 305, 309 to 314, 319, 321, 323, 324 | RETIRE as gates | Structure skill stays advisory; 100% fixture noise on R-311/312/324 |
| R-341 to 346, 351 | RETIRE (reminders) | Keep as CLAUDE-OBSERVABILITY.md text; reminder hooks never log and no recorded effect |
| R-361 to 364 | MODIFY | Keep text in CLAUDE-DATABASE.md; custom data-access checkers are bespoke linters: keep only if run in project CI |
| R-365 | KEEP | SQL from input is a security control |
| R-404 | MODIFY | Fold into R-204 ("reproduce before deploy") |
| R-406 | REINSTATE | Negative-input test per input handler; owner global rule and streamline keep it |
| R-407 | KEEP | Build-smoke for runtime assets, in TS convention file |
| R-410, R-411, R-412 | defer | TDD researcher; one-liner: lock only if retained on high-risk; the evidence is 331 denials, 0 product catches |
| R-501 | RETIRE | 108 warnings; worktrees solve it |
| R-504 | RETIRE | Reminder; agent habit |
| R-505 | RETIRE hook | Squash-merge makes branch subjects irrelevant; PR-title check in CI |
| R-508 | RETIRE | Reviewer concern |
| R-509 | MODIFY | Practice "run affected tests before pushing"; Stop gate retired, CI is the verifier (320 blocks, no defect) |
| R-512 | MODIFY | Squash-only as a GitHub ruleset, not a guard |
| R-513 | MODIFY | Keep one line; CI test failure already catches it |
| R-515 | RETIRE | Copilot review retired; over-resolution incident |
| R-516 | RETIRE | Governance-generating governance (manifest entry + fixture + closure for every rule) |
| R-518 | RETIRE | Hook that opens PRs (338 lines); agent can open one |
| R-601, R-602 | MODIFY | Free-form handoff, only when work is left open; drop SHA/size/section hooks and generated Task state |
| R-603, R-604 | MODIFY | Keep memory routing as one line; drop rule_fires/rule_misses routing |
| R-605 | MODIFY | Ticket optional; link in PR description if one exists |
| R-606 | RETIRE | Measured close fields have no consumer; `report risk` is process about process |
| R-607, R-608 | RETIRE as universal | Per-repo opt-in; docs/stack.md with six fields per dependency is a product-management preference |
| Tombstoned R-206, 213, 215, 322, 408, 409, 502, 503, 506, 510, 511, 906, 907 | KEEP deleted | No case to reinstate; delete tombstones too (they are bookkeeping) |
| Merged R-103, R-108, R-202 into R-102; R-405 into R-204 | KEEP | Fine |

### 4.3 Rulebook sections R-0xx/2xx/5xx/6xx/7xx/8xx/9xx (rulebook/agents.md, audits.md, cost.md)
| Rule | Class | Reason |
|---|---|---|
| R-701, R-702 dispatch prompt contents, worktree-first | MODIFY | Shrink to a shared prompt snippet; "paths not values" is good |
| R-703 canary agent first for N>=3 | RETIRE | Serial round trip with no recorded catch |
| R-704 inline under 5 tasks | KEEP | Aligns with cost; one line |
| R-705 gate impl on proven RED | defer (TDD) | High-risk only |
| R-706 50-tool-call cap | RETIRE | Manual, unobservable |
| R-707 fresh-context roles high-risk | defer (TDD) | One-liner: high-risk only |
| R-708 subagent watchdog (M, added 10-03) | MODIFY | Make dispatch-guard the only mechanism; drop watchdog script and instruction hook |
| R-801 audits on signal only | KEEP | Principle; hook retired |
| R-802 audits declare findings, never act | MODIFY | Findings go to the owner, no automatic tickets/remediation program |
| R-803 on-request roles | RETIRE | Six of nine audit agents never produced a report |
| R-804 audit finding discipline | MODIFY | Keep "paste evidence, mark fixes as hypotheses"; shorten |
| R-805 audit read restrictions | KEEP | Covered by secret rule |
| R-901 tier tags (trivial/standard/complex/saga) | RETIRE | Second classification beside R-110 risk; merge into one axis |
| R-902 inline brainstorm/spec/execute | KEEP | One line |
| R-903 model routing | KEEP | Cost; retire model-switch-guard |
| R-904 | RETIRE | Duplicates R-801 |
| R-905 retros only after incidents | KEEP | Consistent with budget |
| R-908 | KEEP | Money |
| R-0xx (R-001, R-003) | see 4.2 | |
| R-2xx (R-201..R-215) | see 4.1/4.2 | R-206, R-213, R-215 stay deleted |
| R-5xx, R-6xx | see 4.2 | |
| TDD/review/security (R-401, 403, 410 to 412, 509, 517, 109, 110) | one-liners above | Covered by other researchers |

---

## 5. Candidate anti-recursion principles (each tied to a failure above)

1. No recursive workflow restart. A fix, review finding, or rebase never reopens an earlier lifecycle stage. A fix is an ordinary commit with a test; a review covers the PR at the time it was approved, and later commits need a re-review only if they touch what the reviewer flagged or a security control. (Failure: head-pinned R-517 range; fix = full TDD slice; IAN-286 doc-only re-review; PR #15 base-merge 9 min; 8 rework rounds in PR #16.)
2. No governance-generated governance. A rule, hook, or review does not create tickets, ledgers, manifests, closure tests, or follow-up rules about itself. Findings go in the PR or final report; the owner decides whether anything is filed. (Failure: R-214, R-516 manifest + `# Covers:` closure, hook-hashes.txt, finding.sh value-rating, rule-text fixtures, `report risk`.)
3. Bounded review. At most one review round per PR by default; a second only for a HIGH or a security finding; the security exception is itself bounded (for example three rounds, stop at first round with nothing above LOW, then the owner decides). Reviewers do not review reviewers' output, and only one reviewer role applies to a change (the rulebook currently needs a precedence paragraph for five). (Failure: 7-round sync.sh review, 13 and 8 round reviews, four critic rounds on a scrubber.)
4. Proportional verification. Verification cost scales with the blast radius: CI is the verifier for lint/format/tests, a hook is for irreversible harm only, a stateful subsystem requires the owner's written approval. Never run the full suite twice per slice. (Failure: two 95 s full-suite runs per slice, R-509 Stop gate 320 blocks, TDD lock 331 denials.)
5. Order of preference is mandatory: compiler/formatter/linter, ordinary test, CI check, simple hook, stateful governance subsystem. A new gate must name the cheaper tier it was rejected from. (Failure: push-eslint/ruff/semgrep gates duplicating CI; commit-message-guard vs PR-title lint under squash; conflict-markers vs `git diff --check`; constant-change-guard vs failing tests.)
6. The five-question test before any new rule or hook (confirm this is the intended meaning): (a) what real failure did it prevent, with a citation; (b) which cheaper tier cannot catch it; (c) what is its false-positive rate on real work, not fixtures; (d) how many fixture lines (cap at 1x the hook's lines, no `# Covers:` closure); (e) which owner click or minute does it add per PR. If (a) has no citation, it is a default line, not a hook. (Failure: R-708 added mandatory within 24 h of the prune with 837 lines for one incident.)
7. Governance maintenance counts as process cost. Time spent on hooks, fixtures, hash/port regeneration, audits, proposals, and reforms is booked against the same 1:1 budget, measured per week; a maintenance share above a threshold (say 25% of commits in the harness repo) freezes new rules until it falls. (Failure: 73% of ag-main commits touch the hash manifest; 64% of fixes are self-plumbing; the 09-18 freeze recommendation was ignored; the prune itself was 200 files.)
8. Gates do not guard gates. Protection of the harness comes from one mechanism (file permissions/CODEOWNERS/required review on `~/.claude` source, plus settings deny rules), not integrity hooks, registration checks, ConfigChange guards, and closure tests, each of which needs its own fixtures. (Failure: hook-integrity-check warns only yet drives 73% of commits; enforcement-guard-check, redaction-guard-check, settings-change-guard.)
9. Measure outcomes on real work only. Telemetry excludes fixture runs by construction and a rule's keep/retire decision uses real-session denials plus recorded catches; no rule survives on "no data". Add a retirement clock: a default that has not fired or caught anything in 30 days is deleted, not demoted. (Failure: 99% of R-517 fires were fixture noise; 38 hooks never log; 13 rules deleted only after a full audit program.)
10. No mandatory rule from a single incident, and no rule/tombstone churn. One incident gets a default line or a memory entry; promotion to mandatory needs a second occurrence or irreversibility. Trial changes run as a slice-plan note for 2-3 sessions before becoming rule text (09-26 audit F4). Deleted rules lose their tombstones. (Failure: R-708, Codex reviewer reversed in 4.6 days, merge-on-green reversed in 11 h, 13 tombstones.)
11. Humans are not on the critical path of a gate. Any gate whose only exit is an owner click or manual file deletion is redesigned (ask must be answerable in place; no state file the agent cannot reset). (Failure: DISPUTE loop 5 h 18 min wait; 421 R-907 asks; 242 merge asks that "exist for understanding, not correctness".)
12. One classification axis per decision. Pick risk (R-110) or task tier, not both; one source of truth per rule (CLAUDE.md line or rulebook spec, not norm + spec + manifest + 2 generated ports + fixture). (Failure: tier vs risk both drive process; R-901 table duplicated; rule text in 5 places for TDD.)

---

## Caveats
- ag-main history begins at #127 (squash history), so pre-09-24 ratios use the predecessor repo and audit figures; those commit counts are from the audits, not recomputed.
- Fixture-line counts are by file-name match plus "mentions the hook's file name"; shared fixtures are double counted across hooks in the "mentioning" column, so treat those as upper bounds. Named-only counts are lower bounds.
- Hook FP numbers (real denials/asks) come from the IAN-568 proposal's noise-filtered telemetry (2026-09-15 to 10-02); 38 hooks never log so "no data" is not "no value".
- PR #187 was compared only as a reference point.
